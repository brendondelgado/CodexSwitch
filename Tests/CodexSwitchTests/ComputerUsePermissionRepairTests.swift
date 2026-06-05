import Testing
@testable import CodexSwitch

@Suite("Computer Use permission repair")
struct ComputerUsePermissionRepairTests {
    @Test("Computer Use grants are generic through System Events")
    func computerUseGrantsAreGenericThroughSystemEvents() {
        let clientIDs = ComputerUsePermissionRepair.genericAppleEventsClients.map(\.bundleIdentifier)

        #expect(clientIDs.contains("com.openai.codex"))
        #expect(clientIDs.contains("com.openai.sky.CUAService"))
        #expect(clientIDs.contains("com.openai.sky.CUAService.cli"))
        #expect(!clientIDs.contains { $0.localizedCaseInsensitiveContains("ColorControl") })
    }

    @Test("AppleEvents SQL targets System Events, not a single app")
    func appleEventsSQLTargetsSystemEventsNotSingleApp() {
        let sql = ComputerUsePermissionRepair.appleEventsUpsertSQL(
            clientBundleIdentifier: "com.openai.sky.CUAService.cli",
            clientRequirementHex: "fade0c00",
            targetRequirementHex: "fade0c01",
            timestamp: 1_777_000_000
        )

        #expect(sql.contains("com.openai.sky.CUAService.cli"))
        #expect(sql.contains("com.apple.systemevents"))
        #expect(!sql.localizedCaseInsensitiveContains("ColorControl"))
        #expect(!sql.contains("com.brendondelgado.ColorControlMac"))
    }
}
