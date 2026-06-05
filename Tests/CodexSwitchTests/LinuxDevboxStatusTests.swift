import Foundation
import Testing
@testable import CodexSwitch

@Suite("Linux devbox status")
struct LinuxDevboxStatusTests {
    @Test("Ready status names the VPS active account")
    func readyStatusNamesTheVPSActiveAccount() {
        let status = LinuxDevboxStatus(
            state: .ready,
            summary: "ready active=brendon@delgadoforge.dev",
            activeEmail: "brendon@delgadoforge.dev"
        )

        #expect(status.isVisible)
        #expect(status.isHealthy)
        #expect(status.label == "VPS CLI — Ready: brendon@delgadoforge.dev")
    }

    @Test("Unconfigured status stays hidden from the popover")
    func unconfiguredStatusStaysHiddenFromThePopover() {
        #expect(!LinuxDevboxStatus.notConfigured.isVisible)
        #expect(!LinuxDevboxStatus.notConfigured.isHealthy)
    }

    @Test("Healthy status is preserved during background refresh")
    func healthyStatusIsPreservedDuringBackgroundRefresh() {
        let status = LinuxDevboxStatus(
            state: .ready,
            summary: "daemon running",
            activeEmail: "ready@example.com"
        )

        #expect(!status.shouldShowCheckingPlaceholderBeforeRefresh)
        #expect(LinuxDevboxStatus.notConfigured.shouldShowCheckingPlaceholderBeforeRefresh)
    }

    @Test("Single VPS readiness blip is suppressed after ready")
    func singleVPSReadinessBlipIsSuppressedAfterReady() {
        #expect(LinuxDevboxStatus.shouldSuppressTransientIssue(wasReady: true, consecutiveIssueChecks: 1))
        #expect(!LinuxDevboxStatus.shouldSuppressTransientIssue(wasReady: true, consecutiveIssueChecks: 2))
        #expect(!LinuxDevboxStatus.shouldSuppressTransientIssue(wasReady: false, consecutiveIssueChecks: 1))
        #expect(!LinuxDevboxStatus.shouldSuppressTransientIssue(wasReady: nil, consecutiveIssueChecks: 1))
    }

    @Test("Remote poll selector is shell quoted safely")
    func remotePollSelectorIsShellQuotedSafely() {
        #expect(LinuxDevboxMonitor.shellQuote("brendon@delgadoforge.dev") == "'brendon@delgadoforge.dev'")
        #expect(LinuxDevboxMonitor.shellQuote("weird'account") == "'weird'\\''account'")
    }

    @Test("Remote swap command targets exact active account safely")
    func remoteSwapCommandTargetsExactActiveAccountSafely() {
        let command = LinuxDevboxMonitor.remoteSwapCommand(selector: "weird'account@example.com")

        #expect(command.contains("codexswitch-cli swap 'weird'\\''account@example.com'"))
        #expect(!command.contains("accessToken"))
        #expect(!command.contains("refreshToken"))
        #expect(!command.contains("idToken"))
    }

    @Test("SSH candidates prefer Tailscale userspace proxy when available")
    func sshCandidatesPreferTailscaleUserspaceProxyWhenAvailable() {
        let settings = LinuxDevboxMonitorSettings(
            enabled: true,
            host: "100.95.84.123",
            user: "signul",
            sshKeyPath: "~/.ssh/id_ed25519",
            port: 22
        )

        let candidates = LinuxDevboxMonitor.sshArgumentCandidates(settings: settings)

        #expect(!candidates.isEmpty)
        #expect(candidates.last?.contains("signul@100.95.84.123") == true)
        if FileManager.default.isExecutableFile(atPath: LinuxDevboxMonitor.tailscaleBinaryPath) {
            #expect(candidates.first?.contains { $0.contains("Tailscale.app/Contents/MacOS/Tailscale nc %h %p") } == true)
        }
    }

    @Test("SSH candidates disable OpenSSH multiplexing for control-plane probes")
    func sshCandidatesDisableOpenSSHMultiplexingForControlPlaneProbes() {
        let settings = LinuxDevboxMonitorSettings(
            enabled: true,
            host: "100.95.84.123",
            user: "signul",
            sshKeyPath: "~/.ssh/id_ed25519",
            port: 22
        )

        let candidates = LinuxDevboxMonitor.sshArgumentCandidates(settings: settings)

        #expect(!candidates.isEmpty)
        for candidate in candidates {
            #expect(candidate.contains("ControlMaster=no"))
            #expect(candidate.contains("ControlPath=none"))
            #expect(candidate.contains("ControlPersist=no"))
        }
    }

    @Test("Detects interactive codex-vps attach without counting monitor SSH probes")
    func detectsInteractiveCodexVPSAttachWithoutCountingMonitorSSHProbes() {
        let active = """
        zsh /Users/brendondelgado/.local/bin/codex-vps
        /Users/brendondelgado/.local/share/codexswitch/patched-mac-remote-client/codex -c features.goals=true --remote ws://100.95.84.123:8390 resume abc
        """
        #expect(LinuxDevboxMonitor.isInteractiveCodexVPSAttachRunning(psOutput: active))

        let monitorOnly = """
        /usr/bin/ssh -o BatchMode=yes -o ProxyCommand=/Applications/Tailscale.app/Contents/MacOS/Tailscale nc %h %p signul@100.95.84.123 export PATH=\"$HOME/.local/bin:$PATH\"; codexswitch-cli doctor --json
        /Applications/Tailscale.app/Contents/MacOS/Tailscale nc 100.95.84.123 22
        """
        #expect(!LinuxDevboxMonitor.isInteractiveCodexVPSAttachRunning(psOutput: monitorOnly))
    }

    @Test("Remote usage report Python script compiles")
    func remoteUsageReportPythonScriptCompiles() throws {
        let command = LinuxDevboxMonitor.remoteUsageReportCommand(days: 30)
        let marker = "python3 - <<'PY'\n"
        let start = try #require(command.range(of: marker)?.upperBound)
        let end = try #require(command.range(of: "\nPY", options: .backwards)?.lowerBound)
        let script = String(command[start..<end])
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexswitch-remote-usage-\(UUID().uuidString).py")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try script.write(to: tempURL, atomically: true, encoding: .utf8)

        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-m", "py_compile", tempURL.path],
            timeout: 5
        )

        #expect(result.terminationStatus == 0)
    }

    @Test("Remote account state script compiles and does not request token fields")
    func remoteAccountStatePythonScriptCompilesWithoutTokenFields() throws {
        let command = LinuxDevboxMonitor.remoteAccountStateCommand()
        #expect(!command.contains("accessToken"))
        #expect(!command.contains("refreshToken"))
        #expect(!command.contains("idToken"))

        let marker = "python3 - <<'PY'\n"
        let start = try #require(command.range(of: marker)?.upperBound)
        let end = try #require(command.range(of: "\nPY", options: .backwards)?.lowerBound)
        let script = String(command[start..<end])
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexswitch-remote-account-state-\(UUID().uuidString).py")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try script.write(to: tempURL, atomically: true, encoding: .utf8)

        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-m", "py_compile", tempURL.path],
            timeout: 5
        )

        #expect(result.terminationStatus == 0)
    }
}
