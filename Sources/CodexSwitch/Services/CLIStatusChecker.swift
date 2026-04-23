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
    let usageState: CodexDesktopAppUsageState
    let isRunning: Bool
    let port: UInt16?

    var label: String {
        usageState.runtimeLabel
    }

    var autoSwapReady: Bool { usageState == .appRunning }

    var autoSwapLabel: String {
        switch usageState {
        case .appRunning:
            return "Desktop auto-swap ready"
        case .backgroundServiceOnly:
            return "Desktop auto-swap unavailable: Codex.app UI is not running"
        case .notRunning:
            return "Desktop auto-swap disconnected"
        }
    }

    var icon: String {
        switch usageState {
        case .appRunning:
            return "desktopcomputer"
        case .backgroundServiceOnly:
            return "desktopcomputer.and.arrow.down"
        case .notRunning:
            return "desktopcomputer.trianglebadge.exclamationmark"
        }
    }

    var isHealthy: Bool { autoSwapReady }
}

/// Cached status checker — runs checks on a background queue and caches results.
/// Call `refresh()` periodically; read `cachedCLIStatus` / `cachedDesktopStatus` from views.
@MainActor
enum CLIStatusChecker {
    private nonisolated static let authPath = NSString("~/.codex/auth.json").expandingTildeInPath
    private nonisolated static let refreshGate = SingleFlightGate()

    // Cached values — safe to read from view body without blocking
    private(set) static var cachedCLIStatus: CLIStatus = .noActiveAccount
    private(set) static var cachedDesktopStatus = DesktopAppStatus(
        usageState: .notRunning,
        isRunning: false,
        port: nil
    )

    static func setCachedDesktopStatusForTesting(_ status: DesktopAppStatus) {
        cachedDesktopStatus = status
    }

    /// Refresh cached statuses in the background. Call from a timer, not view body.
    static func refresh(activeAccountId: String?) {
        let accountId = activeAccountId
        Task.detached {
            guard await refreshGate.begin() else { return }
            defer {
                Task {
                    await refreshGate.end()
                }
            }
            let cliStatus = _checkCLI(activeAccountId: accountId)
            let desktopStatus = currentDesktopStatus()
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

    nonisolated static func currentDesktopStatus() -> DesktopAppStatus {
        let usageState = CodexDesktopAppProcessClassifier.usageState(appPath: "/Applications/Codex.app")

        return DesktopAppStatus(
            usageState: usageState,
            isRunning: usageState != .notRunning,
            port: nil
        )
    }

    private nonisolated static func _isCodexRunning() -> Bool {
        guard let output = ProcessRunner.run(
            executablePath: "/usr/bin/pgrep",
            arguments: ["-x", "codex"],
            timeout: 1,
            captureStderr: false
        ) else {
            return false
        }
        guard !output.timedOut else { return false }
        return !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private nonisolated static func _readAuthAccountId() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let authFile = try? JSONDecoder().decode(AuthFile.self, from: data) else {
            return nil
        }
        return authFile.tokens.accountId
    }
}
