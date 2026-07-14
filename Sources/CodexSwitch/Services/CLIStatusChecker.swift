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
                return "Codex desktop app connected (port \(port)): Computer Use plugin preserved; hot-swap unavailable"
            }
            if patchMessage.contains("external/upstream reload path") {
                return "Codex desktop app connected (port \(port)): Computer Use plugin preserved; desktop hot-swap needs upstream reload"
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
            return "Codex desktop app running: Computer Use plugin preserved; hot-swap unavailable"
        }
        if isRunning, patchMessage.contains("external/upstream reload path") {
            return "Codex desktop app running: Computer Use plugin preserved; desktop hot-swap needs upstream reload"
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

struct CLICheckResult: Equatable, Sendable {
    let status: CLIStatus
    let detail: String?
}

struct CLIHotSwapReadiness: Equatable, Sendable {
    let ready: Bool
    let detail: String?
}

struct CLIStatusRefreshGeneration: Equatable, Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var inFlightGeneration: UInt64?

    mutating func begin() -> UInt64? {
        guard inFlightGeneration == nil else { return nil }
        generation += 1
        inFlightGeneration = generation
        return generation
    }

    mutating func invalidate() {
        generation += 1
        inFlightGeneration = nil
    }

    mutating func complete(_ capturedGeneration: UInt64) -> Bool {
        guard capturedGeneration == generation,
              inFlightGeneration == capturedGeneration else {
            return false
        }
        inFlightGeneration = nil
        return true
    }
}

/// Cached status checker — runs checks on a background queue and caches results.
/// Call `refresh()` periodically; read `cachedCLIStatus` / `cachedDesktopStatus` from views.
@MainActor
enum CLIStatusChecker {
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
    private static var refreshGeneration = CLIStatusRefreshGeneration()
    private static var lastDesktopRefreshAt: Date?
    private static let desktopRefreshInterval: TimeInterval = 5 * 60

    /// Refresh cached statuses in the background. Call from a timer, not view body.
    static func refresh(
        activeAccountId: String?,
        onUpdated: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard let generation = refreshGeneration.begin() else { return }

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
                guard refreshGeneration.complete(generation) else { return }
                cachedCLIStatus = cliCheck.status
                cachedCLIStatusDetail = cliCheck.detail
                cachedDesktopStatus = desktopStatus
                if shouldRefreshDesktop {
                    lastDesktopRefreshAt = Date()
                }
                onUpdated?()
            }
        }
    }

    /// Invalidates any result captured before the active account changed.
    @MainActor
    static func invalidateForAccountSwap() {
        refreshGeneration.invalidate()
    }

    // MARK: - Background checks (never call from main thread directly)

    private nonisolated static func _checkCLI(activeAccountId: String?) -> CLICheckResult {
        cliCheckResult(activeAccountId: activeAccountId) {
            SwapEngine.localRuntimeEvidenceSnapshot(runtimeKind: .localInteractiveCLI)
        }
    }

    nonisolated static func cliCheckResult(
        activeAccountId: String?,
        runtimeEvidenceProvider: () -> CodexLocalRuntimeEvidenceSnapshot
    ) -> CLICheckResult {
        guard let activeAccountId else {
            return CLICheckResult(status: .noActiveAccount, detail: nil)
        }

        let runtimeEvidence = runtimeEvidenceProvider()
        if runtimeEvidence.isComplete, runtimeEvidence.runtimes.isEmpty {
            return CLICheckResult(status: .cliNotRunning, detail: nil)
        }
        let readiness = codexCLIRuntimeEvidenceIsHotSwapReady(runtimeEvidence)
        if !readiness.ready {
            return CLICheckResult(status: .hotSwapMissing, detail: readiness.detail)
        }

        guard let authIdentity = runtimeEvidence.runtimes.first?.observation.authFileIdentity,
              !authIdentity.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              runtimeEvidence.runtimes.allSatisfy({ evidence in
                  evidence.observation.authFileIdentity == authIdentity
                      && evidence.startupAcknowledgement.binding.authFileIdentity == authIdentity
              }) else {
            return CLICheckResult(
                status: .hotSwapMissing,
                detail: "Local runtime auth identity evidence is inconsistent."
            )
        }

        if authIdentity.accountID == activeAccountId {
            return CLICheckResult(status: .ready, detail: nil)
        }
        return CLICheckResult(status: .authMismatch, detail: nil)
    }

    private nonisolated static func _checkDesktopApp() -> DesktopAppStatus {
        let patchStatus = DesktopPatchManager.currentStatus()
        let runtimeEvidence = SwapEngine.localRuntimeEvidenceSnapshot(
            runtimeKind: .externalAppServer
        )
        let runtimeState: DesktopRuntimeHotSwapState
        if !runtimeEvidence.isComplete {
            runtimeState = .restartRequired
        } else if runtimeEvidence.runtimes.isEmpty {
            runtimeState = .unknown
        } else {
            runtimeState = .ready
        }

        // Check WebSocket port first
        if let port = DesktopAppConnector.discoverPort() {
            let hotSwapReady = runtimeState == .ready
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
        let hotSwapReady = runtimeState == .ready
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
                patchMessage = "Desktop app-server hot-swap ready."
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

    nonisolated static func codexCLIRuntimeEvidenceIsHotSwapReady(
        _ snapshot: CodexLocalRuntimeEvidenceSnapshot,
        detailProvider: (Int32, String) -> String? = { pid, commandLine in
            cliHotSwapBlockerDetail(pid: pid, commandLine: commandLine, missingPatch: true)
        }
    ) -> CLIHotSwapReadiness {
        guard snapshot.isComplete else {
            return CLIHotSwapReadiness(
                ready: false,
                detail: "Local runtime discovery or identity evidence is incomplete."
            )
        }
        guard !snapshot.runtimes.isEmpty else {
            return CLIHotSwapReadiness(ready: false, detail: nil)
        }

        for evidence in snapshot.runtimes {
            let observation = evidence.observation
            guard observation.target.runtimeKind == .localInteractiveCLI,
                  SwapEngine.bindingMatchesObservation(
                    evidence.startupAcknowledgement.binding,
                    observation
                  ) else {
                let process = observation.target.process
                return CLIHotSwapReadiness(
                    ready: false,
                    detail: detailProvider(
                        process.identity.pid,
                        process.arguments.joined(separator: " ")
                    )
                )
            }
        }
        return CLIHotSwapReadiness(ready: true, detail: nil)
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
        let executableToken = lower
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let executableName = (executableToken as NSString).lastPathComponent
        if executableName == "node"
            || executableName == "bash"
            || executableName == "zsh"
            || executableName == "sh" {
            return false
        }

        let excludedFragments = [
            "codexswitch.app",
            "codexswitch-cli",
            "codex-code-mode-host",
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
}
