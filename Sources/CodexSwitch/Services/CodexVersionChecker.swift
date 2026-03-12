import Foundation
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "VersionChecker")

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

    private nonisolated static let versionJsonPath = NSString("~/.codex/version.json").expandingTildeInPath
    private nonisolated static let forkMarkerPath = NSString("~/.codexswitch/sighup-enabled").expandingTildeInPath
    private nonisolated static let forkSourcePath = NSString("~/Developer/codex/codex-rs").expandingTildeInPath
    private nonisolated static let forkBinaryPath = NSString("~/Developer/codex/codex-rs/target/release/codex").expandingTildeInPath
    private nonisolated static let stockBinaryDir = "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex"

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
                    self?.updateResult = "Updated npm package. Rebuilding SIGHUP fork (this takes a few minutes)..."
                }

                let forkResult = Self._rebuildFork(version: newNpmVersion)

                let installed = Self._getInstalledVersion()
                let latest = Self._getLatestVersion()

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

    // MARK: - Private (nonisolated for background execution)

    private nonisolated static func _getInstalledVersion() -> String {
        // Read version from the binary directly
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

    private struct ActionResult {
        let success: Bool
        let message: String
    }

    private nonisolated static func _performNpmUpdate() -> ActionResult {
        let errPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/npm")
        process.arguments = ["install", "-g", "@openai/codex@latest"]
        process.standardOutput = FileHandle.nullDevice  // stdout unused — discard to avoid pipe deadlock
        process.standardError = errPipe
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        do {
            try process.run()
            // Read pipes before waitUntilExit to avoid deadlock
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

    /// Rebuild the SIGHUP fork binary against the current source with the given version.
    private nonisolated static func _rebuildFork(version: String) -> ActionResult {
        let cargoTomlPath = "\(forkSourcePath)/Cargo.toml"

        // Step 1: git pull FIRST so Cargo.toml version update isn't clobbered by rebase
        let pullProcess = Process()
        pullProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        pullProcess.arguments = ["-C", forkSourcePath, "pull", "--rebase"]
        pullProcess.standardOutput = FileHandle.nullDevice  // discard to avoid pipe deadlock
        pullProcess.standardError = FileHandle.nullDevice
        try? pullProcess.run()
        pullProcess.waitUntilExit()

        // Step 2: Update version in workspace Cargo.toml (after pull so it persists)
        do {
            var content = try String(contentsOfFile: cargoTomlPath, encoding: .utf8)
            // Replace version line in [workspace.package]
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
        buildProcess.executableURL = URL(fileURLWithPath: NSString("~/.cargo/bin/cargo").expandingTildeInPath)
        buildProcess.arguments = ["build", "--release", "-p", "codex-cli"]
        buildProcess.currentDirectoryURL = URL(fileURLWithPath: forkSourcePath)
        buildProcess.standardOutput = FileHandle.nullDevice
        buildProcess.standardError = buildErrPipe
        var env = ProcessInfo.processInfo.environment
        let cargoDir = NSString("~/.cargo/bin").expandingTildeInPath
        env["PATH"] = "\(cargoDir):/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        buildProcess.environment = env

        do {
            try buildProcess.run()
            // Read pipe before waitUntilExit to avoid deadlock
            let errData = buildErrPipe.fileHandleForReading.readDataToEndOfFile()
            buildProcess.waitUntilExit()

            guard buildProcess.terminationStatus == 0 else {
                let errStr = String(data: errData, encoding: .utf8) ?? "Unknown"
                return ActionResult(success: false, message: "Cargo build failed: \(String(errStr.suffix(300)))")
            }
        } catch {
            return ActionResult(success: false, message: "Failed to start cargo: \(error.localizedDescription)")
        }

        // Step 4: Copy fork binary over stock binary
        let targetBinary = "\(stockBinaryDir)/codex"
        let stockBackup = "\(stockBinaryDir)/codex.stock-v\(version)"

        do {
            // Backup the stock binary if not already backed up
            if !FileManager.default.fileExists(atPath: stockBackup) {
                try FileManager.default.copyItem(atPath: targetBinary, toPath: stockBackup)
            }

            // Copy fork binary
            try FileManager.default.removeItem(atPath: targetBinary)
            try FileManager.default.copyItem(atPath: forkBinaryPath, toPath: targetBinary)

            // Ensure executable
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetBinary)

            // Update marker file timestamp
            let markerPath = forkMarkerPath
            if FileManager.default.fileExists(atPath: markerPath) {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: markerPath
                )
            }

            logger.info("Fork binary installed for v\(version)")
            SwapLog.append(.cliStatusChanged(from: "stock-\(version)", to: "fork-\(version)"))
            return ActionResult(success: true, message: "Fork rebuilt and installed for v\(version)")
        } catch {
            return ActionResult(success: false, message: "Binary copy failed: \(error.localizedDescription)")
        }
    }
}
