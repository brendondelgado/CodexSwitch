import Foundation
import Testing
@testable import CodexSwitch

@Suite("Desktop app status")
struct DesktopStatusTests {
    @Test("Running patched desktop app without live hot-swap asks for restart")
    func patchedDesktopAppRequiresRestart() {
        let status = DesktopAppStatus(
            isRunning: true,
            port: nil,
            hotSwapReady: false,
            patchInstalled: true,
            patchMessage: "Desktop app is ready."
        )

        #expect(status.label == "Codex desktop app running: restart Codex.app to activate hot-swap")
        #expect(status.icon == "desktopcomputer.trianglebadge.exclamationmark")
        #expect(status.isHealthy == false)
    }

    @Test("Connected port without live hot-swap does not claim ready")
    func connectedPortWithoutHotSwapIsNotReady() {
        let status = DesktopAppStatus(
            isRunning: true,
            port: 49_999,
            hotSwapReady: false,
            patchInstalled: true,
            patchMessage: "Desktop app is ready."
        )

        #expect(status.label == "Codex desktop app connected (port 49999): restart Codex.app to activate hot-swap")
        #expect(status.isHealthy == false)
    }

    @Test("Desktop status surfaces patch blocker instead of generic missing patch")
    func desktopStatusSurfacesPatchBlocker() {
        let running = DesktopAppStatus(
            isRunning: true,
            port: nil,
            hotSwapReady: false,
            patchInstalled: false,
            patchMessage: "Desktop app patch blocked: Apple signing identity/private key is missing; quitting Codex.app alone will not patch it."
        )
        #expect(
            running.label == "Codex desktop app running: Desktop app patch blocked: Apple signing identity/private key is missing; quitting Codex.app alone will not patch it."
        )

        let stopped = DesktopAppStatus(
            isRunning: false,
            port: nil,
            hotSwapReady: false,
            patchInstalled: false,
            patchMessage: "Desktop app patch blocked: Apple signing identity/private key is missing. Revoke and recreate Apple Development in Xcode."
        )
        #expect(
            stopped.label == "Codex desktop app not running: Desktop app patch blocked: Apple signing identity/private key is missing. Revoke and recreate Apple Development in Xcode."
        )
    }

    @Test("Computer Use plugin must preserve official OpenAI signature")
    func computerUsePluginMustPreserveOfficialSignature() {
        #expect(
            DesktopPatchManager.computerUsePluginSignatureCompatible(
                parentTeam: "Y6LQRA2L45",
                pluginTeams: ["2DC432GLL2", "2DC432GLL2"]
            ) == false
        )
        #expect(
            DesktopPatchManager.computerUsePluginSignatureCompatible(
                parentTeam: "Y6LQRA2L45",
                pluginTeams: ["Y6LQRA2L45", "Y6LQRA2L45"]
            ) == false
        )
        #expect(
            DesktopPatchManager.computerUsePluginSignatureCompatible(
                parentTeam: "2DC432GLL2",
                pluginTeams: ["2DC432GLL2", "2DC432GLL2"]
            ) == true
        )
        #expect(
            DesktopPatchManager.computerUsePluginSignatureCompatible(
                parentTeam: "Y6LQRA2L45",
                pluginTeams: ["Y6LQRA2L45", "Y6LQRA2L45"],
                pluginEntitlements: [
                    "<string>2DC432GLL2.com.openai.sky.CUAService.cli</string>",
                    "<string>2DC432GLL2.com.openai.sky.CUAService</string>",
                ]
            ) == false
        )
        #expect(
            DesktopPatchManager.computerUsePluginSignatureCompatible(
                parentTeam: "Y6LQRA2L45",
                pluginTeams: ["2DC432GLL2", "2DC432GLL2"],
                pluginEntitlements: [
                    "<string>2DC432GLL2.com.openai.sky.CUAService.cli</string>",
                    "<string>2DC432GLL2.com.openai.sky.CUAService</string>",
                ]
            ) == false
        )
        #expect(
            DesktopPatchManager.computerUsePluginSignatureCompatible(
                parentTeam: "2DC432GLL2",
                pluginTeams: ["2DC432GLL2", "2DC432GLL2"],
                pluginEntitlements: [
                    "<string>2DC432GLL2.com.openai.sky.CUAService.cli</string>",
                    "<string>2DC432GLL2.com.openai.sky.CUAService</string>",
                ]
            ) == true
        )
    }


    @Test("Auth shell patch with preserved Computer Use signatures is desktop-ready")
    func authShellPatchWithPreservedComputerUseSignaturesIsDesktopReady() {
        let markers = DesktopPatchManager.InstalledMarkers(
            auth: true,
            fast: false,
            bundledPluginListRoot: false,
            bundledCLI: false,
            versionCompatible: true,
            computerUsePluginSignatureCompatible: true
        )

        #expect(!markers.required)
        #expect(markers.desktopIntegrationInstalled)
        #expect(markers.computerUsePreservedModeInstalled)
        #expect(
            DesktopPatchManager.statusMessage(
                running: true,
                runtimeState: .ready,
                automaticPatchingEnabled: true,
                permissionDeniedBackoffActive: false,
                codexAppSignatureCompatible: true,
                markers: markers
            ) == "Desktop app is ready."
        )
    }

    @Test("Locally signed shell with preserved Computer Use signatures is desktop-ready")
    func locallySignedShellWithPreservedComputerUseSignaturesIsDesktopReady() {
        let markers = DesktopPatchManager.InstalledMarkers(
            auth: true,
            fast: false,
            bundledPluginListRoot: false,
            bundledCLI: false,
            versionCompatible: true,
            computerUsePluginSignatureCompatible: true
        )

        #expect(
            DesktopPatchManager.statusMessage(
                running: true,
                runtimeState: .unknown,
                automaticPatchingEnabled: true,
                permissionDeniedBackoffActive: false,
                codexAppSignatureCompatible: false,
                markers: markers
            ) == "Desktop app patch is installed, but live hot-swap is not confirmed."
        )
    }

    @Test("Official Codex app without auth shell patch requests patch window")
    func officialCodexAppWithoutAuthShellPatchRequestsPatchWindow() {
        let markers = DesktopPatchManager.InstalledMarkers(
            auth: false,
            fast: false,
            bundledPluginListRoot: false,
            bundledCLI: false,
            versionCompatible: true,
            computerUsePluginSignatureCompatible: true
        )

        #expect(
            DesktopPatchManager.statusMessage(
                running: true,
                runtimeState: .unknown,
                automaticPatchingEnabled: false,
                permissionDeniedBackoffActive: false,
                codexAppSignatureCompatible: true,
                markers: markers
            ) == "Desktop app patch pending: Codex.app/app-server is still running; use ⌘Q to quit."
        )
    }

    @Test("Missing desktop patch reports disabled only when user setting is off")
    func missingDesktopPatchReportsDisabledOnlyWhenUserSettingIsOff() {
        let markers = DesktopPatchManager.InstalledMarkers(
            auth: false,
            fast: false,
            bundledPluginListRoot: false,
            bundledCLI: false,
            versionCompatible: true,
            computerUsePluginSignatureCompatible: true
        )

        #expect(
            DesktopPatchManager.statusMessage(
                running: false,
                runtimeState: .unknown,
                automaticPatchingEnabled: false,
                permissionDeniedBackoffActive: false,
                codexAppSignatureCompatible: true,
                markers: markers
            ) == "Desktop app hot-swap patch is off in CodexSwitch settings."
        )
    }

    @Test("Missing desktop patch auto repairs by default")
    func missingDesktopPatchAutoRepairsByDefault() {
        let markers = DesktopPatchManager.InstalledMarkers(
            auth: false,
            fast: false,
            bundledPluginListRoot: false,
            bundledCLI: false,
            versionCompatible: true,
            computerUsePluginSignatureCompatible: true
        )

        #expect(
            DesktopPatchManager.statusMessage(
                running: false,
                runtimeState: .unknown,
                automaticPatchingEnabled: true,
                permissionDeniedBackoffActive: false,
                codexAppSignatureCompatible: true,
                markers: markers
            ) == "Desktop app patch missing; will patch in background."
        )
    }

    @Test("Missing signing identity reports blocked instead of pending")
    func missingSigningIdentityReportsBlockedInsteadOfPending() {
        let markers = DesktopPatchManager.InstalledMarkers(
            auth: false,
            fast: false,
            bundledPluginListRoot: false,
            bundledCLI: false,
            versionCompatible: true,
            computerUsePluginSignatureCompatible: true
        )

        #expect(
            DesktopPatchManager.statusMessage(
                running: false,
                runtimeState: .unknown,
                automaticPatchingEnabled: true,
                permissionDeniedBackoffActive: false,
                codexAppSignatureCompatible: true,
                codesignIdentityAvailable: false,
                markers: markers
            ) == "Desktop app patch blocked: Apple signing identity/private key is missing. Revoke and recreate Apple Development in Xcode."
        )
    }

    @Test("Missing signing identity reports blocked even while app is running")
    func missingSigningIdentityReportsBlockedWhileRunning() {
        let markers = DesktopPatchManager.InstalledMarkers(
            auth: false,
            fast: false,
            bundledPluginListRoot: false,
            bundledCLI: false,
            versionCompatible: true,
            computerUsePluginSignatureCompatible: true
        )

        #expect(
            DesktopPatchManager.statusMessage(
                running: true,
                runtimeState: .unknown,
                automaticPatchingEnabled: true,
                permissionDeniedBackoffActive: false,
                codexAppSignatureCompatible: true,
                codesignIdentityAvailable: false,
                markers: markers
            ) == "Desktop app patch blocked: Apple signing identity/private key is missing; quitting Codex.app alone will not patch it."
        )
    }

    @Test("Local self-signed identity is rejected for desktop patching")
    func localSigningIdentityIsRejectedForDesktopPatching() {
        #expect(
            DesktopPatchManager.allowedCodesignIdentityLine(
                #"1) 8CFF4BA0812483B709263B1AA1B28B763BCB786D "CodexSwitch Local Code Signing""#
            ) == false
        )
        #expect(
            DesktopPatchManager.allowedCodesignIdentityLine(
                #"1) 05F3F54B7BC635F239D9420690E1ED22C693FFD0 "Apple Development: Brendon Delgado (856E75LLMU)""#
            ) == true
        )
    }


    @Test("Global vendor CLI repair is disabled")
    func globalVendorCLIRepairIsDisabled() {
        #expect(DesktopPatchManager.stockVendorCLIRepairAllowed() == false)
    }

    @Test("Post-quit desktop patch retry keeps trying through transient blockers")
    func postQuitPatchRetryKeepsTryingThroughTransientBlockers() {
        #expect(DesktopPatchManager.postQuitPatchRetryDelaysSeconds == [1, 3, 8, 20, 45])
        #expect(DesktopPatchAttemptOutcome.waitingForCodexAppQuit.shouldStopPostQuitRetry == false)
        #expect(DesktopPatchAttemptOutcome.permissionDeniedBackoff.shouldStopPostQuitRetry == false)
        #expect(DesktopPatchAttemptOutcome.permissionDenied.shouldStopPostQuitRetry == false)
        #expect(DesktopPatchAttemptOutcome.cooldownActive.shouldStopPostQuitRetry == false)
        #expect(DesktopPatchAttemptOutcome.timedOut.shouldStopPostQuitRetry == false)
        #expect(DesktopPatchAttemptOutcome.failed(1).shouldStopPostQuitRetry == false)
    }

    @Test("Post-quit desktop patch retry stops on terminal outcomes")
    func postQuitPatchRetryStopsOnTerminalOutcomes() {
        #expect(DesktopPatchAttemptOutcome.notNeeded.shouldStopPostQuitRetry)
        #expect(DesktopPatchAttemptOutcome.disabled.shouldStopPostQuitRetry)
        #expect(DesktopPatchAttemptOutcome.missingSigningIdentity.shouldStopPostQuitRetry)
        #expect(DesktopPatchAttemptOutcome.scriptMissing.shouldStopPostQuitRetry)
        #expect(DesktopPatchAttemptOutcome.completed.shouldStopPostQuitRetry)
    }

    @Test("Marker scan does not require loading whole file")
    func markerScanFindsMarkersAcrossChunkBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("large-marker.bin")
        let data = Data("abcdef-CODEXSWITCH_MARKER-ghijkl".utf8)
        try data.write(to: file)

        #expect(
            DesktopPatchManager.fileContainsMarker(
                "CODEXSWITCH_MARKER",
                at: file.path,
                chunkSize: 10
            )
        )
        #expect(
            !DesktopPatchManager.fileContainsMarker(
                "CODEXSWITCH_MISSING",
                at: file.path,
                chunkSize: 10
            )
        )
    }

}
