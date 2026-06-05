import Foundation
import Testing
@testable import CodexSwitch

@Suite("Status refresh coordination")
struct StatusRefreshTests {
    @Test("Single-flight gate rejects overlapping work and reopens after completion")
    func singleFlightGatePreventsOverlap() async {
        let gate = SingleFlightGate()

        let first = await gate.begin()
        let second = await gate.begin()
        await gate.end()
        let third = await gate.begin()

        #expect(first)
        #expect(!second)
        #expect(third)
    }

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
