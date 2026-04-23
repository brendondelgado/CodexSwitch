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

    @Test("Version checks are skipped while a fresh result is still available")
    func versionCheckStalenessPolicySkipsFreshResults() {
        let now = Date()
        let lastChecked = now.addingTimeInterval(-20)

        #expect(!CodexVersionChecker.shouldCheckVersions(
            lastChecked: lastChecked,
            now: now,
            isChecking: false,
            minimumInterval: 60
        ))
        #expect(!CodexVersionChecker.shouldCheckVersions(
            lastChecked: nil,
            now: now,
            isChecking: true,
            minimumInterval: 60
        ))
        #expect(CodexVersionChecker.shouldCheckVersions(
            lastChecked: now.addingTimeInterval(-120),
            now: now,
            isChecking: false,
            minimumInterval: 60
        ))
    }

    @MainActor
    @Test("Desktop runtime refresh reuses cached status instead of re-probing")
    func desktopRuntimeRefreshUsesCachedStatus() {
        let cachedStatus = DesktopAppStatus(
            usageState: .backgroundServiceOnly,
            isRunning: true,
            port: nil
        )
        CLIStatusChecker.setCachedDesktopStatusForTesting(cachedStatus)

        let checker = CodexVersionChecker()
        checker.desktopPatchHealthy = true
        checker.refreshDesktopRuntimeStatus()

        #expect(checker.desktopRuntimeLabel == cachedStatus.label)
        #expect(checker.desktopAutoSwapLabel == "Desktop auto-swap unavailable: Codex.app UI is not running")
        #expect(!checker.desktopAutoSwapReady)
    }

    @Test("Process runner captures stderr and times out stalled commands")
    func processRunnerHandlesOutputAndTimeout() throws {
        let output = try #require(ProcessRunner.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'out'; printf 'err' >&2"],
            timeout: 1
        ))

        #expect(output.terminationStatus == 0)
        #expect(!output.timedOut)
        #expect(output.stdout == "out")
        #expect(output.stderr == "err")

        let timedOut = try #require(ProcessRunner.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 3"],
            timeout: 0.1
        ))

        #expect(timedOut.timedOut)
        #expect(timedOut.terminationStatus != 0)
    }
}
