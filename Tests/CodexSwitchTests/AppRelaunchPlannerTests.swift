import Foundation
import Testing
@testable import CodexSwitch

@Suite("App relaunch planning")
struct AppRelaunchPlannerTests {
    @Test("Relaunch command waits for old process exit before reopening")
    func relaunchCommandWaitsForPriorProcessExit() {
        let command = AppRelaunchPlanner.shellCommand(
            appPath: "/Applications/CodexSwitch.app",
            currentProcessID: 31702
        )

        #expect(command.contains("kill -0 31702"))
        #expect(command.contains("/usr/bin/pgrep -x CodexSwitch >/dev/null 2>&1"))
        #expect(command.contains("sleep 0.1"))
        #expect(command.contains("sleep 1.0"))
        #expect(command.contains("sleep 3.0"))
        #expect(command.contains("/usr/bin/open -n '/Applications/CodexSwitch.app'"))
        #expect(command.contains("relaunch retry"))
        #expect(command.contains("relaunch.log"))
    }
}
