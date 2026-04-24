import Foundation
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "VersionChecker")

struct CodexDesktopDisplayState: Equatable, Sendable {
    let installedVersionLabel: String
    let latestVersionLabel: String
    let runtimeLabel: String
    let autoSwapLabel: String
    let patchLabel: String
    let patchHealthy: Bool
    let canPatchNow: Bool
    let updateAvailable: Bool
    let autoSwapReady: Bool
}

@MainActor
@Observable
final class CodexVersionChecker {
    private static let minimumAutomaticRefreshInterval: TimeInterval = 60

    var installedVersion: String = "..."
    var latestVersion: String = "..."
    var lastChecked: Date?
    var isChecking = false
    var updateAvailable = false
    var isUpdating = false
    var updateResult: String?
    var updateSucceeded: Bool = false
    var forkInstalled = false
    var forkRebuilding = false
    var desktopInstalledVersionLabel: String = "..."
    var desktopLatestVersionLabel: String = "..."
    var desktopRuntimeLabel: String = "..."
    var desktopAutoSwapLabel: String = "..."
    var desktopAutoSwapReady = false
    var desktopPatchLabel: String = "..."
    var desktopPatchHealthy = false
    var desktopCanPatchNow = false
    var desktopPatchInFlight = false
    var desktopPatchResult: String?
    var desktopPatchSucceeded = false
    var desktopUpdateAvailable = false
    var desktopUpdateInFlight = false
    var desktopUpdateResult: String?
    var desktopUpdateSucceeded = false
    private var desktopLatestRelease: CodexDesktopAppRelease?

    private nonisolated static let versionJsonPath = NSString("~/.codex/version.json").expandingTildeInPath
    private nonisolated static let forkEnabledMarkerPath = NSString("~/.codexswitch/sighup-enabled").expandingTildeInPath
    private nonisolated static let forkSourcePath = NSString("~/Developer/codex/codex-rs").expandingTildeInPath
    private nonisolated static let forkCargoProfile = "fork-release"
    private nonisolated static let forkBinaryName = "codex"

    func checkVersions(force: Bool = false) {
        let now = Date()
        if !force && !Self.shouldCheckVersions(
            lastChecked: lastChecked,
            now: now,
            isChecking: isChecking,
            minimumInterval: Self.minimumAutomaticRefreshInterval
        ) {
            return
        }
        if force && isChecking {
            return
        }
        isChecking = true
        updateResult = nil

        Task.detached {
            let installed = Self._getInstalledVersion()
            let latest = Self._getLatestVersion()
            let hasFork = FileManager.default.fileExists(atPath: Self.forkEnabledMarkerPath)
            let latestDesktopRelease = await CodexDesktopAppUpdater.latestRelease()
            let desktopStatus = Self._getDesktopStatus()
            let liveDesktopStatus = await MainActor.run { CLIStatusChecker.cachedDesktopStatus }
            let desktopDisplay = Self.describeDesktop(
                summary: desktopStatus,
                liveStatus: liveDesktopStatus,
                latestRelease: latestDesktopRelease
            )
            await MainActor.run { [weak self] in
                self?.installedVersion = installed
                self?.latestVersion = latest
                self?.lastChecked = now
                self?.isChecking = false
                self?.forkInstalled = hasFork
                self?.updateAvailable = (installed != latest && latest != "?" && installed != "?")
                self?.desktopLatestRelease = latestDesktopRelease
                self?.applyDesktopDisplay(desktopDisplay)
            }
        }
    }

    func runUpdate() {
        isUpdating = true
        updateResult = nil
        updateSucceeded = false

        Task.detached {
            // Step 1: npm update
            let npmResult = Self._performNpmUpdate()
            guard npmResult.success else {
                await MainActor.run { [weak self] in
                    self?.isUpdating = false
                    self?.updateSucceeded = false
                    self?.updateResult = npmResult.message
                }
                return
            }

            let newNpmVersion = Self._getNpmPackageVersion()

            // Step 2: If fork is installed, rebuild it with the new version
            let hasFork = FileManager.default.fileExists(atPath: Self.forkEnabledMarkerPath)
            if hasFork {
                await MainActor.run { [weak self] in
                    self?.forkRebuilding = true
                    self?.updateResult = "Updated npm package. Rebuilding SIGHUP fork (this takes a few minutes)..."
                }

                let forkResult = Self._rebuildFork(version: newNpmVersion)

                let installed = Self._getInstalledVersion()
                let latest = Self._getLatestVersion()
                let latestDesktopRelease = await CodexDesktopAppUpdater.latestRelease()
                let desktopStatus = Self._getDesktopStatus()
                let liveDesktopStatus = await MainActor.run { CLIStatusChecker.cachedDesktopStatus }
                let desktopDisplay = Self.describeDesktop(
                    summary: desktopStatus,
                    liveStatus: liveDesktopStatus,
                    latestRelease: latestDesktopRelease
                )

                await MainActor.run { [weak self] in
                    self?.installedVersion = installed
                    self?.latestVersion = latest
                    self?.isUpdating = false
                    self?.forkRebuilding = false
                    self?.updateAvailable = (installed != latest && latest != "?" && installed != "?")
                    self?.updateSucceeded = forkResult.success
                    self?.updateResult = forkResult.success
                        ? "Updated to v\(newNpmVersion) with SIGHUP fork"
                        : "npm updated but fork rebuild failed: \(forkResult.message). Run `codex` manually to use stock binary."
                    self?.lastChecked = Date()
                    self?.desktopLatestRelease = latestDesktopRelease
                    self?.applyDesktopDisplay(desktopDisplay)
                }
            } else {
                let installed = Self._getInstalledVersion()
                let latest = Self._getLatestVersion()
                let latestDesktopRelease = await CodexDesktopAppUpdater.latestRelease()
                let desktopStatus = Self._getDesktopStatus()
                let liveDesktopStatus = await MainActor.run { CLIStatusChecker.cachedDesktopStatus }
                let desktopDisplay = Self.describeDesktop(
                    summary: desktopStatus,
                    liveStatus: liveDesktopStatus,
                    latestRelease: latestDesktopRelease
                )

                await MainActor.run { [weak self] in
                    self?.installedVersion = installed
                    self?.latestVersion = latest
                    self?.isUpdating = false
                    self?.updateAvailable = (installed != latest && latest != "?" && installed != "?")
                    self?.updateSucceeded = true
                    self?.updateResult = "Updated to v\(newNpmVersion)"
                    self?.lastChecked = Date()
                    self?.desktopLatestRelease = latestDesktopRelease
                    self?.applyDesktopDisplay(desktopDisplay)
                }
            }
        }
    }

    func refreshDesktopRuntimeStatus() {
        let liveDesktopStatus = CLIStatusChecker.cachedDesktopStatus
        desktopRuntimeLabel = liveDesktopStatus.label
        let autoSwapState = Self.describeDesktopAutoSwap(
            patchHealthy: desktopPatchHealthy,
            liveStatus: liveDesktopStatus
        )
        desktopAutoSwapLabel = autoSwapState.label
        desktopAutoSwapReady = autoSwapState.ready
    }

    func patchDesktopAppNow() {
        desktopPatchInFlight = true
        desktopPatchResult = nil
        desktopPatchSucceeded = false

        Task.detached {
            let result = CodexDesktopAppPatcher.patchInstalledAppNow()
            let latestDesktopRelease = await CodexDesktopAppUpdater.latestRelease()
            let desktopStatus = Self._getDesktopStatus()
            let liveDesktopStatus = await MainActor.run { CLIStatusChecker.cachedDesktopStatus }
            let desktopDisplay = Self.describeDesktop(
                summary: desktopStatus,
                liveStatus: liveDesktopStatus,
                latestRelease: latestDesktopRelease
            )

            await MainActor.run { [weak self] in
                self?.desktopPatchInFlight = false
                self?.desktopPatchResult = result.message
                self?.desktopPatchSucceeded = result.success
                self?.desktopLatestRelease = latestDesktopRelease
                self?.applyDesktopDisplay(desktopDisplay)
                self?.lastChecked = Date()
            }
        }
    }

    func installLatestDesktopNow() {
        guard let desktopLatestRelease else {
            desktopUpdateResult = "Could not determine the latest Codex desktop build"
            desktopUpdateSucceeded = false
            return
        }

        desktopUpdateInFlight = true
        desktopUpdateResult = nil
        desktopUpdateSucceeded = false

        Task.detached {
            let result = await CodexDesktopAppUpdater.installLatestStock(desktopLatestRelease)
            let latestDesktopRelease = await CodexDesktopAppUpdater.latestRelease()
            let desktopStatus = Self._getDesktopStatus()
            let liveDesktopStatus = await MainActor.run { CLIStatusChecker.cachedDesktopStatus }
            let desktopDisplay = Self.describeDesktop(
                summary: desktopStatus,
                liveStatus: liveDesktopStatus,
                latestRelease: latestDesktopRelease
            )

            await MainActor.run { [weak self] in
                self?.desktopUpdateInFlight = false
                self?.desktopUpdateResult = result.message
                self?.desktopUpdateSucceeded = result.success
                self?.desktopLatestRelease = latestDesktopRelease
                self?.applyDesktopDisplay(desktopDisplay)
                self?.lastChecked = Date()
            }
        }
    }

    // MARK: - Private (nonisolated for background execution)

    private nonisolated static func _getInstalledVersion() -> String {
        CodexInstallLocator.currentVersion()
    }

    private nonisolated static func _getNpmPackageVersion() -> String {
        let packageJsonPath = "/opt/homebrew/lib/node_modules/@openai/codex/package.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: packageJsonPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else {
            return "?"
        }
        return version
    }

    private nonisolated static func _getLatestVersion() -> String {
        // Try ~/.codex/version.json first (Codex's own check)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: versionJsonPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let latest = json["latest_version"] as? String {
            return latest
        }

        // Fall back to npm registry
        guard let output = ProcessRunner.run(
            executablePath: "/opt/homebrew/bin/npm",
            arguments: ["view", "@openai/codex", "version"],
            timeout: 5
        ) else {
            return "?"
        }
        guard !output.timedOut else { return "?" }
        let latest = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return latest.isEmpty ? "?" : latest
    }

    private nonisolated static func _getDesktopStatus() -> CodexDesktopAppStatusSummary {
        CodexDesktopAppPatcher.currentStatusSummary()
    }

    nonisolated static func describeDesktop(
        summary: CodexDesktopAppStatusSummary,
        liveStatus: DesktopAppStatus,
        latestRelease: CodexDesktopAppRelease?
    ) -> CodexDesktopDisplayState {
        let latestVersionLabel = latestRelease?.versionLabel ?? "Unavailable"
        let updateAvailable = latestRelease.map { $0.versionLabel != summary.installedVersionLabel } ?? false
        let autoSwapState = describeDesktopAutoSwap(
            patchHealthy: summary.patchHealthy,
            liveStatus: liveStatus
        )

        return CodexDesktopDisplayState(
            installedVersionLabel: summary.installedVersionLabel,
            latestVersionLabel: latestVersionLabel,
            runtimeLabel: liveStatus.label,
            autoSwapLabel: autoSwapState.label,
            patchLabel: summary.patchLabel,
            patchHealthy: summary.patchHealthy,
            canPatchNow: summary.canPatchNow,
            updateAvailable: updateAvailable,
            autoSwapReady: autoSwapState.ready
        )
    }

    private nonisolated static func describeDesktopAutoSwap(
        patchHealthy: Bool,
        liveStatus: DesktopAppStatus
    ) -> (ready: Bool, label: String) {
        _ = patchHealthy

        switch liveStatus.usageState {
        case .appRunning:
            return (true, "Desktop auto-swap ready")
        case .backgroundServiceOnly:
            return (false, "Desktop auto-swap unavailable: Codex.app UI is not running")
        case .notRunning:
            return (false, "Desktop auto-swap disconnected")
        }
    }

    struct ActionResult {
        let success: Bool
        let message: String
    }

    struct ForkBuildPlan: Equatable {
        let cargoArguments: [String]
        let outputBinaryPath: String
    }

    private nonisolated static func _performNpmUpdate() -> ActionResult {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

        guard let result = ProcessRunner.run(
            executablePath: "/opt/homebrew/bin/npm",
            arguments: ["install", "-g", "@openai/codex@latest"],
            timeout: 600,
            environment: env,
            captureStdout: false
        ) else {
            return ActionResult(success: false, message: "Failed to start npm update")
        }
        if result.timedOut {
            return ActionResult(success: false, message: "npm update timed out")
        }
        if result.terminationStatus == 0 {
            return ActionResult(success: true, message: "npm update succeeded")
        }
        return ActionResult(
            success: false,
            message: "npm update failed: \(String(result.stderr.prefix(200)))"
        )
    }

    nonisolated static func repairInstalledForkIfNeeded() -> ActionResult? {
        let forkEnabled = FileManager.default.fileExists(atPath: forkEnabledMarkerPath)
        guard forkEnabled else { return nil }
        guard let install = CodexInstallLocator.locate() else {
            return ActionResult(success: false, message: "Could not locate active codex install")
        }

        let currentVersion = _getInstalledVersion()
        guard currentVersion != "?" else {
            return ActionResult(success: false, message: "Could not read current codex version")
        }

        let savedState = CodexPatchStateStore.load()
        let verifiedMarkerPresent = CodexSighupMarkers.hasVerifiedMarker()
        if savedState == nil && CodexPatchRepairDecider.canRecoverPatchedState(
            verifiedMarkerPresent: verifiedMarkerPresent,
            currentInstall: install,
            currentVersion: currentVersion
        ) {
            try? CodexPatchStateStore.save(
                CodexPatchedInstallState(
                    version: currentVersion,
                    patchTargetPath: install.patchTargetPath
                )
            )
            return nil
        }

        guard CodexPatchRepairDecider.needsRepair(
            forkEnabled: forkEnabled,
            currentInstall: install,
            currentVersion: currentVersion,
            savedState: savedState
        ) else {
            return nil
        }

        return _rebuildFork(version: currentVersion, install: install)
    }

    /// Rebuild the SIGHUP fork binary against the current source with the given version.
    private nonisolated static func _rebuildFork(
        version: String,
        install: CodexInstall? = nil
    ) -> ActionResult {
        let cargoTomlPath = "\(forkSourcePath)/Cargo.toml"
        guard let install = install ?? CodexInstallLocator.locate() else {
            return ActionResult(success: false, message: "Could not locate active codex install")
        }

        // Step 1: Update version in workspace Cargo.toml.
        do {
            var content = try String(contentsOfFile: cargoTomlPath, encoding: .utf8)
            if let range = content.range(of: #"version = "[^"]+""#, options: .regularExpression) {
                content.replaceSubrange(range, with: "version = \"\(version)\"")
                try content.write(toFile: cargoTomlPath, atomically: true, encoding: .utf8)
            }
        } catch {
            return ActionResult(success: false, message: "Failed to update Cargo.toml: \(error.localizedDescription)")
        }

        // Step 2: Rebuild
        let buildPlan = forkBuildPlan(
            targetDirectory: _resolveCargoTargetDirectory(forkSourcePath: forkSourcePath)
                ?? "\(forkSourcePath)/target"
        )

        var env = ProcessInfo.processInfo.environment
        let cargoDir = NSString("~/.cargo/bin").expandingTildeInPath
        env["PATH"] = "\(cargoDir):/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        guard let buildResult = ProcessRunner.run(
            executablePath: NSString("~/.cargo/bin/cargo").expandingTildeInPath,
            arguments: buildPlan.cargoArguments,
            timeout: 1800,
            currentDirectoryURL: URL(fileURLWithPath: forkSourcePath),
            environment: env,
            captureStdout: false
        ) else {
            return ActionResult(success: false, message: "Failed to start cargo")
        }
        if buildResult.timedOut {
            return ActionResult(success: false, message: "Cargo build timed out")
        }
        guard buildResult.terminationStatus == 0 else {
            return ActionResult(
                success: false,
                message: "Cargo build failed: \(String(buildResult.stderr.suffix(300)))"
            )
        }

        guard FileManager.default.fileExists(atPath: buildPlan.outputBinaryPath) else {
            return ActionResult(
                success: false,
                message: "Fork build succeeded but binary was missing at \(buildPlan.outputBinaryPath)"
            )
        }

        // Step 3: Copy fork binary over the active install target
        let targetBinary = install.patchTargetPath
        let stockBackup = "\(targetBinary).stock-v\(version)"

        do {
            // Backup the stock binary if not already backed up
            if !FileManager.default.fileExists(atPath: stockBackup) {
                try FileManager.default.copyItem(atPath: targetBinary, toPath: stockBackup)
            }

            // Copy fork binary
            try FileManager.default.removeItem(atPath: targetBinary)
            try FileManager.default.copyItem(atPath: buildPlan.outputBinaryPath, toPath: targetBinary)

            // Ensure executable
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetBinary)

            try CodexPatchStateStore.save(
                CodexPatchedInstallState(
                    version: version,
                    patchTargetPath: install.patchTargetPath
                )
            )

            let markerPath = forkEnabledMarkerPath
            if FileManager.default.fileExists(atPath: markerPath) {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: markerPath
                )
            }

            logger.info("Fork binary installed for v\(version) at \(install.patchTargetPath, privacy: .public)")
            SwapLog.append(.cliStatusChanged(from: "stock-\(version)", to: "fork-\(version)"))
            return ActionResult(success: true, message: "Fork rebuilt and installed for v\(version)")
        } catch {
            return ActionResult(success: false, message: "Binary copy failed: \(error.localizedDescription)")
        }
    }

    nonisolated static func forkBuildPlan(targetDirectory: String) -> ForkBuildPlan {
        ForkBuildPlan(
            cargoArguments: [
                "build",
                "--profile", forkCargoProfile,
                "-p", "codex-cli",
                "--bin", forkBinaryName,
            ],
            outputBinaryPath: "\(targetDirectory)/\(forkCargoProfile)/\(forkBinaryName)"
        )
    }

    nonisolated static func shouldCheckVersions(
        lastChecked: Date?,
        now: Date,
        isChecking: Bool,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard !isChecking else { return false }
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= minimumInterval
    }

    private nonisolated static func _resolveCargoTargetDirectory(forkSourcePath: String) -> String? {
        guard let output = ProcessRunner.run(
            executablePath: NSString("~/.cargo/bin/cargo").expandingTildeInPath,
            arguments: ["metadata", "--no-deps", "--format-version", "1"],
            timeout: 5,
            currentDirectoryURL: URL(fileURLWithPath: forkSourcePath)
        ) else {
            return nil
        }
        guard !output.timedOut,
              output.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any],
              let targetDirectory = json["target_directory"] as? String,
              !targetDirectory.isEmpty else {
            return nil
        }

        return targetDirectory
    }

    private func applyDesktopDisplay(_ display: CodexDesktopDisplayState) {
        desktopInstalledVersionLabel = display.installedVersionLabel
        desktopLatestVersionLabel = display.latestVersionLabel
        desktopRuntimeLabel = display.runtimeLabel
        desktopAutoSwapLabel = display.autoSwapLabel
        desktopAutoSwapReady = display.autoSwapReady
        desktopPatchLabel = display.patchLabel
        desktopPatchHealthy = display.patchHealthy
        desktopCanPatchNow = display.canPatchNow
        desktopUpdateAvailable = display.updateAvailable
    }
}
