import CryptoKit
import Darwin
import Foundation

enum CodexDesktopPathSecurity {
    static func lexicallyStandardized(_ url: URL) -> URL {
        var components: [Substring] = []
        for component in url.path.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        let path = "/" + components.joined(separator: "/")
        return URL(
            fileURLWithPath: path,
            isDirectory: url.hasDirectoryPath
        )
    }

    static func containsNoSymbolicLinkComponents(_ url: URL) -> Bool {
        let standardized = lexicallyStandardized(url)
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0,
                  (info.st_mode & S_IFMT) != S_IFLNK else {
                return false
            }
        }
        return true
    }

    static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = lexicallyStandardized(root).pathComponents
        let candidateComponents = lexicallyStandardized(candidate).pathComponents
        return candidateComponents.count > rootComponents.count
            && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = lexicallyStandardized(root).pathComponents
        let candidateComponents = lexicallyStandardized(candidate).pathComponents
        return candidateComponents.count >= rootComponents.count
            && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    static func ensureDirectoryExists(
        _ url: URL,
        permissions: mode_t = 0o700,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws {
        let standardized = lexicallyStandardized(url)
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else {
            throw pathError("Updater directory path must be absolute")
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw pathError("Could not open the filesystem root")
        }
        defer { _ = close(descriptor) }

        for component in standardized.pathComponents.dropFirst() {
            if isCancelled() { throw CancellationError() }
            var next = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            if next < 0, errno == ENOENT {
                if isCancelled() { throw CancellationError() }
                if mkdirat(descriptor, component, permissions) != 0, errno != EEXIST {
                    throw pathError("Could not create updater directory component")
                }
                next = openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard next >= 0 else {
                throw pathError("Updater directory contains an unsafe path component")
            }
            _ = close(descriptor)
            descriptor = next
        }
    }

    private static func pathError(_ message: String) -> NSError {
        NSError(
            domain: "CodexDesktopPathSecurity",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

final class CodexDesktopRetainedDirectoryPath: @unchecked Sendable {
    private struct Component {
        let name: String?
        let descriptor: Int32
        let identity: DesktopInstallPathIdentity
    }

    let url: URL
    let descriptor: Int32
    let identity: DesktopInstallPathIdentity
    private let components: [Component]

    init?(url: URL) {
        let standardized = CodexDesktopPathSecurity.lexicallyStandardized(url)
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else { return nil }
        var opened: [Component] = []
        var succeeded = false
        defer {
            if !succeeded {
                for component in opened { _ = close(component.descriptor) }
            }
        }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0, let root = Self.component(name: nil, descriptor: current) else {
            if current >= 0 { _ = close(current) }
            return nil
        }
        opened.append(root)
        for name in standardized.pathComponents.dropFirst() {
            current = openat(
                current,
                name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard current >= 0,
                  let component = Self.component(name: name, descriptor: current) else {
                if current >= 0 { _ = close(current) }
                return nil
            }
            opened.append(component)
        }
        guard let last = opened.last else { return nil }
        self.url = standardized
        self.descriptor = last.descriptor
        self.identity = last.identity
        self.components = opened
        succeeded = true
    }

    deinit {
        for component in components { _ = close(component.descriptor) }
    }

    func isCurrent() -> Bool {
        for (index, component) in components.enumerated() {
            var retained = stat()
            guard fstat(component.descriptor, &retained) == 0,
                  (retained.st_mode & S_IFMT) == S_IFDIR,
                  Self.identity(retained) == component.identity else {
                return false
            }
            guard index > 0, let name = component.name else { continue }
            var current = stat()
            guard fstatat(
                components[index - 1].descriptor,
                name,
                &current,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            (current.st_mode & S_IFMT) == S_IFDIR,
            Self.identity(current) == component.identity else {
                return false
            }
        }
        return true
    }

    private static func component(name: String?, descriptor: Int32) -> Component? {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return Component(name: name, descriptor: descriptor, identity: identity(info))
    }

    private static func identity(_ info: stat) -> DesktopInstallPathIdentity {
        DesktopInstallPathIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino)
        )
    }
}

enum CodexDesktopStagingWorkspace {
    static func withTemporaryDirectory<Result>(
        in root: URL,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled },
        perform: (URL) throws -> Result
    ) throws -> Result {
        if isCancelled() { throw CancellationError() }
        try CodexDesktopPathSecurity.ensureDirectoryExists(root, isCancelled: isCancelled)
        let directory = root.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        if isCancelled() { throw CancellationError() }
        try CodexDesktopPathSecurity.ensureDirectoryExists(directory, isCancelled: isCancelled)
        defer { try? fileManager.removeItem(at: directory) }
        if isCancelled() { throw CancellationError() }
        return try perform(directory)
    }
}

enum CodexDesktopTemporaryWorkspace {
    static let stagePrefix = "CodexSwitch-DesktopStage-"
    static let updatePrefix = "CodexSwitch-DesktopUpdate-"
    static let staleAge: TimeInterval = 24 * 60 * 60
    static let maximumDirectoriesPerRun = 8
    static let maximumEntriesPerDirectory = 50_000
    private static let ownerFileName = ".codexswitch-owner.json"

    private struct Owner: Codable {
        let processIdentifier: Int32
        let startedAt: Date
    }

    static func create(
        in root: URL,
        prefix: String,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        now: Date = Date(),
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> URL {
        guard [stagePrefix, updatePrefix].contains(prefix) else {
            throw workspaceError("Unknown desktop workspace prefix")
        }
        let directory = root.appendingPathComponent(
            "\(prefix)\(processIdentifier)-\(UUID().uuidString)",
            isDirectory: true
        )
        if isCancelled() { throw CancellationError() }
        try CodexDesktopPathSecurity.ensureDirectoryExists(directory, isCancelled: isCancelled)
        let owner = try JSONEncoder().encode(
            Owner(processIdentifier: processIdentifier, startedAt: now)
        )
        if isCancelled() {
            try? fileManager.removeItem(at: directory)
            throw CancellationError()
        }
        do {
            try owner.write(to: directory.appendingPathComponent(ownerFileName), options: .atomic)
            if isCancelled() { throw CancellationError() }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return directory
    }

    static func cleanupStaleDirectories(
        in root: URL,
        now: Date = Date(),
        staleAfter: TimeInterval = staleAge,
        maximumDirectories: Int = maximumDirectoriesPerRun,
        maximumEntries: Int = maximumEntriesPerDirectory,
        fileManager: FileManager = .default,
        processIsAlive: (Int32) -> Bool = isProcessAlive,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> CodexDesktopTemporaryWorkspaceCleanupReport {
        if isCancelled() { throw CancellationError() }
        guard maximumDirectories > 0, maximumEntries > 0,
              fileManager.fileExists(atPath: root.path) else {
            return CodexDesktopTemporaryWorkspaceCleanupReport(
                removedDirectoryCount: 0,
                reclaimedBytes: 0
            )
        }
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(root) else {
            throw workspaceError("Desktop workspace root contains a symbolic-link component")
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .creationDateKey,
            .contentModificationDateKey,
        ]
        let candidates = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants]
        ).compactMap { url -> (URL, Date)? in
            guard matchesOwnedPrefix(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let date = newestDate(values),
                  now.timeIntervalSince(date) >= staleAfter,
                  !hasLiveOrUnknownOwner(
                      in: url,
                      fileManager: fileManager,
                      processIsAlive: processIsAlive
                  ) else {
                return nil
            }
            return (url, date)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.lastPathComponent < $1.0.lastPathComponent
        }
        if isCancelled() { throw CancellationError() }

        var removed = 0
        var bytes: UInt64 = 0
        for (url, _) in candidates.prefix(maximumDirectories) {
            if isCancelled() { throw CancellationError() }
            guard let inspected = inspect(
                url,
                maximumEntries: maximumEntries,
                fileManager: fileManager,
                isCancelled: isCancelled
            ) else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed += 1
                bytes = adding(bytes, inspected)
            } catch {
                continue
            }
        }
        return CodexDesktopTemporaryWorkspaceCleanupReport(
            removedDirectoryCount: removed,
            reclaimedBytes: bytes
        )
    }

    private static func matchesOwnedPrefix(_ name: String) -> Bool {
        [stagePrefix, updatePrefix].contains { prefix in
            name.hasPrefix(prefix) && name.count > prefix.count
        }
    }

    private static func hasLiveOrUnknownOwner(
        in directory: URL,
        fileManager: FileManager,
        processIsAlive: (Int32) -> Bool
    ) -> Bool {
        let url = directory.appendingPathComponent(ownerFileName)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(url),
              let data = try? Data(contentsOf: url),
              let owner = try? JSONDecoder().decode(Owner.self, from: data),
              owner.processIdentifier > 0 else {
            return true
        }
        return processIsAlive(owner.processIdentifier)
    }

    private static func inspect(
        _ directory: URL,
        maximumEntries: Int,
        fileManager: FileManager,
        isCancelled: () -> Bool
    ) -> UInt64? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) else { return nil }
        var entries = 0
        var bytes: UInt64 = 0
        for case let item as URL in enumerator {
            if isCancelled() { return nil }
            entries += 1
            guard entries <= maximumEntries,
                  let values = try? item.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else {
                return nil
            }
            if values.isRegularFile == true {
                bytes = adding(bytes, UInt64(max(0, values.fileSize ?? 0)))
            }
        }
        return bytes
    }

    private static func newestDate(_ values: URLResourceValues) -> Date? {
        [values.creationDate, values.contentModificationDate].compactMap { $0 }.max()
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private static func isProcessAlive(_ processIdentifier: Int32) -> Bool {
        if kill(processIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func workspaceError(_ message: String) -> NSError {
        NSError(
            domain: "CodexDesktopTemporaryWorkspace",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

final class DesktopBundleTreeMutationGuard: @unchecked Sendable {
    private struct RetainedPath {
        let url: URL
        let descriptor: Int32
        let identity: DesktopInstallPathIdentity
    }

    private var retainedPaths: [RetainedPath] = []
    private var queueDescriptor: Int32 = -1

    init?(appURL: URL) {
        let appURL = CodexDesktopPathSecurity.lexicallyStandardized(appURL)
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(appURL) else {
            return nil
        }
        let openedQueue = kqueue()
        guard openedQueue >= 0 else { return nil }
        var openedPaths: [RetainedPath] = []
        var initializationSucceeded = false
        defer {
            if !initializationSucceeded {
                for path in openedPaths { _ = close(path.descriptor) }
                _ = close(openedQueue)
            }
        }

        var current = URL(fileURLWithPath: "/", isDirectory: true)
        let paths = [current] + appURL.pathComponents.dropFirst().map { component -> URL in
            current.appendPathComponent(component)
            return current
        }
        for path in paths {
            let descriptor = open(path.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { return nil }
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else {
                _ = close(descriptor)
                return nil
            }
            let identity = DesktopInstallPathIdentity(
                device: UInt64(bitPattern: Int64(info.st_dev)),
                inode: UInt64(info.st_ino)
            )
            var observedEvents = NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE
            if CodexDesktopPathSecurity.lexicallyStandardized(path) == appURL {
                observedEvents |= NOTE_WRITE | NOTE_EXTEND | NOTE_LINK
            }
            var change = kevent64_s(
                ident: UInt64(descriptor),
                filter: Int16(EVFILT_VNODE),
                flags: UInt16(EV_ADD | EV_CLEAR),
                fflags: UInt32(observedEvents),
                data: 0,
                udata: 0,
                ext: (0, 0)
            )
            guard Darwin.kevent64(openedQueue, &change, 1, nil, 0, 0, nil) == 0 else {
                _ = close(descriptor)
                return nil
            }
            openedPaths.append(
                RetainedPath(url: path, descriptor: descriptor, identity: identity)
            )
        }
        retainedPaths = openedPaths
        queueDescriptor = openedQueue
        initializationSucceeded = true
    }

    deinit {
        for path in retainedPaths { _ = close(path.descriptor) }
        if queueDescriptor >= 0 { _ = close(queueDescriptor) }
    }

    func observedMutation() -> Bool {
        for retained in retainedPaths {
            var pathInfo = stat()
            var descriptorInfo = stat()
            guard lstat(retained.url.path, &pathInfo) == 0,
                  (pathInfo.st_mode & S_IFMT) != S_IFLNK,
                  fstat(retained.descriptor, &descriptorInfo) == 0 else {
                return true
            }
            let pathIdentity = DesktopInstallPathIdentity(
                device: UInt64(bitPattern: Int64(pathInfo.st_dev)),
                inode: UInt64(pathInfo.st_ino)
            )
            let descriptorIdentity = DesktopInstallPathIdentity(
                device: UInt64(bitPattern: Int64(descriptorInfo.st_dev)),
                inode: UInt64(descriptorInfo.st_ino)
            )
            if pathIdentity != retained.identity || descriptorIdentity != retained.identity {
                return true
            }
        }

        var event = kevent64_s()
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        return Darwin.kevent64(queueDescriptor, nil, 0, &event, 1, 0, &timeout) > 0
    }
}

final class DesktopRetainedBundleTree: @unchecked Sendable {
    let parentDescriptor: Int32
    let rootDescriptor: Int32
    let name: String
    let rootIdentity: DesktopInstallPathIdentity
    private let retainedParentPath: CodexDesktopRetainedDirectoryPath?

    init?(
        parentDescriptor: Int32,
        name: String,
        retainedParentPath: CodexDesktopRetainedDirectoryPath? = nil
    ) {
        guard Self.isSimpleName(name) else { return nil }
        let retainedParent = fcntl(parentDescriptor, F_DUPFD_CLOEXEC, 0)
        guard retainedParent >= 0 else { return nil }
        let retainedRoot = openat(
            retainedParent,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard retainedRoot >= 0 else {
            _ = close(retainedParent)
            return nil
        }
        var info = stat()
        guard fstat(retainedRoot, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            _ = close(retainedRoot)
            _ = close(retainedParent)
            return nil
        }
        self.parentDescriptor = retainedParent
        self.rootDescriptor = retainedRoot
        self.name = name
        self.rootIdentity = Self.identity(info)
        self.retainedParentPath = retainedParentPath
    }

    convenience init?(appURL: URL) {
        let appURL = CodexDesktopPathSecurity.lexicallyStandardized(appURL)
        let parent = appURL.deletingLastPathComponent()
        guard appURL.isFileURL,
              !appURL.lastPathComponent.isEmpty,
              let retainedParentPath = CodexDesktopRetainedDirectoryPath(url: parent) else {
            return nil
        }
        self.init(
            parentDescriptor: retainedParentPath.descriptor,
            name: appURL.lastPathComponent,
            retainedParentPath: retainedParentPath
        )
    }

    deinit {
        _ = close(rootDescriptor)
        _ = close(parentDescriptor)
    }

    func isCurrent() -> Bool {
        isCurrent(named: name)
    }

    func isCurrent(named currentName: String) -> Bool {
        guard Self.isSimpleName(currentName) else { return false }
        guard retainedParentPath?.isCurrent() != false else { return false }
        var retained = stat()
        var current = stat()
        return fstat(rootDescriptor, &retained) == 0
            && fstatat(parentDescriptor, currentName, &current, AT_SYMLINK_NOFOLLOW) == 0
            && (current.st_mode & S_IFMT) == S_IFDIR
            && Self.identity(retained) == rootIdentity
            && Self.identity(current) == rootIdentity
    }

    private static func isSimpleName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func identity(_ info: stat) -> DesktopInstallPathIdentity {
        DesktopInstallPathIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino)
        )
    }
}

enum DesktopBundleTreeIntegrity {
    static let sealFormatVersion = 3
    static let maximumEntryCount = 200_000
    static let maximumByteCount: UInt64 = 16 * 1024 * 1024 * 1024
    static let maximumExtendedAttributeCount = 1_024
    static let maximumExtendedAttributeBytes = 64 * 1024 * 1024

    private struct TreeCapture {
        let portableContentSHA256: String
        let liveStateSHA256: String
        let sealFiles: [CodexDesktopStagedFileSeal]
        let entryCount: Int
        let byteCount: UInt64
    }

    private struct TreeWalkState {
        var contentHasher = SHA256()
        var liveStateHasher = SHA256()
        var sealFiles: [CodexDesktopStagedFileSeal] = []
        var entryCount = 0
        var byteCount: UInt64 = 0
        var paths = Set<String>()
        var symbolicLinks: [String: String] = [:]
    }

    private enum TreeEntryKind: UInt64 {
        case directory = 1
        case regularFile = 2
        case symbolicLink = 3
    }

    static func makeSeal(
        appURL: URL,
        validatedAt: Date,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool
    ) -> CodexDesktopStagedValidationSeal? {
        _ = fileManager
        guard let retained = DesktopRetainedBundleTree(appURL: appURL),
              let capture = stableCapture(retained: retained, isCancelled: isCancelled),
              !capture.sealFiles.isEmpty else { return nil }
        return CodexDesktopStagedValidationSeal(
            formatVersion: sealFormatVersion,
            validatedAt: validatedAt,
            files: capture.sealFiles
        )
    }

    static func isComplete(_ seal: CodexDesktopStagedValidationSeal?) -> Bool {
        guard let seal,
              seal.formatVersion == sealFormatVersion,
              !seal.files.isEmpty,
              seal.files.first?.relativePath == ".",
              seal.files == seal.files.sorted(by: { $0.relativePath < $1.relativePath }) else {
            return false
        }
        var paths = Set<String>()
        return seal.files.allSatisfy { file in
            !file.relativePath.isEmpty
                && paths.insert(file.relativePath).inserted
                && file.contentSHA256?.count == 64
                && file.posixPermissions != nil
        }
    }

    static func makeBundleIdentity(
        appURL: URL,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> DesktopInstallBundleIdentity? {
        _ = fileManager
        guard let retained = DesktopRetainedBundleTree(appURL: appURL) else { return nil }
        return makeBundleIdentity(retained: retained, isCancelled: isCancelled)
    }

    static func makeBundleIdentity(
        retained: DesktopRetainedBundleTree,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> DesktopInstallBundleIdentity? {
        makeBundleIdentities(retained: retained, isCancelled: isCancelled)?.bound
    }

    static func makeBundleIdentity(
        retained: DesktopRetainedBundleTree,
        boundAtName name: String,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> DesktopInstallBundleIdentity? {
        makeBundleIdentities(
            retained: retained,
            bindingName: name,
            isCancelled: isCancelled
        )?.bound
    }

    static func makePortableBundleIdentity(
        retained: DesktopRetainedBundleTree,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> DesktopInstallBundleIdentity? {
        makeBundleIdentities(retained: retained, isCancelled: isCancelled)?.portable
    }

    static func makeBundleIdentities(
        retained: DesktopRetainedBundleTree,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> (bound: DesktopInstallBundleIdentity, portable: DesktopInstallBundleIdentity)? {
        makeBundleIdentities(
            retained: retained,
            bindingName: nil,
            isCancelled: isCancelled
        )
    }

    private static func makeBundleIdentities(
        retained: DesktopRetainedBundleTree,
        bindingName: String?,
        isCancelled: () -> Bool
    ) -> (bound: DesktopInstallBundleIdentity, portable: DesktopInstallBundleIdentity)? {
        guard let capture = stableCapture(
            retained: retained,
            bindingName: bindingName,
            isCancelled: isCancelled
        ) else {
            return nil
        }
        let portable = DesktopInstallBundleIdentity(
            root: retained.rootIdentity,
            contentSHA256: capture.portableContentSHA256,
            entryCount: capture.entryCount,
            byteCount: capture.byteCount
        )
        let bound = DesktopInstallBundleIdentity(
            root: retained.rootIdentity,
            contentSHA256: boundDigest(
                portable: capture.portableContentSHA256,
                liveState: capture.liveStateSHA256
            ),
            entryCount: capture.entryCount,
            byteCount: capture.byteCount
        )
        return (bound, portable)
    }

    private static func stableCapture(
        retained: DesktopRetainedBundleTree,
        bindingName: String? = nil,
        isCancelled: () -> Bool
    ) -> TreeCapture? {
        let isCurrent = {
            bindingName.map { retained.isCurrent(named: $0) } ?? retained.isCurrent()
        }
        guard isCurrent(),
              let first = capture(retained: retained, isCancelled: isCancelled),
              isCurrent(),
              let second = capture(retained: retained, isCancelled: isCancelled),
              isCurrent(),
              first.portableContentSHA256 == second.portableContentSHA256,
              first.liveStateSHA256 == second.liveStateSHA256,
              first.sealFiles == second.sealFiles,
              first.entryCount == second.entryCount,
              first.byteCount == second.byteCount else {
            return nil
        }
        return second
    }

    private static func capture(
        retained: DesktopRetainedBundleTree,
        isCancelled: () -> Bool
    ) -> TreeCapture? {
        var state = TreeWalkState()
        guard walkDirectory(
            descriptor: retained.rootDescriptor,
            relativePath: ".",
            state: &state,
            isCancelled: isCancelled
        ), validateSymbolicLinks(state.symbolicLinks, paths: state.paths) else {
            return nil
        }
        let contentSHA256 = state.contentHasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        let liveStateSHA256 = state.liveStateHasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        state.sealFiles.sort { $0.relativePath < $1.relativePath }
        return TreeCapture(
            portableContentSHA256: contentSHA256,
            liveStateSHA256: liveStateSHA256,
            sealFiles: state.sealFiles,
            entryCount: state.entryCount,
            byteCount: state.byteCount
        )
    }

    private static func walkDirectory(
        descriptor: Int32,
        relativePath: String,
        state: inout TreeWalkState,
        isCancelled: () -> Bool
    ) -> Bool {
        if isCancelled() { return false }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFDIR,
              let metadata = metadata(descriptor: descriptor) else {
            return false
        }
        guard appendEntry(
            relativePath: relativePath,
            kind: .directory,
            info: before,
            metadata: metadata,
            payload: nil,
            payloadByteCount: 0,
            state: &state
        ), let names = directoryEntryNames(descriptor: descriptor) else {
            return false
        }
        for name in names {
            if isCancelled() { return false }
            let childPath = relativePath == "." ? name : "\(relativePath)/\(name)"
            var pathInfo = stat()
            guard fstatat(descriptor, name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                return false
            }
            switch pathInfo.st_mode & S_IFMT {
            case S_IFDIR:
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard child >= 0 else { return false }
                defer { _ = close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0,
                      sameObject(pathInfo, opened),
                      walkDirectory(
                          descriptor: child,
                          relativePath: childPath,
                          state: &state,
                          isCancelled: isCancelled
                      ) else {
                    return false
                }
            case S_IFREG:
                guard walkRegularFile(
                    parentDescriptor: descriptor,
                    name: name,
                    relativePath: childPath,
                    pathInfo: pathInfo,
                    state: &state,
                    isCancelled: isCancelled
                ) else { return false }
            case S_IFLNK:
                guard walkSymbolicLink(
                    parentDescriptor: descriptor,
                    name: name,
                    relativePath: childPath,
                    pathInfo: pathInfo,
                    state: &state
                ) else { return false }
            default:
                return false
            }
        }
        var after = stat()
        return fstat(descriptor, &after) == 0 && sameLiveState(before, after)
    }

    private static func walkRegularFile(
        parentDescriptor: Int32,
        name: String,
        relativePath: String,
        pathInfo: stat,
        state: inout TreeWalkState,
        isCancelled: () -> Bool
    ) -> Bool {
        let descriptor = openat(parentDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              sameObject(pathInfo, before),
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              let metadata = metadata(descriptor: descriptor),
              let contentDigest = digest(descriptor: descriptor, isCancelled: isCancelled) else {
            return false
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, sameLiveState(before, after) else { return false }
        return appendEntry(
            relativePath: relativePath,
            kind: .regularFile,
            info: before,
            metadata: metadata,
            payload: Data(contentDigest.utf8),
            payloadByteCount: UInt64(before.st_size),
            state: &state
        )
    }

    private static func walkSymbolicLink(
        parentDescriptor: Int32,
        name: String,
        relativePath: String,
        pathInfo: stat,
        state: inout TreeWalkState
    ) -> Bool {
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_SYMLINK
        )
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              sameObject(pathInfo, before),
              (before.st_mode & S_IFMT) == S_IFLNK,
              before.st_nlink == 1,
              let metadata = metadata(descriptor: descriptor),
              let target = symbolicLinkTarget(parentDescriptor: parentDescriptor, name: name),
              let normalizedTarget = normalizedSymbolicLinkTarget(
                  target,
                  from: relativePath
              ) else {
            return false
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, sameLiveState(before, after) else { return false }
        state.symbolicLinks[relativePath] = normalizedTarget
        return appendEntry(
            relativePath: relativePath,
            kind: .symbolicLink,
            info: before,
            metadata: metadata,
            payload: Data(target.utf8),
            payloadByteCount: UInt64(target.utf8.count),
            state: &state
        )
    }

    private struct EntryMetadata {
        let extendedAttributes: [(String, Data)]
        let accessControlList: Data
    }

    private static func metadata(descriptor: Int32) -> EntryMetadata? {
        guard let attributes = extendedAttributes(descriptor: descriptor),
              let acl = accessControlList(descriptor: descriptor) else {
            return nil
        }
        return EntryMetadata(extendedAttributes: attributes, accessControlList: acl)
    }

    private static func extendedAttributes(descriptor: Int32) -> [(String, Data)]? {
        let nameByteCount = flistxattr(descriptor, nil, 0, 0)
        guard nameByteCount >= 0,
              nameByteCount <= maximumExtendedAttributeBytes else {
            return nil
        }
        if nameByteCount == 0 { return [] }
        var names = [CChar](repeating: 0, count: Int(nameByteCount))
        let readNameBytes = names.withUnsafeMutableBufferPointer { buffer in
            flistxattr(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard readNameBytes == nameByteCount else { return nil }
        let rawNames = names.map { UInt8(bitPattern: $0) }.split(separator: 0)
        guard rawNames.count <= maximumExtendedAttributeCount else { return nil }
        var result: [(String, Data)] = []
        var totalBytes = 0
        for rawName in rawNames {
            guard let name = String(bytes: rawName, encoding: .utf8), !name.isEmpty else {
                return nil
            }
            let size = name.withCString { fgetxattr(descriptor, $0, nil, 0, 0, 0) }
            guard size >= 0, size <= maximumExtendedAttributeBytes else { return nil }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(Int(size))
            guard !overflow, nextTotal <= maximumExtendedAttributeBytes else { return nil }
            totalBytes = nextTotal
            var value = [UInt8](repeating: 0, count: Int(size))
            let readBytes = name.withCString { attributeName in
                value.withUnsafeMutableBytes { storage in
                    fgetxattr(
                        descriptor,
                        attributeName,
                        storage.baseAddress,
                        storage.count,
                        0,
                        0
                    )
                }
            }
            guard readBytes == size else { return nil }
            result.append((name, Data(value)))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    private static func accessControlList(descriptor: Int32) -> Data? {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == 0 || errno == ENOENT ? Data() : nil
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length),
              length >= 0,
              length <= maximumExtendedAttributeBytes else {
            return nil
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(text)) }
        return Data(bytes: text, count: Int(length))
    }

    private static func appendEntry(
        relativePath: String,
        kind: TreeEntryKind,
        info: stat,
        metadata: EntryMetadata,
        payload: Data?,
        payloadByteCount: UInt64,
        state: inout TreeWalkState
    ) -> Bool {
        state.entryCount += 1
        guard state.entryCount <= maximumEntryCount,
              state.paths.insert(relativePath).inserted else {
            return false
        }
        let (nextBytes, overflow) = state.byteCount.addingReportingOverflow(payloadByteCount)
        guard !overflow, nextBytes <= maximumByteCount else { return false }
        state.byteCount = nextBytes

        hashPortableEntry(
            relativePath: relativePath,
            kind: kind,
            info: info,
            metadata: metadata,
            payload: payload,
            payloadByteCount: payloadByteCount,
            hasher: &state.contentHasher
        )
        var entryHasher = SHA256()
        hashPortableEntry(
            relativePath: relativePath,
            kind: kind,
            info: info,
            metadata: metadata,
            payload: payload,
            payloadByteCount: payloadByteCount,
            hasher: &entryHasher
        )
        let entryDigest = entryHasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        guard payloadByteCount <= UInt64(Int64.max) else { return false }
        state.sealFiles.append(
            CodexDesktopStagedFileSeal(
                relativePath: relativePath,
                byteCount: Int64(payloadByteCount),
                modificationDate: Date(
                    timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                        + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
                ),
                contentSHA256: entryDigest,
                posixPermissions: UInt16(info.st_mode & 0o7777)
            )
        )

        updateHash(Data(relativePath.utf8), hasher: &state.liveStateHasher)
        updateHash(kind.rawValue, hasher: &state.liveStateHasher)
        updateHash(UInt64(bitPattern: Int64(info.st_dev)), hasher: &state.liveStateHasher)
        updateHash(UInt64(info.st_ino), hasher: &state.liveStateHasher)
        updateHash(UInt64(info.st_nlink), hasher: &state.liveStateHasher)
        if relativePath != "." {
            updateHash(UInt64(bitPattern: Int64(info.st_size)), hasher: &state.liveStateHasher)
            updateHash(
                UInt64(bitPattern: Int64(info.st_mtimespec.tv_sec)),
                hasher: &state.liveStateHasher
            )
            updateHash(
                UInt64(bitPattern: Int64(info.st_mtimespec.tv_nsec)),
                hasher: &state.liveStateHasher
            )
            updateHash(
                UInt64(bitPattern: Int64(info.st_ctimespec.tv_sec)),
                hasher: &state.liveStateHasher
            )
            updateHash(
                UInt64(bitPattern: Int64(info.st_ctimespec.tv_nsec)),
                hasher: &state.liveStateHasher
            )
        }
        return true
    }

    private static func hashPortableEntry(
        relativePath: String,
        kind: TreeEntryKind,
        info: stat,
        metadata: EntryMetadata,
        payload: Data?,
        payloadByteCount: UInt64,
        hasher: inout SHA256
    ) {
        updateHash(Data(relativePath.utf8), hasher: &hasher)
        updateHash(kind.rawValue, hasher: &hasher)
        updateHash(UInt64(info.st_mode), hasher: &hasher)
        updateHash(UInt64(info.st_uid), hasher: &hasher)
        updateHash(UInt64(info.st_gid), hasher: &hasher)
        updateHash(UInt64(info.st_flags), hasher: &hasher)
        updateHash(payloadByteCount, hasher: &hasher)
        updateHash(UInt64(metadata.extendedAttributes.count), hasher: &hasher)
        for (name, value) in metadata.extendedAttributes {
            updateHash(Data(name.utf8), hasher: &hasher)
            updateHash(value, hasher: &hasher)
        }
        updateHash(metadata.accessControlList, hasher: &hasher)
        updateHash(payload ?? Data(), hasher: &hasher)
    }

    private static func directoryEntryNames(descriptor: Int32) -> [String]? {
        let enumerationDescriptor = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard enumerationDescriptor >= 0,
              let directory = fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { _ = close(enumerationDescriptor) }
            return nil
        }
        defer { _ = closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            var tuple = entry.pointee.d_name
            let tupleSize = MemoryLayout.size(ofValue: tuple)
            guard let name = withUnsafePointer(to: &tuple, { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: tupleSize
                ) { String(validatingCString: $0) }
            }) else { return nil }
            if name == "." || name == ".." { continue }
            guard !name.isEmpty, !name.contains("/") else { return nil }
            names.append(name)
            guard names.count <= maximumEntryCount else { return nil }
        }
        guard errno == 0 else { return nil }
        let sorted = names.sorted()
        guard Set(sorted).count == sorted.count else { return nil }
        return sorted
    }

    private static func symbolicLinkTarget(
        parentDescriptor: Int32,
        name: String
    ) -> String? {
        var buffer = [CChar](repeating: 0, count: 64 * 1024)
        let count = buffer.withUnsafeMutableBufferPointer { storage in
            readlinkat(parentDescriptor, name, storage.baseAddress, storage.count)
        }
        guard count > 0, count < buffer.count else { return nil }
        let bytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func normalizedSymbolicLinkTarget(
        _ target: String,
        from relativePath: String
    ) -> String? {
        guard !target.isEmpty, !target.hasPrefix("/") else { return nil }
        var components = relativePath.split(separator: "/").dropLast().map(String.init)
        for component in target.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    private static func validateSymbolicLinks(
        _ symbolicLinks: [String: String],
        paths: Set<String>
    ) -> Bool {
        for target in symbolicLinks.values {
            var pending = normalizedComponents(target)
            var resolved: [String] = []
            var visitedExpansions = Set<String>()
            var expansionCount = 0
            while !pending.isEmpty {
                let component = pending.removeFirst()
                if component == "." { continue }
                resolved.append(component)
                let candidate = resolved.joined(separator: "/")
                guard let expandedTarget = symbolicLinks[candidate] else { continue }
                expansionCount += 1
                let state = candidate + "\u{0}" + pending.joined(separator: "/")
                guard expansionCount <= 64,
                      visitedExpansions.insert(state).inserted else {
                    return false
                }
                pending = normalizedComponents(expandedTarget) + pending
                resolved.removeAll(keepingCapacity: true)
            }
            let resolvedPath = resolved.isEmpty ? "." : resolved.joined(separator: "/")
            guard paths.contains(resolvedPath) else { return false }
        }
        return true
    }

    private static func normalizedComponents(_ path: String) -> [String] {
        path == "." ? [] : path.split(separator: "/").map(String.init)
    }

    private static func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }

    private static func updateHash(_ data: Data, hasher: inout SHA256) {
        updateHash(UInt64(data.count), hasher: &hasher)
        hasher.update(data: data)
    }

    private static func updateHash(_ value: UInt64, hasher: inout SHA256) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { bytes in
            hasher.update(data: Data(bytes))
        }
    }

    private static func boundDigest(portable: String, liveState: String) -> String {
        var hasher = SHA256()
        updateHash(Data("CodexSwitch.BundleTreeIdentity.v2".utf8), hasher: &hasher)
        updateHash(Data(portable.utf8), hasher: &hasher)
        updateHash(Data(liveState.utf8), hasher: &hasher)
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func digest(
        descriptor: Int32,
        isCancelled: () -> Bool
    ) -> String? {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { return nil }
        var hasher = SHA256()
        var bytes = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            if isCancelled() { return nil }
            let count = bytes.withUnsafeMutableBytes { storage in
                Darwin.read(descriptor, storage.baseAddress, storage.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                return nil
            }
            hasher.update(data: Data(bytes.prefix(Int(count))))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sameFileState(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mode == rhs.st_mode
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func sameLiveState(_ lhs: stat, _ rhs: stat) -> Bool {
        sameFileState(lhs, rhs)
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_flags == rhs.st_flags
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

enum DesktopRollbackPointerPublicationCheckpoint: Equatable, Sendable {
    case afterFileSyncBeforeRename
    case afterRenameBeforeDirectorySync
    case afterDirectorySync
}

private final class DesktopRetainedRollbackBundle {
    let root: DesktopRetainedInstallDirectory
    let generationDescriptor: Int32
    let generationName: String
    let generationIdentity: DesktopInstallPathIdentity
    let bundle: DesktopRetainedBundleTree

    init?(
        rollback: CodexDesktopRollbackGeneration,
        rootURL: URL,
        root: DesktopRetainedInstallDirectory
    ) {
        let rootURL = CodexDesktopPathSecurity.lexicallyStandardized(rootURL)
        let rawAppPath = rollback.appPath
        let appURL = CodexDesktopPathSecurity.lexicallyStandardized(
            URL(fileURLWithPath: rawAppPath)
        )
        let rootComponents = rootURL.pathComponents
        let appComponents = appURL.pathComponents
        let generationName = "\(CodexDesktopUpdateStorage.previousPrefix)"
            + rollback.generationIdentifier
        guard !rawAppPath.contains("\0"),
              rawAppPath == appURL.path,
              UUID(uuidString: rollback.generationIdentifier) != nil,
              appComponents.count == rootComponents.count + 2,
              appComponents.prefix(rootComponents.count).elementsEqual(rootComponents),
              appComponents[rootComponents.count] == generationName,
              Self.isSimpleName(generationName),
              Self.isSimpleName(appURL.lastPathComponent),
              (try? root.requireCurrent()) != nil else {
            return nil
        }
        let generationDescriptor = openat(
            root.descriptor,
            generationName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard generationDescriptor >= 0 else { return nil }
        var generationInfo = stat()
        guard fstat(generationDescriptor, &generationInfo) == 0,
              (generationInfo.st_mode & S_IFMT) == S_IFDIR,
              let bundle = DesktopRetainedBundleTree(
                  parentDescriptor: generationDescriptor,
                  name: appURL.lastPathComponent
              ) else {
            _ = close(generationDescriptor)
            return nil
        }
        self.root = root
        self.generationDescriptor = generationDescriptor
        self.generationName = generationName
        self.generationIdentity = Self.identity(generationInfo)
        self.bundle = bundle
    }

    deinit {
        _ = close(generationDescriptor)
    }

    func isCurrent() -> Bool {
        guard (try? root.requireCurrent()) != nil else { return false }
        var retainedGeneration = stat()
        var currentGeneration = stat()
        return fstat(generationDescriptor, &retainedGeneration) == 0
            && fstatat(
                root.descriptor,
                generationName,
                &currentGeneration,
                AT_SYMLINK_NOFOLLOW
            ) == 0
            && (currentGeneration.st_mode & S_IFMT) == S_IFDIR
            && Self.identity(retainedGeneration) == generationIdentity
            && Self.identity(currentGeneration) == generationIdentity
            && bundle.isCurrent()
    }

    private static func isSimpleName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func identity(_ info: stat) -> DesktopInstallPathIdentity {
        DesktopInstallPathIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino)
        )
    }
}

enum CodexDesktopUpdateStorage {
    static let manifestName = "staged-update.json"
    static let pendingManifestName = "pending-update.json"
    static let rollbackManifestName = "rollback-update.json"
    static let rejectedReleasesName = "rejected-releases.json"
    static let legacyStagedDirectoryName = "staged"
    static let generationPrefix = "generation-"
    static let stagingPrefix = ".staging-"
    static let previousPrefix = ".previous-"
    static let quarantinePrefix = ".quarantine-"
    static let manualPrefix = "manual-"
    static let partialArtifactRetentionAge: TimeInterval = 24 * 60 * 60
    static let retainedArtifactMaximumAge: TimeInterval = 7 * 24 * 60 * 60
    static let maximumCandidatesPerRun = 32
    static let maximumTopLevelEntriesPerRun = 256
    static let maximumRemovalsPerRun = 4
    static let maximumEntriesPerArtifact = 50_000
    static let maximumRetainedArtifactCount = 2
    static let maximumRetainedArtifactBytes: UInt64 = 2 * 1024 * 1024 * 1024
    static let maximumManifestBytes = 64 * 1024
    static let maximumRejectedReleaseCount = 8
    static let validationSealRecheckInterval: TimeInterval = 6 * 60 * 60
    static let rollbackFormatVersion = 2

    private enum ManifestState {
        case missing
        case loaded(CodexDesktopStagedUpdate)
        case malformed
    }

    private enum RollbackManifestState {
        case missing
        case loaded(CodexDesktopRollbackGeneration)
        case malformed
    }

    private enum ArtifactKind: Equatable {
        case partial
        case previous
        case generation
        case quarantine
        case manual(bundleVersion: String)
        case legacyStaged
    }

    private struct ArtifactCandidate {
        let url: URL
        let kind: ArtifactKind
        let newestDate: Date
        let byteCount: UInt64
        let identity: DesktopInstallPathIdentity
    }

    static func manifestURL(in root: URL) -> URL {
        root.appendingPathComponent(manifestName)
    }

    static func pendingManifestURL(in root: URL) -> URL {
        root.appendingPathComponent(pendingManifestName)
    }

    static func rollbackManifestURL(in root: URL) -> URL {
        root.appendingPathComponent(rollbackManifestName)
    }

    static func rejectedReleasesURL(in root: URL) -> URL {
        root.appendingPathComponent(rejectedReleasesName)
    }

    static func generationDirectory(in root: URL, identifier: String) -> URL {
        root.appendingPathComponent("\(generationPrefix)\(identifier)", isDirectory: true)
    }

    static func loadAuthoritativeUpdate(
        in root: URL,
        fileManager: FileManager = .default
    ) -> CodexDesktopStagedUpdate? {
        guard case .loaded(let update) = manifestState(
            at: manifestURL(in: root),
            fileManager: fileManager
        ) else { return nil }
        return update
    }

    static func loadPendingUpdate(
        in root: URL,
        fileManager: FileManager = .default
    ) -> CodexDesktopStagedUpdate? {
        guard case .loaded(let update) = manifestState(
            at: pendingManifestURL(in: root),
            fileManager: fileManager
        ) else { return nil }
        return update
    }

    static func loadRollbackGeneration(
        in root: URL,
        fileManager: FileManager = .default
    ) -> CodexDesktopRollbackGeneration? {
        guard let retainedRoot = try? DesktopRetainedInstallDirectory(url: root) else {
            return nil
        }
        return loadRollbackGeneration(
            in: root,
            retainedRoot: retainedRoot,
            fileManager: fileManager
        )
    }

    private static func loadRollbackGeneration(
        in root: URL,
        retainedRoot: DesktopRetainedInstallDirectory,
        fileManager: FileManager
    ) -> CodexDesktopRollbackGeneration? {
        guard case .loaded(let rollback) = rollbackManifestState(
            in: root,
            retainedRoot: retainedRoot,
            fileManager: fileManager
        ) else { return nil }
        return rollback
    }

    static func saveRollbackGeneration(
        _ rollback: CodexDesktopRollbackGeneration,
        in root: URL,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled },
        publicationCheckpoint: (DesktopRollbackPointerPublicationCheckpoint) throws -> Void = {
            _ in
        }
    ) throws {
        guard rollback.formatVersion == rollbackFormatVersion else {
            throw storageError("Rollback generation used an unsupported format")
        }
        if isCancelled() { throw CancellationError() }
        try ensureSafeRoot(root, isCancelled: isCancelled)
        let retainedRoot = try DesktopRetainedInstallDirectory(url: root)
        guard let retainedRollback = DesktopRetainedRollbackBundle(
            rollback: rollback,
            rootURL: root,
            root: retainedRoot
        ), retainedRollback.isCurrent(),
        let install = CodexDesktopAppLocator.locate(appPath: rollback.appPath),
        install.bundleVersion == rollback.bundleVersion,
        install.shortVersion == rollback.shortVersion,
        let currentIdentity = DesktopBundleTreeIntegrity.makeBundleIdentity(
            retained: retainedRollback.bundle,
            isCancelled: isCancelled
        ), currentIdentity == rollback.bundleIdentity else {
            throw storageError("Rollback generation must be contained and content-sealed")
        }
        let previous = loadRollbackGeneration(
            in: root,
            retainedRoot: retainedRoot,
            fileManager: fileManager
        )
        let retainedPrevious: DesktopRetainedRollbackBundle?
        if let previous {
            guard let retained = DesktopRetainedRollbackBundle(
                      rollback: previous,
                      rootURL: root,
                      root: retainedRoot
                  ), retained.isCurrent(),
                  DesktopBundleTreeIntegrity.makeBundleIdentity(
                      retained: retained.bundle,
                      isCancelled: isCancelled
                  ) == previous.bundleIdentity else {
                throw storageError("Former rollback generation changed before publication")
            }
            retainedPrevious = retained
        } else {
            retainedPrevious = nil
        }
        let data = try JSONEncoder().encode(rollback)
        guard data.count <= maximumManifestBytes else {
            throw storageError("Rollback generation manifest exceeded its size bound")
        }
        if isCancelled() { throw CancellationError() }
        try retainedRoot.replaceRegularFileAtomically(
            named: rollbackManifestName,
            data: data,
            beforeRename: {
                guard retainedRollback.isCurrent(),
                      DesktopBundleTreeIntegrity.makeBundleIdentity(
                          retained: retainedRollback.bundle,
                          isCancelled: isCancelled
                      ) == currentIdentity else {
                    throw storageError("Rollback generation changed before pointer publication")
                }
                try publicationCheckpoint(.afterFileSyncBeforeRename)
            },
            afterRenameBeforeDirectorySync: {
                try publicationCheckpoint(.afterRenameBeforeDirectorySync)
            }
        )
        try publicationCheckpoint(.afterDirectorySync)
        guard retainedRollback.isCurrent(),
              DesktopBundleTreeIntegrity.makeBundleIdentity(
            retained: retainedRollback.bundle,
            isCancelled: isCancelled
        ) == currentIdentity else {
            throw storageError("Rollback generation changed during pointer publication")
        }

        guard let previous,
              let retainedPrevious,
              previous.generationIdentifier != rollback.generationIdentifier,
              UUID(uuidString: previous.generationIdentifier) != nil else {
            return
        }
        let oldName = "\(previousPrefix)\(previous.generationIdentifier)"
        guard oldName != retainedRollback.generationName,
              retainedPrevious.isCurrent() else { return }
        try? retainedRoot.removeTree(
            named: oldName,
            expectedIdentity: retainedPrevious.generationIdentity
        )
    }

    static func saveAuthoritativeUpdate(
        _ staged: CodexDesktopStagedUpdate,
        in root: URL,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws {
        guard DesktopBundleTreeIntegrity.isComplete(staged.validationSeal),
              ownedDirectory(for: staged, in: root, fileManager: fileManager) != nil else {
            throw storageError("Authoritative update must be contained and digest-sealed")
        }
        try writeManifest(
            staged,
            to: manifestURL(in: root),
            root: root,
            fileManager: fileManager,
            isCancelled: isCancelled
        )
    }

    static func saveUnsealedAuthoritativeUpdateForMigration(
        _ staged: CodexDesktopStagedUpdate,
        in root: URL,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws {
        guard staged.validationSeal == nil,
              ownedDirectory(for: staged, in: root, fileManager: fileManager) != nil else {
            throw storageError("Legacy authoritative update must be unsealed and contained")
        }
        try writeManifest(
            staged,
            to: manifestURL(in: root),
            root: root,
            fileManager: fileManager,
            isCancelled: isCancelled
        )
    }

    static func savePendingUpdate(
        _ pending: CodexDesktopStagedUpdate,
        in root: URL,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws {
        guard pending.generationIdentifier != nil,
              pending.validationSeal == nil,
              ownedDirectory(for: pending, in: root, fileManager: fileManager) != nil else {
            throw storageError("Pending update must be an unsealed contained generation")
        }
        try writeManifest(
            pending,
            to: pendingManifestURL(in: root),
            root: root,
            fileManager: fileManager,
            isCancelled: isCancelled
        )
    }

    static func makeValidationSeal(
        for staged: CodexDesktopStagedUpdate,
        in root: URL,
        validatedAt: Date = Date(),
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> CodexDesktopStagedValidationSeal? {
        guard ownedDirectory(for: staged, in: root, fileManager: fileManager) != nil else {
            return nil
        }
        let app = CodexDesktopPathSecurity.lexicallyStandardized(
            URL(fileURLWithPath: staged.appPath)
        )
        return DesktopBundleTreeIntegrity.makeSeal(
            appURL: app,
            validatedAt: validatedAt,
            fileManager: fileManager,
            isCancelled: isCancelled
        )
    }

    static func resolveAuthoritativeGeneration(
        _ staged: CodexDesktopStagedUpdate,
        in root: URL,
        now: Date = Date(),
        fileManager: FileManager = .default,
        lifetime: DesktopUpdateOperationLifetime? = nil,
        isCancelled: () -> Bool = { Task.isCancelled },
        fullValidation: (URL, String, String) -> CodexDesktopBundleValidationResult
    ) -> CodexDesktopStagedGenerationResolution {
        guard structurallyMatches(staged, root: root, fileManager: fileManager) else {
            return .revoke("Staged desktop generation is incomplete or has the wrong build")
        }
        if isCancelled() { return .cancelled }
        if let seal = staged.validationSeal,
           DesktopBundleTreeIntegrity.isComplete(seal) {
            let sealAge = max(0, now.timeIntervalSince(seal.validatedAt))
            if sealAge < validationSealRecheckInterval {
                return isCancelled() ? .cancelled : .reuse(staged)
            }
            if let refreshedSeal = makeValidationSeal(
                for: staged,
                in: root,
                validatedAt: now,
                fileManager: fileManager,
                isCancelled: isCancelled
            ), refreshedSeal.files == seal.files {
                if isCancelled() { return .cancelled }
                let refreshed = replacingSeal(staged, seal: refreshedSeal)
                do {
                    try publishAuthoritativeUpdate(
                        refreshed,
                        in: root,
                        fileManager: fileManager,
                        lifetime: lifetime,
                        isCancelled: isCancelled
                    )
                    return .reuse(refreshed)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .preserveForRetry(error.localizedDescription)
                }
            }
        }
        let appURL = URL(fileURLWithPath: staged.appPath)
        guard let mutationGuard = DesktopBundleTreeMutationGuard(appURL: appURL),
              let baselineSeal = makeValidationSeal(
            for: staged,
            in: root,
            validatedAt: now,
            fileManager: fileManager,
            isCancelled: isCancelled
        ) else {
            return isCancelled() ? .cancelled : .revoke("Staged generation could not be digested")
        }
        let result = fullValidation(
            appURL,
            staged.bundleVersion,
            staged.shortVersion
        )
        if isCancelled() || result == .cancelled { return .cancelled }
        if mutationGuard.observedMutation() {
            return .revoke("Staged generation path identity changed during trust validation")
        }
        switch result {
        case .valid:
            guard let seal = makeValidationSeal(
                for: staged,
                in: root,
                validatedAt: now,
                fileManager: fileManager,
                isCancelled: isCancelled
            ), seal == baselineSeal else {
                return isCancelled()
                    ? .cancelled
                    : .revoke("Staged generation changed during trust validation")
            }
            if isCancelled() { return .cancelled }
            let sealed = replacingSeal(staged, seal: seal)
            do {
                try publishAuthoritativeUpdate(
                    sealed,
                    in: root,
                    fileManager: fileManager,
                    lifetime: lifetime,
                    isCancelled: isCancelled
                )
                return .reuse(sealed)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .preserveForRetry(error.localizedDescription)
            }
        case .invalid(let reason): return .revoke(reason)
        case .unavailable(let reason): return .preserveForRetry(reason)
        case .cancelled: return .cancelled
        }
    }

    static func resolvePendingGeneration(
        _ pending: CodexDesktopStagedUpdate,
        in root: URL,
        now: Date = Date(),
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled },
        fullValidation: (URL, String, String) -> CodexDesktopBundleValidationResult
    ) -> CodexDesktopPendingGenerationResolution {
        guard let current = loadPendingUpdate(in: root, fileManager: fileManager),
              sameGeneration(current, pending),
              pending.validationSeal == nil,
              structurallyMatches(pending, root: root, fileManager: fileManager) else {
            return .revoke("Pending desktop generation is incomplete or has the wrong build")
        }
        if isCancelled() { return .cancelled }
        let appURL = URL(fileURLWithPath: pending.appPath)
        guard let mutationGuard = DesktopBundleTreeMutationGuard(appURL: appURL),
              let baselineSeal = makeValidationSeal(
            for: pending,
            in: root,
            validatedAt: now,
            fileManager: fileManager,
            isCancelled: isCancelled
        ) else {
            return isCancelled() ? .cancelled : .revoke("Pending generation could not be digested")
        }
        let result = fullValidation(
            appURL,
            pending.bundleVersion,
            pending.shortVersion
        )
        if isCancelled() || result == .cancelled { return .cancelled }
        if mutationGuard.observedMutation() {
            return .revoke("Pending generation path identity changed during trust validation")
        }
        switch result {
        case .valid:
            guard let seal = makeValidationSeal(
                for: pending,
                in: root,
                validatedAt: now,
                fileManager: fileManager,
                isCancelled: isCancelled
            ), seal == baselineSeal else {
                return isCancelled()
                    ? .cancelled
                    : .revoke("Pending generation changed during trust validation")
            }
            return isCancelled() ? .cancelled : .ready(replacingSeal(pending, seal: seal))
        case .invalid(let reason): return .revoke(reason)
        case .unavailable(let reason): return .preserveForRetry(reason)
        case .cancelled: return .cancelled
        }
    }

    static func promotePendingUpdate(
        _ pending: CodexDesktopStagedUpdate,
        in root: URL,
        fileManager: FileManager = .default,
        lifetime: DesktopUpdateOperationLifetime? = nil,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws {
        if let lifetime {
            try lifetime.enter(.generationPublication, isCancelled: isCancelled)
            try lifetime.mutationAuthority.withMutation(
                at: [root],
                isCancelled: isCancelled
            ) {
                try promotePendingUpdate(
                    pending,
                    in: root,
                    fileManager: fileManager,
                    lifetime: nil,
                    isCancelled: { false }
                )
            }
            return
        }
        guard DesktopBundleTreeIntegrity.isComplete(pending.validationSeal),
              let current = loadPendingUpdate(in: root, fileManager: fileManager),
              sameGeneration(current, pending) else {
            throw storageError("Pending generation changed before promotion")
        }
        let previous = loadAuthoritativeUpdate(in: root, fileManager: fileManager)
        if isCancelled() { throw CancellationError() }
        // Publishing the authoritative pointer is the promotion commit boundary.
        // Complete pointer cleanup after this write without observing cancellation.
        try saveAuthoritativeUpdate(
            pending,
            in: root,
            fileManager: fileManager,
            isCancelled: isCancelled
        )
        try? fileManager.removeItem(at: pendingManifestURL(in: root))
        removeSupersededGeneration(previous, current: pending, in: root, fileManager: fileManager)
    }

    static func quarantineAuthoritativeUpdate(
        _ staged: CodexDesktopStagedUpdate,
        in root: URL,
        fileManager: FileManager = .default,
        identifier: String = UUID().uuidString,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> URL? {
        guard let current = loadAuthoritativeUpdate(in: root, fileManager: fileManager),
              sameGeneration(current, staged) else { return nil }
        if isCancelled() { throw CancellationError() }
        return try quarantine(
            staged,
            manifestURL: manifestURL(in: root),
            root: root,
            identifier: identifier,
            fileManager: fileManager,
            isCancelled: isCancelled
        )
    }

    static func quarantinePendingUpdate(
        _ pending: CodexDesktopStagedUpdate,
        in root: URL,
        fileManager: FileManager = .default,
        identifier: String = UUID().uuidString,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> URL? {
        guard let current = loadPendingUpdate(in: root, fileManager: fileManager),
              sameGeneration(current, pending) else { return nil }
        if isCancelled() { throw CancellationError() }
        if loadAuthoritativeUpdate(in: root, fileManager: fileManager).map({
            sameGeneration($0, pending)
        }) ?? false {
            if isCancelled() { throw CancellationError() }
            try fileManager.removeItem(at: pendingManifestURL(in: root))
            return nil
        }
        return try quarantine(
            pending,
            manifestURL: pendingManifestURL(in: root),
            root: root,
            identifier: identifier,
            fileManager: fileManager,
            isCancelled: isCancelled
        )
    }

    static func discardAuthoritativeUpdate(
        _ staged: CodexDesktopStagedUpdate,
        in root: URL,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) {
        discardReferenced(
            staged,
            manifestURL: manifestURL(in: root),
            root: root,
            preserveIfOtherManifestReferences: false,
            fileManager: fileManager,
            isCancelled: isCancelled
        )
    }

    static func discardPendingUpdate(
        _ pending: CodexDesktopStagedUpdate,
        in root: URL,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) {
        let alsoAuthoritative = loadAuthoritativeUpdate(in: root, fileManager: fileManager).map {
            sameGeneration($0, pending)
        } ?? false
        discardReferenced(
            pending,
            manifestURL: pendingManifestURL(in: root),
            root: root,
            preserveIfOtherManifestReferences: alsoAuthoritative,
            fileManager: fileManager,
            isCancelled: isCancelled
        )
    }

    static func discardUnreferencedGeneration(
        _ generation: CodexDesktopStagedUpdate,
        in root: URL,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) {
        guard !isCancelled(),
              generation.generationIdentifier != nil,
              !(loadAuthoritativeUpdate(in: root, fileManager: fileManager).map {
                  sameGeneration($0, generation)
              } ?? false),
              !(loadPendingUpdate(in: root, fileManager: fileManager).map {
                  sameGeneration($0, generation)
              } ?? false),
              let directory = ownedDirectory(
                  for: generation,
                  in: root,
                  fileManager: fileManager
              ) else { return }
        if isCancelled() { return }
        try? fileManager.removeItem(at: directory)
    }

    static func isRejectedRelease(
        _ release: CodexDesktopAppRelease,
        in root: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        loadRejectedReleases(in: root, fileManager: fileManager).contains {
            $0.matches(release)
        }
    }

    static func recordRejectedRelease(
        _ release: CodexDesktopAppRelease,
        reasonClass: DesktopRejectedReleaseReasonClass,
        in root: URL,
        now: Date = Date(),
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws {
        if isCancelled() { throw CancellationError() }
        guard let archiveSHA256 = release.archiveSHA256?.lowercased(),
              archiveSHA256.count == 64,
              archiveSHA256.allSatisfy(\.isHexDigit) else {
            return
        }
        var records = loadRejectedReleases(in: root, fileManager: fileManager)
        records.removeAll { $0.matches(release) }
        records.append(
            DesktopRejectedReleaseFingerprint(
                shortVersion: release.shortVersion,
                bundleVersion: release.bundleVersion,
                downloadURL: release.downloadURL,
                archiveSHA256: archiveSHA256,
                reasonClass: reasonClass,
                rejectedAt: now
            )
        )
        records = Array(records.suffix(maximumRejectedReleaseCount))
        let data = try JSONEncoder().encode(records)
        guard data.count <= maximumManifestBytes else {
            throw storageError("Rejected release ledger exceeded its size bound")
        }
        if isCancelled() { throw CancellationError() }
        try ensureSafeRoot(root, isCancelled: isCancelled)
        let destination = rejectedReleasesURL(in: root)
        try requireSafeManifestDestination(destination)
        if isCancelled() { throw CancellationError() }
        try data.write(to: destination, options: .atomic)
    }

    static func cleanupNonAuthoritativeArtifacts(
        in root: URL,
        installedBundleVersion: String?,
        now: Date = Date(),
        maximumCandidates: Int = maximumCandidatesPerRun,
        maximumTopLevelEntries: Int = maximumTopLevelEntriesPerRun,
        maximumRemovals: Int = maximumRemovalsPerRun,
        maximumEntries: Int = maximumEntriesPerArtifact,
        maximumRetainedCount: Int = maximumRetainedArtifactCount,
        maximumRetainedBytes: UInt64 = maximumRetainedArtifactBytes,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> CodexDesktopUpdateStorageCleanupReport {
        if isCancelled() { throw CancellationError() }
        guard maximumCandidates > 0, maximumTopLevelEntries > 0,
              maximumRemovals > 0, maximumEntries > 0,
              fileManager.fileExists(atPath: root.path) else {
            return CodexDesktopUpdateStorageCleanupReport(
                removedArtifactCount: 0,
                reclaimedBytes: 0
            )
        }
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(root) else {
            throw storageError("Desktop update root contains a symbolic-link component")
        }
        let authoritativeState = manifestState(at: manifestURL(in: root), fileManager: fileManager)
        let pendingState = manifestState(
            at: pendingManifestURL(in: root),
            fileManager: fileManager
        )
        let rollbackState = rollbackManifestState(in: root, fileManager: fileManager)
        var protectAllGenerations = false
        var protectAllRollbackGenerations = false
        let authoritative = protectedUpdate(
            authoritativeState,
            root: root,
            protectAll: &protectAllGenerations,
            fileManager: fileManager
        )
        let pending = protectedUpdate(
            pendingState,
            root: root,
            protectAll: &protectAllGenerations,
            fileManager: fileManager
        )
        let rollback: CodexDesktopRollbackGeneration?
        switch rollbackState {
        case .loaded(let loaded):
            rollback = loaded
        case .malformed:
            protectAllRollbackGenerations = true
            rollback = nil
        case .missing:
            rollback = nil
        }
        let protectedPaths = Set(
            [authoritative, pending].compactMap { $0 }.compactMap {
                ownedDirectory(for: $0, in: root, fileManager: fileManager)?.path
            } + [rollback?.appPath].compactMap { $0 }.map {
                CodexDesktopPathSecurity.lexicallyStandardized(
                    URL(fileURLWithPath: $0).deletingLastPathComponent()
                ).path
            }
        )

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .creationDateKey,
            .contentModificationDateKey,
        ]
        let topLevelNames = try DesktopUpdateBoundedRetentionFS.entryNames(
            in: root,
            maximumEntries: maximumTopLevelEntries
        )
        let topLevel = topLevelNames.compactMap { name -> (URL, ArtifactKind, Date)? in
            let url = root.appendingPathComponent(name, isDirectory: true)
            guard let kind = artifactKind(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let date = newestDate(values) else { return nil }
            return (CodexDesktopPathSecurity.lexicallyStandardized(url), kind, date)
        }.sorted {
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            return $0.0.lastPathComponent < $1.0.lastPathComponent
        }.prefix(maximumCandidates)
        if isCancelled() { throw CancellationError() }

        var candidates: [ArtifactCandidate] = []
        for (url, kind, _) in topLevel {
            if isCancelled() { throw CancellationError() }
            if protectedPaths.contains(url.path) { continue }
            if protectAllGenerations, kind == .generation || kind == .legacyStaged { continue }
            if protectAllRollbackGenerations, kind == .previous { continue }
            guard let inspection = inspectArtifact(
                url,
                maximumEntries: maximumEntries,
                fileManager: fileManager,
                isCancelled: isCancelled
            ), let identity = DesktopUpdateBoundedRetentionFS.identity(of: url) else { continue }
            candidates.append(
                ArtifactCandidate(
                    url: url,
                    kind: kind,
                    newestDate: inspection.date,
                    byteCount: inspection.bytes,
                    identity: identity
                )
            )
        }

        let newestVersion = [
            installedBundleVersion,
            authoritative?.bundleVersion,
            pending?.bundleVersion,
        ].compactMap { $0 }.max { $0.compare($1, options: .numeric) == .orderedAscending }
        let capacityEligible = candidates.sorted {
            if $0.newestDate != $1.newestDate { return $0.newestDate > $1.newestDate }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }
        var retainedCount = 0
        var retainedBytes: UInt64 = 0
        var overCapacity = Set<String>()
        for candidate in capacityEligible {
            let nextBytes = adding(retainedBytes, candidate.byteCount)
            if retainedCount >= max(0, maximumRetainedCount) || nextBytes > maximumRetainedBytes {
                overCapacity.insert(candidate.url.path)
            } else {
                retainedCount += 1
                retainedBytes = nextBytes
            }
        }

        let removable = candidates.filter { candidate in
            if overCapacity.contains(candidate.url.path) { return true }
            let age = now.timeIntervalSince(candidate.newestDate)
            switch candidate.kind {
            case .manual(let version):
                let obsolete = newestVersion.map {
                    $0.compare(version, options: .numeric) != .orderedAscending
                } ?? false
                return obsolete || age >= retainedArtifactMaximumAge
            case .quarantine:
                return age >= retainedArtifactMaximumAge
            case .partial, .previous, .generation, .legacyStaged:
                return age >= partialArtifactRetentionAge
            }
        }.sorted {
            if $0.newestDate != $1.newestDate { return $0.newestDate < $1.newestDate }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }

        var removed = 0
        var reclaimed: UInt64 = 0
        for candidate in removable.prefix(maximumRemovals) {
            if isCancelled() { throw CancellationError() }
            do {
                try DesktopUpdateBoundedRetentionFS.removeTree(
                    named: candidate.url.lastPathComponent,
                    from: root,
                    expectedIdentity: candidate.identity,
                    maximumEntries: maximumEntries + 1
                )
                removed += 1
                reclaimed = adding(reclaimed, candidate.byteCount)
            } catch {
                continue
            }
        }
        return CodexDesktopUpdateStorageCleanupReport(
            removedArtifactCount: removed,
            reclaimedBytes: reclaimed
        )
    }

    static func removeSupersededGeneration(
        _ previous: CodexDesktopStagedUpdate?,
        current: CodexDesktopStagedUpdate,
        in root: URL,
        fileManager: FileManager = .default
    ) {
        guard let previous,
              let old = ownedDirectory(for: previous, in: root, fileManager: fileManager),
              let new = ownedDirectory(for: current, in: root, fileManager: fileManager),
              old != new else { return }
        try? fileManager.removeItem(at: old)
    }

    private static func writeManifest(
        _ update: CodexDesktopStagedUpdate,
        to url: URL,
        root: URL,
        fileManager: FileManager,
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
        let data = try JSONEncoder().encode(update)
        guard data.count <= maximumManifestBytes else {
            throw storageError("Desktop update manifest exceeded its size bound")
        }
        if isCancelled() { throw CancellationError() }
        try ensureSafeRoot(root, isCancelled: isCancelled)
        try requireSafeManifestDestination(url)
        if isCancelled() { throw CancellationError() }
        try data.write(to: url, options: .atomic)
    }

    private static func publishAuthoritativeUpdate(
        _ update: CodexDesktopStagedUpdate,
        in root: URL,
        fileManager: FileManager,
        lifetime: DesktopUpdateOperationLifetime?,
        isCancelled: () -> Bool
    ) throws {
        guard let lifetime else {
            try saveAuthoritativeUpdate(
                update,
                in: root,
                fileManager: fileManager,
                isCancelled: isCancelled
            )
            return
        }
        try lifetime.enter(.generationPublication, isCancelled: isCancelled)
        try lifetime.mutationAuthority.withMutation(
            at: [manifestURL(in: root)],
            isCancelled: isCancelled
        ) {
            try saveAuthoritativeUpdate(
                update,
                in: root,
                fileManager: fileManager,
                isCancelled: { false }
            )
        }
    }

    private static func ensureSafeRoot(
        _ root: URL,
        isCancelled: () -> Bool
    ) throws {
        try CodexDesktopPathSecurity.ensureDirectoryExists(root, isCancelled: isCancelled)
    }

    private static func requireSafeManifestDestination(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw storageError("Could not inspect desktop update manifest destination")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw storageError("Desktop update manifest destination is not a regular file")
        }
    }

    private static func structurallyMatches(
        _ update: CodexDesktopStagedUpdate,
        root: URL,
        fileManager: FileManager
    ) -> Bool {
        guard ownedDirectory(for: update, in: root, fileManager: fileManager) != nil,
              let install = CodexDesktopAppLocator.locate(appPath: update.appPath) else {
            return false
        }
        return install.bundleVersion == update.bundleVersion
            && install.shortVersion == update.shortVersion
    }

    private static func ownedDirectory(
        for update: CodexDesktopStagedUpdate,
        in root: URL,
        fileManager: FileManager
    ) -> URL? {
        let root = CodexDesktopPathSecurity.lexicallyStandardized(root)
        let app = CodexDesktopPathSecurity.lexicallyStandardized(
            URL(fileURLWithPath: update.appPath)
        )
        guard CodexDesktopPathSecurity.isStrictDescendant(app, of: root),
              CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(root),
              CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(app) else {
            return nil
        }
        let rootCount = root.pathComponents.count
        let appComponents = app.pathComponents
        guard appComponents.count > rootCount else { return nil }
        let topName = appComponents[rootCount]
        if let identifier = update.generationIdentifier {
            guard UUID(uuidString: identifier) != nil,
                  topName == "\(generationPrefix)\(identifier)" else { return nil }
        } else {
            guard topName == legacyStagedDirectoryName else { return nil }
        }
        let directory = root.appendingPathComponent(topName, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? directory.resourceValues(forKeys: keys),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return nil }
        return directory
    }

    private static func manifestState(
        at url: URL,
        fileManager: FileManager
    ) -> ManifestState {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(url),
              let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= maximumManifestBytes,
              let data = try? Data(contentsOf: url),
              let update = try? JSONDecoder().decode(CodexDesktopStagedUpdate.self, from: data) else {
            return .malformed
        }
        return .loaded(update)
    }

    private static func rollbackManifestState(
        in root: URL,
        fileManager: FileManager
    ) -> RollbackManifestState {
        guard let retainedRoot = try? DesktopRetainedInstallDirectory(url: root) else {
            return fileManager.fileExists(atPath: root.path) ? .malformed : .missing
        }
        return rollbackManifestState(
            in: root,
            retainedRoot: retainedRoot,
            fileManager: fileManager
        )
    }

    private static func rollbackManifestState(
        in root: URL,
        retainedRoot: DesktopRetainedInstallDirectory,
        fileManager: FileManager
    ) -> RollbackManifestState {
        _ = fileManager
        let data: Data?
        do {
            data = try retainedRoot.readRegularFile(
                named: rollbackManifestName,
                maximumBytes: maximumManifestBytes
            )
        } catch {
            return .malformed
        }
        guard let data else { return .missing }
        guard let rollback = try? JSONDecoder().decode(
                  CodexDesktopRollbackGeneration.self,
                  from: data
              ),
              rollback.formatVersion == rollbackFormatVersion,
              let retainedRollback = DesktopRetainedRollbackBundle(
                  rollback: rollback,
                  rootURL: root,
                  root: retainedRoot
              ), retainedRollback.isCurrent(),
              let install = CodexDesktopAppLocator.locate(appPath: rollback.appPath),
              install.bundleVersion == rollback.bundleVersion,
              install.shortVersion == rollback.shortVersion,
              DesktopBundleTreeIntegrity.makeBundleIdentity(
                  retained: retainedRollback.bundle,
                  isCancelled: { false }
              ) == rollback.bundleIdentity,
              retainedRollback.isCurrent() else {
            return .malformed
        }
        return .loaded(rollback)
    }

    private static func protectedUpdate(
        _ state: ManifestState,
        root: URL,
        protectAll: inout Bool,
        fileManager: FileManager
    ) -> CodexDesktopStagedUpdate? {
        switch state {
        case .loaded(let update):
            guard ownedDirectory(for: update, in: root, fileManager: fileManager) != nil else {
                protectAll = true
                return nil
            }
            return update
        case .malformed:
            protectAll = true
            return nil
        case .missing:
            return nil
        }
    }

    private static func replacingSeal(
        _ update: CodexDesktopStagedUpdate,
        seal: CodexDesktopStagedValidationSeal
    ) -> CodexDesktopStagedUpdate {
        CodexDesktopStagedUpdate(
            shortVersion: update.shortVersion,
            bundleVersion: update.bundleVersion,
            downloadURL: update.downloadURL,
            appPath: update.appPath,
            stagedAt: update.stagedAt,
            generationIdentifier: update.generationIdentifier,
            validationSeal: seal,
            archiveSHA256: update.archiveSHA256,
            archiveLength: update.archiveLength
        )
    }

    private static func quarantine(
        _ update: CodexDesktopStagedUpdate,
        manifestURL: URL,
        root: URL,
        identifier: String,
        fileManager: FileManager,
        isCancelled: () -> Bool
    ) throws -> URL? {
        guard let source = ownedDirectory(for: update, in: root, fileManager: fileManager),
              fileManager.fileExists(atPath: source.path) else {
            if isCancelled() { throw CancellationError() }
            try fileManager.removeItem(at: manifestURL)
            return nil
        }
        let quarantine = root.appendingPathComponent(
            "\(quarantinePrefix)\(identifier)",
            isDirectory: true
        )
        guard UUID(uuidString: identifier) != nil,
              !fileManager.fileExists(atPath: quarantine.path),
              CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(root) else {
            throw storageError("Could not allocate quarantine")
        }
        if isCancelled() { throw CancellationError() }
        try fileManager.moveItem(at: source, to: quarantine)
        do {
            try fileManager.removeItem(at: manifestURL)
            return quarantine
        } catch {
            try? fileManager.moveItem(at: quarantine, to: source)
            throw error
        }
    }

    private static func discardReferenced(
        _ update: CodexDesktopStagedUpdate,
        manifestURL: URL,
        root: URL,
        preserveIfOtherManifestReferences: Bool,
        fileManager: FileManager,
        isCancelled: () -> Bool
    ) {
        guard !isCancelled() else { return }
        let directory = ownedDirectory(for: update, in: root, fileManager: fileManager)
        guard !isCancelled() else { return }
        do { try fileManager.removeItem(at: manifestURL) } catch { return }
        if let directory, !preserveIfOtherManifestReferences {
            try? fileManager.removeItem(at: directory)
        }
    }

    private static func sameGeneration(
        _ lhs: CodexDesktopStagedUpdate,
        _ rhs: CodexDesktopStagedUpdate
    ) -> Bool {
        lhs.bundleVersion == rhs.bundleVersion
            && lhs.appPath == rhs.appPath
            && lhs.generationIdentifier == rhs.generationIdentifier
    }

    private static func loadRejectedReleases(
        in root: URL,
        fileManager: FileManager
    ) -> [DesktopRejectedReleaseFingerprint] {
        let url = rejectedReleasesURL(in: root)
        guard fileManager.fileExists(atPath: url.path),
              CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(url),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size <= maximumManifestBytes,
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode(
                  [DesktopRejectedReleaseFingerprint].self,
                  from: data
              ) else { return [] }
        return Array(records.suffix(maximumRejectedReleaseCount))
    }

    private static func artifactKind(_ name: String) -> ArtifactKind? {
        if name == legacyStagedDirectoryName { return .legacyStaged }
        for (prefix, kind): (String, ArtifactKind) in [
            (stagingPrefix, .partial),
            (previousPrefix, .previous),
            (generationPrefix, .generation),
            (quarantinePrefix, .quarantine),
        ] where name.hasPrefix(prefix) {
            let suffix = String(name.dropFirst(prefix.count))
            if UUID(uuidString: suffix) != nil { return kind }
        }
        if name.hasPrefix(manualPrefix) {
            let version = String(name.dropFirst(manualPrefix.count))
            if !version.isEmpty, version.allSatisfy(\.isNumber) {
                return .manual(bundleVersion: version)
            }
        }
        return nil
    }

    private static func inspectArtifact(
        _ directory: URL,
        maximumEntries: Int,
        fileManager: FileManager,
        isCancelled: () -> Bool
    ) -> (date: Date, bytes: UInt64)? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .creationDateKey, .contentModificationDateKey,
        ]
        var enumerationFailed = false
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(directory),
              let rootValues = try? directory.resourceValues(forKeys: keys),
              let rootDate = newestDate(rootValues),
              let enumerator = fileManager.enumerator(
                  at: directory,
                  includingPropertiesForKeys: Array(keys),
                  errorHandler: { _, _ in
                      enumerationFailed = true
                      return false
                  }
              ) else { return nil }
        var date = rootDate
        var bytes: UInt64 = 0
        var entries = 0
        for case let item as URL in enumerator {
            if isCancelled() { return nil }
            entries += 1
            guard entries <= maximumEntries,
                  let values = try? item.resourceValues(forKeys: keys),
                  let itemDate = newestDate(values) else { return nil }
            date = max(date, itemDate)
            if values.isSymbolicLink == true {
                guard symbolicLinkStaysInside(
                    item,
                    artifactRoot: directory,
                    fileManager: fileManager
                ) else { return nil }
                enumerator.skipDescendants()
            } else if values.isRegularFile == true {
                bytes = adding(bytes, UInt64(max(0, values.fileSize ?? 0)))
            } else if values.isDirectory != true {
                return nil
            }
        }
        guard !enumerationFailed else { return nil }
        return (date, bytes)
    }

    private static func symbolicLinkStaysInside(
        _ link: URL,
        artifactRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
            return false
        }
        let destinationURL = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : link.deletingLastPathComponent().appendingPathComponent(destination)
        return CodexDesktopPathSecurity.isStrictDescendant(
            CodexDesktopPathSecurity.lexicallyStandardized(destinationURL),
            of: CodexDesktopPathSecurity.lexicallyStandardized(artifactRoot)
        )
    }

    private static func newestDate(_ values: URLResourceValues) -> Date? {
        [values.creationDate, values.contentModificationDate].compactMap { $0 }.max()
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private static func storageError(_ message: String) -> NSError {
        NSError(
            domain: "CodexDesktopUpdateStorage",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

enum CodexDesktopDownloadedGenerationCoordinator {
    static func prepare(
        release: CodexDesktopAppRelease,
        in root: URL,
        now: Date = Date(),
        fileManager: FileManager = .default,
        lifetime: DesktopUpdateOperationLifetime? = nil,
        isCancelled: () -> Bool = { Task.isCancelled },
        fullValidation: (URL, String, String) -> CodexDesktopBundleValidationResult,
        download: () async throws -> CodexDesktopStagedUpdate
    ) async throws -> CodexDesktopDownloadedGenerationPreparationResult {
        if isCancelled() { throw CancellationError() }
        let pending: CodexDesktopStagedUpdate
        if let existing = CodexDesktopUpdateStorage.loadPendingUpdate(
            in: root,
            fileManager: fileManager
        ), matches(existing, release: release) {
            pending = existing
        } else {
            if let obsolete = CodexDesktopUpdateStorage.loadPendingUpdate(
                in: root,
                fileManager: fileManager
            ) {
                if isCancelled() { throw CancellationError() }
                CodexDesktopUpdateStorage.discardPendingUpdate(
                    obsolete,
                    in: root,
                    fileManager: fileManager,
                    isCancelled: isCancelled
                )
                if isCancelled() { throw CancellationError() }
            }
            let downloaded = try await download()
            guard matches(downloaded, release: release), downloaded.validationSeal == nil else {
                try lifetime?.enter(.rejectionLedger, isCancelled: { false })
                try CodexDesktopUpdateStorage.recordRejectedRelease(
                    release,
                    reasonClass: .releaseMetadata,
                    in: root,
                    now: now,
                    fileManager: fileManager,
                    isCancelled: { false }
                )
                CodexDesktopUpdateStorage.discardUnreferencedGeneration(
                    downloaded,
                    in: root,
                    fileManager: fileManager,
                    isCancelled: { false }
                )
                throw DesktopDefinitiveReleaseRejection(
                    reason: "Downloaded generation metadata did not match release",
                    reasonClass: .releaseMetadata
                )
            }
            do {
                // The generation rename has already committed. Publish its only
                // pointer without observing cancellation, or remove it before
                // allowing the task to unwind.
                try withOwnedMutation(
                    lifetime: lifetime,
                    paths: [root],
                    isCancelled: { false }
                ) {
                    try CodexDesktopUpdateStorage.savePendingUpdate(
                        downloaded,
                        in: root,
                        fileManager: fileManager,
                        isCancelled: { false }
                    )
                }
            } catch {
                CodexDesktopUpdateStorage.discardUnreferencedGeneration(
                    downloaded,
                    in: root,
                    fileManager: fileManager,
                    isCancelled: { false }
                )
                throw error
            }
            pending = downloaded
            if isCancelled() { throw CancellationError() }
        }
        if isCancelled() { throw CancellationError() }
        try lifetime?.enter(.bundleVerification, isCancelled: isCancelled)
        switch CodexDesktopUpdateStorage.resolvePendingGeneration(
            pending,
            in: root,
            now: now,
            fileManager: fileManager,
            isCancelled: isCancelled,
            fullValidation: fullValidation
        ) {
        case .ready(let staged):
            if isCancelled() { throw CancellationError() }
            try CodexDesktopUpdateStorage.promotePendingUpdate(
                staged,
                in: root,
                fileManager: fileManager,
                lifetime: lifetime,
                isCancelled: isCancelled
            )
            return .staged(staged)
        case .preserveForRetry(let reason):
            return .pendingAssessment(pending, reason: reason)
        case .revoke(let reason):
            if isCancelled() { throw CancellationError() }
            try lifetime?.enter(.rejectionLedger, isCancelled: isCancelled)
            let reasonClass = DesktopBundleTrustValidator.rejectionClass(
                for: .invalid(reason)
            ) ?? .bundleStructure
            try CodexDesktopUpdateStorage.recordRejectedRelease(
                release,
                reasonClass: reasonClass,
                in: root,
                now: now,
                fileManager: fileManager,
                isCancelled: isCancelled
            )
            if isCancelled() { throw CancellationError() }
            _ = try CodexDesktopUpdateStorage.quarantinePendingUpdate(
                pending,
                in: root,
                fileManager: fileManager,
                isCancelled: isCancelled
            )
            throw DesktopDefinitiveReleaseRejection(
                reason: reason,
                reasonClass: reasonClass
            )
        case .cancelled:
            throw CancellationError()
        }
    }

    private static func matches(
        _ update: CodexDesktopStagedUpdate,
        release: CodexDesktopAppRelease
    ) -> Bool {
        update.matches(release)
    }

    private static func withOwnedMutation<Result>(
        lifetime: DesktopUpdateOperationLifetime?,
        paths: [URL],
        isCancelled: () -> Bool,
        operation: () throws -> Result
    ) throws -> Result {
        guard let lifetime else { return try operation() }
        return try lifetime.mutationAuthority.withMutation(
            at: paths,
            isCancelled: isCancelled,
            operation
        )
    }

}
