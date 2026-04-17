import CommonCrypto
import Foundation
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "VersionChecker")

enum ForkBuildStatus: Equatable {
    case active(version: String, builtAt: Date)
    case rebuilding(detail: String)
    case failed(error: String)
    case unavailable  // no fork source or cargo installed
    case stale        // binary updated, fork needs rebuild
    case unknown

    var label: String {
        switch self {
        case .active(let version, let builtAt):
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d @ h:mma"
            return "Hot-reload: v\(version) rebuilt \(formatter.string(from: builtAt))"
        case .rebuilding(let detail):
            return "Hot-reload: \(detail)"
        case .failed(let error):
            return "Hot-reload: Build failed — \(error)"
        case .unavailable:
            return "Hot-reload: Fork not installed"
        case .stale:
            return "Hot-reload: Binary updated, rebuilding..."
        case .unknown:
            return "Hot-reload: Checking..."
        }
    }

    var icon: String {
        switch self {
        case .active: return "hammer.circle.fill"
        case .rebuilding, .stale: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .unavailable, .unknown: return "minus.circle"
        }
    }

    var color: String {
        switch self {
        case .active: return "green"
        case .rebuilding, .stale: return "orange"
        case .failed: return "red"
        case .unavailable, .unknown: return "secondary"
        }
    }
}

@MainActor
@Observable
final class CodexVersionChecker {
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
    var forkBuildStatus: ForkBuildStatus = .unknown

    private var isAutoRebuilding = false
    private var lastAutoRebuildAttempt: Date?
    private var lastNpmCheckTime: Date?
    private static let autoRebuildCooldown: TimeInterval = 300 // 5 min cooldown after failure
    private static let npmCheckInterval: TimeInterval = 3600 // check npm every hour

    nonisolated static let versionJsonPath = NSString("~/.codex/version.json").expandingTildeInPath
    nonisolated static let forkMarkerPath = NSString("~/.codexswitch/sighup-enabled").expandingTildeInPath
    nonisolated static let forkSourcePath = NSString("~/Developer/codex/codex-rs").expandingTildeInPath
    nonisolated static let forkBinaryPath = NSString("~/Developer/codex/codex-rs/target/fork-release/codex").expandingTildeInPath
    nonisolated static let stockBinaryDir = "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex"
    nonisolated static let vendorBinaryPath = "\(stockBinaryDir)/codex"
    nonisolated static let sighupVerifiedExecPath = NSString("~/.codexswitch/sighup-verified-exec").expandingTildeInPath
    nonisolated static let sighupVerifiedTuiPath = NSString("~/.codexswitch/sighup-verified-tui").expandingTildeInPath
    nonisolated static let cargoPath = NSString("~/.cargo/bin/cargo").expandingTildeInPath
    nonisolated static let asarPath = "/Applications/Codex.app/Contents/Resources/app.asar"
    nonisolated static let asarPatcherPath = "/Users/brendondelgado/Developer/CodexSwitch/scripts/patch-asar.py"

    // MARK: - UserDefaults keys for persisted fork build info
    private nonisolated static let buildVersionKey = "forkBuildVersion"
    private nonisolated static let buildDateKey = "forkBuildDate"
    private nonisolated static let asarPatchedHashKey = "asarPatchedHash"

    // MARK: - Auto-rebuild

    /// Called from the periodic timer. Checks if the vendor binary was updated
    /// and our SIGHUP fork needs rebuilding. Triggers rebuild automatically.
    func autoRebuildIfNeeded() {
        guard !isAutoRebuilding, !isUpdating else { return }

        // Cooldown after any rebuild attempt (success or failure) to avoid thrashing
        if let last = lastAutoRebuildAttempt,
           Date().timeIntervalSince(last) < Self.autoRebuildCooldown {
            return
        }

        // Check npm for new CLI version every hour and auto-update
        if lastNpmCheckTime == nil || Date().timeIntervalSince(lastNpmCheckTime!) >= Self.npmCheckInterval {
            lastNpmCheckTime = Date()
            _autoUpdateCliIfNeeded()
        }

        Task.detached { [weak self] in
            let status = Self._checkForkStatus()
            await MainActor.run {
                guard let self else { return }
                switch status {
                case .needsRebuild(let version):
                    self.forkBuildStatus = .stale
                    self.triggerAutoRebuild(version: version)
                case .active(let version, let builtAt, let asarNeedsPatching):
                    self.forkBuildStatus = .active(version: version, builtAt: builtAt)
                    self.forkInstalled = true
                    if asarNeedsPatching {
                        self.triggerAsarPatch()
                    }
                case .unavailable:
                    self.forkBuildStatus = .unavailable
                    self.forkInstalled = false
                }
            }
        }
    }

    private func triggerAutoRebuild(version: String) {
        guard !isAutoRebuilding else { return }
        isAutoRebuilding = true
        forkBuildStatus = .rebuilding(detail: "Downloading fork v\(version)...")
        lastAutoRebuildAttempt = Date()

        // If the fork binary already exists and just needs to be re-copied
        // (e.g. Codex app was reinstalled), skip both download and build.
        let forkBinaryExists = FileManager.default.fileExists(atPath: Self.forkBinaryPath)
        SwapLog.append(.debug("Auto-rebuild triggered for v\(version), forkBinaryExists=\(forkBinaryExists)"))

        Task.detached { [weak self] in
            let result: ActionResult

            if forkBinaryExists {
                // Binary cached locally -- just re-install it
                result = Self._installForkBinary(version: version)
            } else {
                // Strategy: try GitHub Releases download first, fall back to cargo build
                SwapLog.append(.debug("Attempting GitHub Releases download for v\(version)"))
                let downloadResult = await Self._downloadForkBinary(version: version)

                if downloadResult.success {
                    result = Self._installForkBinary(version: version)
                } else {
                    // Download unavailable -- fall back to local cargo build if possible
                    let hasCargoAndSource = FileManager.default.fileExists(atPath: Self.forkSourcePath)
                        && FileManager.default.fileExists(atPath: Self.cargoPath)

                    if hasCargoAndSource {
                        SwapLog.append(.debug("Download failed (\(downloadResult.message)), falling back to cargo build"))
                        await MainActor.run {
                            self?.forkBuildStatus = .rebuilding(detail: "Building fork v\(version)...")
                        }
                        result = Self._rebuildFork(version: version)
                    } else {
                        SwapLog.append(.debug("Download failed and no local build deps available"))
                        result = ActionResult(
                            success: false,
                            message: "No pre-built binary available and Rust toolchain not installed"
                        )
                    }
                }
            }

            // After binary install succeeds, also patch the desktop app asar
            if result.success {
                await MainActor.run {
                    self?.forkBuildStatus = .rebuilding(detail: "Patching desktop app...")
                }
                let asarResult = Self._patchDesktopAsar()
                if !asarResult.success {
                    SwapLog.append(.debug("Asar patch after rebuild failed (non-fatal): \(asarResult.message)"))
                    logger.warning("Asar patch after rebuild failed: \(asarResult.message)")
                }
            }

            let now = Date()
            await MainActor.run {
                guard let self else { return }
                self.isAutoRebuilding = false

                if result.success {
                    self.forkBuildStatus = .active(version: version, builtAt: now)
                    self.forkInstalled = true
                    UserDefaults.standard.set(version, forKey: Self.buildVersionKey)
                    UserDefaults.standard.set(now, forKey: Self.buildDateKey)
                    SwapLog.append(.cliStatusChanged(from: "stock-\(version)", to: "fork-\(version)"))
                    logger.info("Auto-rebuild succeeded for v\(version)")
                } else {
                    self.forkBuildStatus = .failed(error: String(result.message.prefix(80)))
                    SwapLog.append(.debug("Auto-rebuild failed: \(result.message)"))
                    logger.error("Auto-rebuild failed: \(result.message)")
                }
            }
        }
    }

    /// Trigger asar patching independently (e.g. desktop app updated but fork binary is current).
    /// Runs in a background task and updates UI status while patching.
    private func triggerAsarPatch() {
        guard !isAutoRebuilding else { return }
        let previousStatus = forkBuildStatus
        forkBuildStatus = .rebuilding(detail: "Patching desktop app...")

        Task.detached { [weak self] in
            let asarResult = Self._patchDesktopAsar()
            await MainActor.run {
                guard let self else { return }
                if asarResult.success {
                    // Restore the previous active status (asar patch is additive)
                    self.forkBuildStatus = previousStatus
                    logger.info("Asar patch succeeded (standalone)")
                } else {
                    // Asar failure is non-fatal -- restore status and log
                    self.forkBuildStatus = previousStatus
                    SwapLog.append(.debug("Standalone asar patch failed: \(asarResult.message)"))
                    logger.warning("Standalone asar patch failed: \(asarResult.message)")
                }
            }
        }
    }

    private enum ForkCheckResult {
        case active(version: String, builtAt: Date, asarNeedsPatching: Bool)
        case needsRebuild(version: String)
        case unavailable
    }

    /// Check GitHub releases for a newer Codex CLI binary and auto-update if found.
    ///
    /// Uses `gh release download` from GitHub releases instead of npm, because
    /// npm's registry frequently serves stale native binaries that don't match
    /// the package version (e.g., npm says 0.120.0 but the binary reports 0.116.0).
    /// GitHub releases always have the correct binary.
    ///
    /// Also copies the updated binary into the Codex desktop app bundle so the
    /// Electron frontend's version check passes.
    private func _autoUpdateCliIfNeeded() {
        Task.detached {
            // Get the version we're comparing against. If the fork is installed,
            // the vendor binary reports the fork's version (0.116.0) which doesn't
            // reflect the actual stock version available. Use the cached binary instead.
            let cachePath = NSString("~/.codexswitch/cache/codex-latest").expandingTildeInPath
            let cacheVersion = Self._getBinaryVersion(cachePath)
            let vendorVersion = Self._getBinaryVersion(Self.vendorBinaryPath)
            let installedVersion = cacheVersion.isEmpty ? vendorVersion : cacheVersion
            guard !installedVersion.isEmpty else {
                logger.info("No binary found — skipping update check")
                return
            }

            // Get latest release tag from GitHub
            let ghProcess = Process()
            ghProcess.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/gh")
            ghProcess.arguments = ["release", "list", "--repo", "openai/codex", "--limit", "1", "--json", "tagName", "--jq", ".[0].tagName"]
            let ghPipe = Pipe()
            ghProcess.standardOutput = ghPipe
            ghProcess.standardError = FileHandle.nullDevice
            do { try ghProcess.run() } catch {
                logger.error("Failed to run gh: \(error.localizedDescription)")
                return
            }
            ghProcess.waitUntilExit()
            let tagName = String(data: ghPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !tagName.isEmpty else { return }

            // Extract version from tag (e.g., "rust-v0.120.0" → "0.120.0")
            let latestVersion = tagName.replacingOccurrences(of: "rust-v", with: "")
            guard !latestVersion.isEmpty else { return }

            guard latestVersion != installedVersion else {
                logger.info("CLI binary is up to date: \(installedVersion)")
                return
            }

            logger.info("CLI binary update available: \(installedVersion) → \(latestVersion) (tag: \(tagName))")
            SwapLog.append(.debug("CLI_UPDATE: \(installedVersion) → \(latestVersion) via gh release"))

            // Download the native binary from GitHub releases
            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-update-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let downloadProcess = Process()
            downloadProcess.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/gh")
            downloadProcess.arguments = [
                "release", "download", tagName,
                "--repo", "openai/codex",
                "--pattern", "*darwin*arm64*",
                "--dir", tmpDir.path
            ]
            downloadProcess.standardOutput = FileHandle.nullDevice
            downloadProcess.standardError = FileHandle.nullDevice
            do { try downloadProcess.run() } catch {
                logger.error("gh release download failed: \(error.localizedDescription)")
                SwapLog.append(.debug("CLI_UPDATE: gh download failed — \(error.localizedDescription)"))
                return
            }
            downloadProcess.waitUntilExit()
            guard downloadProcess.terminationStatus == 0 else {
                SwapLog.append(.debug("CLI_UPDATE: gh download exit \(downloadProcess.terminationStatus)"))
                return
            }

            // Extract the tgz to get the native binary
            guard let tgz = try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
                .first(where: { $0.hasSuffix(".tgz") }) else {
                SwapLog.append(.debug("CLI_UPDATE: no .tgz found in download"))
                return
            }

            let extractProcess = Process()
            extractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            extractProcess.arguments = ["xzf", tmpDir.appendingPathComponent(tgz).path, "-C", tmpDir.path]
            extractProcess.standardOutput = FileHandle.nullDevice
            extractProcess.standardError = FileHandle.nullDevice
            try? extractProcess.run()
            extractProcess.waitUntilExit()

            let newBinary = tmpDir.appendingPathComponent("package/vendor/aarch64-apple-darwin/codex/codex")
            guard FileManager.default.fileExists(atPath: newBinary.path) else {
                SwapLog.append(.debug("CLI_UPDATE: extracted binary not found"))
                return
            }

            // Verify the new binary reports the expected version
            let newVersion = Self._getBinaryVersion(newBinary.path)
            if newVersion != latestVersion {
                logger.warning("Binary version mismatch: expected \(latestVersion), got \(newVersion)")
                SwapLog.append(.debug("CLI_UPDATE: version mismatch expected=\(latestVersion) got=\(newVersion)"))
            }

            // Install to app bundle and cache. Skip the vendor binary if the
            // SIGHUP fork is installed — the fork build system manages that path,
            // and overwriting it with stock removes the SIGHUP handler until the
            // next fork rebuild (which can leave a window where swaps kill sessions).
            let forkInstalled = FileManager.default.fileExists(atPath: Self.sighupVerifiedExecPath)
                || FileManager.default.fileExists(atPath: Self.sighupVerifiedTuiPath)
            var destinations = [
                "/Applications/Codex.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/bin/codex",
                cachePath,
            ]
            if !forkInstalled {
                destinations.insert(Self.vendorBinaryPath, at: 0)
            } else {
                SwapLog.append(.debug("CLI_UPDATE: skipping vendor binary (fork installed)"))
            }
            var installed = 0
            for dest in destinations {
                // Ensure parent directory exists
                let parent = (dest as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                do {
                    // Remove old binary first (handles locked files)
                    try? FileManager.default.removeItem(atPath: dest)
                    try FileManager.default.copyItem(atPath: newBinary.path, toPath: dest)
                    // Ensure executable
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
                    installed += 1
                } catch {
                    logger.warning("Failed to install to \(dest): \(error.localizedDescription)")
                }
            }

            let finalVersion = Self._getBinaryVersion(Self.vendorBinaryPath)
            SwapLog.append(.debug("CLI_UPDATE: installed \(finalVersion) to \(installed)/\(destinations.count) locations"))
            logger.info("CLI updated: \(installedVersion) → \(finalVersion)")
            NotificationManager.notify(
                title: "Codex CLI Updated",
                body: "\(installedVersion) → \(finalVersion) (from GitHub releases). Fork binary will be rebuilt automatically."
            )
        }
    }

    /// Get the version string from a codex binary by running `<path> --version`.
    nonisolated static func _getBinaryVersion(_ path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // "codex-cli 0.120.0" → "0.120.0"
        return output.replacingOccurrences(of: "codex-cli ", with: "")
    }

    private nonisolated static func _checkForkStatus() -> ForkCheckResult {
        let fm = FileManager.default

        // The vendor binary (stock Codex CLI) must exist for patching to be meaningful
        guard fm.fileExists(atPath: vendorBinaryPath) else {
            return .unavailable
        }

        // We can proceed with either download (no local deps) or cargo build
        // (requires fork source + cargo). If neither path is available, mark unavailable.
        let hasLocalBuildDeps = fm.fileExists(atPath: forkSourcePath) && fm.fileExists(atPath: cargoPath)
        let hasForkBinary = fm.fileExists(atPath: forkBinaryPath)
        let hasForkMarker = fm.fileExists(atPath: forkMarkerPath)
        if !hasLocalBuildDeps && !hasForkBinary && !hasForkMarker {
            // No way to obtain a fork binary and none cached -- still proceed
            // so triggerAutoRebuild can attempt a download. Only truly unavailable
            // if the vendor binary is also missing (caught above).
        }

        let version = _getNpmPackageVersion()

        // Check if the DESKTOP binary is actually our fork (not stock from a reinstall).
        // Our fork is ~150-190MB, stock is ~110-120MB. If the desktop binary is too small,
        // it was replaced by a fresh install and needs re-patching.
        let desktopBinary = "/Applications/Codex.app/Contents/Resources/codex"
        if fm.fileExists(atPath: desktopBinary),
           fm.fileExists(atPath: forkBinaryPath) {
            let desktopSize = (try? fm.attributesOfItem(atPath: desktopBinary))?[.size] as? Int ?? 0
            let forkSize = (try? fm.attributesOfItem(atPath: forkBinaryPath))?[.size] as? Int ?? 0
            // If the desktop binary size doesn't match our fork, it was replaced
            if forkSize > 0 && desktopSize != forkSize {
                return .needsRebuild(version: version)
            }
        }

        // Check if sighup verification is current (marker >= binary mod date)
        let execDate = (try? fm.attributesOfItem(atPath: sighupVerifiedExecPath))?[.modificationDate] as? Date
        let tuiDate = (try? fm.attributesOfItem(atPath: sighupVerifiedTuiPath))?[.modificationDate] as? Date
        let markerDate = [execDate, tuiDate].compactMap { $0 }.max()
        let binaryDate = (try? fm.attributesOfItem(atPath: vendorBinaryPath))?[.modificationDate] as? Date

        if SwapEngine.isSighupVerificationCurrent(
            markerModificationDate: markerDate,
            binaryModificationDate: binaryDate
        ) {
            let builtAt = UserDefaults.standard.object(forKey: buildDateKey) as? Date ?? (markerDate ?? Date())
            let asarNeedsPatching = _isAsarPatchNeeded()
            return .active(version: version, builtAt: builtAt, asarNeedsPatching: asarNeedsPatching)
        }

        // Marker is stale or missing — need rebuild
        return .needsRebuild(version: version)
    }

    // MARK: - Manual version check + update (Settings UI)

    func checkVersions() {
        isChecking = true
        updateResult = nil

        Task.detached {
            let installed = Self._getInstalledVersion()
            let latest = Self._getLatestVersion()
            let hasFork = FileManager.default.fileExists(atPath: Self.forkMarkerPath)
            let now = Date()

            await MainActor.run { [weak self] in
                self?.installedVersion = installed
                self?.latestVersion = latest
                self?.lastChecked = now
                self?.isChecking = false
                self?.forkInstalled = hasFork
                self?.updateAvailable = (installed != latest && latest != "?" && installed != "?")
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
            let hasFork = FileManager.default.fileExists(atPath: Self.forkMarkerPath)
            if hasFork {
                await MainActor.run { [weak self] in
                    self?.forkRebuilding = true
                    self?.forkBuildStatus = .rebuilding(detail: "Building fork v\(newNpmVersion)...")
                    self?.updateResult = "Updated npm package. Rebuilding SIGHUP fork (this takes a few minutes)..."
                }

                let forkResult = Self._rebuildFork(version: newNpmVersion)

                // Also patch the asar after a successful fork rebuild
                if forkResult.success {
                    await MainActor.run { [weak self] in
                        self?.forkBuildStatus = .rebuilding(detail: "Patching desktop app...")
                    }
                    let asarResult = Self._patchDesktopAsar()
                    if !asarResult.success {
                        SwapLog.append(.debug("Asar patch after manual update failed (non-fatal): \(asarResult.message)"))
                        logger.warning("Asar patch after manual update failed: \(asarResult.message)")
                    }
                }

                let now = Date()

                let installed = Self._getInstalledVersion()
                let latest = Self._getLatestVersion()

                await MainActor.run { [weak self] in
                    self?.installedVersion = installed
                    self?.latestVersion = latest
                    self?.isUpdating = false
                    self?.forkRebuilding = false
                    self?.updateAvailable = (installed != latest && latest != "?" && installed != "?")
                    self?.updateSucceeded = forkResult.success
                    if forkResult.success {
                        self?.updateResult = "Updated to v\(newNpmVersion) with SIGHUP fork"
                        self?.forkBuildStatus = .active(version: newNpmVersion, builtAt: now)
                        UserDefaults.standard.set(newNpmVersion, forKey: Self.buildVersionKey)
                        UserDefaults.standard.set(now, forKey: Self.buildDateKey)
                    } else {
                        self?.updateResult = "npm updated but fork rebuild failed: \(forkResult.message)"
                        self?.forkBuildStatus = .failed(error: String(forkResult.message.prefix(80)))
                    }
                    self?.lastChecked = Date()
                }
            } else {
                let installed = Self._getInstalledVersion()
                let latest = Self._getLatestVersion()

                await MainActor.run { [weak self] in
                    self?.installedVersion = installed
                    self?.latestVersion = latest
                    self?.isUpdating = false
                    self?.updateAvailable = (installed != latest && latest != "?" && installed != "?")
                    self?.updateSucceeded = true
                    self?.updateResult = "Updated to v\(newNpmVersion)"
                    self?.lastChecked = Date()
                }
            }
        }
    }

    // MARK: - Private helpers (nonisolated for background execution)

    private nonisolated static func _getInstalledVersion() -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let version = output.replacingOccurrences(of: "codex-cli ", with: "")
            return version.isEmpty ? "?" : version
        } catch {
            return "?"
        }
    }

    nonisolated static func _getNpmPackageVersion() -> String {
        let packageJsonPath = "/opt/homebrew/lib/node_modules/@openai/codex/package.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: packageJsonPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else {
            return "?"
        }
        return version
    }

    private nonisolated static func _getLatestVersion() -> String {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: versionJsonPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let latest = json["latest_version"] as? String {
            return latest
        }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/npm")
        process.arguments = ["view", "@openai/codex", "version"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output.isEmpty ? "?" : output
        } catch {
            return "?"
        }
    }

    private nonisolated static func _performNpmUpdate() -> ActionResult {
        let errPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/npm")
        process.arguments = ["install", "-g", "@openai/codex@latest"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        do {
            try process.run()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return ActionResult(success: true, message: "npm update succeeded")
            } else {
                let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
                return ActionResult(success: false, message: "npm update failed: \(String(errStr.prefix(200)))")
            }
        } catch {
            return ActionResult(success: false, message: "Failed: \(error.localizedDescription)")
        }
    }

    struct ActionResult {
        let success: Bool
        let message: String
    }

    /// Download a pre-built fork binary from GitHub Releases.
    /// Returns success if the binary was downloaded and saved to `forkBinaryPath`.
    nonisolated static func _downloadForkBinary(version: String) async -> ActionResult {
        let tagName = "fork-v\(version)"
        let assetName = "codex-fork-\(version)-arm64-darwin"
        let releaseURL = "https://api.github.com/repos/brendondelgado/codex/releases/tags/\(tagName)"

        logger.info("Checking GitHub Releases for \(tagName)")

        // Step 1: Query the GitHub Releases API for the tagged release
        guard let apiURL = URL(string: releaseURL) else {
            return ActionResult(success: false, message: "Invalid release URL")
        }

        var apiRequest = URLRequest(url: apiURL)
        apiRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        apiRequest.timeoutInterval = 15

        let releaseData: Data
        let releaseResponse: URLResponse
        do {
            (releaseData, releaseResponse) = try await URLSession.shared.data(for: apiRequest)
        } catch {
            return ActionResult(success: false, message: "GitHub API request failed: \(error.localizedDescription)")
        }

        guard let httpResponse = releaseResponse as? HTTPURLResponse else {
            return ActionResult(success: false, message: "Unexpected response type from GitHub API")
        }

        if httpResponse.statusCode == 404 {
            return ActionResult(success: false, message: "No release found for tag \(tagName)")
        }
        guard httpResponse.statusCode == 200 else {
            return ActionResult(success: false, message: "GitHub API returned status \(httpResponse.statusCode)")
        }

        // Step 2: Parse the release JSON to find the asset download URL
        guard let json = try? JSONSerialization.jsonObject(with: releaseData) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            return ActionResult(success: false, message: "Failed to parse release JSON")
        }

        guard let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
              let downloadURLString = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLString) else {
            let availableNames = assets.compactMap { $0["name"] as? String }.joined(separator: ", ")
            return ActionResult(
                success: false,
                message: "Asset \(assetName) not found in release. Available: \(availableNames)"
            )
        }

        logger.info("Downloading fork binary from \(downloadURLString)")

        // Step 3: Download the binary
        var downloadRequest = URLRequest(url: downloadURL)
        downloadRequest.timeoutInterval = 120 // binary is ~150-180MB

        let binaryFileURL: URL
        let downloadResponse: URLResponse
        do {
            (binaryFileURL, downloadResponse) = try await URLSession.shared.download(for: downloadRequest)
        } catch {
            return ActionResult(success: false, message: "Binary download failed: \(error.localizedDescription)")
        }

        guard let dlHTTP = downloadResponse as? HTTPURLResponse, dlHTTP.statusCode == 200 else {
            let status = (downloadResponse as? HTTPURLResponse)?.statusCode ?? -1
            return ActionResult(success: false, message: "Binary download returned status \(status)")
        }

        // Step 4: Move the downloaded file to the fork binary path
        let fm = FileManager.default
        let targetDir = (forkBinaryPath as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: forkBinaryPath) {
                try fm.removeItem(atPath: forkBinaryPath)
            }
            try fm.moveItem(at: binaryFileURL, to: URL(fileURLWithPath: forkBinaryPath))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: forkBinaryPath)
        } catch {
            return ActionResult(success: false, message: "Failed to save binary: \(error.localizedDescription)")
        }

        // Verify the file is reasonably sized (fork binaries are ~150-180MB)
        let fileSize = (try? fm.attributesOfItem(atPath: forkBinaryPath))?[.size] as? Int ?? 0
        if fileSize < 50_000_000 {
            try? fm.removeItem(atPath: forkBinaryPath)
            return ActionResult(success: false, message: "Downloaded file too small (\(fileSize) bytes), likely not a valid binary")
        }

        logger.info("Fork binary downloaded: \(fileSize) bytes for v\(version)")
        SwapLog.append(.debug("Downloaded fork binary v\(version) (\(fileSize / 1_048_576) MB) from GitHub Releases"))
        return ActionResult(success: true, message: "Downloaded fork binary v\(version)")
    }

    /// Rebuild the SIGHUP fork binary against the current source with the given version.
    nonisolated static func _rebuildFork(version: String) -> ActionResult {
        let cargoTomlPath = "\(forkSourcePath)/Cargo.toml"

        // Step 1: Clean working tree, fetch upstream, rebase
        // Stash any uncommitted changes (e.g. Cargo.lock drift) so rebase can proceed
        func git(_ args: String...) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", forkSourcePath] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }

        _ = git("stash")
        _ = git("fetch", "upstream")
        let rebaseStatus = git("rebase", "upstream/main")
        _ = git("stash", "pop")

        if rebaseStatus != 0 {
            _ = git("rebase", "--abort")
            _ = git("stash", "pop")
            return ActionResult(success: false, message: "Rebase failed — patches need manual conflict resolution")
        }

        // Step 2: Update version in workspace Cargo.toml
        do {
            var content = try String(contentsOfFile: cargoTomlPath, encoding: .utf8)
            if let range = content.range(of: #"version = "\d+\.\d+\.\d+""#, options: .regularExpression) {
                content.replaceSubrange(range, with: "version = \"\(version)\"")
                try content.write(toFile: cargoTomlPath, atomically: true, encoding: .utf8)
            }
        } catch {
            return ActionResult(success: false, message: "Failed to update Cargo.toml: \(error.localizedDescription)")
        }

        // Step 3: Rebuild
        let buildErrPipe = Pipe()
        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: cargoPath)
        buildProcess.arguments = ["build", "--profile", "fork-release", "-p", "codex-cli"]
        buildProcess.currentDirectoryURL = URL(fileURLWithPath: forkSourcePath)
        buildProcess.standardOutput = FileHandle.nullDevice
        buildProcess.standardError = buildErrPipe
        var env = ProcessInfo.processInfo.environment
        let cargoDir = NSString("~/.cargo/bin").expandingTildeInPath
        env["PATH"] = "\(cargoDir):/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        buildProcess.environment = env

        do {
            try buildProcess.run()
            let errData = buildErrPipe.fileHandleForReading.readDataToEndOfFile()
            buildProcess.waitUntilExit()

            guard buildProcess.terminationStatus == 0 else {
                let errStr = String(data: errData, encoding: .utf8) ?? "Unknown"
                return ActionResult(success: false, message: "Cargo build failed: \(String(errStr.suffix(300)))")
            }
        } catch {
            return ActionResult(success: false, message: "Failed to start cargo: \(error.localizedDescription)")
        }

        // Step 4: Copy fork binary over CLI vendor binary AND desktop app binary
        let cliBinary = "\(stockBinaryDir)/codex"
        let desktopBinary = "/Applications/Codex.app/Contents/Resources/codex"
        let fm = FileManager.default

        do {
            // CLI vendor binary
            let cliBackup = "\(stockBinaryDir)/codex.stock-v\(version)"
            if !fm.fileExists(atPath: cliBackup) {
                try? fm.copyItem(atPath: cliBinary, toPath: cliBackup)
            }
            try? fm.removeItem(atPath: cliBinary)
            try fm.copyItem(atPath: forkBinaryPath, toPath: cliBinary)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliBinary)

            // Desktop app binaries (both legacy and new path)
            let desktopPaths = [
                "/Applications/Codex.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/bin/codex",
            ]
            for desktopPath in desktopPaths {
                let dir = (desktopPath as NSString).deletingLastPathComponent
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: desktopPath) {
                    let backup = "\(desktopPath).stock"
                    if !fm.fileExists(atPath: backup) {
                        try? fm.copyItem(atPath: desktopPath, toPath: backup)
                    }
                    try? fm.removeItem(atPath: desktopPath)
                }
                try fm.copyItem(atPath: forkBinaryPath, toPath: desktopPath)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: desktopPath)
            }
            logger.info("Desktop app binaries patched for v\(version)")

            // Re-sign the entire Codex.app bundle (inner frameworks first, then outer).
            // Signing individual binaries alone isn't enough — adding files to a signed
            // bundle breaks the seal, and Electron's integrity check crashes on launch.
            _resignCodexApp()
            logger.info("Re-signed Codex.app after fork binary install")

            // Touch/create ALL markers so the staleness check passes immediately
            let markerDir = NSString("~/.codexswitch").expandingTildeInPath
            try? fm.createDirectory(atPath: markerDir, withIntermediateDirectories: true)
            for marker in [forkMarkerPath, sighupVerifiedExecPath, sighupVerifiedTuiPath] {
                if fm.fileExists(atPath: marker) {
                    try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: marker)
                } else {
                    fm.createFile(atPath: marker, contents: nil)
                }
            }

            logger.info("Fork binary installed for v\(version)")
            return ActionResult(success: true, message: "Fork rebuilt and installed for v\(version)")
        } catch {
            return ActionResult(success: false, message: "Binary copy failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Asar patching

    /// Compute a SHA-256 hash of the given file. Returns nil if the file does not exist.
    private nonisolated static func _computeAsarHash() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: asarPath)) else {
            return nil
        }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Check whether the asar needs patching by comparing its current hash
    /// against the hash stored when we last successfully patched it.
    nonisolated static func _isAsarPatchNeeded() -> Bool {
        guard FileManager.default.fileExists(atPath: asarPath) else {
            return false // No Codex.app installed
        }
        guard let currentHash = _computeAsarHash() else {
            return false
        }
        let storedHash = UserDefaults.standard.string(forKey: asarPatchedHashKey)
        return currentHash != storedHash
    }

    /// Run the asar patcher Python script as a subprocess.
    /// On success, stores the new asar hash in UserDefaults so the same asar
    /// is not re-patched until Codex updates again.
    /// On failure, logs the error but returns a non-fatal result.
    nonisolated static func _patchDesktopAsar() -> ActionResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: asarPath) else {
            return ActionResult(success: false, message: "app.asar not found at \(asarPath)")
        }
        guard fm.fileExists(atPath: asarPatcherPath) else {
            return ActionResult(success: false, message: "patch-asar.py not found at \(asarPatcherPath)")
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [asarPatcherPath]
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Ensure npx (from node/npm) is on the PATH for asar extract/pack
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(env["PATH"] ?? "/usr/bin:/bin")"
        process.environment = env

        do {
            try process.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")

            switch process.terminationStatus {
            case 0:
                // Patched successfully (or already patched) -- store hash
                if let newHash = _computeAsarHash() {
                    UserDefaults.standard.set(newHash, forKey: asarPatchedHashKey)
                }
                // Re-sign the Codex.app to fix the broken code seal
                // The asar patch modifies sealed resources, which causes Electron
                // integrity checks to crash the app on launch.
                _resignCodexApp()
                SwapLog.append(.debug("Asar patch succeeded"))
                logger.info("Asar patch succeeded: \(String(stdout.prefix(200)))")
                return ActionResult(success: true, message: "Asar patched successfully")

            case 2:
                // Exit code 2 = no patch needed (file not found or structure changed)
                // Still store the hash so we don't re-run until the asar changes
                if let newHash = _computeAsarHash() {
                    UserDefaults.standard.set(newHash, forKey: asarPatchedHashKey)
                }
                SwapLog.append(.debug("Asar patch skipped (exit 2): \(String(combined.prefix(120)))"))
                logger.info("Asar patch not needed: \(String(combined.prefix(200)))")
                return ActionResult(success: true, message: "Asar patch not needed")

            default:
                SwapLog.append(.debug("Asar patch failed (exit \(process.terminationStatus)): \(String(combined.prefix(200)))"))
                logger.error("Asar patch failed (exit \(process.terminationStatus)): \(String(combined.prefix(300)))")
                return ActionResult(success: false, message: "patch-asar.py exited \(process.terminationStatus): \(String(combined.prefix(150)))")
            }
        } catch {
            logger.error("Failed to run patch-asar.py: \(error.localizedDescription)")
            return ActionResult(success: false, message: "Failed to run patcher: \(error.localizedDescription)")
        }
    }

    /// Disable the Electron asar integrity fuse and update Info.plist hash,
    /// then re-sign the Codex.app bundle. This is required after modifying
    /// app.asar or adding files to the bundle.
    ///
    /// Electron validates the asar via a binary fuse (EnableEmbeddedAsarIntegrityValidation)
    /// AND an Info.plist hash. Both must be handled or the app crashes with SIGTRAP on launch.
    nonisolated static func _resignCodexApp() {
        let codexApp = "/Applications/Codex.app"
        guard FileManager.default.fileExists(atPath: codexApp) else { return }

        // 1. Disable the asar integrity fuse in Electron Framework binary.
        //    Fuse sentinel: "dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX"
        //    Fuse 4 (offset sentinel+2+4) = EnableEmbeddedAsarIntegrityValidation
        //    ASCII '1' = enabled, '0' = disabled
        let electronBin = "\(codexApp)/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
        if let electronURL = URL(string: "file://\(electronBin)"),
           FileManager.default.isWritableFile(atPath: electronBin) {
            do {
                var data = try Data(contentsOf: URL(fileURLWithPath: electronBin))
                let sentinel = "dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX".data(using: .ascii)!
                if let range = data.range(of: sentinel) {
                    let fuseStart = range.upperBound.advanced(by: 2) // skip schema + count
                    let fuse4Offset = fuseStart.advanced(by: 4)
                    if fuse4Offset < data.count && data[fuse4Offset] == UInt8(ascii: "1") {
                        data[fuse4Offset] = UInt8(ascii: "0")
                        try data.write(to: URL(fileURLWithPath: electronBin))
                        logger.info("Disabled Electron asar integrity fuse")
                        SwapLog.append(.debug("Disabled Electron asar integrity fuse"))
                    }
                }
            } catch {
                logger.error("Failed to patch Electron fuse: \(error.localizedDescription)")
            }
        }

        // 2. Update the asar hash in Info.plist to match the patched asar
        let asarPath = "\(codexApp)/Contents/Resources/app.asar"
        let plistPath = "\(codexApp)/Contents/Info.plist"
        if FileManager.default.fileExists(atPath: asarPath),
           FileManager.default.fileExists(atPath: plistPath) {
            let hashProcess = Process()
            hashProcess.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
            hashProcess.arguments = ["-a", "256", asarPath]
            let hashPipe = Pipe()
            hashProcess.standardOutput = hashPipe
            hashProcess.standardError = FileHandle.nullDevice
            try? hashProcess.run()
            hashProcess.waitUntilExit()
            let hashOutput = String(data: hashPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let newHash = hashOutput.split(separator: " ").first.map(String.init) ?? ""

            if !newHash.isEmpty {
                // Use PlistBuddy to update the hash
                let buddy = Process()
                buddy.executableURL = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
                buddy.arguments = ["-c", "Set :ElectronAsarIntegrity:Resources/app.asar:hash \(newHash)", plistPath]
                buddy.standardOutput = FileHandle.nullDevice
                buddy.standardError = FileHandle.nullDevice
                try? buddy.run()
                buddy.waitUntilExit()
            }
        }

        // 3. Re-sign inner frameworks/helpers first, then the outer bundle
        let innerTargets = [
            "\(codexApp)/Contents/Frameworks/Codex Helper.app",
            "\(codexApp)/Contents/Frameworks/Codex Helper (GPU).app",
            "\(codexApp)/Contents/Frameworks/Codex Helper (Renderer).app",
            "\(codexApp)/Contents/Frameworks/Codex Helper (Plugin).app",
            "\(codexApp)/Contents/Frameworks/Electron Framework.framework",
            "\(codexApp)/Contents/Frameworks/Mantle.framework",
            "\(codexApp)/Contents/Frameworks/ReactiveObjC.framework",
            "\(codexApp)/Contents/Frameworks/Squirrel.framework",
            "\(codexApp)/Contents/Frameworks/Sparkle.framework",
        ]

        for target in innerTargets + [codexApp] {
            guard FileManager.default.fileExists(atPath: target) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--force", "--sign", "-", target]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }

        // 4. Verify
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", codexApp]
        verify.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        verify.standardError = errPipe
        try? verify.run()
        verify.waitUntilExit()
        if verify.terminationStatus == 0 {
            logger.info("Codex.app re-signed successfully")
            SwapLog.append(.debug("Codex.app re-signed successfully"))
        } else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8) ?? ""
            logger.error("Codex.app re-sign verification failed: \(err)")
            SwapLog.append(.debug("Codex.app re-sign failed: \(err)"))
        }
    }

    /// Quick install: copy existing fork binary to CLI + desktop without rebuilding from source.
    /// Used when the fork binary already exists but the desktop app was reinstalled.
    nonisolated static func _installForkBinary(version: String) -> ActionResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: forkBinaryPath) else {
            return ActionResult(success: false, message: "Fork binary not found at \(forkBinaryPath)")
        }

        let cliBinary = "\(stockBinaryDir)/codex"
        let desktopPaths = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/bin/codex",
        ]

        do {
            // CLI
            if fm.fileExists(atPath: cliBinary) {
                let cliSize = (try? fm.attributesOfItem(atPath: cliBinary))?[.size] as? Int ?? 0
                let forkSize = (try? fm.attributesOfItem(atPath: forkBinaryPath))?[.size] as? Int ?? 0
                if cliSize != forkSize {
                    try? fm.removeItem(atPath: cliBinary)
                    try fm.copyItem(atPath: forkBinaryPath, toPath: cliBinary)
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliBinary)
                }
            }

            // Desktop
            for desktopPath in desktopPaths {
                let dir = (desktopPath as NSString).deletingLastPathComponent
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? fm.removeItem(atPath: desktopPath)
                try fm.copyItem(atPath: forkBinaryPath, toPath: desktopPath)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: desktopPath)
            }
            _resignCodexApp()

            // Touch markers
            let markerDir = NSString("~/.codexswitch").expandingTildeInPath
            try? fm.createDirectory(atPath: markerDir, withIntermediateDirectories: true)
            for marker in [forkMarkerPath, sighupVerifiedExecPath, sighupVerifiedTuiPath] {
                if fm.fileExists(atPath: marker) {
                    try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: marker)
                } else {
                    fm.createFile(atPath: marker, contents: nil)
                }
            }

            logger.info("Fork binary re-installed for v\(version) (no rebuild needed)")
            SwapLog.append(.debug("Fork binary re-installed (copy only) for v\(version)"))
            return ActionResult(success: true, message: "Fork re-installed for v\(version)")
        } catch {
            return ActionResult(success: false, message: "Install failed: \(error.localizedDescription)")
        }
    }
}
