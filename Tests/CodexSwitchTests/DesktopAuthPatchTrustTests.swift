import CryptoKit
import Foundation
import Testing
@testable import CodexSwitch

@Suite("Explicit desktop auth patch trust")
struct DesktopAuthPatchTrustTests {
    @Test("Local patch metadata binds the complete ASAR and compatibility markers")
    func metadataIsBoundToExactArchive() {
        let bytes = Data([
            "CODEXSWITCH_PRIORITY_AUTH_TRANSITION_V1",
            "CODEXSWITCH_AUTH_CACHE_INVALIDATION_V3",
            "CODEXSWITCH_AUTH_EVENT_DEDUPE_V1",
            "CODEXSWITCH_AUTH_SINGLE_FLIGHT_V1",
            "CODEXSWITCH_AUTH_TRANSITION_V2",
            "CODEXSWITCH_NATIVE_UPDATER_DISABLED_V1",
        ].joined(separator: " ").utf8)
        var info: [String: Any] = [
            "CFBundleIdentifier": "com.openai.codex",
            "CodexSwitchAuthPatchVersion": "CODEXSWITCH_PRIORITY_AUTH_TRANSITION_V1",
            "CodexSwitchAuthPatchAsarSHA256": SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }.joined(),
        ]
        #expect(CodexDesktopAppLocator.localAuthPatchMetadataMatches(info, asar: bytes))
        #expect(!CodexDesktopAppLocator.localAuthPatchMetadataMatches(info, asar: bytes + Data([0])))
        info["CodexSwitchAuthPatchVersion"] = "unknown"
        #expect(!CodexDesktopAppLocator.localAuthPatchMetadataMatches(info, asar: bytes))
        info["CodexSwitchAuthPatchVersion"] = "CODEXSWITCH_PRIORITY_AUTH_TRANSITION_V1"
        info["CFBundleIdentifier"] = "unrelated.application"
        #expect(!CodexDesktopAppLocator.localAuthPatchMetadataMatches(info, asar: bytes))
    }
}
