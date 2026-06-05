import Testing
@testable import CodexSwitch

@Suite("CLI status checker")
struct CLIStatusCheckerTests {
    @Test("CLI status copy distinguishes local Mac sessions from VPS remote sessions")
    func cliStatusCopyDistinguishesLocalMacSessionsFromVPSRemoteSessions() {
        #expect(CLIStatus.cliNotRunning.label == "Mac CLI — No local session detected")
        #expect(CLIStatus.hotSwapMissing.label == "Mac CLI — Connected: restart local CLI to activate hot-swap")
    }

    @Test("CLI process detection ignores desktop app-server and helpers")
    func cliProcessDetectionIgnoresDesktopProcesses() {
        let output = """
        30351 /Applications/Codex.app/Contents/MacOS/Codex
        30437 /Applications/Codex.app/Contents/Frameworks/Codex Helper (Renderer).app/Contents/MacOS/Codex Helper (Renderer) --type=renderer
        58182 /Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled
        65703 /Applications/CodexSwitch.app/Contents/MacOS/CodexSwitch
        """

        #expect(CLIStatusChecker.codexCLIProcessPIDs(fromPGrepOutput: output).isEmpty)
    }

    @Test("CLI process detection keeps terminal launchers and native sessions")
    func cliProcessDetectionKeepsTerminalSessions() {
        let output = """
        50807 /Users/brendondelgado/.local/bin/headroom wrap codex
        51098 node /opt/homebrew/bin/codex
        51099 /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex
        51100 /Users/brendondelgado/.local/share/codexswitch/remote-client/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex resume --yolo
        51101 /Users/brendondelgado/.local/share/codexswitch/patched-codex/codex resume --yolo
        71863 /Users/brendondelgado/.local/share/codexswitch/prepared-codex/0.128.0/codex resume --yolo
        8746 /Users/brendondelgado/Developer/codex/codex-rs/target/fork-release/codex resume 019dcf51 --yolo
        64525 /Users/brendondelgado/Developer/codex/codex-rs/target/fork-release/codex --remote ws://127.0.0.1:18390 resume 019ddf25
        26584 /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex exec --ephemeral review
        26585 /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex exec --model gpt-5.5 --config model_reasoning_effort=xhigh
        23863 /Users/brendondelgado/.git-ai/bin/git-ai checkpoint codex --hook-input stdin
        """

        #expect(CLIStatusChecker.codexCLIProcessPIDs(fromPGrepOutput: output) == [51098, 51099, 51100, 51101, 71863, 8746])
    }

    @Test("CLI readiness requires marker support plus live ack")
    func cliReadinessRequiresMarkerSupportPlusLiveAck() {
        #expect(
            CLIStatusChecker.codexCLIProcessPIDsAreHotSwapReady(
                [42],
                hotSwapSupport: { $0 == 42 },
                hotSwapAck: { _ in false }
            ) == false
        )
        #expect(
            CLIStatusChecker.codexCLIProcessPIDsAreHotSwapReady(
                [42],
                hotSwapSupport: { $0 == 42 },
                hotSwapAck: { $0 == 42 }
            )
        )
    }

    @Test("CLI readiness reports the blocking process")
    func cliReadinessReportsBlockingProcess() {
        let readiness = CLIStatusChecker.codexCLIProcessesAreHotSwapReady(
            [
                CodexCLIProcessInfo(
                    pid: 42,
                    commandLine: "/Users/me/.local/share/codexswitch/remote-client/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex resume --yolo"
                )
            ],
            hotSwapSupport: { _ in false },
            hotSwapAck: { _ in false },
            detailProvider: { pid, _, missingPatch in
                "pid=\(pid) missingPatch=\(missingPatch)"
            }
        )

        #expect(readiness.ready == false)
        #expect(readiness.detail == "pid=42 missingPatch=true")
    }

    @Test("CLI status polling never bootstraps with SIGHUP")
    func cliStatusPollingNeverBootstrapsWithSighup() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/Services/CLIStatusChecker.swift",
            encoding: .utf8
        )

        #expect(!source.contains("ensureCodexProcessHotSwapAck"))
    }

    @Test("Desktop status reports connected patched app as ready")
    func desktopStatusReportsConnectedPatchedAppAsReady() {
        let status = DesktopAppStatus(
            isRunning: true,
            port: 49_999,
            hotSwapReady: true,
            patchInstalled: true,
            patchMessage: "Desktop app is ready."
        )

        #expect(status.label == "Codex desktop app connected (port 49999): Auto-swap ready")
        #expect(status.isHealthy)
    }
}
