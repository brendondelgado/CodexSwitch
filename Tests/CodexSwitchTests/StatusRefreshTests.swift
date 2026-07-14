import Foundation
import Testing
@testable import CodexSwitch

@Suite("Status refresh coordination")
struct StatusRefreshTests {
    @Test("Process runner captures stderr and times out stalled commands")
    func processRunnerHandlesOutputAndTimeout() throws {
        let output = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'out'; printf 'err' >&2"],
            timeout: 1
        )

        #expect(output.terminationStatus == 0)
        #expect(!output.timedOut)
        #expect(output.stdoutString == "out")
        #expect(output.stderrString == "err")

        let timedOut = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 3"],
            timeout: 0.1
        )

        #expect(timedOut.timedOut)
        #expect(timedOut.terminationStatus != 0)
    }
}
