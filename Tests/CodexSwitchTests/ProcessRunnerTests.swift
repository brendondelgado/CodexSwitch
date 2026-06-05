import Foundation
import Testing
@testable import CodexSwitch

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("Timeout returns promptly for a hung subprocess")
    func timeoutReturnsPromptly() {
        let startedAt = Date()

        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 5"],
            timeout: 0.2
        )

        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(startedAt) < 2.0)
    }

    @Test("Captures stdout and stderr without blocking")
    func capturesOutput() {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf out; printf err >&2"],
            timeout: 2
        )

        #expect(!result.timedOut)
        #expect(result.terminationStatus == 0)
        #expect(result.stdoutString == "out")
        #expect(result.stderrString == "err")
    }
}
