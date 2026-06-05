import Testing
@testable import CodexSwitch

@Suite("Desktop runtime hot-swap state")
struct DesktopRuntimeHotSwapStateTests {
    @Test("Any stale desktop bundled CLI process forces restart-required")
    func staleProcessForcesRestart() {
        let output = """
        10069 /Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled
        79565 /Applications/Codex.app/Contents/Resources/codex resume --yolo
        """

        let state = DesktopPatchManager.runtimeHotSwapState(from: output) { pid in
            pid != 10069
        }

        #expect(state == .restartRequired)
    }

    @Test("All live desktop bundled CLI processes patched and acknowledged means ready")
    func patchedRuntimeIsReady() {
        let output = """
        10069 /Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled
        79565 /Applications/Codex.app/Contents/Resources/codex resume --yolo
        """

        let state = DesktopPatchManager.runtimeHotSwapState(
            from: output,
            hotSwapSupport: { _ in true },
            hotSwapAck: { _ in true }
        )

        #expect(state == .ready)
    }

    @Test("Patched desktop runtime without live ack is not ready")
    func patchedRuntimeWithoutAckIsRestartRequired() {
        let output = """
        10069 /Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled
        """

        let state = DesktopPatchManager.runtimeHotSwapState(
            from: output,
            hotSwapSupport: { _ in true },
            hotSwapAck: { _ in false }
        )

        #expect(state == .restartRequired)
    }

    @Test("Homebrew vendor app-server process is a desktop runtime")
    func homebrewVendorAppServerIsDesktopRuntime() {
        let output = """
        90660 node /opt/homebrew/bin/codex app-server --analytics-default-enabled
        90722 /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex app-server --analytics-default-enabled
        """

        let state = DesktopPatchManager.runtimeHotSwapState(
            from: output,
            hotSwapSupport: { pid in pid == 90722 },
            hotSwapAck: { pid in pid == 90722 }
        )

        #expect(state == .ready)
    }

    @Test("Managed SIGHUP fork app-server is a desktop runtime")
    func managedSighupForkAppServerIsDesktopRuntime() {
        let output = """
        80379 /Users/brendondelgado/Developer/codex/codex-rs/target/fork-release/codex app-server --analytics-default-enabled
        """

        let state = DesktopPatchManager.runtimeHotSwapState(
            from: output,
            hotSwapSupport: { pid in pid == 80379 },
            hotSwapAck: { pid in pid == 80379 }
        )

        #expect(state == .ready)
    }

    @Test("Managed prepared Codex app-server is a desktop runtime")
    func managedPreparedCodexAppServerIsDesktopRuntime() {
        let output = """
        80806 /Users/brendondelgado/.local/share/codexswitch/prepared-codex/0.132.0/codex app-server --analytics-default-enabled
        """

        let state = DesktopPatchManager.runtimeHotSwapState(
            from: output,
            hotSwapSupport: { pid in pid == 80806 },
            hotSwapAck: { pid in pid == 80806 }
        )

        #expect(state == .ready)
    }

    @Test("Node launcher alone is not enough to prove desktop runtime")
    func nodeLauncherAloneIsIgnored() {
        let output = """
        90660 node /opt/homebrew/bin/codex app-server --analytics-default-enabled
        """

        let state = DesktopPatchManager.runtimeHotSwapState(from: output) { _ in false }

        #expect(state == .unknown)
    }
}
