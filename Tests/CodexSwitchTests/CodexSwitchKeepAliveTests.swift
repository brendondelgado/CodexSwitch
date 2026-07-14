import Foundation
import Testing
@testable import CodexSwitch

@Suite("CodexSwitch keepalive")
struct CodexSwitchKeepAliveTests {
    @Test("Watchdog script relaunches only when executable is missing")
    func watchdogScriptRelaunchesOnlyWhenExecutableIsMissing() {
        let script = CodexSwitchKeepAlive.watchdogScript(
            appPath: "/Applications/CodexSwitch.app",
            executablePath: "/Applications/CodexSwitch.app/Contents/MacOS/CodexSwitch"
        )

        #expect(script.contains("pgrep -fx \"$executable_path\""))
        #expect(script.contains("/usr/bin/open \"$app_path\""))
        #expect(script.contains("/bin/sleep 10"))
    }

    @Test("Launch agent keeps watchdog alive")
    func launchAgentKeepsWatchdogAlive() {
        let plist = CodexSwitchKeepAlive.launchAgentPlist(scriptPath: "/Users/me/.codexswitch/bin/codexswitch-watchdog.sh")

        #expect(plist.contains("<string>com.codexswitch.watchdog</string>"))
        #expect(plist.contains("<key>RunAtLoad</key>"))
        #expect(plist.contains("<key>KeepAlive</key>"))
        #expect(plist.contains("/Users/me/.codexswitch/bin/codexswitch-watchdog.sh"))
    }

    @Test("Launch scheduling runs keepalive installation off the main actor")
    func launchSchedulingRunsOffMain() async {
        let observation = AsyncStream.makeStream(of: Bool.self)
        let installTask = await MainActor.run {
            AppDelegate.installKeepAliveOffMainActor {
                observation.continuation.yield(Thread.isMainThread)
                observation.continuation.finish()
            }
        }

        let ranOnMainThread = await observation.stream.first(where: { _ in true })
        await installTask.value
        #expect(ranOnMainThread == false)
    }
}
