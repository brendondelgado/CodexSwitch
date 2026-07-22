import CryptoKit
import Darwin
import Dispatch
import Foundation

struct SecureAtomicFileTransaction: Sendable {
    struct Generation: Equatable, Sendable {
        let value: String

        static let missing = Generation(value: "missing")
    }

    struct Snapshot: Equatable, Sendable {
        let bytes: Data?
        let generation: Generation
        fileprivate let identity: FileIdentity?

        static let missing = Snapshot(bytes: nil, generation: .missing, identity: nil)
    }

    struct TestHooks: Sendable {
        var afterLock: (@Sendable () throws -> Void)? = nil
        var beforeGenerationCheck: (@Sendable () throws -> Void)? = nil
        var beforeReadback: (@Sendable () throws -> Void)? = nil
    }

    struct LockedFile {
        fileprivate let transaction: SecureAtomicFileTransaction
        fileprivate let parentDescriptor: Int32

        func read(allowMissing: Bool = true) throws -> Snapshot {
            try transaction.read(parentDescriptor: parentDescriptor, allowMissing: allowMissing)
        }

        func replace(_ data: Data, expectedGeneration: Generation) throws -> Snapshot {
            try transaction.replace(
                data,
                expectedGeneration: expectedGeneration,
                parentDescriptor: parentDescriptor
            )
        }

        @discardableResult
        func remove(expectedGeneration: Generation) throws -> Snapshot {
            try transaction.remove(
                expectedGeneration: expectedGeneration,
                parentDescriptor: parentDescriptor
            )
        }
    }

    fileprivate struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    let path: String
    private let parentPath: String
    private let fileName: String
    private let lockFileName: String
    private let subject: String
    private let lockAcquisitionTimeout: TimeInterval
    private let lockRetryInterval: TimeInterval
    private let testHooks: TestHooks

    init(
        path: String,
        lockFileName: String? = nil,
        subject: String = "secure file",
        lockAcquisitionTimeout: TimeInterval = 1,
        lockRetryInterval: TimeInterval = 0.02,
        testHooks: TestHooks = TestHooks()
    ) {
        let expanded = NSString(string: path).expandingTildeInPath
        self.path = expanded
        self.parentPath = (expanded as NSString).deletingLastPathComponent
        self.fileName = (expanded as NSString).lastPathComponent
        self.lockFileName = lockFileName ?? "\((expanded as NSString).lastPathComponent).lock"
        self.subject = subject
        self.lockAcquisitionTimeout = lockAcquisitionTimeout.isFinite
            ? max(0, lockAcquisitionTimeout)
            : 1
        self.lockRetryInterval = lockRetryInterval.isFinite
            ? max(0.001, lockRetryInterval)
            : 0.02
        self.testHooks = testHooks
    }

    func withExclusiveLock<T>(_ operation: (LockedFile) throws -> T) throws -> T {
        try validateConfiguredPath()
        let parentDescriptor = try openOrCreateValidatedParentDirectory()
        defer { Darwin.close(parentDescriptor) }

        let lockPath = (parentPath as NSString).appendingPathComponent(lockFileName)
        let lockDescriptor = Darwin.openat(
            parentDescriptor,
            lockFileName,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard lockDescriptor >= 0 else {
            throw SecureAtomicFileError.lockFailed(path: lockPath, operation: "open", code: errno)
        }
        defer { Darwin.close(lockDescriptor) }

        let lockMetadata = try metadata(
            for: lockDescriptor,
            path: lockPath,
            operation: "fstat lock"
        )
        try validateRegularFile(lockMetadata, path: lockPath, requireSecureMode: false)
        guard fchmod(lockDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw SecureAtomicFileError.lockFailed(path: lockPath, operation: "chmod", code: errno)
        }
        try acquireExclusiveLock(lockDescriptor, path: lockPath)
        defer { _ = flock(lockDescriptor, LOCK_UN) }

        try testHooks.afterLock?()
        return try operation(LockedFile(transaction: self, parentDescriptor: parentDescriptor))
    }

    private func acquireExclusiveLock(_ descriptor: Int32, path: String) throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let maximumTimeout = TimeInterval(UInt64.max / 1_000_000_000)
        let timeoutNanoseconds = lockAcquisitionTimeout >= maximumTimeout
            ? UInt64.max
            : UInt64(lockAcquisitionTimeout * 1_000_000_000)
        let deadlineResult = startedAt.addingReportingOverflow(timeoutNanoseconds)
        let deadline = deadlineResult.overflow ? UInt64.max : deadlineResult.partialValue
        var isFirstAttempt = true
        while true {
            let beforeAttempt = DispatchTime.now().uptimeNanoseconds
            if !isFirstAttempt, beforeAttempt >= deadline {
                throw SecureAtomicFileError.lockTimedOut(
                    path: path,
                    timeout: lockAcquisitionTimeout
                )
            }
            isFirstAttempt = false

            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return
            }

            let code = errno
            if code == EINTR {
                continue
            }
            guard code == EWOULDBLOCK || code == EAGAIN else {
                throw SecureAtomicFileError.lockFailed(
                    path: path,
                    operation: "flock",
                    code: code
                )
            }

            let afterAttempt = DispatchTime.now().uptimeNanoseconds
            guard afterAttempt < deadline else {
                throw SecureAtomicFileError.lockTimedOut(
                    path: path,
                    timeout: lockAcquisitionTimeout
                )
            }
            let remaining = TimeInterval(deadline - afterAttempt) / 1_000_000_000
            Thread.sleep(forTimeInterval: min(lockRetryInterval, remaining))
        }
    }

    private func validateConfiguredPath() throws {
        guard path.hasPrefix("/"), !fileName.isEmpty, !lockFileName.isEmpty else {
            throw SecureAtomicFileError.unsafePath(path: path, reason: "path must be absolute")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("."), !components.contains("..") else {
            throw SecureAtomicFileError.unsafePath(path: path, reason: "dot traversal is not allowed")
        }
        guard parentPath != "/" else {
            throw SecureAtomicFileError.unsafePath(path: path, reason: "root cannot be the file parent")
        }
        guard !lockFileName.contains("/"), lockFileName != ".", lockFileName != ".." else {
            throw SecureAtomicFileError.unsafePath(path: path, reason: "lock name must be one path component")
        }
    }

    private func openOrCreateValidatedParentDirectory() throws -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SecureAtomicFileError.operationFailed(path: "/", operation: "open root", code: errno)
        }

        do {
            let rootMetadata = try metadata(for: descriptor, path: "/", operation: "fstat root")
            try validateDirectory(rootMetadata, path: "/", requireCurrentUser: false)
        } catch {
            Darwin.close(descriptor)
            throw error
        }

        let components = parentPath.split(separator: "/", omittingEmptySubsequences: true)
        for (index, component) in components.enumerated() {
            let isFinal = index == components.count - 1
            let name = String(component)
            let componentPath = "/" + components[...index].joined(separator: "/")
            var createdIdentity: FileIdentity?
            var nextDescriptor = Darwin.openat(
                descriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
                0
            )

            if nextDescriptor < 0, errno == ENOENT, isFinal {
                do {
                    createdIdentity = try createPrivateDirectory(
                        named: name,
                        path: componentPath,
                        parentDescriptor: descriptor
                    )
                } catch SecureAtomicFileError.operationFailed(_, "mkdir parent", EEXIST) {
                    createdIdentity = nil
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
                nextDescriptor = Darwin.openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
                    0
                )
            }

            guard nextDescriptor >= 0 else {
                let code = errno
                Darwin.close(descriptor)
                if code == ELOOP || code == ENOTDIR {
                    throw SecureAtomicFileError.unsafePath(
                        path: componentPath,
                        reason: "symlink traversal or a non-directory parent is not allowed"
                    )
                }
                throw SecureAtomicFileError.operationFailed(
                    path: componentPath,
                    operation: "open parent component",
                    code: code
                )
            }

            do {
                let directoryMetadata = try metadata(
                    for: nextDescriptor,
                    path: componentPath,
                    operation: "fstat parent component"
                )
                try validateDirectory(
                    directoryMetadata,
                    path: componentPath,
                    requireCurrentUser: isFinal
                )
                if let createdIdentity {
                    let openedIdentity = FileIdentity(
                        device: directoryMetadata.st_dev,
                        inode: directoryMetadata.st_ino
                    )
                    guard openedIdentity == createdIdentity else {
                        throw SecureAtomicFileError.unsafePath(
                            path: componentPath,
                            reason: "newly created directory identity changed before open"
                        )
                    }
                }
                if isFinal {
                    guard fchmod(nextDescriptor, mode_t(S_IRWXU)) == 0 else {
                        throw SecureAtomicFileError.operationFailed(
                            path: parentPath,
                            operation: "fchmod parent",
                            code: errno
                        )
                    }
                    let securedMetadata = try metadata(
                        for: nextDescriptor,
                        path: parentPath,
                        operation: "fstat secured parent"
                    )
                    try validateDirectory(
                        securedMetadata,
                        path: parentPath,
                        requireCurrentUser: true
                    )
                    guard securedMetadata.st_mode & mode_t(0o777) == mode_t(S_IRWXU) else {
                        throw SecureAtomicFileError.unsafePath(
                            path: parentPath,
                            reason: "file parent permissions must be 0700"
                        )
                    }
                }
            } catch {
                Darwin.close(nextDescriptor)
                Darwin.close(descriptor)
                throw error
            }

            Darwin.close(descriptor)
            descriptor = nextDescriptor
        }
        return descriptor
    }

    private func createPrivateDirectory(
        named name: String,
        path: String,
        parentDescriptor: Int32
    ) throws -> FileIdentity {
        guard mkdirat(parentDescriptor, name, mode_t(S_IRWXU)) == 0 else {
            throw SecureAtomicFileError.operationFailed(
                path: path,
                operation: "mkdir parent",
                code: errno
            )
        }

        var createdMetadata = stat()
        guard fstatat(parentDescriptor, name, &createdMetadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SecureAtomicFileError.operationFailed(
                path: path,
                operation: "fstatat new parent",
                code: errno
            )
        }
        try validateDirectory(createdMetadata, path: path, requireCurrentUser: true)
        let identity = FileIdentity(device: createdMetadata.st_dev, inode: createdMetadata.st_ino)

        guard fchmodat(parentDescriptor, name, mode_t(S_IRWXU), AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SecureAtomicFileError.operationFailed(
                path: path,
                operation: "fchmodat new parent",
                code: errno
            )
        }

        var securedMetadata = stat()
        guard fstatat(parentDescriptor, name, &securedMetadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SecureAtomicFileError.operationFailed(
                path: path,
                operation: "fstatat secured parent",
                code: errno
            )
        }
        guard FileIdentity(device: securedMetadata.st_dev, inode: securedMetadata.st_ino) == identity else {
            throw SecureAtomicFileError.unsafePath(
                path: path,
                reason: "newly created directory identity changed during permission repair"
            )
        }
        try validateDirectory(securedMetadata, path: path, requireCurrentUser: true)
        guard securedMetadata.st_mode & mode_t(0o777) == mode_t(S_IRWXU) else {
            throw SecureAtomicFileError.unsafePath(
                path: path,
                reason: "newly created file parent permissions must be 0700"
            )
        }
        return identity
    }

    private func read(parentDescriptor: Int32, allowMissing: Bool) throws -> Snapshot {
        let descriptor = Darwin.openat(
            parentDescriptor,
            fileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW,
            0
        )
        if descriptor < 0 {
            let code = errno
            if allowMissing, code == ENOENT {
                return .missing
            }
            throw SecureAtomicFileError.operationFailed(
                path: path,
                operation: "open \(subject)",
                code: code
            )
        }
        defer { Darwin.close(descriptor) }

        let fileMetadata = try metadata(
            for: descriptor,
            path: path,
            operation: "fstat \(subject)"
        )
        try validateRegularFile(fileMetadata, path: path, requireSecureMode: true)
        let data = try readAll(from: descriptor)
        return Snapshot(
            bytes: data,
            generation: Self.generation(of: data),
            identity: FileIdentity(device: fileMetadata.st_dev, inode: fileMetadata.st_ino)
        )
    }

    private func replace(
        _ data: Data,
        expectedGeneration: Generation,
        parentDescriptor: Int32
    ) throws -> Snapshot {
        let temporaryFileName = ".\(fileName).tmp-\(getpid())-\(UUID().uuidString)"
        let temporaryPath = (parentPath as NSString).appendingPathComponent(temporaryFileName)
        let temporaryDescriptor = Darwin.openat(
            parentDescriptor,
            temporaryFileName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard temporaryDescriptor >= 0 else {
            throw SecureAtomicFileError.operationFailed(
                path: temporaryPath,
                operation: "create temporary \(subject)",
                code: errno
            )
        }

        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporaryDescriptor)
            if shouldRemoveTemporary {
                _ = Darwin.unlinkat(parentDescriptor, temporaryFileName, 0)
            }
        }

        guard fchmod(temporaryDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw SecureAtomicFileError.operationFailed(
                path: temporaryPath,
                operation: "chmod temporary \(subject)",
                code: errno
            )
        }
        let temporaryMetadata = try metadata(
            for: temporaryDescriptor,
            path: temporaryPath,
            operation: "fstat temporary \(subject)"
        )
        try validateRegularFile(temporaryMetadata, path: temporaryPath, requireSecureMode: true)
        try writeAll(data, to: temporaryDescriptor, path: temporaryPath)
        try sync(
            descriptor: temporaryDescriptor,
            path: temporaryPath,
            operation: "fsync temporary \(subject)"
        )

        try testHooks.beforeGenerationCheck?()
        let current = try read(parentDescriptor: parentDescriptor, allowMissing: true)
        guard current.generation == expectedGeneration else {
            throw SecureAtomicFileError.staleGeneration(
                expected: expectedGeneration.value,
                actual: current.generation.value
            )
        }

        guard Darwin.renameat(parentDescriptor, temporaryFileName, parentDescriptor, fileName) == 0 else {
            throw SecureAtomicFileError.operationFailed(
                path: path,
                operation: "rename temporary \(subject)",
                code: errno
            )
        }
        shouldRemoveTemporary = false
        try sync(descriptor: parentDescriptor, path: parentPath, operation: "fsync parent")

        try testHooks.beforeReadback?()
        let readback = try read(parentDescriptor: parentDescriptor, allowMissing: false)
        guard readback.bytes == data, readback.generation == Self.generation(of: data) else {
            throw SecureAtomicFileError.readbackMismatch(path: path)
        }
        return readback
    }

    private func remove(
        expectedGeneration: Generation,
        parentDescriptor: Int32
    ) throws -> Snapshot {
        try testHooks.beforeGenerationCheck?()
        let current = try read(parentDescriptor: parentDescriptor, allowMissing: true)
        guard current.generation == expectedGeneration else {
            throw SecureAtomicFileError.staleGeneration(
                expected: expectedGeneration.value,
                actual: current.generation.value
            )
        }

        if let expectedIdentity = current.identity {
            var pathMetadata = stat()
            guard fstatat(parentDescriptor, fileName, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw SecureAtomicFileError.operationFailed(
                    path: path,
                    operation: "fstatat \(subject) before delete",
                    code: errno
                )
            }
            try validateRegularFile(pathMetadata, path: path, requireSecureMode: true)
            guard FileIdentity(device: pathMetadata.st_dev, inode: pathMetadata.st_ino) == expectedIdentity else {
                throw SecureAtomicFileError.staleGeneration(
                    expected: expectedGeneration.value,
                    actual: "identity-changed"
                )
            }
            guard Darwin.unlinkat(parentDescriptor, fileName, 0) == 0 else {
                throw SecureAtomicFileError.operationFailed(
                    path: path,
                    operation: "unlink \(subject)",
                    code: errno
                )
            }
        }

        try sync(descriptor: parentDescriptor, path: parentPath, operation: "fsync parent")
        try testHooks.beforeReadback?()
        let readback = try read(parentDescriptor: parentDescriptor, allowMissing: true)
        guard readback == .missing else {
            throw SecureAtomicFileError.readbackMismatch(path: path)
        }
        return readback
    }

    private func metadata(for descriptor: Int32, path: String, operation: String) throws -> stat {
        var result = stat()
        guard fstat(descriptor, &result) == 0 else {
            throw SecureAtomicFileError.operationFailed(path: path, operation: operation, code: errno)
        }
        return result
    }

    private func validateDirectory(
        _ metadata: stat,
        path: String,
        requireCurrentUser: Bool
    ) throws {
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw SecureAtomicFileError.unsafePath(path: path, reason: "expected a directory")
        }

        let currentUser = geteuid()
        if requireCurrentUser, metadata.st_uid != currentUser {
            throw SecureAtomicFileError.unsafePath(
                path: path,
                reason: "file parent is not owned by the current user"
            )
        }

        let writableByNonOwner = metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) != 0
        if metadata.st_uid == 0 {
            if writableByNonOwner, metadata.st_mode & mode_t(S_ISVTX) == 0 {
                throw SecureAtomicFileError.unsafePath(
                    path: path,
                    reason: "root-owned writable ancestor must have the sticky bit"
                )
            }
            return
        }

        if metadata.st_uid == currentUser {
            guard !writableByNonOwner else {
                throw SecureAtomicFileError.unsafePath(
                    path: path,
                    reason: "current-user ancestor grants group or other write access"
                )
            }
            return
        }

        throw SecureAtomicFileError.unsafePath(
            path: path,
            reason: "ancestor is owned by neither root nor the current user"
        )
    }

    private func validateRegularFile(
        _ metadata: stat,
        path: String,
        requireSecureMode: Bool
    ) throws {
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw SecureAtomicFileError.unsafePath(path: path, reason: "expected a regular file")
        }
        guard metadata.st_uid == geteuid() else {
            throw SecureAtomicFileError.unsafePath(path: path, reason: "file is not owned by the current user")
        }
        if requireSecureMode, metadata.st_mode & mode_t(0o077) != 0 {
            throw SecureAtomicFileError.unsafePath(
                path: path,
                reason: "file permissions must not grant group or other access"
            )
        }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer.prefix(Int(count)))
            } else if count == 0 {
                return result
            } else if errno != EINTR {
                throw SecureAtomicFileError.operationFailed(
                    path: path,
                    operation: "read \(subject)",
                    code: errno
                )
            }
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    throw SecureAtomicFileError.operationFailed(
                        path: path,
                        operation: "write temporary \(subject)",
                        code: EIO
                    )
                } else if errno != EINTR {
                    throw SecureAtomicFileError.operationFailed(
                        path: path,
                        operation: "write temporary \(subject)",
                        code: errno
                    )
                }
            }
        }
    }

    private func sync(descriptor: Int32, path: String, operation: String) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno != EINTR {
                throw SecureAtomicFileError.operationFailed(path: path, operation: operation, code: errno)
            }
        }
    }

    private static func generation(of data: Data) -> Generation {
        Generation(value: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

enum SecureAtomicFileError: Error, Equatable, LocalizedError {
    case lockFailed(path: String, operation: String, code: Int32)
    case lockTimedOut(path: String, timeout: TimeInterval)
    case operationFailed(path: String, operation: String, code: Int32)
    case unsafePath(path: String, reason: String)
    case staleGeneration(expected: String, actual: String)
    case readbackMismatch(path: String)

    var errorDescription: String? {
        switch self {
        case .lockFailed(let path, let operation, let code):
            return "Secure-file lock \(operation) failed for \(path): errno \(code)"
        case .lockTimedOut(let path, let timeout):
            return "Secure-file lock timed out after \(timeout) seconds for \(path)"
        case .operationFailed(let path, let operation, let code):
            return "Secure-file \(operation) failed for \(path): errno \(code)"
        case .unsafePath(let path, let reason):
            return "Unsafe secure-file path \(path): \(reason)"
        case .staleGeneration(let expected, let actual):
            return "Secure-file generation changed while locked: expected \(expected), found \(actual)"
        case .readbackMismatch(let path):
            return "Secure-file readback did not prove committed state for \(path)"
        }
    }
}
