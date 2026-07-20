import Foundation
import Testing
@testable import CodexSwitch

@Suite("Codex patching")
struct CodexPatchingTests {
    @Test("Desktop app locator prefers the unified ChatGPT bundle")
    func desktopAppLocatorPrefersUnifiedChatGPTBundle() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let unified = temp.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let legacy = temp.appendingPathComponent("Codex.app", isDirectory: true)
        for app in [legacy, unified] {
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            let resources = contents.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try Data().write(to: resources.appendingPathComponent("app.asar"))
            try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleIdentifier": "com.openai.codex",
                    "CFBundleVersion": "5042",
                    "CFBundleShortVersionString": "26.707.31123",
                ],
                format: .xml,
                options: 0
            ).write(to: contents.appendingPathComponent("Info.plist"))
        }

        let install = CodexDesktopAppLocator.locate(
            candidateAppPaths: [unified.path, legacy.path]
        )

        #expect(install?.appPath == unified.path)
    }

    @Test("Desktop updater accepts the unified ChatGPT archive layout")
    func desktopUpdaterAcceptsUnifiedArchiveLayout() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let unified = temp.appendingPathComponent("ChatGPT.app", isDirectory: true)
        try FileManager.default.createDirectory(at: unified, withIntermediateDirectories: true)

        let extracted = try #require(CodexDesktopAppUpdater.findDesktopApp(in: temp))

        #expect(extracted == unified)
        #expect(CodexDesktopAppUpdater.installationPath(for: extracted) == "/Applications/ChatGPT.app")
    }

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

    @Test("Desktop update comparison uses monotonically increasing bundle builds")
    func desktopUpdateComparisonUsesBundleBuilds() {
        #expect(CodexDesktopAppUpdater.isReleaseNewer(bundleVersion: "5103", than: "5059"))
        #expect(!CodexDesktopAppUpdater.isReleaseNewer(bundleVersion: "5059", than: "5059"))
        #expect(!CodexDesktopAppUpdater.isReleaseNewer(bundleVersion: "5042", than: "5059"))
    }

    @Test("Staged desktop update waits for a safe quit boundary")
    func stagedDesktopUpdateWaitsForSafeQuit() {
        #expect(
            CodexDesktopAppUpdater.installDecision(
                stagedBundleVersion: "5103",
                installedBundleVersion: "5059",
                desktopRuntimeRunning: true
            ) == .waitForDesktopQuit
        )
        #expect(
            CodexDesktopAppUpdater.installDecision(
                stagedBundleVersion: "5103",
                installedBundleVersion: "5059",
                desktopRuntimeRunning: false
            ) == .install
        )
        #expect(
            CodexDesktopAppUpdater.installDecision(
                stagedBundleVersion: "5059",
                installedBundleVersion: "5059",
                desktopRuntimeRunning: false
            ) == .discard
        )
    }

    @Test("Desktop update coordinator checks the official feed every minute")
    func desktopUpdateCoordinatorChecksEveryMinute() {
        #expect(CodexDesktopUpdateCoordinator.checkInterval == 60)
        #expect(CodexDesktopAppUpdater.hasEnoughDiskSpace(availableBytes: 6 * 1024 * 1024 * 1024))
        #expect(!CodexDesktopAppUpdater.hasEnoughDiskSpace(availableBytes: 512 * 1024 * 1024))
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

    @Test("Desktop app locator requires auth, recents, model, Fast, reconnect, and updater markers")
    func desktopAppLocatorRequiresCurrentDesktopPatchMarkers() throws {
        let temp = temporaryDirectory()
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let asar = temp.appendingPathComponent("app.asar")
        let install = CodexDesktopAppInstall(
            appPath: "/Applications/Codex.app",
            asarPath: asar.path,
            bundleVersion: "1858",
            shortVersion: "26.417.41555"
        )

        try Data("_invalidateAccountQueries".utf8).write(to: asar)
        #expect(!CodexDesktopAppLocator.patchMarkerPresent(install: install))

        try Data(
            "_invalidateAccountQueries CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH "
                .appending("CODEXSWITCH_MODEL_LABEL_FALLBACK")
                .utf8
        ).write(to: asar)
        #expect(!CodexDesktopAppLocator.patchMarkerPresent(install: install))

        try Data(
            "_invalidateAccountQueries CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH "
                .appending("CODEXSWITCH_MODEL_LABEL_FALLBACK ")
                .appending("CODEXSWITCH_MODEL_AVAILABILITY_FALLBACK")
                .utf8
        ).write(to: asar)
        #expect(!CodexDesktopAppLocator.patchMarkerPresent(install: install))

        try Data(
            "_invalidateAccountQueries CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH "
                .appending("CODEXSWITCH_MODEL_LABEL_FALLBACK ")
                .appending("CODEXSWITCH_MODEL_AVAILABILITY_FALLBACK ")
                .appending("CODEXSWITCH_SELECTED_MODEL_LABEL_FALLBACK ")
                .appending("CODEXSWITCH_REMOTE_MODEL_REFRESH_PATCH")
                .utf8
        ).write(to: asar)
        #expect(!CodexDesktopAppLocator.patchMarkerPresent(install: install))

        try Data(
            "_invalidateAccountQueries CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH "
                .appending("CODEXSWITCH_MODEL_LABEL_FALLBACK ")
                .appending("CODEXSWITCH_MODEL_AVAILABILITY_FALLBACK ")
                .appending("CODEXSWITCH_SELECTED_MODEL_LABEL_FALLBACK ")
                .appending("CODEXSWITCH_GPT56_MAX_EFFORT_FALLBACK ")
                .appending("CODEXSWITCH_REMOTE_MODEL_REFRESH_PATCH")
                .utf8
        ).write(to: asar)
        #expect(!CodexDesktopAppLocator.patchMarkerPresent(install: install))

        try Data(
            "_invalidateAccountQueries CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH "
                .appending("CODEXSWITCH_MODEL_LABEL_FALLBACK ")
                .appending("CODEXSWITCH_MODEL_AVAILABILITY_FALLBACK ")
                .appending("CODEXSWITCH_SELECTED_MODEL_LABEL_FALLBACK ")
                .appending("CODEXSWITCH_GPT56_MAX_EFFORT_FALLBACK ")
                .appending("CODEXSWITCH_REMOTE_MODEL_REFRESH_PATCH ")
                .appending("CODEXSWITCH_NATIVE_UPDATER_DISABLED_V1 ")
                .appending("_bundledFastModels")
                .utf8
        ).write(to: asar)
        #expect(!CodexDesktopAppLocator.patchMarkerPresent(install: install))

        try Data(
            "_invalidateAccountQueries CODEXSWITCH_AUTH_CACHE_INVALIDATION_V2 "
                .appending("CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH_V2 ")
                .appending("CODEXSWITCH_MODEL_LABEL_FALLBACK ")
                .appending("CODEXSWITCH_MODEL_AVAILABILITY_FALLBACK ")
                .appending("CODEXSWITCH_SELECTED_MODEL_LABEL_FALLBACK ")
                .appending("CODEXSWITCH_GPT56_MAX_EFFORT_FALLBACK ")
                .appending("CODEXSWITCH_REMOTE_MODEL_REFRESH_PATCH ")
                .appending("CODEXSWITCH_NATIVE_UPDATER_DISABLED_V1 ")
                .appending("_bundledFastModels")
                .utf8
        ).write(to: asar)
        #expect(CodexDesktopAppLocator.patchMarkerPresent(install: install))

        try Data(
            "_invalidateAccountQueries CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH "
                .appending("_codexSwitchEnsureDesktopAuthSync")
                .utf8
        ).write(to: asar)
        #expect(!CodexDesktopAppLocator.patchMarkerPresent(install: install))
        #expect(CodexDesktopAppLocator.legacyPatchMarkerPresent(install: install))
    }

    @Test("App packager refuses replacement when CodexSwitch does not quit")
    func appPackagerGuardsLiveBundleReplacement() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: projectRoot.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        let guardText = "if /usr/bin/pgrep -x \"$APP_NAME\" >/dev/null 2>&1; then"
        let refusalText = "refusing to replace its installed bundle"
        let activationText = "atomic_swap_paths \"$STAGED_PATH\" \"$INSTALL_PATH\""
        let guardRange = try #require(script.range(of: guardText))
        let refusalRange = try #require(script.range(of: refusalText))
        let activationRange = try #require(script.range(of: activationText))

        #expect(guardRange.lowerBound < refusalRange.lowerBound)
        #expect(refusalRange.lowerBound < activationRange.lowerBound)
        #expect(!script.contains("rm -rf \"$INSTALL_PATH\""))
    }

    private func temporaryDirectory() -> URL {
        let temporaryPath = (
            FileManager.default.temporaryDirectory.path as NSString
        ).standardizingPath
        let canonicalPath: String
        if temporaryPath == "/tmp" || temporaryPath.hasPrefix("/tmp/")
            || temporaryPath == "/var" || temporaryPath.hasPrefix("/var/") {
            canonicalPath = "/private\(temporaryPath)"
        } else {
            canonicalPath = temporaryPath
        }
        return URL(fileURLWithPath: canonicalPath, isDirectory: true)
            .appendingPathComponent(
                "CodexPatchingTests-\(UUID().uuidString)",
                isDirectory: true
            )
    }
}
