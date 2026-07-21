import AppKit
import Darwin
import Foundation
import os

private let desktopPatchLogger = Logger(subsystem: "com.codexswitch", category: "DesktopPatch")

enum DesktopRuntimeHotSwapState: Sendable, Equatable {
    case ready
    case restartRequired
    case unknown
}

enum HotSwapRuntimeKind: String, Decodable, Sendable, Equatable {
    case externalAppServer = "external-app-server"
    case headlessRemoteControlAppServer = "headless-remote-control-app-server"
    case localInteractiveCLI = "local-interactive-cli"
}

enum DesktopPatchAttemptOutcome: Sendable, Equatable {
    case notNeeded
    case disabled
    case missingSigningIdentity
    case waitingForCodexAppQuit
    case permissionDeniedBackoff
    case permissionDenied
    case cooldownActive
    case scriptMissing
    case alreadyInProgress
    case leaseUnavailable
    case completed
    case timedOut
    case structureChanged
    case failed(Int32)

    var logValue: String {
        switch self {
        case .notNeeded: "not_needed"
        case .disabled: "disabled"
        case .missingSigningIdentity: "missing_signing_identity"
        case .waitingForCodexAppQuit: "waiting_for_codex_app_quit"
        case .permissionDeniedBackoff: "permission_denied_backoff"
        case .permissionDenied: "permission_denied"
        case .cooldownActive: "cooldown_active"
        case .scriptMissing: "script_missing"
        case .alreadyInProgress: "already_in_progress"
        case .leaseUnavailable: "lease_unavailable"
        case .completed: "completed"
        case .timedOut: "timed_out"
        case .structureChanged: "structure_changed"
        case .failed(let status): "failed_\(status)"
        }
    }

    var shouldStopPostQuitRetry: Bool {
        switch self {
        case .notNeeded, .disabled, .missingSigningIdentity, .scriptMissing, .completed:
            true
        case .waitingForCodexAppQuit,
             .permissionDeniedBackoff,
             .permissionDenied,
             .cooldownActive,
             .alreadyInProgress,
             .leaseUnavailable,
             .timedOut,
             .structureChanged,
             .failed:
            false
        }
    }
}

struct DesktopPatchStatus: Sendable, Equatable {
    let isCodexAppRunning: Bool
    let codexAppSignatureCompatible: Bool
    let codesignIdentityAvailable: Bool
    let authPatchInstalled: Bool
    let remoteRecentsPatchInstalled: Bool
    let fastPatchInstalled: Bool
    let bundledCLIHotSwapInstalled: Bool
    let bundledCLIVersionCompatible: Bool
    let computerUsePluginSignatureCompatible: Bool
    let lastMessage: String

    var allPatchesInstalled: Bool {
        authPatchInstalled
            && remoteRecentsPatchInstalled
            && fastPatchInstalled
            && bundledCLIHotSwapInstalled
            && bundledCLIVersionCompatible
            && computerUsePluginSignatureCompatible
    }

    var computerUsePreservedModeInstalled: Bool {
        authPatchInstalled
            && remoteRecentsPatchInstalled
            && fastPatchInstalled
            && !bundledCLIHotSwapInstalled
            && bundledCLIVersionCompatible
            && computerUsePluginSignatureCompatible
    }

    var desktopIntegrationInstalled: Bool {
        allPatchesInstalled || computerUsePreservedModeInstalled
    }
}

private final class DesktopPatchStatusCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedStatus: DesktopPatchStatus?
    private var cachedAt: Date?

    func get(maxAge: TimeInterval) -> DesktopPatchStatus? {
        guard maxAge > 0 else { return nil }
        return lock.withLock {
            guard let cachedStatus, let cachedAt else { return nil }
            guard Date().timeIntervalSince(cachedAt) <= maxAge else { return nil }
            return cachedStatus
        }
    }

    func set(_ status: DesktopPatchStatus) {
        lock.withLock {
            cachedStatus = status
            cachedAt = Date()
        }
    }
}

private enum DesktopPatchLeaseAcquisition {
    case acquired(DesktopPatchMutationLease)
    case alreadyInProgress
    case unavailable
}

private final class DesktopPatchMutationLease {
    private static let processLock = NSLock()

    private var fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        release()
    }

    static func acquire(at path: String) -> DesktopPatchLeaseAcquisition {
        guard processLock.try() else {
            return .alreadyInProgress
        }

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory
            )
        } catch {
            processLock.unlock()
            return .unavailable
        }

        let opened = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard opened >= 0 else {
            processLock.unlock()
            return .unavailable
        }

        guard Darwin.fchmod(opened, mode_t(0o600)) == 0 else {
            Darwin.close(opened)
            processLock.unlock()
            return .unavailable
        }

        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(opened)
            processLock.unlock()
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return .alreadyInProgress
            }
            return .unavailable
        }

        _ = ftruncate(opened, 0)
        let pidLine = Data("\(getpid())\n".utf8)
        pidLine.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = Darwin.write(opened, baseAddress, buffer.count)
        }

        return .acquired(DesktopPatchMutationLease(fileDescriptor: opened))
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        let descriptor = fileDescriptor
        fileDescriptor = -1
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        Self.processLock.unlock()
    }
}

enum DesktopPatchManager {
    struct InstallationFingerprint: Sendable, Equatable {
        struct FileFingerprint: Sendable, Equatable {
            let path: String
            let exists: Bool
            let fileType: String?
            let size: UInt64?
            let inode: UInt64?
            let modifiedAt: TimeInterval?
        }

        let shortVersion: String?
        let bundleVersion: String?
        let files: [FileFingerprint]
    }

    struct InstalledMarkers: Sendable, Equatable {
        let auth: Bool
        let remoteRecents: Bool
        let fast: Bool
        let bundledPluginListRoot: Bool
        let bundledCLI: Bool
        let versionCompatible: Bool
        let computerUsePluginSignatureCompatible: Bool

        init(
            auth: Bool,
            remoteRecents: Bool = true,
            fast: Bool,
            bundledPluginListRoot: Bool,
            bundledCLI: Bool,
            versionCompatible: Bool,
            computerUsePluginSignatureCompatible: Bool
        ) {
            self.auth = auth
            self.remoteRecents = remoteRecents
            self.fast = fast
            self.bundledPluginListRoot = bundledPluginListRoot
            self.bundledCLI = bundledCLI
            self.versionCompatible = versionCompatible
            self.computerUsePluginSignatureCompatible = computerUsePluginSignatureCompatible
        }

        var required: Bool {
            auth
                && remoteRecents
                && fast
                && bundledCLI
                && versionCompatible
                && computerUsePluginSignatureCompatible
        }

        var computerUsePreservedModeInstalled: Bool {
            auth
                && remoteRecents
                && fast
                && !bundledCLI
                && versionCompatible
                && computerUsePluginSignatureCompatible
        }

        var desktopIntegrationInstalled: Bool {
            required || computerUsePreservedModeInstalled
        }
    }

    nonisolated static let automaticPatchingDefaultsKey = "desktopAutomaticPatchingEnabled"
    private nonisolated static let automaticPatchingMigrationKey = "desktopAutomaticPatchingEnabled.v2Migrated"

    private nonisolated static var codexAppPath: String {
        CodexDesktopAppLocator.locate()?.appPath
            ?? CodexDesktopAppLocator.defaultAppPaths[0]
    }
    private nonisolated static var asarPath: String {
        "\(codexAppPath)/Contents/Resources/app.asar"
    }
    private nonisolated static var bundledCLIPath: String {
        "\(codexAppPath)/Contents/Resources/codex"
    }
    private nonisolated static var computerUsePluginAppPath: String {
        "\(codexAppPath)/Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app"
    }
    private nonisolated static var skyComputerUseClientAppPath: String {
        "\(computerUsePluginAppPath)/Contents/SharedSupport/SkyComputerUseClient.app"
    }
    private nonisolated static let stockVendorCLIPath =
        "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex"
    private nonisolated static let lastPatchAttemptPath =
        NSString("~/.codexswitch/desktop-patch-last-attempt").expandingTildeInPath
    private nonisolated static let patchLogPath =
        NSString("~/.codexswitch/logs/desktop-patch.log").expandingTildeInPath
    private nonisolated static let permissionDeniedPath =
        NSString("~/.codexswitch/desktop-patch-permission-denied").expandingTildeInPath
    private nonisolated static let patchLeasePath =
        NSString("~/.codexswitch/desktop-patch.lock").expandingTildeInPath

    private nonisolated static let authPatchMarker = "CODEXSWITCH_AUTH_CACHE_INVALIDATION_V3"
    private nonisolated static let authTransitionPatchMarker = "CODEXSWITCH_AUTH_TRANSITION_V1"
    private nonisolated static let remoteRecentsPatchMarker = "CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH_V2"
    private nonisolated static let modelLabelFallbackMarker = "CODEXSWITCH_MODEL_LABEL_FALLBACK"
    private nonisolated static let modelAvailabilityFallbackMarker = "CODEXSWITCH_MODEL_AVAILABILITY_FALLBACK"
    private nonisolated static let selectedModelLabelFallbackMarker = "CODEXSWITCH_SELECTED_MODEL_LABEL_FALLBACK"
    private nonisolated static let gpt56MaxEffortFallbackMarker = "CODEXSWITCH_GPT56_MAX_EFFORT_FALLBACK"
    private nonisolated static let remoteModelRefreshMarker = "CODEXSWITCH_REMOTE_MODEL_REFRESH_PATCH"
    private nonisolated static let nativeUpdaterDisabledMarker = "CODEXSWITCH_NATIVE_UPDATER_DISABLED_V1"
    private nonisolated static let fastPatchMarker = "_bundledFastModels"
    private nonisolated static let bundledPluginListRootPatchMarker = "CODEXSWITCH_BUNDLED_PLUGIN_LIST_ROOT_PATCH"
    private nonisolated static let goalUsageMarker = "Usage: /goal <objective>"
    private nonisolated static let goalStatusMarker = "Pursuing goal"
    private nonisolated static let goalRPCMarker = "thread/goal/set"
    nonisolated static let desktopHostBundleIdentifiers = [
        "com.openai.codex",
        "com.openai.chat",
    ]
    private nonisolated static let patchCooldownSeconds: TimeInterval = 60
    private nonisolated static let permissionDeniedBackoffSeconds: TimeInterval = 60 * 60
    private nonisolated static let openAITeamIdentifier = "2DC432GLL2"
    private nonisolated static let statusCache = DesktopPatchStatusCache()

    nonisolated static let postQuitPatchRetryDelaysSeconds: [TimeInterval] = [1, 3, 8, 20, 45]

    nonisolated static var automaticPatchingEnabled: Bool {
        guard let value = UserDefaults.standard.object(forKey: automaticPatchingDefaultsKey) as? Bool else {
            return true
        }
        return value
    }

    nonisolated static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            automaticPatchingDefaultsKey: true,
        ])
        migrateAutomaticPatchingDefaultIfNeeded()
    }

    private nonisolated static func migrateAutomaticPatchingDefaultIfNeeded() {
        guard UserDefaults.standard.object(forKey: automaticPatchingMigrationKey) == nil else { return }
        UserDefaults.standard.set(true, forKey: automaticPatchingDefaultsKey)
        UserDefaults.standard.set(true, forKey: automaticPatchingMigrationKey)
    }

    nonisolated static func currentStatus(maxAge: TimeInterval = 60) -> DesktopPatchStatus {
        if let cached = statusCache.get(maxAge: maxAge) {
            return cached
        }
        let status = computeCurrentStatus()
        statusCache.set(status)
        return status
    }

    nonisolated static func installationFingerprint(
        codexAppPath: String = codexAppPath,
        asarPath: String = asarPath,
        bundledCLIPath: String = bundledCLIPath
    ) -> InstallationFingerprint? {
        guard FileManager.default.fileExists(atPath: codexAppPath) else {
            return nil
        }

        let infoPlistPath = URL(fileURLWithPath: codexAppPath)
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")
            .path
        let versions = infoPlistVersionValues(at: infoPlistPath)
        let trackedPaths = [
            codexAppPath,
            infoPlistPath,
            asarPath,
            bundledCLIPath,
        ]

        return InstallationFingerprint(
            shortVersion: versions.shortVersion,
            bundleVersion: versions.bundleVersion,
            files: trackedPaths.map { fileFingerprint(at: $0) }
        )
    }

    private nonisolated static func infoPlistVersionValues(at path: String) -> (shortVersion: String?, bundleVersion: String?) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return (nil, nil)
        }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            return (nil, nil)
        }
        return (
            plist["CFBundleShortVersionString"] as? String,
            plist["CFBundleVersion"] as? String
        )
    }

    private nonisolated static func fileFingerprint(at path: String) -> InstallationFingerprint.FileFingerprint {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return InstallationFingerprint.FileFingerprint(
                path: path,
                exists: false,
                fileType: nil,
                size: nil,
                inode: nil,
                modifiedAt: nil
            )
        }

        return InstallationFingerprint.FileFingerprint(
            path: path,
            exists: true,
            fileType: (attributes[.type] as? FileAttributeType)?.rawValue,
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            modifiedAt: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
        )
    }

    private nonisolated static func computeCurrentStatus() -> DesktopPatchStatus {
        guard FileManager.default.fileExists(atPath: codexAppPath) else {
            return DesktopPatchStatus(
                isCodexAppRunning: false,
                codexAppSignatureCompatible: false,
                codesignIdentityAvailable: false,
                authPatchInstalled: false,
                remoteRecentsPatchInstalled: false,
                fastPatchInstalled: false,
                bundledCLIHotSwapInstalled: false,
                bundledCLIVersionCompatible: false,
                computerUsePluginSignatureCompatible: false,
                lastMessage: "Codex.app is not installed."
            )
        }

        let running = isCodexDesktopRuntimeRunning()
        let markers = installedMarkers()
        let codexAppSignatureCompatible = officialCodexAppSignatureCompatible()
        let codesignIdentityAvailable = codesignIdentityAvailable()
        let runtimeState = running ? runtimeHotSwapState() : .unknown
        let message = statusMessage(
            running: running,
            runtimeState: runtimeState,
            automaticPatchingEnabled: automaticPatchingEnabled,
            permissionDeniedBackoffActive: permissionDeniedBackoffActive(),
            codexAppSignatureCompatible: codexAppSignatureCompatible,
            codesignIdentityAvailable: codesignIdentityAvailable,
            markers: markers
        )

        return DesktopPatchStatus(
            isCodexAppRunning: running,
            codexAppSignatureCompatible: codexAppSignatureCompatible,
            codesignIdentityAvailable: codesignIdentityAvailable,
            authPatchInstalled: markers.auth,
            remoteRecentsPatchInstalled: markers.remoteRecents,
            fastPatchInstalled: markers.fast,
            bundledCLIHotSwapInstalled: markers.bundledCLI,
            bundledCLIVersionCompatible: markers.versionCompatible,
            computerUsePluginSignatureCompatible: markers.computerUsePluginSignatureCompatible,
            lastMessage: message
        )
    }

    @discardableResult
    nonisolated static func checkAndPatchIfPossible(
        ignoreCooldown: Bool = false,
        ignorePermissionDeniedBackoff: Bool = false
    ) -> DesktopPatchAttemptOutcome {
        let status = currentStatus(maxAge: 0)
        guard !status.desktopIntegrationInstalled else { return .notNeeded }
        appendPatchLog("desktop patch needed: running=\(status.isCodexAppRunning) automatic=\(automaticPatchingEnabled)")
        SwapLog.append(.debug("DESKTOP_PATCH_NEEDED running=\(status.isCodexAppRunning) automatic=\(automaticPatchingEnabled)"))
        guard automaticPatchingEnabled else {
            appendPatchLog("desktop ASAR patch skipped: automatic desktop patching is disabled by user setting")
            SwapLog.append(.debug("DESKTOP_ASAR_PATCH_DISABLED_BY_USER"))
            return .disabled
        }
        guard codesignIdentityAvailable() else {
            let suffix = status.isCodexAppRunning ? " (Codex.app also running)" : ""
            appendPatchLog("desktop ASAR patch blocked: no usable non-ad-hoc code signing identity\(suffix)")
            SwapLog.append(.debug("DESKTOP_PATCH_SIGNING_IDENTITY_MISSING"))
            return .missingSigningIdentity
        }
        guard !status.isCodexAppRunning else {
            appendPatchLog("desktop patch pending: Codex.app is still running")
            SwapLog.append(.debug("DESKTOP_PATCH_WAITING_FOR_CODEX_APP_QUIT"))
            return .waitingForCodexAppQuit
        }
        if permissionDeniedBackoffActive(), !ignorePermissionDeniedBackoff {
            appendPatchLog("desktop ASAR patch blocked: permission denied backoff active")
            SwapLog.append(.debug("DESKTOP_PATCH_PERMISSION_DENIED_BACKOFF"))
            return .permissionDeniedBackoff
        }
        guard let script = patchScriptPath() else {
            appendPatchLog("patch script not found")
            return .scriptMissing
        }

        let outcome = withDesktopPatchMutationLease(
            lockPath: patchLeasePath,
            appendLog: { appendPatchLog($0) }
        ) {
            if !patchCooldownExpired(), !ignoreCooldown {
                appendPatchLog("desktop ASAR patch skipped: patch attempt cooldown active")
                SwapLog.append(.debug("DESKTOP_PATCH_COOLDOWN_ACTIVE"))
                return .cooldownActive
            }

            markPatchAttempt()
            appendPatchLog("starting desktop patch with \(script)")

            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["CODEXSWITCH_CODEX_APP_PATH"] = codexAppPath

            let result = ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [script],
                timeout: 600,
                environment: environment
            )

            let output = [result.stdoutString, result.stderrString]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            appendPatchLog(output.isEmpty ? "patch exited status=\(result.terminationStatus)" : output)

            if result.timedOut {
                desktopPatchLogger.error("Desktop patch timed out")
                SwapLog.append(.debug("DESKTOP_PATCH_TIMEOUT"))
                return .timedOut
            } else if result.terminationStatus == 0 {
                clearPermissionDenied()
                desktopPatchLogger.info("Desktop patch completed")
                SwapLog.append(.debug("DESKTOP_PATCH_COMPLETED"))
                return .completed
            } else if result.terminationStatus == 3 || isLiveAppRefusal(output) {
                clearPatchAttempt()
                desktopPatchLogger.warning("Desktop patch waiting for Codex.app to quit")
                SwapLog.append(.debug("DESKTOP_PATCH_WAITING_FOR_CODEX_APP_QUIT"))
                return .waitingForCodexAppQuit
            } else if result.terminationStatus == 2 {
                desktopPatchLogger.warning("Desktop patch skipped; app structure changed")
                SwapLog.append(.debug("DESKTOP_PATCH_SKIPPED_STRUCTURE_CHANGED"))
                return .structureChanged
            } else if isSigningIdentityMissing(output) {
                desktopPatchLogger.error("Desktop patch needs a non-ad-hoc code signing identity")
                SwapLog.append(.debug("DESKTOP_PATCH_SIGNING_IDENTITY_MISSING"))
                return .missingSigningIdentity
            } else if isPermissionDenied(output) {
                markPermissionDenied()
                desktopPatchLogger.error("Desktop patch needs App Management permission")
                SwapLog.append(.debug("DESKTOP_PATCH_PERMISSION_DENIED"))
                return .permissionDenied
            } else {
                desktopPatchLogger.error("Desktop patch failed status=\(result.terminationStatus)")
                SwapLog.append(.debug("DESKTOP_PATCH_FAILED status=\(result.terminationStatus)"))
                return .failed(result.terminationStatus)
            }
        }

        switch outcome {
        case .alreadyInProgress:
            SwapLog.append(.debug("DESKTOP_PATCH_ALREADY_IN_PROGRESS"))
        case .leaseUnavailable:
            SwapLog.append(.debug("DESKTOP_PATCH_LEASE_UNAVAILABLE"))
        case .completed:
            statusCache.set(computeCurrentStatus())
        default:
            break
        }
        return outcome
    }

    nonisolated static func withDesktopPatchMutationLease(
        lockPath: String,
        appendLog: (String) -> Void,
        operation: () throws -> DesktopPatchAttemptOutcome
    ) rethrows -> DesktopPatchAttemptOutcome {
        switch DesktopPatchMutationLease.acquire(at: lockPath) {
        case .acquired(let lease):
            defer { lease.release() }
            return try operation()
        case .alreadyInProgress:
            let outcome = DesktopPatchAttemptOutcome.alreadyInProgress
            appendLog(
                "desktop patch lease contention: another patch attempt is already in progress outcome=\(outcome.logValue)"
            )
            return outcome
        case .unavailable:
            let outcome = DesktopPatchAttemptOutcome.leaseUnavailable
            appendLog("desktop patch lease unavailable at \(lockPath): outcome=\(outcome.logValue)")
            return outcome
        }
    }

    nonisolated static func runtimeHotSwapState(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        runtimeEvidenceProvider: @Sendable (
            HotSwapRuntimeKind,
            URL
        ) -> CodexLocalRuntimeEvidenceSnapshot = { runtimeKind, homeDirectory in
            SwapEngine.localRuntimeEvidenceSnapshot(
                runtimeKind: runtimeKind,
                homeDirectory: homeDirectory
            )
        }
    ) -> DesktopRuntimeHotSwapState {
        let evidence = runtimeEvidenceProvider(
            .externalAppServer,
            homeDirectory
        )
        return runtimeHotSwapState(from: evidence)
    }

    nonisolated static func runtimeHotSwapState(
        from evidence: CodexLocalRuntimeEvidenceSnapshot
    ) -> DesktopRuntimeHotSwapState {
        guard evidence.isComplete, !evidence.runtimes.isEmpty else { return .unknown }
        return evidence.runtimes.allSatisfy { runtime in
            runtime.observation.target.runtimeKind == .externalAppServer
                && SwapEngine.bindingMatchesObservation(
                    runtime.startupAcknowledgement.binding,
                    runtime.observation
                )
        } ? .ready : .unknown
    }

    nonisolated static func isDesktopHotSwapRuntimeLine(_ lowercasedProcessLine: String) -> Bool {
        if lowercasedProcessLine.contains(" app-server")
            && lowercasedProcessLine.contains("/applications/codex.app/contents/resources/codex") {
            return true
        }
        if lowercasedProcessLine.contains(" app-server")
            && lowercasedProcessLine.contains("/developer/codex/codex-rs/target/fork-release/codex") {
            return true
        }
        if lowercasedProcessLine.contains(" app-server")
            && lowercasedProcessLine.contains("/developer/codex/codex-rs/target/release/codex") {
            return true
        }
        if lowercasedProcessLine.contains(" app-server")
            && isCodexSwitchManagedDesktopRuntimeLine(lowercasedProcessLine) {
            return true
        }
        if lowercasedProcessLine.contains(" app-server")
            && lowercasedProcessLine.contains("/@openai/codex")
            && lowercasedProcessLine.contains("/vendor/aarch64-apple-darwin/codex/codex") {
            return true
        }
        return false
    }

    private nonisolated static func isCodexSwitchManagedDesktopRuntimeLine(_ lowercasedProcessLine: String) -> Bool {
        lowercasedProcessLine.contains(" app-server")
            && (
                lowercasedProcessLine.contains("/.local/share/codexswitch/prepared-codex/")
                    || lowercasedProcessLine.contains("/.local/share/codexswitch/patched-codex/codex")
            )
    }

    nonisolated static func statusMessage(
        running: Bool,
        runtimeState: DesktopRuntimeHotSwapState,
        automaticPatchingEnabled: Bool,
        permissionDeniedBackoffActive: Bool,
        codexAppSignatureCompatible: Bool,
        codesignIdentityAvailable: Bool = true,
        markers: InstalledMarkers
    ) -> String {
        if !codexAppSignatureCompatible && !markers.computerUsePluginSignatureCompatible {
            return running
                ? "Codex.app is locally signed; quit Codex.app to restore official signing for Computer Use."
                : "Codex.app is locally signed; restore official Codex.app to repair Computer Use."
        }
        if markers.desktopIntegrationInstalled {
            switch runtimeState {
            case .ready:
                return "Desktop app is ready."
            case .unknown where !running:
                return "Desktop app is ready."
            case .restartRequired:
                return "Desktop app is patched on disk; restart Codex.app to activate hot-swap."
            case .unknown:
                return "Desktop app patch is installed, but live hot-swap is not confirmed."
            }
        }
        if markers.auth && markers.bundledCLI && markers.versionCompatible && !markers.computerUsePluginSignatureCompatible {
            return running
                ? "Desktop app patch pending: quit Codex.app to repair Computer Use plugin signatures."
                : "Desktop app patch pending: Computer Use plugin signature repair needed."
        }
        if markers.auth && markers.bundledCLI && !markers.versionCompatible {
            return "Desktop app patch pending: bundled CLI version is stale."
        }
        if markers.auth && !markers.computerUsePluginSignatureCompatible {
            return "Desktop app patch pending: Computer Use plugin signature repair needed."
        }
        if !codesignIdentityAvailable {
            return running
                ? "Desktop app patch blocked: Apple signing identity/private key is missing; quitting Codex.app alone will not patch it."
                : "Desktop app patch blocked: Apple signing identity/private key is missing. Open Xcode account signing or restore the cached Apple-issued iPhone Developer keypair."
        }
        if running {
            return "Desktop app patch pending: Codex.app/app-server is still running; use ⌘Q to quit."
        }
        if !automaticPatchingEnabled {
            return "Desktop app hot-swap patch is off in CodexSwitch settings."
        }
        if permissionDeniedBackoffActive {
            return "Desktop app patch needs macOS App Management permission."
        }
        return "Desktop app patch missing; will patch in background."
    }

    private nonisolated static func installedMarkers() -> InstalledMarkers {
        guard FileManager.default.fileExists(atPath: asarPath) else {
            return InstalledMarkers(
                auth: false,
                remoteRecents: false,
                fast: false,
                bundledPluginListRoot: false,
                bundledCLI: false,
                versionCompatible: false,
                computerUsePluginSignatureCompatible: false
            )
        }
        let auth = fileContainsMarker(authPatchMarker, at: asarPath)
            && fileContainsMarker(authTransitionPatchMarker, at: asarPath)
            && fileContainsMarker(modelLabelFallbackMarker, at: asarPath)
            && fileContainsMarker(modelAvailabilityFallbackMarker, at: asarPath)
            && fileContainsMarker(selectedModelLabelFallbackMarker, at: asarPath)
            && fileContainsMarker(gpt56MaxEffortFallbackMarker, at: asarPath)
            && fileContainsMarker(remoteModelRefreshMarker, at: asarPath)
            && fileContainsMarker(nativeUpdaterDisabledMarker, at: asarPath)
        let remoteRecents = fileContainsMarker(remoteRecentsPatchMarker, at: asarPath)
        let fast = fileContainsMarker(fastPatchMarker, at: asarPath)
        let bundledPluginListRoot = fileContainsMarker(bundledPluginListRootPatchMarker, at: asarPath)
        let bundledCLI = bundledCLIHasHotSwapPatch()
        let pluginSignatureCompatible = bundledComputerUsePluginSignatureCompatible()
        let versionCompatible = bundledCLI ? bundledCLIVersionCompatible() : pluginSignatureCompatible
        return InstalledMarkers(
            auth: auth,
            remoteRecents: remoteRecents,
            fast: fast,
            bundledPluginListRoot: bundledPluginListRoot,
            bundledCLI: bundledCLI,
            versionCompatible: versionCompatible,
            computerUsePluginSignatureCompatible: pluginSignatureCompatible
        )
    }

    nonisolated static func computerUsePluginSignatureCompatible(
        parentTeam: String?,
        pluginTeams: [String?],
        pluginEntitlements: [String] = []
    ) -> Bool {
        guard !pluginTeams.isEmpty else {
            return false
        }
        let openAIParent = parentTeam == openAITeamIdentifier
        let openAITeams = pluginTeams.allSatisfy { $0 == openAITeamIdentifier }
        let openAIEntitlements = pluginEntitlements.isEmpty
            || pluginEntitlements.allSatisfy { $0.contains(openAITeamIdentifier) }
        return openAIParent && openAITeams && openAIEntitlements
    }

    nonisolated static func bundledComputerUsePluginSignatureCompatible() -> Bool {
        let pluginPaths = [skyComputerUseClientAppPath, computerUsePluginAppPath]
        guard pluginPaths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
            return false
        }

        return computerUsePluginSignatureCompatible(
            parentTeam: codeSignatureTeamIdentifier(at: bundledCLIPath),
            pluginTeams: pluginPaths.map { codeSignatureTeamIdentifier(at: $0) },
            pluginEntitlements: pluginPaths.map { codeSignatureEntitlements(at: $0) }
        )
    }

    nonisolated static func officialCodexAppSignatureCompatible() -> Bool {
        codeSignatureTeamIdentifier(at: codexAppPath) == openAITeamIdentifier
            && spctlAccepts(path: codexAppPath)
    }

    nonisolated static func bundledCLIHasHotSwapPatch() -> Bool {
        (
            RuntimeHotSwapContract.commonMarkers
                + RuntimeHotSwapContract.externalAppServerMarkers
                + RuntimeHotSwapContract.headlessRemoteControlMarkers
        )
            .allSatisfy { fileContainsMarker($0, at: bundledCLIPath) }
            && fileHasGoalSupport(at: bundledCLIPath)
    }

    nonisolated static func fileContainsMarker(
        _ marker: String,
        at path: String,
        chunkSize: Int = 64 * 1024
    ) -> Bool {
        guard !marker.isEmpty,
              chunkSize > 0 else {
            return false
        }

        let fileDescriptor = open(path, O_RDONLY)
        guard fileDescriptor >= 0 else { return false }
        defer { close(fileDescriptor) }

        let needle = Array(marker.utf8)
        var failure = Array(repeating: 0, count: needle.count)
        if needle.count > 1 {
            for index in 1..<needle.count {
                var matched = failure[index - 1]
                while matched > 0, needle[index] != needle[matched] {
                    matched = failure[matched - 1]
                }
                if needle[index] == needle[matched] {
                    matched += 1
                }
                failure[index] = matched
            }
        }

        var buffer = Array(repeating: UInt8(0), count: chunkSize)
        var matched = 0
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 { return false }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return false
            }

            for index in 0..<bytesRead {
                let byte = buffer[index]
                while matched > 0, byte != needle[matched] {
                    matched = failure[matched - 1]
                }
                if byte == needle[matched] {
                    matched += 1
                    if matched == needle.count {
                        return true
                    }
                }
            }
        }
    }

    nonisolated static func bundledCLIVersionCompatible() -> Bool {
        guard let bundledVersion = cliVersion(at: bundledCLIPath) else {
            return false
        }
        guard let stockVersion = cliVersion(at: stockVendorCLIPath) else {
            return true
        }
        return !bundledVersion.lexicographicallyPrecedes(stockVersion)
    }

    nonisolated static func fileHasGoalSupport(at path: String) -> Bool {
        fileContainsMarker(goalUsageMarker, at: path)
            || (
                fileContainsMarker(goalStatusMarker, at: path)
                    && fileContainsMarker(goalRPCMarker, at: path)
            )
    }

    nonisolated static func binaryDataHasGoalSupport(_ data: Data) -> Bool {
        data.range(of: Data(goalUsageMarker.utf8)) != nil
            || (
                data.range(of: Data(goalStatusMarker.utf8)) != nil
                    && data.range(of: Data(goalRPCMarker.utf8)) != nil
            )
    }

    private nonisolated static func cliVersion(at path: String) -> [Int]? {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }

        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: path),
            arguments: ["--version"],
            timeout: 3
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return nil
        }
        return parseVersion(result.stdoutString)
    }

    private nonisolated static func codeSignatureTeamIdentifier(at path: String) -> String? {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dv", path],
            timeout: 2
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return nil
        }

        let output = result.stdoutString + "\n" + result.stderrString
        for line in output.components(separatedBy: "\n") {
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            return String(line.dropFirst("TeamIdentifier=".count))
        }
        return nil
    }

    private nonisolated static func codeSignatureEntitlements(at path: String) -> String {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-d", "--entitlements", ":-", path],
            timeout: 2
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return ""
        }
        return result.stdoutString + "\n" + result.stderrString
    }

    nonisolated static func codesignIdentityAvailable() -> Bool {
        selectedCodesignIdentityFromPatcher() != nil
    }

    nonisolated static func selectedCodesignIdentityFromPatcher() -> String? {
        guard let script = patchScriptPath() else {
            return nil
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [script, "--print-codesign-identity"],
            timeout: 30,
            environment: environment
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return nil
        }
        let output = result.stdoutString + "\n" + result.stderrString
        guard let identity = output.components(separatedBy: "\n")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .last(where: { !$0.isEmpty }),
            identity != "-"
        else {
            return nil
        }
        return identity
    }

    nonisolated static func legacyCodesignIdentityLineAvailable() -> Bool {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-identity", "-v", "-p", "codesigning"],
            timeout: 3
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return false
        }
        let output = result.stdoutString + "\n" + result.stderrString
        return output.components(separatedBy: "\n").contains(where: allowedCodesignIdentityLine)
    }

    nonisolated static func allowedCodesignIdentityLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard !lower.contains("0 valid identities found") else { return false }
        guard !lower.contains("valid identities found") else { return false }
        guard !lower.contains("\"-\""), !lower.contains("adhoc"), !lower.contains("ad-hoc") else {
            return false
        }
        guard let firstQuote = trimmed.firstIndex(of: "\""),
              let lastQuote = trimmed.lastIndex(of: "\""),
              firstQuote < lastQuote
        else {
            return false
        }
        let identity = String(trimmed[trimmed.index(after: firstQuote)..<lastQuote])
        return identity.hasPrefix("Developer ID Application")
            || identity.hasPrefix("Apple Distribution")
            || identity.hasPrefix("Apple Development")
            || identity.hasPrefix("Mac Developer")
            || identity.hasPrefix("iPhone Developer")
    }

    private nonisolated static func spctlAccepts(path: String) -> Bool {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/spctl"),
            arguments: ["--assess", "--type", "execute", path],
            timeout: 5
        )
        return !result.timedOut && result.terminationStatus == 0
    }

    private nonisolated static func parseVersion(_ output: String) -> [Int]? {
        let pattern = /(\d+)\.(\d+)\.(\d+)/
        guard let match = output.firstMatch(of: pattern) else { return nil }
        return [
            Int(match.output.1) ?? 0,
            Int(match.output.2) ?? 0,
            Int(match.output.3) ?? 0,
        ]
    }

    private nonisolated static func patchScriptPath() -> String? {
        let candidates: [String] = [
            Bundle.main.resourceURL?.appendingPathComponent("patch-asar.py").path,
            "/Applications/CodexSwitch.app/Contents/Resources/patch-asar.py",
            NSString("~/Developer/CodexSwitch/scripts/patch-asar.py").expandingTildeInPath,
            NSString("~/Developer/codexswitch/scripts/patch-asar.py").expandingTildeInPath,
        ].compactMap { $0 }

        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    nonisolated static func isCodexDesktopRuntimeRunning() -> Bool {
        let runningHostBundleIdentifiers = desktopHostBundleIdentifiers.filter { bundleIdentifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .contains { !$0.isTerminated }
        }
        if desktopSafeQuitIsBlocked(
            runningHostBundleIdentifiers: runningHostBundleIdentifiers,
            appServerProcessListOutput: ""
        ) {
            return true
        }

        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-fl", "codex.*app-server"],
            timeout: 2
        )
        if result.timedOut || (result.terminationStatus != 0 && result.terminationStatus != 1) {
            return true
        }
        guard result.terminationStatus == 0 else {
            return false
        }

        return desktopSafeQuitIsBlocked(
            runningHostBundleIdentifiers: [],
            appServerProcessListOutput: result.stdoutString
        )
    }

    nonisolated static func desktopSafeQuitIsBlocked(
        runningHostBundleIdentifiers: [String],
        appServerProcessListOutput: String
    ) -> Bool {
        let knownBundleIdentifiers = Set(desktopHostBundleIdentifiers.map { $0.lowercased() })
        if runningHostBundleIdentifiers.contains(where: {
            knownBundleIdentifiers.contains($0.lowercased())
        }) {
            return true
        }
        return !DesktopRuntimeDiagnostics.parseAppServerProcesses(
            fromPGrepOutput: appServerProcessListOutput
        ).isEmpty
    }

    private nonisolated static func appServerPIDs() -> [Int32] {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-fl", "codex app-server"],
            timeout: 2
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return []
        }

        return result.stdoutString.components(separatedBy: "\n").compactMap { line in
            let lower = line.lowercased()
            if lower.contains("codexswitch") { return nil }
            if lower.contains("pgrep") { return nil }
            guard lower.contains(" app-server") else { return nil }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let first = parts.first else { return nil }
            return Int32(first)
        }
    }

    private nonisolated static func codexDesktopHostPIDs() -> [Int32] {
        let appContentsPath = "\(codexAppPath)/Contents"
        let lowerAppContentsPath = appContentsPath.lowercased()
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-fl", appContentsPath],
            timeout: 2
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return []
        }

        return result.stdoutString.components(separatedBy: "\n").compactMap { line in
            let lower = line.lowercased()
            if lower.contains("codexswitch") { return nil }
            if lower.contains("pgrep") { return nil }
            if lower.contains("codex resume") { return nil }
            if lower.contains("codex exec") { return nil }
            if lower.contains("computer use") { return nil }
            guard lower.contains("\(lowerAppContentsPath)/macos/")
                || lower.contains("codex helper")
                || lower.contains("codex (renderer)") else {
                return nil
            }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let first = parts.first else { return nil }
            return Int32(first)
        }
    }

    private nonisolated static func processEnvironment(for pid: Int32) -> String? {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["eww", "-p", "\(pid)"],
            timeout: 2
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return nil
        }
        return result.stdoutString
    }

    private nonisolated static func patchCooldownExpired() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: lastPatchAttemptPath),
              let date = attrs[.modificationDate] as? Date else {
            return true
        }
        return Date().timeIntervalSince(date) >= patchCooldownSeconds
    }

    private nonisolated static func markPatchAttempt() {
        let dir = (lastPatchAttemptPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        FileManager.default.createFile(atPath: lastPatchAttemptPath, contents: Data())
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: lastPatchAttemptPath
        )
    }

    private nonisolated static func clearPatchAttempt() {
        try? FileManager.default.removeItem(atPath: lastPatchAttemptPath)
    }

    private nonisolated static func permissionDeniedBackoffActive() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: permissionDeniedPath),
              let date = attrs[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(date) < permissionDeniedBackoffSeconds
    }

    private nonisolated static func markPermissionDenied() {
        let dir = (permissionDeniedPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        FileManager.default.createFile(atPath: permissionDeniedPath, contents: Data())
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: permissionDeniedPath
        )
    }

    private nonisolated static func clearPermissionDenied() {
        try? FileManager.default.removeItem(atPath: permissionDeniedPath)
    }

    private nonisolated static func isPermissionDenied(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("operation not permitted")
            || lower.contains("permissionerror")
            || lower.contains("app management")
            || lower.contains("ad-hoc sign codex.app")
    }

    private nonisolated static func isSigningIdentityMissing(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("no usable non-ad-hoc code signing identity")
            || lower.contains("refusing to ad-hoc sign codex.app")
    }

    private nonisolated static func isLiveAppRefusal(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("codex.app is running")
            && lower.contains("refusing to patch")
    }

    private nonisolated static func appendPatchLog(_ message: String) {
        let dir = (patchLogPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: patchLogPath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: patchLogPath, atomically: true, encoding: .utf8)
        }
    }
}
