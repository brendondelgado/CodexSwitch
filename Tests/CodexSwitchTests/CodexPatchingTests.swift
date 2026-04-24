import Foundation
import Testing
@testable import CodexSwitch

@Suite("Codex patching")
struct CodexPatchingTests {
    @Test("Desktop appcast parser extracts the latest release")
    func parsesLatestDesktopRelease() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <title>26.417.41555</title>
              <sparkle:version>1858</sparkle:version>
              <sparkle:shortVersionString>26.417.41555</sparkle:shortVersionString>
              <enclosure
                url="https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-arm64-26.417.41555.zip"
                type="application/octet-stream" />
            </item>
          </channel>
        </rss>
        """

        let release = try #require(
            CodexDesktopAppcastParser.latestRelease(from: Data(xml.utf8))
        )

        #expect(release.shortVersion == "26.417.41555")
        #expect(release.bundleVersion == "1858")
        #expect(
            release.downloadURL.absoluteString
                == "https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-arm64-26.417.41555.zip"
        )
    }

    @Test("Desktop runtime label follows the live process state")
    func desktopRuntimeLabelFollowsUsageState() {
        let status = DesktopAppStatus(
            usageState: .appRunning,
            isRunning: true,
            port: nil
        )

        #expect(status.label == "Codex desktop app is running")
        #expect(status.autoSwapReady)
        #expect(status.autoSwapLabel == "Desktop auto-swap ready")
    }

    @Test("Desktop display state exposes update availability and auto-swap readiness separately")
    func desktopDisplayStateSeparatesPatchAndAutoSwap() {
        let summary = CodexDesktopAppStatusSummary(
            installedVersionLabel: "26.417.41555 (1858)",
            runtimeLabel: "stale runtime",
            patchLabel: "Desktop hot-swap ready",
            patchHealthy: true,
            canPatchNow: false
        )
        let liveStatus = DesktopAppStatus(
            usageState: .appRunning,
            isRunning: true,
            port: nil
        )
        let release = CodexDesktopAppRelease(
            shortVersion: "26.418.50000",
            bundleVersion: "1900",
            downloadURL: URL(string: "https://example.com/Codex.zip")!
        )

        let display = CodexVersionChecker.describeDesktop(
            summary: summary,
            liveStatus: liveStatus,
            latestRelease: release
        )

        #expect(display.installedVersionLabel == "26.417.41555 (1858)")
        #expect(display.latestVersionLabel == "26.418.50000 (1900)")
        #expect(display.runtimeLabel == "Codex desktop app is running")
        #expect(display.autoSwapLabel == "Desktop auto-swap ready")
        #expect(display.autoSwapReady)
        #expect(display.patchHealthy)
        #expect(display.updateAvailable)
    }

    @Test("Desktop display keeps auto-swap ready even when the bundle stays stock")
    func desktopDisplayKeepsStockBundleSwapReady() {
        let summary = CodexDesktopAppStatusSummary(
            installedVersionLabel: "26.417.41555 (1858)",
            runtimeLabel: "stale runtime",
            patchLabel: "Desktop compatibility will be verified automatically",
            patchHealthy: false,
            canPatchNow: true
        )
        let liveStatus = DesktopAppStatus(
            usageState: .appRunning,
            isRunning: true,
            port: nil
        )

        let display = CodexVersionChecker.describeDesktop(
            summary: summary,
            liveStatus: liveStatus,
            latestRelease: nil
        )

        #expect(display.autoSwapReady)
        #expect(display.autoSwapLabel == "Desktop auto-swap ready")
        #expect(!display.patchHealthy)
    }

    @Test("Desktop repair decider patches a stopped stock bundle without patch markers")
    func desktopRepairDeciderPatchesStoppedStockBundle() {
        let install = CodexDesktopAppInstall(
            appPath: "/Applications/Codex.app",
            asarPath: "/Applications/Codex.app/Contents/Resources/app.asar",
            bundleVersion: "1858",
            shortVersion: "26.417.41555"
        )

        let decision = CodexDesktopAppPatchRepairDecider.decision(
            currentInstall: install,
            savedState: nil,
            patchMarkerPresent: false,
            legacyPatchMarkerPresent: false,
            usageState: .notRunning,
            bundleIsValid: true,
            signatureStatus: .officialOpenAI
        )

        #expect(decision == .repairNeeded)
    }

    @Test("Desktop repair decider accepts a valid stock bundle with matching state")
    func desktopRepairDeciderAcceptsStockBundleWithMatchingState() {
        let install = CodexDesktopAppInstall(
            appPath: "/Applications/Codex.app",
            asarPath: "/Applications/Codex.app/Contents/Resources/app.asar",
            bundleVersion: "1858",
            shortVersion: "26.417.41555"
        )
        let savedState = CodexDesktopPatchedAppState(
            bundleVersion: "1858",
            asarPath: "/Applications/Codex.app/Contents/Resources/app.asar"
        )

        let decision = CodexDesktopAppPatchRepairDecider.decision(
            currentInstall: install,
            savedState: savedState,
            patchMarkerPresent: false,
            legacyPatchMarkerPresent: false,
            usageState: .notRunning,
            bundleIsValid: true,
            signatureStatus: .officialOpenAI
        )

        #expect(decision == .noRepairNeeded)
    }

    @Test("Desktop signature parser distinguishes official and ad-hoc bundles")
    func desktopSignatureParserDistinguishesStableIdentity() {
        let official = CodexDesktopAppLocator.signatureStatus(
            from: """
            Executable=/Applications/Codex.app/Contents/MacOS/Codex
            TeamIdentifier=2DC432GLL2
            Authority=Developer ID Application: OpenAI, L.L.C. (2DC432GLL2)
            """
        )
        let adHoc = CodexDesktopAppLocator.signatureStatus(
            from: """
            Executable=/Applications/Codex.app/Contents/MacOS/Codex
            Signature=adhoc
            TeamIdentifier=not set
            """
        )

        #expect(official == .officialOpenAI)
        #expect(adHoc == .adHoc)
    }

    @Test("Lightweight rebuild uses the fork-release Codex binary artifact")
    func lightweightRebuildUsesForkReleaseArtifact() {
        let plan = CodexVersionChecker.forkBuildPlan(
            targetDirectory: "/Users/test/Developer/codex/codex-rs/target"
        )

        #expect(plan.cargoArguments == [
            "build",
            "--profile", "fork-release",
            "-p", "codex-cli",
            "--bin", "codex",
        ])
        #expect(
            plan.outputBinaryPath
                == "/Users/test/Developer/codex/codex-rs/target/fork-release/codex"
        )
    }

    @Test("Patch target resolves to Homebrew cask binary when codex is installed from cask")
    func resolvesHomebrewCaskPatchTarget() {
        let install = CodexInstallLocator.install(
            whichCodexPath: "/opt/homebrew/bin/codex",
            resolvedExecutablePath: "/opt/homebrew/Caskroom/codex/0.120.0/codex-aarch64-apple-darwin",
            npmVendorBinaryPath: "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex"
        )

        #expect(install.channel == .homebrewCask)
        #expect(install.patchTargetPath == "/opt/homebrew/Caskroom/codex/0.120.0/codex-aarch64-apple-darwin")
    }

    @Test("Current upstream SIGHUP verification markers are accepted")
    func acceptsCurrentVerifiedMarkers() {
        let markerDirectory = "/Users/test/.codexswitch"

        let hasTuiMarker = CodexSighupMarkers.hasVerifiedMarker(
            markerDirectory: markerDirectory,
            fileExists: { $0 == "\(markerDirectory)/sighup-verified-tui" }
        )
        let hasExecMarker = CodexSighupMarkers.hasVerifiedMarker(
            markerDirectory: markerDirectory,
            fileExists: { $0 == "\(markerDirectory)/sighup-verified-exec" }
        )

        #expect(hasTuiMarker)
        #expect(hasExecMarker)
    }

    @Test("Auto repair is required when the patched state drifts from the active install")
    func needsRepairWhenPatchedStateDrifts() {
        let install = CodexInstall(
            executablePath: "/opt/homebrew/bin/codex",
            resolvedExecutablePath: "/opt/homebrew/Caskroom/codex/0.121.0/codex-aarch64-apple-darwin",
            patchTargetPath: "/opt/homebrew/Caskroom/codex/0.121.0/codex-aarch64-apple-darwin",
            channel: .homebrewCask
        )
        let staleState = CodexPatchedInstallState(
            version: "0.120.0",
            patchTargetPath: "/opt/homebrew/Caskroom/codex/0.120.0/codex-aarch64-apple-darwin"
        )

        #expect(CodexPatchRepairDecider.needsRepair(
            forkEnabled: true,
            currentInstall: install,
            currentVersion: "0.121.0",
            savedState: staleState
        ))
    }

    @Test("Auto repair is skipped when patched state still matches the active install")
    func skipsRepairWhenPatchedStateMatches() {
        let install = CodexInstall(
            executablePath: "/opt/homebrew/bin/codex",
            resolvedExecutablePath: "/opt/homebrew/Caskroom/codex/0.121.0/codex-aarch64-apple-darwin",
            patchTargetPath: "/opt/homebrew/Caskroom/codex/0.121.0/codex-aarch64-apple-darwin",
            channel: .homebrewCask
        )
        let currentState = CodexPatchedInstallState(
            version: "0.121.0",
            patchTargetPath: "/opt/homebrew/Caskroom/codex/0.121.0/codex-aarch64-apple-darwin"
        )

        #expect(!CodexPatchRepairDecider.needsRepair(
            forkEnabled: true,
            currentInstall: install,
            currentVersion: "0.121.0",
            savedState: currentState
        ))
    }

    @Test("Bootstrap only trusts existing patch state when the current-version backup exists")
    func recoversPatchedStateOnlyWithCurrentVersionBackup() {
        let install = CodexInstall(
            executablePath: "/opt/homebrew/bin/codex",
            resolvedExecutablePath: "/opt/homebrew/Caskroom/codex/0.121.0/codex-aarch64-apple-darwin",
            patchTargetPath: "/opt/homebrew/Caskroom/codex/0.121.0/codex-aarch64-apple-darwin",
            channel: .homebrewCask
        )
        let expectedBackup = "/opt/homebrew/Caskroom/codex/0.121.0/codex-aarch64-apple-darwin.stock-v0.121.0"

        let recovered = CodexPatchRepairDecider.canRecoverPatchedState(
            verifiedMarkerPresent: true,
            currentInstall: install,
            currentVersion: "0.121.0",
            fileExists: { $0 == expectedBackup }
        )

        #expect(recovered)
    }

    @Test("Bootstrap rejects stale markers when there is no current-version backup")
    func rejectsStaleMarkersWithoutCurrentVersionBackup() {
        let install = CodexInstall(
            executablePath: "/opt/homebrew/bin/codex",
            resolvedExecutablePath: "/opt/homebrew/Caskroom/codex/0.121.0/codex-aarch64-apple-darwin",
            patchTargetPath: "/opt/homebrew/Caskroom/codex/0.121.0/codex-aarch64-apple-darwin",
            channel: .homebrewCask
        )

        let recovered = CodexPatchRepairDecider.canRecoverPatchedState(
            verifiedMarkerPresent: true,
            currentInstall: install,
            currentVersion: "0.121.0",
            fileExists: { _ in false }
        )

        #expect(!recovered)
    }

    @Test("Desktop app repair defers a running stock unpatched bundle")
    func desktopRepairDefersRunningStockBundle() {
        let install = CodexDesktopAppInstall(
            appPath: "/Applications/Codex.app",
            asarPath: "/Applications/Codex.app/Contents/Resources/app.asar",
            bundleVersion: "1799",
            shortVersion: "26.415.40636"
        )

        let decision = CodexDesktopAppPatchRepairDecider.decision(
            currentInstall: install,
            savedState: nil,
            patchMarkerPresent: false,
            legacyPatchMarkerPresent: false,
            usageState: .appRunning,
            bundleIsValid: true,
            signatureStatus: .officialOpenAI
        )

        #expect(decision == .deferWhileRunning)
    }

    @Test("Desktop app repair patches a valid stock bundle when Codex is stopped")
    func desktopRepairPatchesStoppedStockBundle() {
        let install = CodexDesktopAppInstall(
            appPath: "/Applications/Codex.app",
            asarPath: "/Applications/Codex.app/Contents/Resources/app.asar",
            bundleVersion: "1799",
            shortVersion: "26.415.40636"
        )

        let decision = CodexDesktopAppPatchRepairDecider.decision(
            currentInstall: install,
            savedState: nil,
            patchMarkerPresent: false,
            legacyPatchMarkerPresent: false,
            usageState: .notRunning,
            bundleIsValid: true,
            signatureStatus: .officialOpenAI
        )

        #expect(decision == .repairNeeded)
    }

    @Test("Desktop app repair does not defer when only the detached app-server is running")
    func desktopRepairDoesNotDeferForBackgroundService() {
        let install = CodexDesktopAppInstall(
            appPath: "/Applications/Codex.app",
            asarPath: "/Applications/Codex.app/Contents/Resources/app.asar",
            bundleVersion: "1858",
            shortVersion: "26.417.41555"
        )
        let staleState = CodexDesktopPatchedAppState(
            bundleVersion: "1799",
            asarPath: "/Applications/Codex.app/Contents/Resources/app.asar"
        )

        let decision = CodexDesktopAppPatchRepairDecider.decision(
            currentInstall: install,
            savedState: staleState,
            patchMarkerPresent: false,
            legacyPatchMarkerPresent: false,
            usageState: .backgroundServiceOnly,
            bundleIsValid: false,
            signatureStatus: .unreadable
        )

        #expect(decision == .repairNeeded)
    }

    @Test("Desktop app repair does not trust unrecorded ad-hoc bundles")
    func desktopRepairDoesNotTrustUnrecordedAdHocBundle() {
        let install = CodexDesktopAppInstall(
            appPath: "/Applications/Codex.app",
            asarPath: "/Applications/Codex.app/Contents/Resources/app.asar",
            bundleVersion: "1858",
            shortVersion: "26.417.41555"
        )

        let decision = CodexDesktopAppPatchRepairDecider.decision(
            currentInstall: install,
            savedState: nil,
            patchMarkerPresent: true,
            legacyPatchMarkerPresent: false,
            usageState: .notRunning,
            bundleIsValid: true,
            signatureStatus: .adHoc
        )

        #expect(decision == .repairNeeded)
    }

    @Test("Desktop app repair does not trust matching patch state when bundle signature is invalid")
    func desktopRepairRebuildsWhenBundleSignatureIsInvalid() {
        let install = CodexDesktopAppInstall(
            appPath: "/Applications/Codex.app",
            asarPath: "/Applications/Codex.app/Contents/Resources/app.asar",
            bundleVersion: "1858",
            shortVersion: "26.417.41555"
        )
        let currentState = CodexDesktopPatchedAppState(
            bundleVersion: "1858",
            asarPath: "/Applications/Codex.app/Contents/Resources/app.asar"
        )

        let decision = CodexDesktopAppPatchRepairDecider.decision(
            currentInstall: install,
            savedState: currentState,
            patchMarkerPresent: true,
            legacyPatchMarkerPresent: false,
            usageState: .notRunning,
            bundleIsValid: false,
            signatureStatus: .adHoc
        )

        #expect(decision == .repairNeeded)
    }

    @Test("Desktop restore preparation stops detached app-server before reinstall")
    func desktopRestorePreparationStopsDetachedAppServer() {
        var terminatedPath: String?

        let result = CodexDesktopAppPatcher.prepareForRestore(
            usageState: .backgroundServiceOnly,
            appPath: "/Applications/Codex.app",
            stopDetachedAppServer: { appPath in
                terminatedPath = appPath
                return true
            }
        )

        #expect(result == nil)
        #expect(terminatedPath == "/Applications/Codex.app")
    }

    @Test("Desktop restore preparation surfaces detached app-server shutdown failures")
    func desktopRestorePreparationFailsWhenDetachedAppServerWontStop() {
        let result = CodexDesktopAppPatcher.prepareForRestore(
            usageState: .backgroundServiceOnly,
            appPath: "/Applications/Codex.app",
            stopDetachedAppServer: { _ in false }
        )

        #expect(result?.success == false)
        #expect(result?.message == "Failed to stop the detached Codex app-server before restoring the desktop bundle")
    }

    @Test("Desktop app process classifier ignores detached app-server as a patch blocker")
    func desktopProcessClassifierIgnoresDetachedAppServer() {
        let usageState = CodexDesktopAppProcessClassifier.usageState(
            appPath: "/Applications/Codex.app",
            processCommands: [
                "/Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled"
            ]
        )

        #expect(usageState == .backgroundServiceOnly)
    }

    @Test("Desktop app process classifier blocks patching when the GUI app binary is running")
    func desktopProcessClassifierBlocksForegroundApp() {
        let usageState = CodexDesktopAppProcessClassifier.usageState(
            appPath: "/Applications/Codex.app",
            processCommands: [
                "/Applications/Codex.app/Contents/MacOS/Codex"
            ]
        )

        #expect(usageState == .appRunning)
    }

    @Test("Desktop app repair runs when the tracked build changed and the new asar is unpatched")
    func desktopRepairRunsWhenBuildChanges() {
        let install = CodexDesktopAppInstall(
            appPath: "/Applications/Codex.app",
            asarPath: "/Applications/Codex.app/Contents/Resources/app.asar",
            bundleVersion: "1799",
            shortVersion: "26.415.40636"
        )
        let staleState = CodexDesktopPatchedAppState(
            bundleVersion: "1763",
            asarPath: "/Applications/Codex.app/Contents/Resources/app.asar"
        )

        let decision = CodexDesktopAppPatchRepairDecider.decision(
            currentInstall: install,
            savedState: staleState,
            patchMarkerPresent: false,
            legacyPatchMarkerPresent: false,
            usageState: .notRunning,
            bundleIsValid: false,
            signatureStatus: .unreadable
        )

        #expect(decision == .repairNeeded)
    }

    @Test("Desktop app repair defers while an ad-hoc bundle is still running")
    func desktopRepairDefersForRunningAdHocBundle() {
        let install = CodexDesktopAppInstall(
            appPath: "/Applications/Codex.app",
            asarPath: "/Applications/Codex.app/Contents/Resources/app.asar",
            bundleVersion: "1858",
            shortVersion: "26.417.41555"
        )

        let decision = CodexDesktopAppPatchRepairDecider.decision(
            currentInstall: install,
            savedState: nil,
            patchMarkerPresent: false,
            legacyPatchMarkerPresent: false,
            usageState: .appRunning,
            bundleIsValid: true,
            signatureStatus: .adHoc
        )

        #expect(decision == .deferWhileRunning)
    }
}
