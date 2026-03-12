import Foundation
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "SwapLog")

/// Diagnostic event log for CodexSwitch.
/// Records swap decisions, SIGHUP signaling, errors, and CLI status changes.
/// Logs contain account email addresses for debugging — stored locally at ~/.codexswitch/logs/.
enum SwapLog {
    private static let logDir = NSString("~/.codexswitch/logs").expandingTildeInPath

    /// Create a fresh formatter per call to avoid thread-safety issues
    /// (Foundation formatters are not safe to share across threads).
    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    enum Event: CustomStringConvertible {
        // Swap lifecycle
        case swapTriggered(from: String, to: String, reason: String)
        case swapCompleted(to: String, durationMs: Int)
        case swapFailed(error: String)

        // Auth file operations
        case authFileWritten(accountId: String)
        case authFileError(error: String)

        // SIGHUP signaling
        case sighupSent(pid: Int32, startedAt: String)
        case sighupSkipped(reason: String)

        // Desktop app connector
        case desktopAppFound(port: UInt16)
        case desktopAppInjected(port: UInt16)
        case desktopAppFailed(error: String)

        // Polling
        case pollResult(accountEmail: String, fiveHrRemaining: Double, weeklyRemaining: Double)
        case pollError(accountEmail: String, error: String)

        // CLI status changes
        case cliStatusChanged(from: String, to: String)

        // Account management
        case accountAdded(email: String)
        case accountRemoved(email: String)
        case tokenRefreshed(email: String)
        case tokenRefreshFailed(email: String, error: String)

        var description: String {
            switch self {
            case .swapTriggered(let from, let to, let reason):
                return "SWAP_TRIGGERED from=\(from) to=\(to) reason=\(reason)"
            case .swapCompleted(let to, let ms):
                return "SWAP_COMPLETED to=\(to) duration_ms=\(ms)"
            case .swapFailed(let error):
                return "SWAP_FAILED error=\(error)"
            case .authFileWritten(let id):
                return "AUTH_WRITTEN account_id=\(id)"
            case .authFileError(let error):
                return "AUTH_ERROR error=\(error)"
            case .sighupSent(let pid, let started):
                return "SIGHUP_SENT pid=\(pid) process_started=\(started)"
            case .sighupSkipped(let reason):
                return "SIGHUP_SKIPPED reason=\(reason)"
            case .desktopAppFound(let port):
                return "DESKTOP_FOUND port=\(port)"
            case .desktopAppInjected(let port):
                return "DESKTOP_INJECTED port=\(port)"
            case .desktopAppFailed(let error):
                return "DESKTOP_FAILED error=\(error)"
            case .pollResult(let email, let fh, let wk):
                return "POLL_OK email=\(email) 5h_remaining=\(String(format: "%.1f", fh))% weekly=\(String(format: "%.1f", wk))%"
            case .pollError(let email, let error):
                return "POLL_ERR email=\(email) error=\(error)"
            case .cliStatusChanged(let from, let to):
                return "CLI_STATUS from=\(from) to=\(to)"
            case .accountAdded(let email):
                return "ACCOUNT_ADDED email=\(email)"
            case .accountRemoved(let email):
                return "ACCOUNT_REMOVED email=\(email)"
            case .tokenRefreshed(let email):
                return "TOKEN_REFRESHED email=\(email)"
            case .tokenRefreshFailed(let email, let error):
                return "TOKEN_REFRESH_FAILED email=\(email) error=\(error)"
            }
        }
    }

    /// Append an event to today's log file.
    static func append(_ event: Event) {
        let timestamp = makeISOFormatter().string(from: Date())
        let line = "[\(timestamp)] \(event.description)\n"

        // Ensure log directory exists
        try? FileManager.default.createDirectory(
            atPath: logDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Daily log file rotation
        let dateStr = String(timestamp.prefix(10)) // YYYY-MM-DD
        let logPath = "\(logDir)/codexswitch-\(dateStr).log"

        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: logPath
            )
        }
    }

    /// Read the last N lines from today's log.
    static func recentEntries(count: Int = 50) -> [String] {
        let dateStr = makeISOFormatter().string(from: Date()).prefix(10)
        let logPath = "\(logDir)/codexswitch-\(String(dateStr)).log"
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return []
        }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        return Array(lines.suffix(count))
    }

    /// Clean up logs older than 7 days.
    static func pruneOldLogs() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logDir) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()

        for file in files where file.hasPrefix("codexswitch-") && file.hasSuffix(".log") {
            let path = "\(logDir)/\(file)"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let modDate = attrs[.modificationDate] as? Date,
               modDate < cutoff {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
