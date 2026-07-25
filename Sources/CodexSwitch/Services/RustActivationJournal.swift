import Darwin
import Foundation

enum RustActivationHandoffDisposition: Equatable, Sendable {
    case ready
    case deferred(String)
    case blocked(String)
}

struct RustActivationJournalRecord: Decodable, Equatable, Sendable {
    let version: Int
    let state: String
    let targetAccountId: String
    let authFingerprint: String?
    let updatedAt: String
}

enum RustActivationJournal {
    static let currentVersion = 3
    static let fileOnlyConvergenceGraceInterval: TimeInterval = 15
    static let maximumBytes = 1024 * 1024

    static let defaultURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codexswitch", isDirectory: true)
            .appendingPathComponent("accounts.activation.json")
    }()

    static func handoffDisposition(
        for account: CodexAccount,
        at date: Date = Date(),
        journalURL: URL = defaultURL
    ) -> RustActivationHandoffDisposition {
        guard let targetFingerprint = SwapEngine.completeTokenFingerprint(for: account) else {
            return .blocked("target token fingerprint is incomplete")
        }
        guard let record = observe(journalURL) else {
            return pathExistsWithoutFollowing(journalURL.path)
                ? .deferred("activation journal is temporarily unreadable")
                : .ready
        }
        return handoffDisposition(
            record: record,
            targetProviderAccountId: account.accountId,
            targetFingerprint: targetFingerprint,
            at: date
        )
    }

    static func handoffDisposition(
        record: RustActivationJournalRecord,
        targetProviderAccountId: String,
        targetFingerprint: String,
        at date: Date
    ) -> RustActivationHandoffDisposition {
        guard record.targetAccountId == targetProviderAccountId,
              record.authFingerprint == targetFingerprint else {
            return .ready
        }
        guard record.version == currentVersion else {
            return .blocked("activation journal version is unsupported")
        }

        switch record.state {
        case "confirmed", "committed_degraded":
            return .ready
        case "prepared":
            return .deferred("Rust activation is still committing credentials")
        case "file_only":
            guard let updatedAt = decodeDate(record.updatedAt) else {
                return .blocked("file-only activation time is invalid")
            }
            let age = date.timeIntervalSince(updatedAt)
            guard age.isFinite, age >= 0 else {
                return .deferred("file-only activation time is not yet current")
            }
            return age < fileOnlyConvergenceGraceInterval
                ? .deferred("Rust runtime convergence is still in flight")
                : .ready
        case "manual_review", "rolled_back":
            return .blocked("Rust activation requires reconciliation")
        default:
            return .blocked("Rust activation state is unsupported")
        }
    }

    private static func observe(_ url: URL) -> RustActivationJournalRecord? {
        guard let snapshot = SwapEngine.secureFileSnapshot(
            at: url.path,
            maximumBytes: maximumBytes,
            requiredOwnerUID: UInt32(getuid())
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(
            RustActivationJournalRecord.self,
            from: snapshot.data
        )
    }

    private static func pathExistsWithoutFollowing(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }

    private static func decodeDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        return internet.date(from: value)
    }
}
