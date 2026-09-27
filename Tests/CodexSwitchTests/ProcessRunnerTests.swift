import Darwin
import Foundation
import Testing
@testable import CodexSwitch

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("Default subprocess environment inherits HOME")
    func defaultEnvironmentInheritsHome() throws {
        let home = try #require(ProcessInfo.processInfo.environment["HOME"])
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printenv"),
            arguments: ["HOME"],
            timeout: 2
        )

        #expect(!result.timedOut)
        #expect(result.terminationStatus == 0)
        #expect(result.stdoutString == home + "\n")
    }

    @Test("Explicit subprocess environment replaces inherited values")
    func explicitEnvironmentReplacesInheritedValues() {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printenv"),
            timeout: 2,
            environment: ["CODEXSWITCH_ENVIRONMENT_FIXTURE": "isolated"]
        )

        #expect(!result.timedOut)
        #expect(result.terminationStatus == 0)
        #expect(result.stdoutString == "CODEXSWITCH_ENVIRONMENT_FIXTURE=isolated\n")
    }

    @Test("Explicit empty subprocess environment remains empty")
    func explicitEmptyEnvironmentRemainsEmpty() {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printenv"),
            arguments: ["HOME"],
            timeout: 2,
            environment: [:]
        )

        #expect(!result.timedOut)
        #expect(result.terminationStatus == 1)
        #expect(result.stdout.isEmpty)
    }

    @Test("Desktop updater environment inherits HOME by default")
    func desktopUpdaterEnvironmentInheritsHome() throws {
        let home = try #require(ProcessInfo.processInfo.environment["HOME"])
        let result = DesktopUpdaterProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printenv"),
            arguments: ["HOME"],
            timeout: 2
        )

        #expect(!result.timedOut)
        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput == home + "\n")
    }

    @Test("Explicit desktop updater environment replaces inherited values")
    func explicitDesktopUpdaterEnvironmentReplacesInheritedValues() {
        let result = DesktopUpdaterProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printenv"),
            timeout: 2,
            environment: ["CODEXSWITCH_ENVIRONMENT_FIXTURE": "isolated"]
        )

        #expect(!result.timedOut)
        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput == "CODEXSWITCH_ENVIRONMENT_FIXTURE=isolated\n")
    }

    @Test("Explicit empty desktop updater environment remains empty")
    func explicitEmptyDesktopUpdaterEnvironmentRemainsEmpty() {
        let result = DesktopUpdaterProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printenv"),
            arguments: ["HOME"],
            timeout: 2,
            environment: [:]
        )

        #expect(!result.timedOut)
        #expect(result.terminationStatus == 1)
        #expect(result.standardOutput.isEmpty)
    }

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

    @Test("Drains saturated stdout and stderr while retaining bounded prefixes")
    func drainsSaturatedStreamsWithBoundedRetention() {
        let retainedBytes = 64 * 1024
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "(/usr/bin/yes e | /usr/bin/head -c 2097152 >&2) & "
                    + "/usr/bin/yes o | /usr/bin/head -c 2097152; wait",
            ],
            timeout: 5,
            maxOutputBytes: retainedBytes
        )

        #expect(!result.timedOut)
        #expect(result.terminationStatus == 0)
        #expect(result.stdout.count == retainedBytes)
        #expect(result.stderr.count == retainedBytes)
        #expect(result.stdoutTruncated)
        #expect(result.stderrTruncated)
    }

    @Test("Timed out child is gone before return")
    func timedOutChildIsReaped() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "codexswitch-process-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pidFile = root.appending(path: "pid")

        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo $$ > '\(pidFile.path)'; exec /bin/sleep 10"],
            timeout: 0.2
        )

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))
        #expect(result.timedOut)
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}
