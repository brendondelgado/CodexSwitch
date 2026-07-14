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
            patchMessage: "Desktop app patch blocked: Apple signing identity/private key is missing. Open Xcode account signing or restore the cached Apple-issued iPhone Developer keypair."
        )
        #expect(
            stopped.label == "Codex desktop app not running: Desktop app patch blocked: Apple signing identity/private key is missing. Open Xcode account signing or restore the cached Apple-issued iPhone Developer keypair."
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
            fast: true,
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
            fast: true,
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

    @Test("Missing Fast compatibility keeps desktop patch pending")
    func missingFastCompatibilityRequestsPatchWindow() {
        let markers = DesktopPatchManager.InstalledMarkers(
            auth: true,
            fast: false,
            bundledPluginListRoot: false,
            bundledCLI: false,
            versionCompatible: true,
            computerUsePluginSignatureCompatible: true
        )
        let status = DesktopPatchStatus(
            isCodexAppRunning: false,
            codexAppSignatureCompatible: true,
            codesignIdentityAvailable: true,
            authPatchInstalled: true,
            remoteRecentsPatchInstalled: true,
            fastPatchInstalled: false,
            bundledCLIHotSwapInstalled: false,
            bundledCLIVersionCompatible: true,
            computerUsePluginSignatureCompatible: true,
            lastMessage: ""
        )

        #expect(!markers.required)
        #expect(!markers.computerUsePreservedModeInstalled)
        #expect(!markers.desktopIntegrationInstalled)
        #expect(!status.computerUsePreservedModeInstalled)
        #expect(!status.desktopIntegrationInstalled)
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

    @Test("Auth patch without remote recents refresh still requests patch window")
    func authPatchWithoutRemoteRecentsRefreshRequestsPatchWindow() {
        let markers = DesktopPatchManager.InstalledMarkers(
            auth: true,
            remoteRecents: false,
            fast: false,
            bundledPluginListRoot: false,
            bundledCLI: false,
            versionCompatible: true,
            computerUsePluginSignatureCompatible: true
        )

        #expect(!markers.desktopIntegrationInstalled)
        #expect(
            DesktopPatchManager.statusMessage(
                running: true,
                runtimeState: .unknown,
                automaticPatchingEnabled: true,
                permissionDeniedBackoffActive: false,
                codexAppSignatureCompatible: false,
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
            ) == "Desktop app patch blocked: Apple signing identity/private key is missing. Open Xcode account signing or restore the cached Apple-issued iPhone Developer keypair."
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
        #expect(
            DesktopPatchManager.allowedCodesignIdentityLine(
                #"2) 9351EC70C5A219354618190A5C1541026B2F98B8 "iPhone Developer: bd7349@gmail.com (856E75LLMU)""#
            ) == true
        )
    }
    @Test("Installed app fingerprint changes when Codex app payload changes")
    func installationFingerprintTracksInstalledPayloadChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let app = directory.appendingPathComponent("Codex.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let infoPlist = contents.appendingPathComponent("Info.plist")
        let asar = resources.appendingPathComponent("app.asar")
        let codex = resources.appendingPathComponent("codex")
        try writeCodexInfoPlist(shortVersion: "26.1", bundleVersion: "100", to: infoPlist)
        try Data("asar-v1".utf8).write(to: asar)
        try Data("codex-v1".utf8).write(to: codex)

        let first = try #require(
            DesktopPatchManager.installationFingerprint(
                codexAppPath: app.path,
                asarPath: asar.path,
                bundledCLIPath: codex.path
            )
        )

        try Data("asar-v2-expanded".utf8).write(to: asar)
        let second = try #require(
            DesktopPatchManager.installationFingerprint(
                codexAppPath: app.path,
                asarPath: asar.path,
                bundledCLIPath: codex.path
            )
        )
        #expect(first != second)

        try writeCodexInfoPlist(shortVersion: "26.1", bundleVersion: "101", to: infoPlist)
        let third = try #require(
            DesktopPatchManager.installationFingerprint(
                codexAppPath: app.path,
                asarPath: asar.path,
                bundledCLIPath: codex.path
            )
        )
        #expect(second != third)
    }

    @Test("Post-quit desktop patch retry keeps trying through transient blockers")
    func postQuitPatchRetryKeepsTryingThroughTransientBlockers() {
        #expect(DesktopPatchManager.postQuitPatchRetryDelaysSeconds == [1, 3, 8, 20, 45])
        #expect(DesktopPatchAttemptOutcome.waitingForCodexAppQuit.shouldStopPostQuitRetry == false)
        #expect(DesktopPatchAttemptOutcome.permissionDeniedBackoff.shouldStopPostQuitRetry == false)
        #expect(DesktopPatchAttemptOutcome.permissionDenied.shouldStopPostQuitRetry == false)
        #expect(DesktopPatchAttemptOutcome.cooldownActive.shouldStopPostQuitRetry == false)
        #expect(DesktopPatchAttemptOutcome.alreadyInProgress.shouldStopPostQuitRetry == false)
        #expect(DesktopPatchAttemptOutcome.leaseUnavailable.shouldStopPostQuitRetry == false)
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

    @Test("Desktop patch lease serializes local and cross-process attempts")
    func desktopPatchLeaseSerializesAttempts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let lockFile = directory.appendingPathComponent("desktop-patch.lock")
        let readyFile = directory.appendingPathComponent("holder.ready")
        let releaseFile = directory.appendingPathComponent("holder.release")
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = [
            "-c",
            """
            import fcntl
            import os
            import pathlib
            import sys
            import time

            lock_path, ready_path, release_path = sys.argv[1:]
            descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
            os.fchmod(descriptor, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            pathlib.Path(ready_path).touch(mode=0o600)
            while not os.path.exists(release_path):
                time.sleep(0.01)
            os.close(descriptor)
            """,
            lockFile.path,
            readyFile.path,
            releaseFile.path,
        ]
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer {
            FileManager.default.createFile(atPath: releaseFile.path, contents: Data())
            if holder.isRunning {
                holder.terminate()
            }
            holder.waitUntilExit()
        }
        try #require(waitForFile(at: readyFile, process: holder, timeout: 5))

        var crossProcessOperationRan = false
        var crossProcessLog: [String] = []
        let crossProcessOutcome = DesktopPatchManager.withDesktopPatchMutationLease(
            lockPath: lockFile.path,
            appendLog: { crossProcessLog.append($0) }
        ) {
            crossProcessOperationRan = true
            return .completed
        }
        #expect(crossProcessOutcome == .alreadyInProgress)
        #expect(crossProcessOutcome.logValue == "already_in_progress")
        #expect(!crossProcessOperationRan)
        #expect(
            crossProcessLog == [
                "desktop patch lease contention: another patch attempt is already in progress outcome=already_in_progress",
            ]
        )

        FileManager.default.createFile(atPath: releaseFile.path, contents: Data())
        holder.waitUntilExit()
        #expect(holder.terminationStatus == 0)

        let invalidParent = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: invalidParent)
        let invalidLock = invalidParent.appendingPathComponent("desktop-patch.lock")
        var unavailableOperationRan = false
        var unavailableLog: [String] = []
        let unavailableOutcome = DesktopPatchManager.withDesktopPatchMutationLease(
            lockPath: invalidLock.path,
            appendLog: { unavailableLog.append($0) }
        ) {
            unavailableOperationRan = true
            return .completed
        }
        #expect(unavailableOutcome == .leaseUnavailable)
        #expect(unavailableOutcome.logValue == "lease_unavailable")
        #expect(!unavailableOperationRan)
        #expect(
            unavailableLog == [
                "desktop patch lease unavailable at \(invalidLock.path): outcome=lease_unavailable",
            ]
        )

        var nestedOutcome: DesktopPatchAttemptOutcome?
        var nestedLog: [String] = []
        let outerOutcome = DesktopPatchManager.withDesktopPatchMutationLease(
            lockPath: lockFile.path,
            appendLog: { _ in }
        ) {
            nestedOutcome = DesktopPatchManager.withDesktopPatchMutationLease(
                lockPath: lockFile.path,
                appendLog: { nestedLog.append($0) }
            ) {
                .completed
            }
            return .timedOut
        }
        #expect(outerOutcome == .timedOut)
        #expect(nestedOutcome == .alreadyInProgress)
        #expect(
            nestedLog == [
                "desktop patch lease contention: another patch attempt is already in progress outcome=already_in_progress",
            ]
        )

        do {
            _ = try DesktopPatchManager.withDesktopPatchMutationLease(
                lockPath: lockFile.path,
                appendLog: { _ in }
            ) {
                throw LeaseProbeError.expected
            }
            Issue.record("Expected the lease probe to throw")
        } catch LeaseProbeError.expected {
            // Expected: the next acquisition proves defer released the lease.
        }

        let finalOutcome = DesktopPatchManager.withDesktopPatchMutationLease(
            lockPath: lockFile.path,
            appendLog: { _ in }
        ) {
            .completed
        }
        #expect(finalOutcome == .completed)

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: lockFile.path)
        let directoryPermissions = try #require(directoryAttributes[.posixPermissions] as? NSNumber)
        let filePermissions = try #require(fileAttributes[.posixPermissions] as? NSNumber)
        #expect(directoryPermissions.intValue & 0o777 == 0o700)
        #expect(filePermissions.intValue & 0o777 == 0o600)
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

    private func writeCodexInfoPlist(shortVersion: String, bundleVersion: String, to url: URL) throws {
        let plist: [String: String] = [
            "CFBundleIdentifier": "com.openai.codex",
            "CFBundleShortVersionString": shortVersion,
            "CFBundleVersion": bundleVersion,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }

    private enum LeaseProbeError: Error {
        case expected
    }

    private func waitForFile(at url: URL, process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            if !process.isRunning {
                return false
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
