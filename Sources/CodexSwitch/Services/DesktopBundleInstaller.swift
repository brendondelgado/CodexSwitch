import Darwin
import Foundation

enum DesktopBundleInstallResult: Equatable, Sendable {
    case installed(cancellationDeferred: Bool, cleanupDeferred: Bool)
    case busy
    case runtimeRunning
    case cancelledBeforeCommit
}

enum DesktopInstallRecoveryResult: Equatable, Sendable {
    case none
    case busy
    case removedPrepared
    case completedCommit
    case rolledBack
    case deferred(String)
}

typealias DesktopBundleValidator = (
    URL,
    String,
    String,
    () -> Bool
) -> CodexDesktopBundleValidationResult

private func runDesktopBundleValidation(
    _ validator: DesktopBundleValidator,
    appURL: URL,
    bundleVersion: String,
    shortVersion: String,
    isCancelled: () -> Bool
) -> CodexDesktopBundleValidationResult {
    withoutActuallyEscaping(isCancelled) { cancellationCheck in
        validator(appURL, bundleVersion, shortVersion, cancellationCheck)
    }
}

final class DesktopRetainedInstallDirectory: @unchecked Sendable {
    static let maximumRemovalEntries = 250_000

    let url: URL
    let descriptor: Int32
    let identity: DesktopInstallPathIdentity
    private let retainedPath: CodexDesktopRetainedDirectoryPath

    init(url: URL) throws {
        let standardizedURL = CodexDesktopPathSecurity.lexicallyStandardized(url)
        guard let retainedPath = CodexDesktopRetainedDirectoryPath(url: standardizedURL) else {
            throw Self.directoryError("Install destination parent contains a symbolic link")
        }
        let openedDescriptor = fcntl(retainedPath.descriptor, F_DUPFD_CLOEXEC, 0)
        guard openedDescriptor >= 0 else {
            throw Self.directoryError("Could not retain install destination parent")
        }
        var info = stat()
        guard fstat(openedDescriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            _ = close(openedDescriptor)
            throw Self.directoryError("Install destination parent is not a directory")
        }
        self.url = standardizedURL
        self.descriptor = openedDescriptor
        self.identity = DesktopInstallPathIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino)
        )
        self.retainedPath = retainedPath
    }

    deinit {
        _ = close(descriptor)
    }

    func requireCurrent() throws {
        var descriptorInfo = stat()
        guard retainedPath.isCurrent(),
              fstat(descriptor, &descriptorInfo) == 0,
              Self.identity(descriptorInfo) == identity else {
            throw Self.directoryError("Install destination parent identity changed")
        }
    }

    func pathIdentity(named name: String) -> DesktopInstallPathIdentity? {
        guard Self.isSimpleName(name) else { return nil }
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              (info.st_mode & S_IFMT) != S_IFLNK else {
            return nil
        }
        return Self.identity(info)
    }

    func retainBundle(named name: String) throws -> DesktopRetainedBundleTree? {
        guard Self.isSimpleName(name) else {
            throw Self.directoryError("Install bundle name was invalid")
        }
        try requireCurrent()
        return DesktopRetainedBundleTree(parentDescriptor: descriptor, name: name)
    }

    func rename(from source: String, to destination: String) throws {
        guard Self.isSimpleName(source), Self.isSimpleName(destination) else {
            throw Self.directoryError("Install rename contained an invalid entry name")
        }
        try requireCurrent()
        guard renameat(descriptor, source, descriptor, destination) == 0 else {
            throw Self.directoryError("Atomic install rename failed (errno \(errno))")
        }
    }

    func swap(_ lhs: String, _ rhs: String) throws {
        guard Self.isSimpleName(lhs), Self.isSimpleName(rhs) else {
            throw Self.directoryError("Install swap contained an invalid entry name")
        }
        try requireCurrent()
        let result = lhs.withCString { lhsName in
            rhs.withCString { rhsName in
                renameatx_np(
                    descriptor,
                    lhsName,
                    descriptor,
                    rhsName,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw Self.directoryError("Atomic bundle swap failed (errno \(errno))")
        }
    }

    func synchronize() throws {
        try requireCurrent()
        guard fsync(descriptor) == 0 else {
            throw Self.directoryError("Could not synchronize install destination parent")
        }
    }

    func removeTree(
        named name: String,
        expectedIdentity: DesktopInstallPathIdentity?
    ) throws {
        guard Self.isSimpleName(name) else {
            throw Self.directoryError("Install cleanup contained an invalid entry name")
        }
        try requireCurrent()
        guard let current = pathIdentity(named: name) else { return }
        if let expectedIdentity, current != expectedIdentity {
            throw Self.directoryError("Install cleanup entry identity changed")
        }
        var remaining = Self.maximumRemovalEntries
        try Self.removeEntry(named: name, from: descriptor, remaining: &remaining)
        try synchronize()
    }

    func readRegularFile(named name: String, maximumBytes: Int) throws -> Data? {
        guard Self.isSimpleName(name), maximumBytes >= 0 else {
            throw Self.directoryError("Install journal read contained an invalid entry name")
        }
        try requireCurrent()
        let fileDescriptor = openat(descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fileDescriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Self.directoryError("Could not open install journal")
        }
        defer { _ = close(fileDescriptor) }

        var before = stat()
        guard fstat(fileDescriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= Int64(maximumBytes) else {
            throw Self.directoryError("Install journal is unsafe or too large")
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= maximumBytes {
            let count = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(fileDescriptor, storage.baseAddress, storage.count)
            }
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0, data.count + count <= maximumBytes else {
                throw Self.directoryError("Install journal changed or exceeded its size bound")
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
        var after = stat()
        var current = stat()
        guard fstat(fileDescriptor, &after) == 0,
              fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              Self.sameFileState(before, after),
              Self.identity(current) == Self.identity(after),
              data.count == Int(after.st_size) else {
            throw Self.directoryError("Install journal identity changed while it was read")
        }
        return data
    }

    func replaceRegularFileAtomically(
        named name: String,
        data: Data,
        permissions: mode_t = 0o600,
        beforeRename: () throws -> Void = {},
        afterRenameBeforeDirectorySync: () throws -> Void = {}
    ) throws {
        guard Self.isSimpleName(name) else {
            throw Self.directoryError("Install journal write contained an invalid entry name")
        }
        try requireCurrent()
        var existing = stat()
        if fstatat(descriptor, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG else {
                throw Self.directoryError("Install journal destination is not a regular file")
            }
        } else if errno != ENOENT {
            throw Self.directoryError("Could not inspect install journal destination")
        }

        let temporaryName = ".\(name)-\(UUID().uuidString).tmp"
        let temporaryDescriptor = openat(
            descriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            permissions
        )
        guard temporaryDescriptor >= 0 else {
            throw Self.directoryError("Could not create install journal temporary file")
        }
        var renamed = false
        defer {
            _ = close(temporaryDescriptor)
            if !renamed { _ = unlinkat(descriptor, temporaryName, 0) }
        }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { storage in
                Darwin.write(
                    temporaryDescriptor,
                    storage.baseAddress?.advanced(by: offset),
                    data.count - offset
                )
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else {
                throw Self.directoryError("Could not write install journal")
            }
            offset += written
        }
        guard fchmod(temporaryDescriptor, permissions) == 0,
              fsync(temporaryDescriptor) == 0 else {
            throw Self.directoryError("Could not synchronize install journal temporary file")
        }
        try beforeRename()
        try requireCurrent()
        var retainedTemporary = stat()
        var currentTemporary = stat()
        guard fstat(temporaryDescriptor, &retainedTemporary) == 0,
              retainedTemporary.st_nlink == 1,
              fstatat(
                  descriptor,
                  temporaryName,
                  &currentTemporary,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              (currentTemporary.st_mode & S_IFMT) == S_IFREG,
              Self.identity(retainedTemporary) == Self.identity(currentTemporary) else {
            throw Self.directoryError("Install journal temporary binding changed")
        }
        guard renameat(descriptor, temporaryName, descriptor, name) == 0 else {
            throw Self.directoryError("Could not commit install journal")
        }
        renamed = true
        var committed = stat()
        var retained = stat()
        guard fstat(temporaryDescriptor, &retained) == 0,
              fstatat(descriptor, name, &committed, AT_SYMLINK_NOFOLLOW) == 0,
              Self.identity(retained) == Self.identity(committed) else {
            throw Self.directoryError("Committed install journal identity changed")
        }
        try afterRenameBeforeDirectorySync()
        try synchronize()
    }

    func removeRegularFile(named name: String) throws {
        guard Self.isSimpleName(name) else {
            throw Self.directoryError("Install journal removal contained an invalid entry name")
        }
        try requireCurrent()
        let fileDescriptor = openat(descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fileDescriptor >= 0 else {
            if errno == ENOENT { return }
            throw Self.directoryError("Could not retain install journal for removal")
        }
        defer { _ = close(fileDescriptor) }
        var retained = stat()
        var current = stat()
        guard fstat(fileDescriptor, &retained) == 0,
              (retained.st_mode & S_IFMT) == S_IFREG,
              retained.st_nlink == 1,
              fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              Self.identity(retained) == Self.identity(current),
              unlinkat(descriptor, name, 0) == 0 else {
            throw Self.directoryError("Install journal identity changed before removal")
        }
        try synchronize()
    }

    private static func removeEntry(
        named name: String,
        from parentDescriptor: Int32,
        remaining: inout Int
    ) throws {
        guard remaining > 0 else {
            throw directoryError("Install cleanup exceeded its entry bound")
        }
        remaining -= 1
        var info = stat()
        guard fstatat(parentDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw directoryError("Could not inspect install cleanup entry")
        }
        if (info.st_mode & S_IFMT) != S_IFDIR {
            guard unlinkat(parentDescriptor, name, 0) == 0 else {
                throw directoryError("Could not remove install cleanup file")
            }
            return
        }

        let childDescriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard childDescriptor >= 0 else {
            throw directoryError("Could not open install cleanup directory")
        }
        let enumerationDescriptor = dup(childDescriptor)
        guard enumerationDescriptor >= 0, let directory = fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { _ = close(enumerationDescriptor) }
            _ = close(childDescriptor)
            throw directoryError("Could not enumerate install cleanup directory")
        }
        defer {
            _ = closedir(directory)
            _ = close(childDescriptor)
        }
        while let entry = readdir(directory) {
            var tuple = entry.pointee.d_name
            let tupleSize = MemoryLayout.size(ofValue: tuple)
            let childName = withUnsafePointer(to: &tuple) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: tupleSize
                ) { String(cString: $0) }
            }
            if childName == "." || childName == ".." { continue }
            try removeEntry(
                named: childName,
                from: childDescriptor,
                remaining: &remaining
            )
        }
        guard unlinkat(parentDescriptor, name, AT_REMOVEDIR) == 0 else {
            throw directoryError("Could not remove install cleanup directory")
        }
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

    private static func sameFileState(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mode == rhs.st_mode
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func directoryError(_ message: String) -> NSError {
        NSError(
            domain: "DesktopRetainedInstallDirectory",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

struct DesktopBundleInstaller: @unchecked Sendable {
    static let leaseFileName = ".desktop-install.lock"
    static let journalFileName = "desktop-install-journal.json"
    static let journalVersion = 4
    static let maximumJournalBytes = 64 * 1024

    private enum TransactionLayout: Equatable {
        case prepared
        case activated
        case committedClean
        case rolledBackClean
        case inconsistent
    }

    let transactionRoot: URL
    let fileManager: FileManager
    let processRunner: DesktopUpdaterProcessRunner
    let allowedDestinationPaths: Set<String>
    let beforeCommittedCleanup: () throws -> Void
    let beforeRollbackCommit: () throws -> Void
    let afterRollbackSwapBeforeVerification: () throws -> Void

    init(
        transactionRoot: URL,
        fileManager: FileManager = .default,
        processRunner: DesktopUpdaterProcessRunner = DesktopUpdaterProcessRunner(),
        allowedDestinations: [URL] = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/Codex.app"),
        ],
        beforeCommittedCleanup: @escaping () throws -> Void = {},
        beforeRollbackCommit: @escaping () throws -> Void = {},
        afterRollbackSwapBeforeVerification: @escaping () throws -> Void = {}
    ) {
        self.transactionRoot = CodexDesktopPathSecurity.lexicallyStandardized(transactionRoot)
        self.fileManager = fileManager
        self.processRunner = processRunner
        allowedDestinationPaths = Set(
            allowedDestinations.map {
                CodexDesktopPathSecurity.lexicallyStandardized($0).path
            }
        )
        self.beforeCommittedCleanup = beforeCommittedCleanup
        self.beforeRollbackCommit = beforeRollbackCommit
        self.afterRollbackSwapBeforeVerification = afterRollbackSwapBeforeVerification
    }

    func install(
        lifetime: DesktopUpdateOperationLifetime,
        sourceApp: URL,
        destination: URL,
        expectedBundleVersion: String,
        expectedShortVersion: String,
        kind: CodexDesktopInstallationTransactionKind,
        desktopRuntimeRunning: () -> Bool,
        isCancelled: () -> Bool = { Task.isCancelled },
        beforeAtomicCommit: () -> Void = {},
        validate: DesktopBundleValidator
    ) throws -> DesktopBundleInstallResult {
        if isCancelled() { return .cancelledBeforeCommit }
        return try withExtendedLifetime(lifetime) {
        let recovery = try recoverHoldingLease(
            desktopRuntimeRunning: desktopRuntimeRunning,
            validate: validate,
            isCancelled: isCancelled
        )
        switch recovery {
        case .none, .removedPrepared, .completedCommit, .rolledBack:
            break
        case .deferred(let reason):
            throw installerError("Pending desktop install recovery is deferred: \(reason)")
        case .busy:
            throw DesktopUpdateOwnershipError.permitMismatch
        }
        if isCancelled() { return .cancelledBeforeCommit }
        guard !desktopRuntimeRunning() else { return .runtimeRunning }

        let destination = CodexDesktopPathSecurity.lexicallyStandardized(destination)
        let sourceApp = CodexDesktopPathSecurity.lexicallyStandardized(sourceApp)
        let parent = destination.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path),
              allowedDestinationPaths.contains(destination.path),
              lifetime.mutationAuthority.permits(sourceApp),
              CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(parent),
              CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(sourceApp) else {
            throw installerError("Desktop install source or destination parent is unsafe")
        }
        let destinationDirectory = try DesktopRetainedInstallDirectory(url: parent)
        guard let retainedSource = DesktopRetainedBundleTree(appURL: sourceApp),
              let sourceIdentities = DesktopBundleTreeIntegrity.makeBundleIdentities(
                  retained: retainedSource,
                  isCancelled: isCancelled
              ) else {
            if isCancelled() { return .cancelledBeforeCommit }
            throw installerError("Desktop install source could not be pinned for copying")
        }
        if isCancelled() { return .cancelledBeforeCommit }
        let transactionIdentifier = UUID()
        let incoming = parent.appendingPathComponent(
            ".codexswitch-incoming-\(transactionIdentifier.uuidString).app",
            isDirectory: true
        )
        defer {
            if !fileManager.fileExists(atPath: journalURL.path) {
                try? destinationDirectory.removeTree(
                    named: incoming.lastPathComponent,
                    expectedIdentity: nil
                )
            }
        }

        if isCancelled() { return .cancelledBeforeCommit }
        let copyResult = processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: [sourceApp.path, incoming.path],
            timeout: 300,
            isCancelled: isCancelled
        )
        if copyResult.cancelled {
            try? destinationDirectory.removeTree(
                named: incoming.lastPathComponent,
                expectedIdentity: nil
            )
            return .cancelledBeforeCommit
        }
        guard !copyResult.timedOut, copyResult.terminationStatus == 0 else {
            try? destinationDirectory.removeTree(
                named: incoming.lastPathComponent,
                expectedIdentity: nil
            )
            throw installerError(commandFailure("Could not prepare incoming app", copyResult))
        }
        try destinationDirectory.requireCurrent()
        guard let finalSourceIdentities = DesktopBundleTreeIntegrity.makeBundleIdentities(
            retained: retainedSource,
            isCancelled: isCancelled
        ), finalSourceIdentities.bound == sourceIdentities.bound,
           finalSourceIdentities.portable == sourceIdentities.portable,
           let retainedIncoming = try destinationDirectory.retainBundle(
               named: incoming.lastPathComponent
           ), let incomingPortable = DesktopBundleTreeIntegrity.makePortableBundleIdentity(
               retained: retainedIncoming,
               isCancelled: isCancelled
           ), incomingPortable.hasSameContent(as: sourceIdentities.portable) else {
            try? destinationDirectory.removeTree(
                named: incoming.lastPathComponent,
                expectedIdentity: nil
            )
            if isCancelled() { return .cancelledBeforeCommit }
            throw installerError("Desktop install source changed while it was copied")
        }
        if isCancelled() {
            try? destinationDirectory.removeTree(
                named: incoming.lastPathComponent,
                expectedIdentity: nil
            )
            return .cancelledBeforeCommit
        }

        return try commitPreparedIncoming(
            incoming: incoming,
            destination: destination,
            destinationDirectory: destinationDirectory,
            transactionIdentifier: transactionIdentifier,
            expectedBundleVersion: expectedBundleVersion,
            expectedShortVersion: expectedShortVersion,
            kind: kind,
            desktopRuntimeRunning: desktopRuntimeRunning,
            isCancelled: isCancelled,
            beforeAtomicCommit: beforeAtomicCommit,
            validate: validate
        )
        }
    }

    func recover(
        lifetime: DesktopUpdateOperationLifetime,
        desktopRuntimeRunning: () -> Bool,
        isCancelled: () -> Bool = { Task.isCancelled },
        validate: DesktopBundleValidator
    ) throws -> DesktopInstallRecoveryResult {
        if isCancelled() { throw CancellationError() }
        return try withExtendedLifetime(lifetime) {
            try recoverHoldingLease(
                desktopRuntimeRunning: desktopRuntimeRunning,
                validate: validate,
                isCancelled: isCancelled
            )
        }
    }

    fileprivate func commitPreparedIncoming(
        incoming: URL,
        destination: URL,
        destinationDirectory: DesktopRetainedInstallDirectory,
        transactionIdentifier: UUID,
        expectedBundleVersion: String,
        expectedShortVersion: String,
        kind: CodexDesktopInstallationTransactionKind,
        desktopRuntimeRunning: () -> Bool,
        isCancelled: () -> Bool = { Task.isCancelled },
        beforeAtomicCommit: () -> Void = {},
        validate: DesktopBundleValidator
    ) throws -> DesktopBundleInstallResult {
        let incoming = CodexDesktopPathSecurity.lexicallyStandardized(incoming)
        let destination = CodexDesktopPathSecurity.lexicallyStandardized(destination)
        guard validTransactionPaths(destination: destination, incoming: incoming),
              fileManager.fileExists(atPath: incoming.path),
              CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(incoming) else {
            throw installerError("Prepared desktop install paths are unsafe")
        }
        try destinationDirectory.requireCurrent()
        guard !desktopRuntimeRunning() else { return .runtimeRunning }
        if isCancelled() { return .cancelledBeforeCommit }

        let preflight = runDesktopBundleValidation(
            validate,
            appURL: incoming,
            bundleVersion: expectedBundleVersion,
            shortVersion: expectedShortVersion,
            isCancelled: isCancelled
        )
        if isCancelled() || preflight == .cancelled { return .cancelledBeforeCommit }
        guard preflight == .valid else {
            throw installerError(validationFailure("Incoming desktop bundle", preflight))
        }
        guard !desktopRuntimeRunning() else { return .runtimeRunning }
        if isCancelled() { return .cancelledBeforeCommit }

        let destinationIdentity = destinationDirectory.pathIdentity(
            named: destination.lastPathComponent
        )
        let destinationExisted = destinationIdentity != nil
        guard let incomingIdentity = destinationDirectory.pathIdentity(
            named: incoming.lastPathComponent
        ) else {
            throw installerError("Prepared desktop install identities could not be recorded")
        }
        guard let incomingBundleIdentity = DesktopBundleTreeIntegrity.makeBundleIdentity(
            appURL: incoming,
            fileManager: fileManager,
            isCancelled: isCancelled
        ), incomingBundleIdentity.root == incomingIdentity else {
            throw installerError("Prepared desktop install content identity could not be recorded")
        }
        let previousDestinationIdentity: DesktopInstallPathIdentity?
        let previousDestinationBundleIdentity: DesktopInstallBundleIdentity?
        let previousBundleVersion: String?
        let previousShortVersion: String?
        if destinationExisted {
            guard let destinationIdentity,
                  let previousInstall = CodexDesktopAppLocator.locate(
                      appPath: destination.path
                  ),
                  let previousGuard = DesktopBundleTreeMutationGuard(appURL: destination),
                  let retainedPrevious = try destinationDirectory.retainBundle(
                      named: destination.lastPathComponent
                  ), retainedPrevious.rootIdentity == destinationIdentity else {
                throw installerError(
                    "Previous desktop bundle could not be retained for official trust validation"
                )
            }
            let previousValidation = runDesktopBundleValidation(
                validate,
                appURL: destination,
                bundleVersion: previousInstall.bundleVersion,
                shortVersion: previousInstall.shortVersion,
                isCancelled: isCancelled
            )
            if isCancelled() || previousValidation == .cancelled {
                return .cancelledBeforeCommit
            }
            guard previousValidation == .valid else {
                throw installerError(
                    validationFailure("Previous desktop bundle", previousValidation)
                )
            }
            guard !previousGuard.observedMutation(),
                  retainedPrevious.isCurrent(),
                  let bundleIdentity = DesktopBundleTreeIntegrity.makeBundleIdentity(
                      retained: retainedPrevious,
                      isCancelled: isCancelled
                  ), bundleIdentity.root == destinationIdentity else {
                throw installerError(
                    "Previous desktop bundle changed after official trust validation"
                )
            }
            previousDestinationIdentity = destinationIdentity
            previousDestinationBundleIdentity = bundleIdentity
            previousBundleVersion = previousInstall.bundleVersion
            previousShortVersion = previousInstall.shortVersion
        } else {
            previousDestinationIdentity = nil
            previousDestinationBundleIdentity = nil
            previousBundleVersion = nil
            previousShortVersion = nil
        }
        try ensureTransactionRoot()
        guard let transactionRootIdentity = Self.pathIdentity(at: transactionRoot) else {
            throw installerError("Install transaction root identity could not be retained")
        }
        if isCancelled() { return .cancelledBeforeCommit }
        let journal = DesktopInstallJournal(
            version: Self.journalVersion,
            transactionIdentifier: transactionIdentifier,
            kind: kind,
            destinationPath: destination.path,
            incomingPath: incoming.path,
            transactionRootIdentity: transactionRootIdentity,
            destinationDirectoryIdentity: destinationDirectory.identity,
            destinationExisted: destinationExisted,
            incomingIdentity: incomingIdentity,
            previousDestinationIdentity: previousDestinationIdentity,
            incomingBundleIdentity: incomingBundleIdentity,
            previousDestinationBundleIdentity: previousDestinationBundleIdentity,
            previousBundleVersion: previousBundleVersion,
            previousShortVersion: previousShortVersion,
            expectedBundleVersion: expectedBundleVersion,
            expectedShortVersion: expectedShortVersion,
            phase: .prepared,
            createdAt: Date()
        )
        if isCancelled() { return .cancelledBeforeCommit }
        try writeJournal(journal)

        if isCancelled() {
            try abandonPrepared(journal, directory: destinationDirectory)
            return .cancelledBeforeCommit
        }
        guard !desktopRuntimeRunning() else {
            try abandonPrepared(journal, directory: destinationDirectory)
            return .runtimeRunning
        }
        if isCancelled() {
            try abandonPrepared(journal, directory: destinationDirectory)
            return .cancelledBeforeCommit
        }

        beforeAtomicCommit()
        if isCancelled() {
            try abandonPrepared(journal, directory: destinationDirectory)
            return .cancelledBeforeCommit
        }
        guard !desktopRuntimeRunning() else {
            try abandonPrepared(journal, directory: destinationDirectory)
            return .runtimeRunning
        }

        // Atomic activation starts the non-cancellable transaction interval.
        // Commit is not irrevocable until the committed journal is durable.
        try atomicActivate(journal, directory: destinationDirectory)
        do {
            try destinationDirectory.synchronize()
            try writeJournal(journal.withPhase(.swapped))
            try writeJournal(journal.withPhase(.validating))
        } catch {
            let transactionError = error
            do {
                try rollback(journal, directory: destinationDirectory)
            } catch {
                throw installerError(
                    "Desktop activation bookkeeping failed "
                        + "(\(transactionError.localizedDescription)); "
                        + "atomic rollback also failed: \(error.localizedDescription)"
                )
            }
            throw transactionError
        }

        let postflight = validate(
            destination,
            expectedBundleVersion,
            expectedShortVersion,
            { false }
        )
        if postflight == .valid {
            let committedJournal: DesktopInstallJournal
            do {
                committedJournal = try durablyCommit(
                    journal,
                    directory: destinationDirectory
                )
            } catch {
                let commitError = error
                do {
                    try rollback(journal, directory: destinationDirectory)
                } catch {
                    throw installerError(
                        "Desktop commit could not be recorded "
                            + "(\(commitError.localizedDescription)); "
                            + "atomic rollback also failed: \(error.localizedDescription)"
                    )
                }
                throw commitError
            }

            // Once the committed journal is fsynced the new destination is
            // irrevocable. Cancellation, a newly running desktop process, or
            // cleanup failure leaves cleanup-only recovery state and must
            // never enter rollback.
            let cleanupDeferred: Bool
            if isCancelled() || desktopRuntimeRunning() {
                try? writeJournal(committedJournal.withPhase(.cleanupPending))
                cleanupDeferred = true
            } else {
                do {
                    try cleanupCommitted(
                        committedJournal,
                        directory: destinationDirectory,
                        validate: validate
                    )
                    cleanupDeferred = false
                } catch {
                    try? writeJournal(committedJournal.withPhase(.cleanupPending))
                    cleanupDeferred = true
                }
            }
            return .installed(
                cancellationDeferred: isCancelled(),
                cleanupDeferred: cleanupDeferred
            )
        }

        do {
            try rollback(journal, directory: destinationDirectory)
        } catch {
            throw installerError(
                "Installed desktop bundle failed validation (\(validationFailure("destination", postflight))); "
                    + "atomic rollback failed: \(error.localizedDescription)"
            )
        }
        throw installerError(
            "Installed desktop bundle failed validation and was rolled back: "
                + validationFailure("destination", postflight)
        )
    }

    private var journalURL: URL {
        transactionRoot.appendingPathComponent(Self.journalFileName)
    }

    private func recoverHoldingLease(
        desktopRuntimeRunning: () -> Bool,
        validate: DesktopBundleValidator,
        isCancelled: () -> Bool
    ) throws -> DesktopInstallRecoveryResult {
        guard let journal = try loadJournal() else { return .none }
        guard validJournal(journal) else {
            return .deferred("Install journal is malformed or contains unsafe paths")
        }
        let destination = CodexDesktopPathSecurity.lexicallyStandardized(
            URL(fileURLWithPath: journal.destinationPath)
        )
        let incoming = CodexDesktopPathSecurity.lexicallyStandardized(
            URL(fileURLWithPath: journal.incomingPath)
        )
        let directory = try DesktopRetainedInstallDirectory(
            url: destination.deletingLastPathComponent()
        )
        let layout = transactionLayout(journal, directory: directory)

        switch journal.phase {
        case .prepared:
            return try recoverPrepared(
                journal,
                destination: destination,
                incoming: incoming,
                layout: layout,
                directory: directory,
                desktopRuntimeRunning: desktopRuntimeRunning,
                isCancelled: isCancelled,
                validate: validate
            )
        case .swapped, .validating:
            return try recoverPotentialSwap(
                journal,
                destination: destination,
                incoming: incoming,
                layout: layout,
                directory: directory,
                desktopRuntimeRunning: desktopRuntimeRunning,
                validate: validate
            )
        case .rollback:
            return try recoverRollback(
                journal,
                incoming: incoming,
                layout: layout,
                directory: directory,
                desktopRuntimeRunning: desktopRuntimeRunning
            )
        case .committed, .cleanupPending:
            guard layout == .activated || layout == .committedClean else {
                return .deferred("Committed install journal does not match the activated bundle")
            }
            guard !desktopRuntimeRunning() else {
                return .deferred("Desktop runtime restarted before committed cleanup")
            }
            do {
                try cleanupCommitted(journal, directory: directory, validate: validate)
                return .completedCommit
            } catch {
                try? writeJournal(journal.withPhase(.cleanupPending))
                return .deferred("Committed desktop install cleanup remains incomplete")
            }
        }
    }

    private func recoverPrepared(
        _ journal: DesktopInstallJournal,
        destination: URL,
        incoming: URL,
        layout: TransactionLayout,
        directory: DesktopRetainedInstallDirectory,
        desktopRuntimeRunning: () -> Bool,
        isCancelled: () -> Bool,
        validate: DesktopBundleValidator
    ) throws -> DesktopInstallRecoveryResult {
        switch layout {
        case .prepared:
            if isCancelled() { throw CancellationError() }
            guard !desktopRuntimeRunning() else {
                return .deferred("Desktop runtime restarted before prepared cleanup")
            }
            try abandonPrepared(journal, directory: directory)
            return .removedPrepared
        case .activated:
            return try recoverActivated(
                journal,
                destination,
                directory: directory,
                desktopRuntimeRunning: desktopRuntimeRunning,
                validate: validate
            )
        case .committedClean:
            guard bundleIdentity(
                named: destination.lastPathComponent,
                directory: directory
            ) == journal.incomingBundleIdentity else {
                return .deferred("Prepared journal destination content identity changed")
            }
            let result = validate(
                destination,
                journal.expectedBundleVersion,
                journal.expectedShortVersion,
                { false }
            )
            guard result == .valid else {
                return .deferred(
                    "Prepared journal lost rollback state before validation completed"
                )
            }
            guard !desktopRuntimeRunning() else {
                return .deferred("Desktop runtime restarted before recovered commit")
            }
            return try recoverValidatedCommit(
                journal,
                directory: directory,
                desktopRuntimeRunning: desktopRuntimeRunning,
                validate: validate
            )
        case .rolledBackClean:
            guard !desktopRuntimeRunning() else {
                return .deferred("Desktop runtime restarted before journal cleanup")
            }
            try removeJournal()
            return .rolledBack
        case .inconsistent:
            return .deferred("Prepared install journal paths do not match recorded identities")
        }
    }

    private func recoverPotentialSwap(
        _ journal: DesktopInstallJournal,
        destination: URL,
        incoming: URL,
        layout: TransactionLayout,
        directory: DesktopRetainedInstallDirectory,
        desktopRuntimeRunning: () -> Bool,
        validate: DesktopBundleValidator
    ) throws -> DesktopInstallRecoveryResult {
        switch layout {
        case .activated:
            return try recoverActivated(
                journal,
                destination,
                directory: directory,
                desktopRuntimeRunning: desktopRuntimeRunning,
                validate: validate
            )
        case .prepared:
            guard !desktopRuntimeRunning() else {
                return .deferred("Desktop runtime restarted before rollback cleanup")
            }
            return try finishRollbackCleanup(
                journal,
                incoming: incoming,
                directory: directory
            )
        case .rolledBackClean:
            guard !desktopRuntimeRunning() else {
                return .deferred("Desktop runtime restarted before journal cleanup")
            }
            try removeJournal()
            return .rolledBack
        case .committedClean:
            guard bundleIdentity(
                named: destination.lastPathComponent,
                directory: directory
            ) == journal.incomingBundleIdentity else {
                return .deferred("Activated journal destination content identity changed")
            }
            let result = validate(
                destination,
                journal.expectedBundleVersion,
                journal.expectedShortVersion,
                { false }
            )
            guard result == .valid else {
                return .deferred("Activated bundle lost its recorded rollback identity")
            }
            guard !desktopRuntimeRunning() else {
                return .deferred("Desktop runtime restarted before recovered commit")
            }
            return try recoverValidatedCommit(
                journal,
                directory: directory,
                desktopRuntimeRunning: desktopRuntimeRunning,
                validate: validate
            )
        case .inconsistent:
            return .deferred("Activated install journal paths do not match recorded identities")
        }
    }

    private func recoverActivated(
        _ journal: DesktopInstallJournal,
        _ destination: URL,
        directory: DesktopRetainedInstallDirectory,
        desktopRuntimeRunning: () -> Bool,
        validate: DesktopBundleValidator
    ) throws -> DesktopInstallRecoveryResult {
        let result = validate(
            destination,
            journal.expectedBundleVersion,
            journal.expectedShortVersion,
            { false }
        )
        switch result {
        case .valid:
            guard bundleIdentity(
                named: destination.lastPathComponent,
                directory: directory
            ) == journal.incomingBundleIdentity else {
                guard !desktopRuntimeRunning() else {
                    return .deferred("Desktop runtime restarted before atomic rollback")
                }
                guard rollbackEvidenceIsCurrent(journal, directory: directory) else {
                    return .deferred("Previous desktop bundle content identity changed")
                }
                return recoverByRollingBack(journal, directory: directory)
            }
            guard !desktopRuntimeRunning() else {
                return .deferred("Desktop runtime restarted before recovered commit")
            }
            return try recoverValidatedCommit(
                journal,
                directory: directory,
                desktopRuntimeRunning: desktopRuntimeRunning,
                validate: validate
            )
        case .unavailable, .invalid, .cancelled:
            guard !desktopRuntimeRunning() else {
                return .deferred("Desktop runtime restarted before atomic rollback")
            }
            guard rollbackEvidenceIsCurrent(journal, directory: directory) else {
                return .deferred("Previous desktop bundle content identity changed")
            }
            return recoverByRollingBack(journal, directory: directory)
        }
    }

    private func recoverRollback(
        _ journal: DesktopInstallJournal,
        incoming: URL,
        layout: TransactionLayout,
        directory: DesktopRetainedInstallDirectory,
        desktopRuntimeRunning: () -> Bool
    ) throws -> DesktopInstallRecoveryResult {
        switch layout {
        case .activated:
            guard !desktopRuntimeRunning() else {
                return .deferred("Desktop runtime restarted before atomic rollback")
            }
            guard rollbackEvidenceIsCurrent(journal, directory: directory) else {
                return .deferred("Previous desktop bundle content identity changed")
            }
            return recoverByRollingBack(journal, directory: directory)
        case .prepared:
            guard !desktopRuntimeRunning() else {
                return .deferred("Desktop runtime restarted before rollback cleanup")
            }
            return try finishRollbackCleanup(
                journal,
                incoming: incoming,
                directory: directory
            )
        case .rolledBackClean:
            guard !desktopRuntimeRunning() else {
                return .deferred("Desktop runtime restarted before journal cleanup")
            }
            try removeJournal()
            return .rolledBack
        case .committedClean:
            return .deferred("Rollback state lost the previous installed bundle")
        case .inconsistent:
            return .deferred("Rollback journal paths do not match recorded identities")
        }
    }

    private func finishRollbackCleanup(
        _ journal: DesktopInstallJournal,
        incoming: URL,
        directory: DesktopRetainedInstallDirectory
    ) throws -> DesktopInstallRecoveryResult {
        try directory.removeTree(
            named: incoming.lastPathComponent,
            expectedIdentity: journal.incomingIdentity
        )
        guard directory.pathIdentity(named: incoming.lastPathComponent) == nil else {
            return .deferred("Rolled-back incoming bundle could not be removed")
        }
        try removeJournal()
        return .rolledBack
    }

    private func atomicActivate(
        _ journal: DesktopInstallJournal,
        directory: DesktopRetainedInstallDirectory
    ) throws {
        let destination = URL(fileURLWithPath: journal.destinationPath)
        let incoming = URL(fileURLWithPath: journal.incomingPath)
        guard transactionLayout(journal, directory: directory) == .prepared,
              bundleIdentity(
                  named: incoming.lastPathComponent,
                  directory: directory
              ) == journal.incomingBundleIdentity,
              (!journal.destinationExisted || bundleIdentity(
                  named: destination.lastPathComponent,
                  directory: directory
              ) == journal.previousDestinationBundleIdentity) else {
            throw installerError("Desktop activation paths changed before atomic commit")
        }
        if journal.destinationExisted {
            try directory.swap(destination.lastPathComponent, incoming.lastPathComponent)
        } else {
            try directory.rename(
                from: incoming.lastPathComponent,
                to: destination.lastPathComponent
            )
        }
    }

    private func rollback(
        _ journal: DesktopInstallJournal,
        directory: DesktopRetainedInstallDirectory
    ) throws {
        let incoming = URL(fileURLWithPath: journal.incomingPath)
        guard transactionLayout(journal, directory: directory) == .activated else {
            throw installerError("Atomic rollback paths do not match the activated transaction")
        }
        let retainedPrevious: DesktopRetainedBundleTree?
        if journal.destinationExisted {
            guard let expectedIdentity = journal.previousDestinationBundleIdentity,
                  let retained = try directory.retainBundle(named: incoming.lastPathComponent),
                  DesktopBundleTreeIntegrity.makeBundleIdentity(
                      retained: retained,
                      isCancelled: { false }
                  ) == expectedIdentity else {
                throw installerError("Atomic rollback evidence changed before retention")
            }
            retainedPrevious = retained
        } else {
            retainedPrevious = nil
        }
        try? writeJournal(journal.withPhase(.rollback))
        let destination = URL(fileURLWithPath: journal.destinationPath)
        if journal.destinationExisted {
            try beforeRollbackCommit()
            guard transactionLayout(journal, directory: directory) == .activated,
                  let expectedIdentity = journal.previousDestinationBundleIdentity,
                  let retainedPrevious,
                  retainedPrevious.isCurrent(),
                  DesktopBundleTreeIntegrity.makeBundleIdentity(
                      retained: retainedPrevious,
                      isCancelled: { false }
                  ) == expectedIdentity else {
                throw installerError(
                    "Atomic rollback evidence changed before the descriptor-rooted swap"
                )
            }
            try directory.swap(destination.lastPathComponent, incoming.lastPathComponent)
            do {
                try afterRollbackSwapBeforeVerification()
                guard retainedPrevious.isCurrent(named: destination.lastPathComponent),
                      DesktopBundleTreeIntegrity.makeBundleIdentity(
                          retained: retainedPrevious,
                          boundAtName: destination.lastPathComponent,
                          isCancelled: { false }
                      ) == expectedIdentity else {
                    throw installerError(
                        "Atomic rollback evidence changed during the descriptor-rooted swap"
                    )
                }
            } catch {
                let oldRootStillAtDestination = directory.pathIdentity(
                    named: destination.lastPathComponent
                ) == expectedIdentity.root
                let newRootStillIncoming = directory.pathIdentity(
                    named: incoming.lastPathComponent
                ) == journal.incomingIdentity
                guard oldRootStillAtDestination, newRootStillIncoming else {
                    throw installerError(
                        "Post-swap rollback verification failed and roots were substituted: "
                            + error.localizedDescription
                    )
                }
                do {
                    try directory.swap(
                        destination.lastPathComponent,
                        incoming.lastPathComponent
                    )
                    try directory.synchronize()
                } catch let restorationError {
                    throw installerError(
                        "Post-swap rollback verification failed (\(error.localizedDescription)); "
                            + "reactivation also failed: \(restorationError.localizedDescription)"
                    )
                }
                throw error
            }
            try directory.synchronize()
            try directory.removeTree(
                named: incoming.lastPathComponent,
                expectedIdentity: journal.incomingIdentity
            )
        } else if directory.pathIdentity(named: destination.lastPathComponent) != nil {
            try directory.rename(
                from: destination.lastPathComponent,
                to: incoming.lastPathComponent
            )
            try directory.synchronize()
            try directory.removeTree(
                named: incoming.lastPathComponent,
                expectedIdentity: journal.incomingIdentity
            )
        }
        if directory.pathIdentity(named: incoming.lastPathComponent) == nil {
            try? removeJournal()
        }
    }

    private func durablyCommit(
        _ journal: DesktopInstallJournal,
        directory: DesktopRetainedInstallDirectory
    ) throws -> DesktopInstallJournal {
        let layout = transactionLayout(journal, directory: directory)
        let destination = URL(fileURLWithPath: journal.destinationPath)
        guard (layout == .activated || layout == .committedClean),
              bundleIdentity(
                  named: destination.lastPathComponent,
                  directory: directory
              ) == journal.incomingBundleIdentity else {
            throw installerError("Desktop commit paths do not match the activated transaction")
        }
        let committed = journal.withPhase(.committed)
        try writeJournal(committed)
        return committed
    }

    private func cleanupCommitted(
        _ committedJournal: DesktopInstallJournal,
        directory: DesktopRetainedInstallDirectory,
        validate: DesktopBundleValidator
    ) throws {
        try beforeCommittedCleanup()
        try preserveRollbackGeneration(
            committedJournal,
            directory: directory,
            validate: validate
        )
        let incoming = URL(fileURLWithPath: committedJournal.incomingPath)
        try directory.removeTree(
            named: incoming.lastPathComponent,
            expectedIdentity: committedJournal.previousDestinationIdentity
        )
        guard directory.pathIdentity(named: incoming.lastPathComponent) == nil else {
            throw installerError("Committed desktop install cleanup remains incomplete")
        }
        try removeJournal()
    }

    private func preserveRollbackGeneration(
        _ journal: DesktopInstallJournal,
        directory: DesktopRetainedInstallDirectory,
        validate: DesktopBundleValidator
    ) throws {
        guard journal.destinationExisted else { return }
        guard let expectedIdentity = journal.previousDestinationBundleIdentity,
              let bundleVersion = journal.previousBundleVersion,
              let shortVersion = journal.previousShortVersion else {
            throw installerError("Committed rollback evidence is incomplete")
        }
        let incoming = CodexDesktopPathSecurity.lexicallyStandardized(
            URL(fileURLWithPath: journal.incomingPath)
        )
        guard let retainedPrevious = try directory.retainBundle(named: incoming.lastPathComponent),
              retainedPrevious.rootIdentity == expectedIdentity.root else {
            throw installerError("Previous desktop bundle changed before rollback preservation")
        }
        let sourceValidation = validate(incoming, bundleVersion, shortVersion, { false })
        guard sourceValidation == .valid else {
            throw installerError(validationFailure("Rollback source bundle", sourceValidation))
        }
        guard let previousIdentities = DesktopBundleTreeIntegrity.makeBundleIdentities(
            retained: retainedPrevious,
            isCancelled: { false }
        ), previousIdentities.bound == expectedIdentity else {
            throw installerError(
                "Previous desktop bundle changed after fresh rollback trust validation"
            )
        }
        if let existing = CodexDesktopUpdateStorage.loadRollbackGeneration(
            in: transactionRoot,
            fileManager: fileManager
        ), existing.bundleVersion == bundleVersion,
           existing.shortVersion == shortVersion {
            let existingApp = CodexDesktopPathSecurity.lexicallyStandardized(
                URL(fileURLWithPath: existing.appPath)
            )
            if let retainedExisting = DesktopRetainedBundleTree(appURL: existingApp),
               validate(existingApp, bundleVersion, shortVersion, { false }) == .valid,
               let existingIdentities = DesktopBundleTreeIntegrity.makeBundleIdentities(
                   retained: retainedExisting,
                   isCancelled: { false }
               ), existingIdentities.bound == existing.bundleIdentity,
               existingIdentities.portable.hasSameContent(as: previousIdentities.portable),
               DesktopBundleTreeIntegrity.makeBundleIdentity(
                   retained: retainedPrevious,
                   isCancelled: { false }
               ) == expectedIdentity {
                return
            }
        }

        let identifier = UUID().uuidString
        let generationDirectory = transactionRoot.appendingPathComponent(
            "\(CodexDesktopUpdateStorage.previousPrefix)\(identifier)",
            isDirectory: true
        )
        let (copiedApp, retainedCopy, copiedIdentity) = try CodexDesktopStagingWorkspace
            .withTemporaryDirectory(
            in: transactionRoot,
            fileManager: fileManager,
            isCancelled: { false }
        ) { stagingDirectory in
            let stagedApp = stagingDirectory.appendingPathComponent(
                incoming.lastPathComponent,
                isDirectory: true
            )
            _ = try processRunner.runChecked(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: [incoming.path, stagedApp.path],
                timeout: 300,
                isCancelled: { false }
            )
            guard let install = CodexDesktopAppLocator.locate(appPath: stagedApp.path),
                  install.bundleVersion == bundleVersion,
                  install.shortVersion == shortVersion,
                  let retainedCopy = DesktopRetainedBundleTree(appURL: stagedApp),
                  validate(stagedApp, bundleVersion, shortVersion, { false }) == .valid,
                  let copiedIdentities = DesktopBundleTreeIntegrity.makeBundleIdentities(
                      retained: retainedCopy,
                      isCancelled: { false }
                  ), copiedIdentities.portable.hasSameContent(as: previousIdentities.portable),
                  DesktopBundleTreeIntegrity.makeBundleIdentity(
                      retained: retainedPrevious,
                      isCancelled: { false }
                  ) == expectedIdentity else {
                throw installerError("Rollback copy did not match immutable previous-bundle evidence")
            }
            try fileManager.moveItem(at: stagingDirectory, to: generationDirectory)
            let publishedApp = generationDirectory.appendingPathComponent(
                incoming.lastPathComponent,
                isDirectory: true
            )
            guard let retainedPublishedCopy = DesktopRetainedBundleTree(
                appURL: publishedApp
            ) else {
                throw installerError(
                    "Published rollback generation could not be retained"
                )
            }
            return (publishedApp, retainedPublishedCopy, copiedIdentities.bound)
        }
        guard DesktopBundleTreeIntegrity.makeBundleIdentity(
            retained: retainedCopy,
            isCancelled: { false }
        ) == copiedIdentity,
        let publishedPortable = DesktopBundleTreeIntegrity.makePortableBundleIdentity(
            retained: retainedCopy,
            isCancelled: { false }
        ), publishedPortable.hasSameContent(as: previousIdentities.portable) else {
            throw installerError("Published rollback generation changed before metadata commit")
        }
        let rollback = CodexDesktopRollbackGeneration(
            formatVersion: CodexDesktopUpdateStorage.rollbackFormatVersion,
            generationIdentifier: identifier,
            appPath: copiedApp.path,
            sourceDestinationPath: journal.destinationPath,
            shortVersion: shortVersion,
            bundleVersion: bundleVersion,
            preservedAt: Date(),
            bundleIdentity: copiedIdentity
        )
        try CodexDesktopUpdateStorage.saveRollbackGeneration(
            rollback,
            in: transactionRoot,
            fileManager: fileManager,
            isCancelled: { false }
        )
    }

    private func recoverValidatedCommit(
        _ journal: DesktopInstallJournal,
        directory: DesktopRetainedInstallDirectory,
        desktopRuntimeRunning: () -> Bool,
        validate: DesktopBundleValidator
    ) throws -> DesktopInstallRecoveryResult {
        let committedJournal: DesktopInstallJournal
        do {
            committedJournal = try durablyCommit(journal, directory: directory)
        } catch {
            return recoverByRollingBack(journal, directory: directory)
        }
        guard !desktopRuntimeRunning() else {
            try? writeJournal(committedJournal.withPhase(.cleanupPending))
            return .deferred("Committed desktop install cleanup is waiting for safe quit")
        }
        do {
            try cleanupCommitted(
                committedJournal,
                directory: directory,
                validate: validate
            )
            return .completedCommit
        } catch {
            try? writeJournal(committedJournal.withPhase(.cleanupPending))
            return .deferred("Committed desktop install cleanup remains incomplete")
        }
    }

    private func abandonPrepared(
        _ journal: DesktopInstallJournal,
        directory: DesktopRetainedInstallDirectory
    ) throws {
        let incoming = URL(fileURLWithPath: journal.incomingPath)
        guard transactionLayout(journal, directory: directory) == .prepared,
              bundleIdentity(
                  named: incoming.lastPathComponent,
                  directory: directory
              ) == journal.incomingBundleIdentity else {
            throw installerError("Uncommitted desktop paths changed before cleanup")
        }
        try directory.removeTree(
            named: incoming.lastPathComponent,
            expectedIdentity: journal.incomingIdentity
        )
        guard directory.pathIdentity(named: incoming.lastPathComponent) == nil else {
            throw installerError("Could not remove uncommitted incoming bundle")
        }
        try removeJournal()
    }

    private func recoverByRollingBack(
        _ journal: DesktopInstallJournal,
        directory: DesktopRetainedInstallDirectory
    ) -> DesktopInstallRecoveryResult {
        do {
            try rollback(journal, directory: directory)
            return .rolledBack
        } catch {
            return .deferred(
                "Descriptor-rooted rollback evidence changed: \(error.localizedDescription)"
            )
        }
    }

    private func writeJournal(_ journal: DesktopInstallJournal) throws {
        try ensureTransactionRoot()
        let data = try JSONEncoder().encode(journal)
        guard data.count <= Self.maximumJournalBytes else {
            throw installerError("Install journal exceeded its size bound")
        }
        let directory = try DesktopRetainedInstallDirectory(url: transactionRoot)
        try directory.replaceRegularFileAtomically(
            named: Self.journalFileName,
            data: data
        )
    }

    private func loadJournal() throws -> DesktopInstallJournal? {
        guard fileManager.fileExists(atPath: transactionRoot.path) else { return nil }
        let directory = try DesktopRetainedInstallDirectory(url: transactionRoot)
        guard let data = try directory.readRegularFile(
            named: Self.journalFileName,
            maximumBytes: Self.maximumJournalBytes
        ) else { return nil }
        return try JSONDecoder().decode(DesktopInstallJournal.self, from: data)
    }

    private func removeJournal() throws {
        guard fileManager.fileExists(atPath: transactionRoot.path) else { return }
        let directory = try DesktopRetainedInstallDirectory(url: transactionRoot)
        try directory.removeRegularFile(named: Self.journalFileName)
    }

    private func ensureTransactionRoot() throws {
        if !fileManager.fileExists(atPath: transactionRoot.path) {
            try CodexDesktopPathSecurity.ensureDirectoryExists(transactionRoot)
        }
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(transactionRoot) else {
            throw installerError("Install transaction root contains a symbolic-link component")
        }
    }

    private func validJournal(_ journal: DesktopInstallJournal) -> Bool {
        guard journal.version == Self.journalVersion,
              (journal.previousDestinationIdentity != nil) == journal.destinationExisted,
              (journal.previousDestinationBundleIdentity != nil) == journal.destinationExisted,
              (journal.previousBundleVersion != nil) == journal.destinationExisted,
              (journal.previousShortVersion != nil) == journal.destinationExisted,
              journal.transactionRootIdentity != nil,
              journal.destinationDirectoryIdentity != nil,
              let incomingBundleIdentity = journal.incomingBundleIdentity,
              incomingBundleIdentity.root == journal.incomingIdentity,
              journal.previousDestinationBundleIdentity?.root
                == journal.previousDestinationIdentity,
              incomingBundleIdentity.contentSHA256.count == 64,
              (journal.previousDestinationBundleIdentity?.contentSHA256.count ?? 64) == 64,
              journal.incomingIdentity != journal.previousDestinationIdentity else {
            return false
        }
        let destination = CodexDesktopPathSecurity.lexicallyStandardized(
            URL(fileURLWithPath: journal.destinationPath)
        )
        let incoming = CodexDesktopPathSecurity.lexicallyStandardized(
            URL(fileURLWithPath: journal.incomingPath)
        )
        guard Self.pathIdentity(at: transactionRoot) == journal.transactionRootIdentity,
              Self.pathIdentity(at: destination.deletingLastPathComponent())
                == journal.destinationDirectoryIdentity else {
            return false
        }
        let expectedIncomingName = ".codexswitch-incoming-"
            + journal.transactionIdentifier.uuidString
            + ".app"
        return incoming.lastPathComponent == expectedIncomingName
            && validTransactionPaths(destination: destination, incoming: incoming)
    }

    private func validTransactionPaths(destination: URL, incoming: URL) -> Bool {
        let parent = CodexDesktopPathSecurity.lexicallyStandardized(
            destination.deletingLastPathComponent()
        )
        let prefix = ".codexswitch-incoming-"
        let incomingName = incoming.lastPathComponent
        guard CodexDesktopPathSecurity.lexicallyStandardized(
                  incoming.deletingLastPathComponent()
              ) == parent,
              allowedDestinationPaths.contains(
                  CodexDesktopPathSecurity.lexicallyStandardized(destination).path
              ),
              incomingName.hasPrefix(prefix),
              incomingName.hasSuffix(".app"),
              incoming.pathExtension == "app",
              CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(parent) else {
            return false
        }
        let identifier = incomingName.dropFirst(prefix.count).dropLast(4)
        guard UUID(uuidString: String(identifier)) != nil else { return false }
        if fileManager.fileExists(atPath: destination.path),
           !CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(destination) {
            return false
        }
        if fileManager.fileExists(atPath: incoming.path),
           !CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(incoming) {
            return false
        }
        return true
    }

    static func pathIdentity(at url: URL) -> DesktopInstallPathIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) != S_IFLNK else {
            return nil
        }
        return DesktopInstallPathIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino)
        )
    }

    private func transactionLayout(
        _ journal: DesktopInstallJournal,
        directory: DesktopRetainedInstallDirectory
    ) -> TransactionLayout {
        let destination = URL(fileURLWithPath: journal.destinationPath)
        let incoming = URL(fileURLWithPath: journal.incomingPath)
        let destinationIdentity = directory.pathIdentity(named: destination.lastPathComponent)
        let incomingIdentity = directory.pathIdentity(named: incoming.lastPathComponent)

        if journal.destinationExisted {
            guard let previous = journal.previousDestinationIdentity else {
                return .inconsistent
            }
            if destinationIdentity == previous,
               incomingIdentity == journal.incomingIdentity {
                return .prepared
            }
            if destinationIdentity == journal.incomingIdentity,
               incomingIdentity == previous {
                return .activated
            }
            if destinationIdentity == journal.incomingIdentity, incomingIdentity == nil {
                return .committedClean
            }
            if destinationIdentity == previous, incomingIdentity == nil {
                return .rolledBackClean
            }
            return .inconsistent
        }

        guard journal.previousDestinationIdentity == nil else { return .inconsistent }
        if destinationIdentity == nil, incomingIdentity == journal.incomingIdentity {
            return .prepared
        }
        if destinationIdentity == journal.incomingIdentity, incomingIdentity == nil {
            return .activated
        }
        if destinationIdentity == nil, incomingIdentity == nil {
            return .rolledBackClean
        }
        return .inconsistent
    }

    private func bundleIdentity(
        named name: String,
        directory: DesktopRetainedInstallDirectory
    ) -> DesktopInstallBundleIdentity? {
        guard let retained = try? directory.retainBundle(named: name) else { return nil }
        return DesktopBundleTreeIntegrity.makeBundleIdentity(
            retained: retained,
            isCancelled: { false }
        )
    }

    private func rollbackEvidenceIsCurrent(
        _ journal: DesktopInstallJournal,
        directory: DesktopRetainedInstallDirectory
    ) -> Bool {
        guard journal.destinationExisted else { return true }
        let incoming = URL(fileURLWithPath: journal.incomingPath)
        return bundleIdentity(
            named: incoming.lastPathComponent,
            directory: directory
        ) == journal.previousDestinationBundleIdentity
    }

    private func validationFailure(
        _ subject: String,
        _ result: CodexDesktopBundleValidationResult
    ) -> String {
        switch result {
        case .valid: return "\(subject) unexpectedly passed"
        case .invalid(let reason): return "\(subject) was invalid: \(reason)"
        case .unavailable(let reason): return "\(subject) validation was unavailable: \(reason)"
        case .cancelled: return "\(subject) validation was cancelled"
        }
    }

    private func commandFailure(
        _ prefix: String,
        _ result: CodexDesktopTrustCommandResult
    ) -> String {
        let output = [result.standardOutput, result.standardError]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.timedOut { return "\(prefix): command timed out" }
        return output.isEmpty ? "\(prefix): command failed" : "\(prefix): \(output)"
    }

    private func installerError(_ message: String) -> NSError {
        NSError(
            domain: "DesktopBundleInstaller",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
