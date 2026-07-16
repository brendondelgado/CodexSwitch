import Darwin
import Foundation

enum DesktopUpdateOperationPhase: Int, CaseIterable, Equatable, Sendable {
    case acquired
    case discovery
    case recovery
    case appcast
    case download
    case archiveVerification
    case bundleVerification
    case generationPublication
    case installation
    case rejectionLedger
    case retention
    case finalPublication
    case finished
}

enum DesktopUpdateOwnershipError: Error, Equatable, LocalizedError, Sendable {
    case busy
    case cancelled
    case staleEpoch
    case permitMismatch
    case nestedTransaction
    case inactiveTransaction
    case phaseRegression
    case unauthorizedPath(String)
    case unsafeLease(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "Desktop updater is busy"
        case .cancelled: return "Desktop update operation was cancelled"
        case .staleEpoch: return "Desktop update operation belongs to a stale scheduler epoch"
        case .permitMismatch: return "Desktop update operation permit is inconsistent"
        case .nestedTransaction: return "A desktop install transaction is already active"
        case .inactiveTransaction: return "Desktop install transaction is no longer active"
        case .phaseRegression: return "Desktop update operation attempted to regress its phase"
        case .unauthorizedPath(let path):
            return "Desktop update mutation path is outside the operation allowlist: \(path)"
        case .unsafeLease(let reason): return reason
        }
    }
}

/// The scheduler invalidates this object before cancelling tasks. Holding its
/// lock across a publication makes invalidation and publication one ordered
/// boundary: either the old run finishes the publication first, or it cannot
/// begin it after `stop` returns.
final class DesktopUpdateRunEpoch: @unchecked Sendable {
    let identifier: UUID

    private let lock = NSLock()
    private var valid: Bool

    init(identifier: UUID = UUID(), valid: Bool = true) {
        self.identifier = identifier
        self.valid = valid
    }

    static func standalone() -> DesktopUpdateRunEpoch {
        DesktopUpdateRunEpoch()
    }

    func invalidate() {
        lock.withLock { valid = false }
    }

    func isCurrent() -> Bool {
        lock.withLock { valid }
    }

    fileprivate func withPublication<Result>(
        isCancelled: () -> Bool,
        _ body: () throws -> Result
    ) throws -> Result {
        try lock.withLock {
            guard valid else { throw DesktopUpdateOwnershipError.staleEpoch }
            guard !isCancelled() else { throw DesktopUpdateOwnershipError.cancelled }
            let result = try body()
            guard valid else {
                // Invalidation cannot enter while this lock is held. This check
                // documents and verifies that ordering invariant.
                throw DesktopUpdateOwnershipError.staleEpoch
            }
            return result
        }
    }
}

final class DesktopUpdateCrossProcessLease: @unchecked Sendable {
    let url: URL

    private let lock = NSLock()
    private var descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            descriptor = -1
        }
    }

    static func acquire(
        at url: URL,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> DesktopUpdateCrossProcessLease? {
        guard !isCancelled() else { throw DesktopUpdateOwnershipError.cancelled }
        let standardized = CodexDesktopPathSecurity.lexicallyStandardized(url)
        let parent = standardized.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try CodexDesktopPathSecurity.ensureDirectoryExists(parent, isCancelled: isCancelled)
        }
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(parent) else {
            throw DesktopUpdateOwnershipError.unsafeLease(
                "Updater lease parent contains a symbolic-link component"
            )
        }
        guard !isCancelled() else { throw DesktopUpdateOwnershipError.cancelled }

        let descriptor = open(
            standardized.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw DesktopUpdateOwnershipError.unsafeLease(
                "Could not open updater lease (errno \(errno))"
            )
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1 else {
            _ = close(descriptor)
            throw DesktopUpdateOwnershipError.unsafeLease(
                "Updater lease is not a private, owned regular file"
            )
        }
        guard !isCancelled() else {
            _ = close(descriptor)
            throw DesktopUpdateOwnershipError.cancelled
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN { return nil }
            throw DesktopUpdateOwnershipError.unsafeLease(
                "Could not acquire updater lease (errno \(lockError))"
            )
        }
        guard !isCancelled() else {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw DesktopUpdateOwnershipError.cancelled
        }
        return DesktopUpdateCrossProcessLease(url: standardized, descriptor: descriptor)
    }
}

final class DesktopUpdateMutationAuthority: @unchecked Sendable {
    let operationIdentifier: UUID

    private let epoch: DesktopUpdateRunEpoch
    private let allowedRoots: [URL]
    private let allowedExactPaths: Set<String>

    fileprivate init(
        operationIdentifier: UUID,
        epoch: DesktopUpdateRunEpoch,
        allowedRoots: [URL],
        allowedExactPaths: Set<String>
    ) {
        self.operationIdentifier = operationIdentifier
        self.epoch = epoch
        self.allowedRoots = allowedRoots.map(\.standardizedFileURL)
        self.allowedExactPaths = allowedExactPaths
    }

    func requireCurrent(isCancelled: () -> Bool = { Task.isCancelled }) throws {
        try epoch.withPublication(isCancelled: isCancelled) {}
    }

    func permits(_ path: URL) -> Bool {
        authorizes(path.standardizedFileURL)
    }

    func withMutation<Result>(
        at paths: [URL],
        isCancelled: () -> Bool = { Task.isCancelled },
        _ body: () throws -> Result
    ) throws -> Result {
        try epoch.withPublication(isCancelled: isCancelled) {
            for path in paths {
                guard authorizes(path.standardizedFileURL) else {
                    throw DesktopUpdateOwnershipError.unauthorizedPath(path.path)
                }
            }
            guard !isCancelled() else { throw DesktopUpdateOwnershipError.cancelled }
            return try body()
        }
    }

    /// Used only to remove an unpublished artifact owned by this operation
    /// after epoch invalidation. Callers must provide the operation UUID in the
    /// exact artifact name and use a bounded descriptor-relative remover.
    func withOwnedCleanup<Result>(
        at path: URL,
        expectedOperationIdentifier: UUID,
        _ body: () throws -> Result
    ) throws -> Result {
        guard expectedOperationIdentifier == operationIdentifier,
              authorizes(path.standardizedFileURL) else {
            throw DesktopUpdateOwnershipError.unauthorizedPath(path.path)
        }
        return try body()
    }

    private func authorizes(_ path: URL) -> Bool {
        if allowedExactPaths.contains(path.path) { return true }
        return allowedRoots.contains { root in
            let rootComponents = root.pathComponents
            let pathComponents = path.pathComponents
            return pathComponents.count >= rootComponents.count
                && Array(pathComponents.prefix(rootComponents.count)) == rootComponents
        }
    }
}

final class DesktopUpdateOperationLifetime: @unchecked Sendable {
    let identifier: UUID
    let operation: CodexDesktopUpdateOperation
    let permit: CodexDesktopUpdateStateMachine.Permit
    let mutationAuthority: DesktopUpdateMutationAuthority

    fileprivate let lease: DesktopUpdateCrossProcessLease
    private let phaseLock = NSLock()
    private var phase: DesktopUpdateOperationPhase = .acquired

    fileprivate init(
        identifier: UUID,
        operation: CodexDesktopUpdateOperation,
        permit: CodexDesktopUpdateStateMachine.Permit,
        lease: DesktopUpdateCrossProcessLease,
        mutationAuthority: DesktopUpdateMutationAuthority
    ) {
        self.identifier = identifier
        self.operation = operation
        self.permit = permit
        self.lease = lease
        self.mutationAuthority = mutationAuthority
    }

    func enter(
        _ next: DesktopUpdateOperationPhase,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws {
        try mutationAuthority.requireCurrent(isCancelled: isCancelled)
        try phaseLock.withLock {
            guard next.rawValue >= phase.rawValue else {
                throw DesktopUpdateOwnershipError.phaseRegression
            }
            phase = next
        }
    }

    func currentPhase() -> DesktopUpdateOperationPhase {
        phaseLock.withLock { phase }
    }
}

enum DesktopUpdateOperationAcquisition: Sendable {
    case acquired(DesktopUpdateOperationLifetime)
    case busy
    case cancelled
    case failed(String)
}

actor DesktopUpdateOperationOwner {
    private let stateMachine: CodexDesktopUpdateStateMachine
    private let leaseURL: URL
    private let updateRoot: URL
    private let allowedDestinations: Set<String>

    init(
        stateMachine: CodexDesktopUpdateStateMachine,
        leaseURL: URL,
        updateRoot: URL,
        allowedDestinations: [URL]
    ) {
        self.stateMachine = stateMachine
        self.leaseURL = CodexDesktopPathSecurity.lexicallyStandardized(leaseURL)
        self.updateRoot = CodexDesktopPathSecurity.lexicallyStandardized(updateRoot)
        self.allowedDestinations = Set(allowedDestinations.map { $0.standardizedFileURL.path })
    }

    func acquire(
        _ operation: CodexDesktopUpdateOperation,
        epoch: DesktopUpdateRunEpoch,
        additionalMutationRoots: [URL] = [],
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) async -> DesktopUpdateOperationAcquisition {
        guard !isCancelled(), epoch.isCurrent() else { return .cancelled }
        guard let permit = await stateMachine.acquire(operation) else {
            return isCancelled() || !epoch.isCurrent() ? .cancelled : .busy
        }
        do {
            guard let lease = try DesktopUpdateCrossProcessLease.acquire(
                at: leaseURL,
                isCancelled: isCancelled
            ) else {
                await stateMachine.release(permit)
                return .busy
            }
            guard !isCancelled(), epoch.isCurrent() else {
                await stateMachine.release(permit)
                return .cancelled
            }
            let identifier = UUID()
            let authority = DesktopUpdateMutationAuthority(
                operationIdentifier: identifier,
                epoch: epoch,
                allowedRoots: [updateRoot] + additionalMutationRoots,
                allowedExactPaths: allowedDestinations
            )
            return .acquired(
                DesktopUpdateOperationLifetime(
                    identifier: identifier,
                    operation: operation,
                    permit: permit,
                    lease: lease,
                    mutationAuthority: authority
                )
            )
        } catch DesktopUpdateOwnershipError.cancelled {
            await stateMachine.release(permit)
            return .cancelled
        } catch {
            await stateMachine.release(permit)
            return .failed(error.localizedDescription)
        }
    }

    func finish(
        _ lifetime: DesktopUpdateOperationLifetime
    ) async -> Result<Void, DesktopUpdateOwnershipError> {
        withExtendedLifetime(lifetime) {
            lifetime.lease.release()
        }
        return await stateMachine.releaseChecked(lifetime.permit)
    }
}
