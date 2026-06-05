import Foundation

enum CLIStatus: Sendable {
    case ready          // CLI running + auth.json matches active account
    case authMismatch   // CLI running but auth.json doesn't match
    case cliNotRunning  // No codex processes found
    case hotSwapMissing // CLI running but live binary cannot reload auth
    case noActiveAccount

    var label: String {
        switch self {
        case .ready: return "Mac CLI — Connected: hot-swap ready"
        case .authMismatch: return "Mac CLI — Connected: auth mismatch — swap pending"
        case .cliNotRunning: return "Mac CLI — No local session detected"
        case .hotSwapMissing: return "Mac CLI — Connected: restart local CLI to activate hot-swap"
        case .noActiveAccount: return "Mac CLI — No active account"
        }
    }

    var icon: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .authMismatch: return "exclamationmark.triangle.fill"
        case .cliNotRunning: return "xmark.circle"
        case .hotSwapMissing: return "wrench.and.screwdriver"
        case .noActiveAccount: return "xmark.circle"
        }
    }

    var isHealthy: Bool { self == .ready }
}

struct DesktopAppStatus: Sendable {
    let isRunning: Bool
    let port: UInt16?
    let hotSwapReady: Bool
    let patchInstalled: Bool
    let patchMessage: String

    var label: String {
        if isRunning, let port {
            if hotSwapReady {
                return "Codex desktop app connected (port \(port)): Auto-swap ready"
            }
            if patchMessage.contains("patch blocked") {
                return "Codex desktop app connected (port \(port)): \(patchMessage)"
            }
            if patchMessage.contains("Computer Use") && patchMessage.contains("hot-swap is unavailable") {
                return "Codex desktop app connected (port \(port)): Computer Use ready; hot-swap unavailable"
            }
            if patchMessage.contains("external/upstream reload path") {
                return "Codex desktop app connected (port \(port)): Computer Use ready; desktop hot-swap needs upstream reload"
            }
            if patchInstalled {
                return "Codex desktop app connected (port \(port)): restart Codex.app to activate hot-swap"
            }
            return "Codex desktop app connected (port \(port)): Auto-swap patch not detected"
        }
        if isRunning, hotSwapReady {
            return "Codex desktop app running: Auto-swap ready"
        }
        if isRunning, patchMessage.contains("patch blocked") {
            return "Codex desktop app running: \(patchMessage)"
        }
        if isRunning, patchMessage.contains("Computer Use") && patchMessage.contains("hot-swap is unavailable") {
            return "Codex desktop app running: Computer Use ready; hot-swap unavailable"
        }
        if isRunning, patchMessage.contains("external/upstream reload path") {
            return "Codex desktop app running: Computer Use ready; desktop hot-swap needs upstream reload"
        }
        if isRunning, patchInstalled {
            return "Codex desktop app running: restart Codex.app to activate hot-swap"
        }
        if isRunning {
            return "Codex desktop app running: Auto-swap patch not detected"
        }
        if patchMessage.contains("patch blocked") {
            return "Codex desktop app not running: \(patchMessage)"
        }
        return "Codex desktop app not running"
    }

    var icon: String {
        if isRunning, !hotSwapReady {
            return "desktopcomputer.trianglebadge.exclamationmark"
        }
        return isRunning ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark"
    }

    var isHealthy: Bool { isRunning && hotSwapReady }

}

struct CodexCLIProcessInfo: Equatable, Sendable {
    let pid: Int32
    let commandLine: String
}

private struct CLICheckResult: Sendable {
    let status: CLIStatus
    let detail: String?
}

struct CLIHotSwapReadiness: Equatable, Sendable {
    let ready: Bool
    let detail: String?
}

/// Cached status checker — runs checks on a background queue and caches results.
/// Call `refresh()` periodically; read `cachedCLIStatus` / `cachedDesktopStatus` from views.
@MainActor
enum CLIStatusChecker {
    private nonisolated static let authPath = NSString("~/.codex/auth.json").expandingTildeInPath

    // Cached values — safe to read from view body without blocking
    private(set) static var cachedCLIStatus: CLIStatus = .noActiveAccount
    private(set) static var cachedCLIStatusDetail: String?
    private(set) static var cachedDesktopStatus = DesktopAppStatus(
        isRunning: false,
        port: nil,
        hotSwapReady: false,
        patchInstalled: false,
        patchMessage: "Not checked yet"
    )
    private static var refreshInFlight = false
    private static var lastDesktopRefreshAt: Date?
    private static let desktopRefreshInterval: TimeInterval = 5 * 60

    /// Refresh cached statuses in the background. Call from a timer, not view body.
    static func refresh(
        activeAccountId: String?,
        onUpdated: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard !refreshInFlight else { return }
        refreshInFlight = true

        let accountId = activeAccountId
        let now = Date()
        let shouldRefreshDesktop = lastDesktopRefreshAt
            .map { now.timeIntervalSince($0) >= desktopRefreshInterval }
            ?? true
        let previousDesktopStatus = cachedDesktopStatus
        Task.detached {
            let cliCheck = _checkCLI(activeAccountId: accountId)
            let desktopStatus = shouldRefreshDesktop
                ? _checkDesktopApp()
                : previousDesktopStatus
            await MainActor.run {
                cachedCLIStatus = cliCheck.status
                cachedCLIStatusDetail = cliCheck.detail
                cachedDesktopStatus = desktopStatus
                if shouldRefreshDesktop {
                    lastDesktopRefreshAt = Date()
                }
                refreshInFlight = false
                onUpdated?()
            }
        }
    }

    // MARK: - Background checks (never call from main thread directly)

    private nonisolated static func _checkCLI(activeAccountId: String?) -> CLICheckResult {
        guard let activeAccountId else {
            return CLICheckResult(status: .noActiveAccount, detail: nil)
        }

        let processes = _runningCodexCLIProcesses()
        let authAccountId = _readAuthAccountId()

        if processes.isEmpty {
            return CLICheckResult(status: .cliNotRunning, detail: nil)
        }
        let readiness = codexCLIProcessesAreHotSwapReady(
            processes,
            hotSwapAck: { SwapEngine.codexProcessHotSwapAckExists(pid: $0) }
        )
        if !readiness.ready {
            return CLICheckResult(status: .hotSwapMissing, detail: readiness.detail)
        }
        if authAccountId == activeAccountId {
            return CLICheckResult(status: .ready, detail: nil)
        }
        return CLICheckResult(status: .authMismatch, detail: nil)
    }

    private nonisolated static func _checkDesktopApp() -> DesktopAppStatus {
        let patchStatus = DesktopPatchManager.currentStatus()
        let runtimeState = DesktopPatchManager.runtimeHotSwapState()
        let authWatcherReady = DesktopAppConnector.authWatcherReady()

        // Check WebSocket port first
        if let port = DesktopAppConnector.discoverPort() {
            let hotSwapReady = runtimeState == .ready && authWatcherReady
            let patchMessage = hotSwapReady
                ? "Desktop app-server hot-swap ready."
                : patchStatus.lastMessage
            return DesktopAppStatus(
                isRunning: true,
                port: port,
                hotSwapReady: hotSwapReady,
                patchInstalled: patchStatus.desktopIntegrationInstalled,
                patchMessage: patchMessage
            )
        }
        let hotSwapReady = runtimeState == .ready && authWatcherReady
        guard patchStatus.isCodexAppRunning else {
            return DesktopAppStatus(
                isRunning: false,
                port: nil,
                hotSwapReady: false,
                patchInstalled: patchStatus.desktopIntegrationInstalled,
                patchMessage: patchStatus.lastMessage
            )
        }

        let patchMessage: String
        if patchStatus.computerUsePreservedModeInstalled {
            patchMessage = patchStatus.lastMessage
        } else {
            switch runtimeState {
            case .restartRequired:
                patchMessage = "Desktop app is patched on disk; restart Codex.app to activate hot-swap."
            case .ready:
                patchMessage = authWatcherReady
                    ? "Desktop app-server hot-swap ready."
                    : "Desktop app patch is installed, but the live session has not armed auth watching yet."
            case .unknown:
                patchMessage = patchStatus.lastMessage
            }
        }

        return DesktopAppStatus(
            isRunning: true,
            port: nil,
            hotSwapReady: hotSwapReady,
            patchInstalled: patchStatus.desktopIntegrationInstalled,
            patchMessage: patchMessage
        )
    }

    private nonisolated static func _runningCodexCLIProcesses() -> [CodexCLIProcessInfo] {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-lf", "codex"],
            timeout: 2
        )
        guard !result.timedOut, result.terminationStatus == 0 else { return [] }
        return codexCLIProcesses(fromPGrepOutput: result.stdoutString)
    }

    private nonisolated static func _allRunningCLIsAreHotSwapCapable() -> Bool {
        let processes = _runningCodexCLIProcesses()
        guard !processes.isEmpty else { return false }
        return codexCLIProcessesAreHotSwapReady(
            processes,
            hotSwapAck: { SwapEngine.codexProcessHotSwapAckExists(pid: $0) }
        ).ready
    }

    nonisolated static func codexCLIProcessPIDsAreHotSwapReady(
        _ pids: [Int32],
        hotSwapSupport: (Int32) -> Bool = { SwapEngine.codexProcessHasHotSwapSupport(pid: $0) },
        hotSwapAck: (Int32) -> Bool = { DesktopPatchManager.desktopHotSwapAckExists(pid: $0) }
    ) -> Bool {
        codexCLIProcessesAreHotSwapReady(
            pids.map { CodexCLIProcessInfo(pid: $0, commandLine: "") },
            hotSwapSupport: hotSwapSupport,
            hotSwapAck: hotSwapAck,
            detailProvider: { _, _, _ in nil }
        ).ready
    }

    nonisolated static func codexCLIProcessesAreHotSwapReady(
        _ processes: [CodexCLIProcessInfo],
        hotSwapSupport: (Int32) -> Bool = { SwapEngine.codexProcessHasHotSwapSupport(pid: $0) },
        hotSwapAck: (Int32) -> Bool = { DesktopPatchManager.desktopHotSwapAckExists(pid: $0) },
        detailProvider: (Int32, String, Bool) -> String? = { pid, commandLine, missingPatch in
            cliHotSwapBlockerDetail(pid: pid, commandLine: commandLine, missingPatch: missingPatch)
        }
    ) -> CLIHotSwapReadiness {
        guard !processes.isEmpty else {
            return CLIHotSwapReadiness(ready: false, detail: nil)
        }

        for process in processes {
            let hasSupport = hotSwapSupport(process.pid)
            guard hasSupport else {
                return CLIHotSwapReadiness(
                    ready: false,
                    detail: detailProvider(process.pid, process.commandLine, true)
                )
            }
            guard hotSwapAck(process.pid) else {
                return CLIHotSwapReadiness(
                    ready: false,
                    detail: detailProvider(process.pid, process.commandLine, false)
                )
            }
        }
        return CLIHotSwapReadiness(ready: true, detail: nil)
    }

    nonisolated static func codexCLIProcessPIDs(fromPGrepOutput output: String) -> [Int32] {
        codexCLIProcesses(fromPGrepOutput: output).map(\.pid)
    }

    nonisolated static func codexCLIProcesses(fromPGrepOutput output: String) -> [CodexCLIProcessInfo] {
        output.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
            let commandLine = String(parts[1])
            return isCodexCLICommandLine(commandLine)
                ? CodexCLIProcessInfo(pid: pid, commandLine: commandLine)
                : nil
        }
    }

    private nonisolated static func cliHotSwapBlockerDetail(
        pid: Int32,
        commandLine: String,
        missingPatch: Bool
    ) -> String {
        let lower = commandLine.lowercased()
        let kind = missingPatch ? "old or incomplete hot-swap CLI" : "CLI awaiting SIGHUP ack"
        let cwd = processWorkingDirectory(pid: pid)
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        let tty = processTTY(pid: pid)
        let location = [tty, cwd].compactMap { $0 }.joined(separator: " in ")

        if lower.contains("/.local/share/codexswitch/remote-client/") && !lower.contains(" --remote ") {
            return location.isEmpty
                ? "Blocking \(kind) pid \(pid) from remote-client; quit that old session."
                : "Blocking \(kind) pid \(pid) (\(location)); quit that old session."
        }

        return location.isEmpty
            ? "Blocking \(kind) pid \(pid); restart that session."
            : "Blocking \(kind) pid \(pid) (\(location)); restart that session."
    }

    private nonisolated static func processTTY(pid: Int32) -> String? {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", "\(pid)", "-o", "tty="],
            timeout: 1
        )
        guard !result.timedOut, result.terminationStatus == 0 else { return nil }
        let value = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "??" ? nil : value
    }

    private nonisolated static func processWorkingDirectory(pid: Int32) -> String? {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"],
            timeout: 1
        )
        guard !result.timedOut, result.terminationStatus == 0 else { return nil }
        return result.stdoutString
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("n") }
            .map { String($0.dropFirst()) }
    }

    nonisolated static func isCodexCLICommandLine(_ commandLine: String) -> Bool {
        let lower = commandLine.lowercased()
        guard lower.contains("codex") else { return false }

        let excludedFragments = [
            "codexswitch.app",
            "codexswitch-cli",
            "/contents/macos/codexswitch",
            "pgrep",
            " app-server",
            " exec ",
            " --remote ",
            " --ephemeral ",
            "codex_chronicle",
            "/applications/codex.app/contents/macos/codex",
            "/applications/codex.app/contents/frameworks/codex helper",
            ".git-ai/bin/git-ai",
            "git-ai checkpoint codex",
            "headroom wrap codex",
        ]
        guard !excludedFragments.contains(where: { lower.contains($0) }) else {
            return false
        }

        return lower.contains("/developer/codex/codex-rs/target/fork-release/codex")
            || lower.contains("/developer/codex/codex-rs/target/release/codex")
            || lower.contains("/.local/share/codexswitch/patched-codex/codex")
            || lower.contains("/.local/share/codexswitch/prepared-codex/")
            || lower.contains("/opt/homebrew/bin/codex")
            || lower.contains("/usr/local/bin/codex")
            || (lower.contains("/@openai/codex/") && lower.contains("/vendor/") && lower.contains("/codex/codex"))
            || (lower.contains("/@openai/codex-darwin") && lower.contains("/vendor/") && lower.contains("/codex/codex"))
            || (lower.contains("/@openai/codex-linux") && lower.contains("/vendor/") && lower.contains("/codex/codex"))
            || lower.hasSuffix("/codex")
            || lower.hasPrefix("codex ")
            || lower == "codex"
    }

    private nonisolated static func _readAuthAccountId() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let authFile = try? JSONDecoder().decode(AuthFile.self, from: data) else {
            return nil
        }
        return authFile.tokens.accountId
    }
}
