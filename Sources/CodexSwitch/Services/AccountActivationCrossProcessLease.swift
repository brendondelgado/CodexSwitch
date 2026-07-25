import Darwin
import Foundation
import os

private let accountActivationLeaseLogger = Logger(
    subsystem: "com.codexswitch",
    category: "AccountActivationLease"
)

enum AccountActivationCrossProcessLeaseContext {
    @TaskLocal static var heldLease: AccountActivationCrossProcessLease?

    static func holds(_ url: URL) -> Bool {
        heldLease?.isHeld(at: url) == true
    }
}

enum AccountActivationCrossProcessLeaseError: Error, Equatable, LocalizedError {
    case unsafePath(String)
    case openFailed(Int32)
    case metadataFailed(Int32)
    case invalidFile
    case modeFailed(Int32)
    case lockFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .unsafePath(let reason):
            return "Account activation lease path is unsafe: \(reason)"
        case .openFailed(let code):
            return "Could not open the account activation lease (errno \(code))"
        case .metadataFailed(let code):
            return "Could not inspect the account activation lease (errno \(code))"
        case .invalidFile:
            return "Account activation lease is not a private, owned regular file"
        case .modeFailed(let code):
            return "Could not secure the account activation lease (errno \(code))"
        case .lockFailed(let code):
            return "Could not acquire the account activation lease (errno \(code))"
        }
    }
}

final class AccountActivationCrossProcessLease: @unchecked Sendable {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codexswitch", isDirectory: true)
        .appendingPathComponent("accounts.runtime-activation.lock")

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

    func isHeld(at expectedURL: URL) -> Bool {
        lock.withLock {
            descriptor >= 0
                && url.path
                    == CodexDesktopPathSecurity.lexicallyStandardized(expectedURL).path
        }
    }

    static func acquire(
        at url: URL = defaultURL,
        fileManager: FileManager = .default
    ) throws -> AccountActivationCrossProcessLease? {
        let standardized = CodexDesktopPathSecurity.lexicallyStandardized(url)
        let parent = standardized.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try CodexDesktopPathSecurity.ensureDirectoryExists(parent)
        }
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(parent) else {
            throw AccountActivationCrossProcessLeaseError.unsafePath(
                "parent contains a symbolic-link component"
            )
        }

        let descriptor = open(
            standardized.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw AccountActivationCrossProcessLeaseError.openFailed(errno)
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let code = errno
            _ = close(descriptor)
            throw AccountActivationCrossProcessLeaseError.metadataFailed(code)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1 else {
            _ = close(descriptor)
            throw AccountActivationCrossProcessLeaseError.invalidFile
        }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let code = errno
            _ = close(descriptor)
            throw AccountActivationCrossProcessLeaseError.modeFailed(code)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                return nil
            }
            throw AccountActivationCrossProcessLeaseError.lockFailed(code)
        }

        return AccountActivationCrossProcessLease(
            url: standardized,
            descriptor: descriptor
        )
    }

    static func acquireForAccountMutation(
        at url: URL = defaultURL
    ) -> AccountActivationCrossProcessLease? {
        do {
            return try acquire(at: url)
        } catch {
            accountActivationLeaseLogger.error(
                "Account mutation lease acquisition failed: \(error.localizedDescription, privacy: .public)"
            )
            SwapLog.append(.debug(
                "ACCOUNT_MUTATION_LEASE_FAILED error=\(error.localizedDescription)"
            ))
            return nil
        }
    }
}
