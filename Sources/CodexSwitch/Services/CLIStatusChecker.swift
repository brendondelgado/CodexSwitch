import Foundation

enum CLIStatus: Sendable {
    case ready          // CLI running + auth.json matches active account
    case authMismatch   // CLI running but auth.json doesn't match
    case cliNotRunning  // No codex processes found
    case noActiveAccount

    var label: String {
        switch self {
        case .ready: return "CLI Status — Connected: Auto-swap ready"
        case .authMismatch: return "CLI Status — Connected: Auth mismatch — swap pending"
        case .cliNotRunning: return "CLI Status — Disconnected: Auto-swap disconnected"
        case .noActiveAccount: return "CLI Status — Disconnected: No active account"
        }
    }

    var icon: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .authMismatch: return "exclamationmark.triangle.fill"
        case .cliNotRunning: return "xmark.circle"
        case .noActiveAccount: return "xmark.circle"
        }
    }

    var isHealthy: Bool { self == .ready }
}

struct DesktopAppStatus: Sendable {
    let isRunning: Bool
    let port: UInt16?

    var label: String {
        if isRunning, let port {
            return "Codex desktop app connected (port \(port))"
        }
        if isRunning {
            return "Codex desktop app running"
        }
        return "Codex desktop app not running"
    }

    var icon: String {
        isRunning ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark"
    }

    var isHealthy: Bool { isRunning }
}

/// Cached status checker — runs checks on a background queue and caches results.
/// Call `refresh()` periodically; read `cachedCLIStatus` / `cachedDesktopStatus` from views.
@MainActor
enum CLIStatusChecker {
    private nonisolated static let authPath = NSString("~/.codex/auth.json").expandingTildeInPath

    // Cached values — safe to read from view body without blocking
    private(set) static var cachedCLIStatus: CLIStatus = .noActiveAccount
    private(set) static var cachedDesktopStatus: DesktopAppStatus = DesktopAppStatus(isRunning: false, port: nil)

    /// Refresh cached statuses in the background. Call from a timer, not view body.
    static func refresh(activeAccountId: String?) {
        let accountId = activeAccountId
        Task.detached {
            let cliStatus = _checkCLI(activeAccountId: accountId)
            let desktopStatus = _checkDesktopApp()
            await MainActor.run {
                cachedCLIStatus = cliStatus
                cachedDesktopStatus = desktopStatus
            }
        }
    }

    // MARK: - Background checks (never call from main thread directly)

    private nonisolated static func _checkCLI(activeAccountId: String?) -> CLIStatus {
        guard let activeAccountId else { return .noActiveAccount }

        let cliRunning = _isCodexRunning()
        let authAccountId = _readAuthAccountId()

        if !cliRunning {
            return .cliNotRunning
        }
        if authAccountId == activeAccountId {
            return .ready
        }
        return .authMismatch
    }

    private nonisolated static func _checkDesktopApp() -> DesktopAppStatus {
        // Check WebSocket port first
        if let port = DesktopAppConnector.discoverPort() {
            return DesktopAppStatus(isRunning: true, port: port)
        }
        // Fall back to checking if Codex.app process exists
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "Codex.app/Contents"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return DesktopAppStatus(isRunning: true, port: nil)
        }
        return DesktopAppStatus(isRunning: false, port: nil)
    }

    private nonisolated static func _isCodexRunning() -> Bool {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "codex"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private nonisolated static func _readAuthAccountId() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let authFile = try? JSONDecoder().decode(AuthFile.self, from: data) else {
            return nil
        }
        return authFile.tokens.accountId
    }
}
