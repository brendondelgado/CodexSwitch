import Foundation
import Testing
@testable import CodexSwitch

@Suite("Codex desktop bridge keepalive")
struct CodexDesktopBridgeKeepAliveTests {
    @Test("Bridge script publishes one loopback WebSocket endpoint")
    func bridgeScriptUsesSingleManagedEndpoint() {
        let script = CodexDesktopBridgeKeepAlive.bridgeScript(
            launcherPath: "/Users/me/.local/share/codexswitch/patched-codex/codex"
        )

        #expect(script.contains("CODEX_APP_SERVER_WS_URL"))
        #expect(script.contains("ws://127.0.0.1:9223"))
        #expect(script.contains("app-server"))
        #expect(script.contains("--listen"))
        #expect(script.contains("exec \"$launcher\""))
        #expect(!script.contains("HEADROOM"))
    }

    @Test("Bridge launch agent is persistent and bounded")
    func bridgeLaunchAgentIsPersistent() {
        let plist = CodexDesktopBridgeKeepAlive.launchAgentPlist(
            scriptPath: "/Users/me/.codexswitch/bin/desktop-bridge.sh",
            standardOutputPath: "/Users/me/.codexswitch/logs/bridge.out.log",
            standardErrorPath: "/Users/me/.codexswitch/logs/bridge.err.log"
        )

        #expect(plist.contains("<string>com.codexswitch.desktop-app-server-9223</string>"))
        #expect(plist.contains("<key>RunAtLoad</key>"))
        #expect(plist.contains("<key>KeepAlive</key>"))
        #expect(plist.contains("<key>ThrottleInterval</key>"))
        #expect(plist.contains("<integer>5</integer>"))
    }

    @Test("Bridge installation is scheduled off the main actor")
    func bridgeInstallationRunsOffMain() async {
        let observation = AsyncStream.makeStream(of: Bool.self)
        let installTask = await MainActor.run {
            AppDelegate.installDesktopBridgeOffMainActor {
                observation.continuation.yield(Thread.isMainThread)
                observation.continuation.finish()
            }
        }

        let ranOnMainThread = await nextElement(from: observation.stream)
        await installTask.value
        #expect(ranOnMainThread == false)
    }
}
