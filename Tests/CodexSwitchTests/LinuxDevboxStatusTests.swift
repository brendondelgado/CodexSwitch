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
        let script = try remoteUsageScript()
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

    @Test("Remote usage report keeps missing model evidence unknown and emits aggregates only")
    func remoteUsageReportKeepsMissingModelEvidenceUnknown() throws {
        let home = try isolatedHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sessionID = "11111111-1111-1111-1111-aaaaaaaaaaaa"
        let session = sessions.appendingPathComponent("rollout-\(sessionID).jsonl")
        try """
        {"timestamp":"2026-07-13T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1200,"cached_input_tokens":800,"output_tokens":40,"reasoning_output_tokens":10}}}}
        """.write(to: session, atomically: true, encoding: .utf8)

        let (report, output) = try runRemoteUsageReport(home: home)

        #expect(report.models.map(\.model) == ["unknown"])
        #expect(report.total.inputTokens == 1_200)
        #expect(!output.contains(sessionID))
        #expect(!output.contains(session.path))
    }

    @Test("Remote usage report applies long-context capability to newer GPT-5 models")
    func remoteUsageReportAccountsForNewerGPT5LongContext() throws {
        let home = try isolatedHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDirectory = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let database = codexDirectory.appendingPathComponent("logs_2.sqlite")
        let response = """
        {"type":"response.completed","response":{"id":"resp-sol","model":"gpt-5.6-sol","usage":{"input_tokens":300001,"input_tokens_details":{"cached_tokens":250000},"output_tokens":1000,"output_tokens_details":{"reasoning_tokens":250}}}}
        """
        let setup = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [
                "-c",
                "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1]); c.execute('create table logs (ts integer, target text, feedback_log_body text)'); c.execute('insert into logs values (?, ?, ?)', (int(time.time()), 'fixture', sys.argv[2])); c.commit()",
                database.path,
                response,
            ],
            timeout: 5
        )
        try #require(setup.terminationStatus == 0)

        let (report, _) = try runRemoteUsageReport(home: home)
        let usage = try #require(report.models.first)

        #expect(usage.model == "gpt-5.6-sol")
        #expect(usage.longContextInputTokens == 300_001)
        #expect(usage.longContextCachedInputTokens == 250_000)
        #expect(usage.longContextOutputTokens == 1_000)
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

    private func remoteUsageScript() throws -> String {
        let command = LinuxDevboxMonitor.remoteUsageReportCommand(days: 30)
        let marker = "python3 - <<'PY'\n"
        let start = try #require(command.range(of: marker)?.upperBound)
        let end = try #require(command.range(of: "\nPY", options: .backwards)?.lowerBound)
        return String(command[start..<end])
    }

    private func isolatedHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexswitch-remote-usage-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func runRemoteUsageReport(home: URL) throws -> (CodexTokenUsageReport, String) {
        let script = home.appendingPathComponent("remote-usage.py")
        try remoteUsageScript().write(to: script, atomically: true, encoding: .utf8)
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [script.path],
            timeout: 5,
            environment: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin",
            ]
        )
        try #require(result.terminationStatus == 0)
        let output = result.stdoutString
        let report = try JSONDecoder().decode(CodexTokenUsageReport.self, from: result.stdout)
        return (report, output)
    }
}
