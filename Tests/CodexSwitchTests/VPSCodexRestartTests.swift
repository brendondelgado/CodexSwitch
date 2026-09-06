import Foundation
import Testing
@testable import CodexSwitch

@Suite("VPS Codex config restart")
struct VPSCodexRestartTests {
    private let digest = String(repeating: "a", count: 64)
    private let script = Data("# inert restart fixture".utf8)
    private let token = "vps-restart-fixture"

    private var plan: VPSCodexRestartPlan {
        VPSCodexRestartPlan(pid: 123, processStart: "456", configDigest: digest)
    }

    private func response(
        status: String = "ready", pid: Int = 123, processStart: String = "456",
        configDigest: String? = nil, schemaVersion: Int = 1, version: String = "0.153.2"
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": schemaVersion, "status": status, "pid": pid,
            "processStart": processStart, "configDigest": configDigest ?? digest,
            "appServerVersion": version,
        ])
    }

    private func completed(_ data: Data, status: Int32 = 0) -> ProcessRunResult {
        ProcessRunResult(
            terminationStatus: status, stdout: data,
            stderr: Data("\(LinuxDevboxMonitor.remoteCompletionMarker(executionToken: token)) \(status)\n".utf8),
            timedOut: false
        )
    }

    @Test("Preparation only checks and returns the bound confirmation plan")
    func prepareOnlyChecks() throws {
        let output = try response()
        let result = LinuxDevboxMonitor.restartVPSCodexWithCandidates(
            [["fixture-host"]], script: script, executionToken: token
        ) { executable, arguments, timeout in
            #expect(executable.path == "/usr/bin/ssh")
            #expect(arguments.last?.contains("--check") == true)
            #expect(arguments.last?.contains("--restart") == false)
            #expect(timeout == 50)
            return completed(output)
        }
        guard case .success(let checked) = result else { Issue.record("Expected readiness plan"); return }
        #expect(checked.plan == plan)
    }

    @Test("Restart sends only the confirmed identity and accepts a verified replacement")
    func confirmedRestart() throws {
        let output = try response(status: "restarted", pid: 789, processStart: "1011")
        let result = LinuxDevboxMonitor.restartVPSCodexWithCandidates(
            [["fixture-host"]], script: script, confirmedPlan: plan, executionToken: token
        ) { _, arguments, timeout in
            #expect(arguments.last?.contains("--restart --pid 123 --process-start 456 --config-digest \(digest)") == true)
            #expect(timeout == 210)
            return completed(output)
        }
        guard case .success(let restarted) = result else { Issue.record("Expected verified restart"); return }
        #expect(restarted.pid == 789)
        #expect(restarted.appServerVersion == "0.153.2")
    }

    @Test("Ambiguous SSH loss does not redispatch a restart or leak diagnostics")
    func ambiguousRestartIsNotRetried() {
        var calls = 0
        let result = LinuxDevboxMonitor.restartVPSCodexWithCandidates(
            [["first"], ["second"]], script: script, confirmedPlan: plan, executionToken: token
        ) { _, _, _ in
            calls += 1
            return ProcessRunResult(terminationStatus: 255, stdout: Data(),
                                    stderr: Data("private config secret".utf8), timedOut: false)
        }
        #expect(calls == 1)
        guard case .failure(let failure) = result else { Issue.record("Expected unknown outcome"); return }
        #expect(failure.message.contains("unknown"))
        #expect(!failure.message.contains("private config secret"))
    }

    @Test("Only definite local launch failure permits another SSH candidate")
    func definiteLaunchFailureCanTryAnotherCandidate() throws {
        var calls = 0
        let output = try response(status: "restarted", pid: 789, processStart: "1011")
        let result = LinuxDevboxMonitor.restartVPSCodexWithCandidates(
            [["first"], ["second"]], script: script, confirmedPlan: plan, executionToken: token
        ) { _, _, _ in
            calls += 1
            if calls == 1 {
                return ProcessRunResult(terminationStatus: -1, stdout: Data(), stderr: Data(), timedOut: false)
            }
            return completed(output)
        }
        #expect(calls == 2)
        guard case .success = result else { Issue.record("Expected recovery before remote execution"); return }
    }

    @Test("Malformed, stale and changed replacement evidence is rejected")
    func invalidEvidenceIsRejected() throws {
        let outputs = [
            Data("not JSON".utf8), try response(status: "restarted"),
            try response(status: "ready", pid: 789),
            try response(status: "restarted", pid: 789, schemaVersion: 2),
            try response(status: "restarted", pid: 789, configDigest: String(repeating: "b", count: 64)),
            try response(status: "restarted", pid: 0),
            try response(status: "restarted", pid: 789, processStart: "invalid"),
            try response(status: "restarted", pid: 789, version: "secret\nvalue"),
        ]
        for output in outputs {
            let result = LinuxDevboxMonitor.restartVPSCodexWithCandidates(
                [["fixture"]], script: script, confirmedPlan: plan, executionToken: token
            ) { _, _, _ in completed(output) }
            guard case .failure = result else { Issue.record("Accepted invalid replacement evidence"); continue }
        }
    }

    @Test("Missing completion and truncated output cannot report success")
    func incompleteTransportEvidenceIsRejected() throws {
        let output = try response(status: "restarted", pid: 789)
        for value in [
            ProcessRunResult(terminationStatus: 0, stdout: output, stderr: Data(), timedOut: false),
            ProcessRunResult(terminationStatus: 0, stdout: output, stderr: completed(output).stderr,
                             timedOut: true),
            ProcessRunResult(terminationStatus: 0, stdout: output, stderr: completed(output).stderr,
                             timedOut: false, stdoutTruncated: true),
        ] {
            let result = LinuxDevboxMonitor.restartVPSCodexWithCandidates(
                [["fixture"]], script: script, confirmedPlan: plan, executionToken: token
            ) { _, _, _ in value }
            guard case .failure = result else { Issue.record("Accepted incomplete SSH evidence"); continue }
        }
    }

    @Test("Active-work refusal is surfaced without another attempt")
    func activeWorkRefusalIsSurfaced() throws {
        let output = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "status": "blocked", "message": "VPS work is active. Finish it before restarting.",
        ])
        var calls = 0
        let result = LinuxDevboxMonitor.restartVPSCodexWithCandidates(
            [["first"], ["second"]], script: script, executionToken: token
        ) { _, _, _ in calls += 1; return completed(output) }
        #expect(calls == 1)
        guard case .failure(let failure) = result else { Issue.record("Expected active-work refusal"); return }
        #expect(failure.message.contains("active"))
    }

    @Test("Malformed plans cannot become shell arguments")
    func malformedPlanIsRejectedBeforeSSH() {
        for invalid in [
            VPSCodexRestartPlan(pid: 0, processStart: "456", configDigest: digest),
            VPSCodexRestartPlan(pid: 123, processStart: "456; touch /tmp/no", configDigest: digest),
            VPSCodexRestartPlan(pid: 123, processStart: "456", configDigest: "$(echo invalid)"),
        ] {
            #expect(LinuxDevboxMonitor.remoteVPSCodexRestartCommand(script: script, confirmedPlan: invalid) == nil)
        }
        #expect(LinuxDevboxMonitor.remoteVPSCodexRestartCommand(script: Data(), confirmedPlan: plan) == nil)
    }
}
