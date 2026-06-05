import Foundation
import Testing
@testable import CodexSwitch

@Suite("Codex version checker")
struct CodexVersionCheckerTests {
    @Test("Stable dist-tag is preferred even when alpha is newer")
    func stableDistTagPreferredEvenWhenAlphaIsNewer() {
        let target = CodexVersionChecker.preferredUpdateTarget(
            distTags: [
                "latest": "0.125.0",
                "alpha": "0.126.0-alpha.15",
            ]
        )

        #expect(target?.version == "0.125.0")
        #expect(target?.npmSpecifier == "@openai/codex@latest")
    }

    @Test("Alpha-only dist-tags are ignored for automatic updates")
    func alphaOnlyDistTagIsIgnoredForAutomaticUpdates() {
        let target = CodexVersionChecker.preferredUpdateTarget(
            distTags: [
                "alpha": "0.126.0-alpha.15",
            ]
        )

        #expect(target == nil)
    }

    @Test("Prerelease latest is ignored for automatic updates")
    func prereleaseLatestIsIgnoredForAutomaticUpdates() {
        let target = CodexVersionChecker.preferredUpdateTarget(
            distTags: [
                "latest": "0.129.0-alpha.1",
                "alpha": "0.129.0-alpha.1",
            ]
        )

        #expect(target == nil)
    }

    @Test("Stable latest is preferred once it catches alpha")
    func stableLatestPreferredWhenNotBehindAlpha() {
        let target = CodexVersionChecker.preferredUpdateTarget(
            distTags: [
                "latest": "0.126.0",
                "alpha": "0.126.0-alpha.15",
            ]
        )

        #expect(target?.version == "0.126.0")
        #expect(target?.npmSpecifier == "@openai/codex@latest")
    }

    @Test("Cargo workspace version replacement handles alpha versions")
    func cargoVersionReplacementHandlesAlphaVersions() {
        let input = """
        [workspace.package]
        version = "0.125.0"
        """

        let updated = CodexVersionChecker.replacingWorkspaceVersion(
            in: input,
            with: "0.126.0-alpha.15"
        )

        #expect(updated?.contains(#"version = "0.126.0-alpha.15""#) == true)
        #expect(
            CodexVersionChecker.replacingWorkspaceVersion(
                in: updated ?? "",
                with: "0.126.0-alpha.16"
            )?.contains(#"version = "0.126.0-alpha.16""#) == true
        )
    }

    @Test("Prerelease package triggers global CLI repair without launch probe")
    func prereleasePackageTriggersGlobalCLIRepair() {
        let health = CodexVersionChecker.CodexCLIHealth(
            healthy: true,
            version: "0.126.0-alpha.15",
            timedOut: false,
            terminationStatus: 0
        )

        #expect(
            CodexVersionChecker.shouldRepairGlobalCLI(
                packageVersion: "0.126.0-alpha.15",
                health: health
            )
        )
    }

    @Test("Killed or timed-out CLI triggers global CLI repair")
    func killedOrTimedOutCLITriggersGlobalCLIRepair() {
        #expect(
            CodexVersionChecker.shouldRepairGlobalCLI(
                packageVersion: "0.125.0",
                health: CodexVersionChecker.CodexCLIHealth(
                    healthy: false,
                    version: nil,
                    timedOut: false,
                    terminationStatus: 137
                )
            )
        )
        #expect(
            CodexVersionChecker.shouldRepairGlobalCLI(
                packageVersion: "0.125.0",
                health: CodexVersionChecker.CodexCLIHealth(
                    healthy: false,
                    version: nil,
                    timedOut: true,
                    terminationStatus: -1
                )
            )
        )
    }

    @Test("Healthy stable CLI does not trigger global CLI repair")
    func healthyStableCLIDoesNotTriggerGlobalCLIRepair() {
        #expect(
            CodexVersionChecker.shouldRepairGlobalCLI(
                packageVersion: "0.125.0",
                health: CodexVersionChecker.CodexCLIHealth(
                    healthy: true,
                    version: "0.125.0",
                    timedOut: false,
                    terminationStatus: 0
                )
            ) == false
        )
    }

    @Test("Launcher script prefers patched Codex for local sessions and synced client for remote")
    func launcherScriptPrefersPatchedCodexForLocalSessionsAndSyncedClientForRemote() {
        let script = CodexVersionChecker.launcherScript(
            syncedClientPath: "/tmp/synced-codex",
            managedPatchedCodexPath: "/tmp/patched-codex",
            forkBinaryPath: "/tmp/sighup-codex",
            homebrewCodexPath: "/tmp/brew-codex",
            desktopAppNativePath: "/tmp/app-codex"
        )

        let remoteRange = script.range(of: #"if args_request_remote "$@" && can_run_goal_capable "$SYNCED_CODEX"; then"#)
        let patchedRange = script.range(of: #"exec "$PATCHED_CODEX" -c 'plugins."computer-use@openai-bundled".enabled=false' "$@""#)
        let forkRange = script.range(of: #"exec "$SIGHUP_FORK" -c 'plugins."computer-use@openai-bundled".enabled=false' "$@""#)
        let envRange = script.range(of: #"exec "${CODEX_CLI_PATH}" "$@""#)
        let fallbackSyncedRange = script.range(of: #"exec "$SYNCED_CODEX" "$@""#, options: [], range: envRange!.upperBound..<script.endIndex)

        #expect(script.contains("SYNCED_CODEX='/tmp/synced-codex'"))
        #expect(script.contains("PATCHED_CODEX='/tmp/patched-codex'"))
        #expect(script.contains("SIGHUP_FORK='/tmp/sighup-codex'"))
        #expect(script.contains("args_request_remote"))
        #expect(script.contains("can_run_goal_capable"))
        #expect(script.contains("Usage: \\/goal <objective>"))
        #expect(script.contains(#"plugins."computer-use@openai-bundled".enabled=false"#))
        #expect(script.contains("/usr/bin/awk"))
        #expect(script.contains("hotswap-ack"))
        #expect(script.contains("CodexSwitch rotated accounts after a usage limit"))
        #expect(script.contains("Auth changed, opening new WebSocket with fresh credentials"))
        #expect(!script.contains("/usr/bin/grep -q 'sighup-verified'"))
        #expect(remoteRange != nil)
        #expect(patchedRange != nil)
        #expect(forkRange != nil)
        #expect(envRange != nil)
        #expect(fallbackSyncedRange != nil)
        #expect(remoteRange!.lowerBound < patchedRange!.lowerBound)
        #expect(patchedRange!.lowerBound < forkRange!.lowerBound)
        #expect(forkRange!.lowerBound < envRange!.lowerBound)
        #expect(envRange!.lowerBound < fallbackSyncedRange!.lowerBound)
    }

    @Test("Homebrew bridge script routes desktop app-server through patched runtime")
    func homebrewBridgeScriptRoutesDesktopAppServerThroughPatchedRuntime() {
        let script = CodexVersionChecker.homebrewBridgeScript(
            syncedClientPath: "/tmp/synced-codex",
            managedPatchedCodexPath: "/tmp/patched-codex",
            forkBinaryPath: "/tmp/sighup-codex",
            originalEntryPath: "/tmp/original-codex.js",
            desktopAppNativePath: "/tmp/app-bundled-codex"
        )

        let remoteRange = script.range(of: #"if args_request_remote "$@" && can_run_goal_capable "$SYNCED_CODEX"; then"#)
        let patchedRange = script.range(of: #"exec "$PATCHED_CODEX" -c 'plugins."computer-use@openai-bundled".enabled=false' "$@""#)
        let forkRange = script.range(of: #"exec "$SIGHUP_FORK" -c 'plugins."computer-use@openai-bundled".enabled=false' "$@""#)
        let fallbackSyncedRange = script.range(of: #"exec "$SYNCED_CODEX" "$@""#, options: [], range: forkRange!.upperBound..<script.endIndex)
        let originalRange = script.range(of: #"exec "$ORIGINAL_NODE_ENTRY" "$@""#)

        #expect(script.contains("SYNCED_CODEX='/tmp/synced-codex'"))
        #expect(script.contains("PATCHED_CODEX='/tmp/patched-codex'"))
        #expect(script.contains("SIGHUP_FORK='/tmp/sighup-codex'"))
        #expect(script.contains("ORIGINAL_NODE_ENTRY='/tmp/original-codex.js'"))
        #expect(script.contains("DESKTOP_APP_NATIVE='/tmp/app-bundled-codex'"))
        #expect(script.contains("can_run_goal_capable"))
        #expect(script.contains("Usage: \\/goal <objective>"))
        #expect(script.contains(#"plugins."computer-use@openai-bundled".enabled=false"#))
        #expect(script.contains("hotswap-ack"))
        #expect(script.contains("CodexSwitch rotated accounts after a usage limit"))
        #expect(script.contains("Auth changed, opening new WebSocket with fresh credentials"))
        #expect(!script.contains("/Applications/Codex.app/Contents/MacOS/Codex"))
        #expect(!script.contains(#"exec "$DESKTOP_APP_NATIVE" "$@""#))
        #expect(remoteRange != nil)
        #expect(patchedRange != nil)
        #expect(forkRange != nil)
        #expect(fallbackSyncedRange != nil)
        #expect(originalRange != nil)
        #expect(remoteRange!.lowerBound < patchedRange!.lowerBound)
        #expect(patchedRange!.lowerBound < forkRange!.lowerBound)
        #expect(forkRange!.lowerBound < fallbackSyncedRange!.lowerBound)
        #expect(fallbackSyncedRange!.lowerBound < originalRange!.lowerBound)
    }

    @Test("SIGHUP support requires reload, ack, and usage retry markers")
    func sighupSupportRequiresReloadAckAndUsageRetryMarkers() {
        #expect(CodexVersionChecker.binaryHasSighupSupportData(Data("sighup-verified".utf8)) == false)
        #expect(CodexVersionChecker.binaryHasSighupSupportData(Data("SIGHUP: auth reloaded".utf8)) == false)
        #expect(
            CodexVersionChecker.binaryHasSighupSupportData(
                Data("abc sighup-verified xyz SIGHUP: auth reloaded".utf8)
            ) == false
        )
        #expect(
            CodexVersionChecker.binaryHasSighupSupportData(
                Data("abc sighup-verified xyz SIGHUP: auth reloaded hotswap-ack".utf8)
            ) == false
        )
        #expect(
            CodexVersionChecker.binaryHasSighupSupportData(
                Data("abc sighup-verified xyz SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit".utf8)
            ) == false
        )
        #expect(
            CodexVersionChecker.binaryHasSighupSupportData(
                Data("abc sighup-verified xyz SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit Auth changed, opening new WebSocket with fresh credentials".utf8)
            )
        )
    }

    @Test("Goal support marker accepts slash command or app-server goal RPC markers")
    func goalSupportMarkerAcceptsSlashCommandOrAppServerGoalRPCMarkers() {
        #expect(CodexVersionChecker.binaryHasGoalSupportData(Data("Usage: /goal <objective>".utf8)))
        #expect(CodexVersionChecker.binaryHasGoalSupportData(Data("Pursuing goal thread/goal/set".utf8)))
        #expect(CodexVersionChecker.binaryHasGoalSupportData(Data("Pursuing goal".utf8)) == false)
    }

    @Test("Prepared hot-swap binary discovery prefers newest launchable version")
    func preparedHotSwapBinaryDiscoveryPrefersNewestLaunchableVersion() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "codexswitch-prepared-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try writeFakeCodex(
            version: "0.127.0",
            root: root,
            markers: "sighup-verified SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit Auth changed, opening new WebSocket with fresh credentials Usage: /goal <objective>"
        )
        let newest = try writeFakeCodex(
            version: "0.128.0",
            root: root,
            markers: "sighup-verified SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit Auth changed, opening new WebSocket with fresh credentials Usage: /goal <objective>"
        )
        _ = try writeFakeCodex(
            version: "0.129.0",
            root: root,
            markers: "sighup-verified SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit Auth changed, opening new WebSocket with fresh credentials"
        )

        #expect(CodexVersionChecker.latestPreparedHotSwapBinaryPath(rootPath: root.path) == newest.path)
    }

    @Test("Installed version only reports complete hot-swap binaries")
    func installedVersionOnlyReportsCompleteHotSwapBinaries() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "codexswitch-installed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let incomplete = try writeFakeCodex(
            version: "0.130.0",
            root: root.appending(path: "stale"),
            markers: "stock fallback without hot swap markers"
        )
        _ = try writeFakeCodex(
            version: "0.131.0",
            root: root.appending(path: "prepared"),
            markers: "sighup-verified SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit Auth changed, opening new WebSocket with fresh credentials Usage: /goal <objective>"
        )

        #expect(
            CodexVersionChecker.installedHotSwapVersion(
                preparedRootPath: root.appending(path: "prepared").path,
                managedPatchedCodexPath: incomplete.path,
                forkBinaryPath: root.appending(path: "missing-fork").path
            ) == "0.131.0"
        )
    }

    private func writeFakeCodex(version: String, root: URL, markers: String) throws -> URL {
        let dir = root.appending(path: version)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appending(path: "codex")
        try """
        #!/bin/sh
        # \(markers)
        echo 'codex-cli \(version)'
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }
}
