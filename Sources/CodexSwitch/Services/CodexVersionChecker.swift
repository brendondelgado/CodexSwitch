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
    private var lastCheckStarted: Date?

    private nonisolated static let versionJsonPath = NSString("~/.codex/version.json").expandingTildeInPath
    private nonisolated static let forkMarkerPath = NSString("~/.codexswitch/sighup-enabled").expandingTildeInPath
    private nonisolated static let forkSourcePath = NSString("~/Developer/codex/codex-rs").expandingTildeInPath
    private nonisolated static let forkBinaryPath = NSString("~/Developer/codex/codex-rs/target/fork-release/codex").expandingTildeInPath
    private nonisolated static let managedPatchedCodexPath = NSString("~/.local/share/codexswitch/patched-codex/codex").expandingTildeInPath
    private nonisolated static let preparedCodexRootPath = NSString("~/.local/share/codexswitch/prepared-codex").expandingTildeInPath
    private nonisolated static let syncedClientPath = NSString("~/.local/share/codexswitch/remote-client/node_modules/.bin/codex").expandingTildeInPath
    private nonisolated static let localLauncherPath = NSString("~/.local/bin/codex").expandingTildeInPath
    private nonisolated static let stockBinaryDir = "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex"
    private nonisolated static let stockBinaryPath = "\(stockBinaryDir)/codex"
    private nonisolated static let homebrewCodexPath = "/opt/homebrew/bin/codex"
    private nonisolated static let homebrewNpmEntryPath = "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"
    private nonisolated static let desktopAppNativePath = "/Applications/Codex.app/Contents/Resources/codex"
    private nonisolated static let cliRepairCooldownPath = NSString("~/.codexswitch/cli-repair-last-attempt").expandingTildeInPath
    private nonisolated static let cliRepairCooldownSeconds: TimeInterval = 10 * 60

    struct CodexUpdateTarget: Sendable, Equatable {
        let version: String
        let npmSpecifier: String
    }

    struct CodexCLIRepairResult: Sendable, Equatable {
        let attempted: Bool
        let success: Bool
        let message: String
    }

    struct CodexCLIHealth: Sendable, Equatable {
        let healthy: Bool
        let version: String?
        let timedOut: Bool
        let terminationStatus: Int32
    }

    private struct SemanticVersion: Equatable {
        let major: Int
        let minor: Int
        let patch: Int
        let prerelease: String?
    }

    func checkVersions(force: Bool = false) {
        if isChecking {
            return
        }
        let now = Date()
        if !force, let lastCheckStarted, now.timeIntervalSince(lastCheckStarted) < 60 {
            return
        }
        lastCheckStarted = now
        isChecking = true
        updateResult = nil

        Task.detached {
            _ = Self.repairBrokenGlobalCLIIfNeeded()
            let installed = Self._getInstalledVersion()
            let latest = Self._getLatestVersion()
            let hasFork = FileManager.default.fileExists(atPath: Self.forkMarkerPath)
            let finishedAt = Date()

            await MainActor.run { [weak self] in
                self?.installedVersion = installed
                self?.latestVersion = latest
                self?.lastChecked = finishedAt
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
            let updateTarget = Self._getPreferredUpdateTarget()

            // Step 1: npm update
            let npmResult = Self._performNpmUpdate(target: updateTarget)
            guard npmResult.success else {
                await MainActor.run { [weak self] in
                    self?.isUpdating = false
                    self?.updateSucceeded = false
                    self?.updateResult = npmResult.message
                }
                return
            }

            let newNpmVersion = updateTarget?.version ?? Self._getNpmPackageVersion()

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
        installedHotSwapVersion(
            preparedRootPath: preparedCodexRootPath,
            managedPatchedCodexPath: managedPatchedCodexPath,
            forkBinaryPath: forkBinaryPath
        ) ?? "?"
    }

    nonisolated static func shouldRepairGlobalCLI(packageVersion: String, health: CodexCLIHealth) -> Bool {
        isPrereleaseVersion(packageVersion) || !health.healthy
    }

    @discardableResult
    nonisolated static func repairBrokenGlobalCLIIfNeeded(force: Bool = false) -> CodexCLIRepairResult {
        if let launcherResult = repairSighupLauncherIfAvailable(force: force),
           launcherResult.success || launcherResult.attempted {
            return launcherResult
        }

        let packageVersion = _getNpmPackageVersion()

        // If the installed package is prerelease, do not execute it just to prove
        // it is broken; this is the class of binary that previously triggered
        // macOS SIGKILL/UE hangs before `--version` could return.
        let health = isPrereleaseVersion(packageVersion)
            ? CodexCLIHealth(healthy: false, version: nil, timedOut: false, terminationStatus: -2)
            : _codexCLIHealth(at: homebrewCodexPath)

        guard shouldRepairGlobalCLI(packageVersion: packageVersion, health: health) else {
            return CodexCLIRepairResult(attempted: false, success: true, message: "Global Codex CLI is healthy")
        }
        guard force || cliRepairCooldownExpired() else {
            return CodexCLIRepairResult(attempted: false, success: false, message: "Global Codex CLI repair is in cooldown")
        }
        markCLIRepairAttempt()

        guard let target = _getPreferredUpdateTarget() else {
            return CodexCLIRepairResult(attempted: true, success: false, message: "No stable Codex npm target available for repair")
        }

        let result = _performNpmUpdate(target: target, allowRollback: false)
        if result.success {
            return CodexCLIRepairResult(attempted: true, success: true, message: "Repaired global Codex CLI with \(target.npmSpecifier)")
        }
        return CodexCLIRepairResult(attempted: true, success: false, message: result.message)
    }

    nonisolated static func launcherScript(
        syncedClientPath: String = syncedClientPath,
        managedPatchedCodexPath: String = managedPatchedCodexPath,
        forkBinaryPath: String,
        homebrewCodexPath: String = homebrewCodexPath,
        desktopAppNativePath: String = desktopAppNativePath
    ) -> String {
        """
        #!/bin/bash
        set -euo pipefail
        SYNCED_CODEX=\(shellSingleQuoted(syncedClientPath))
        PATCHED_CODEX=\(shellSingleQuoted(managedPatchedCodexPath))
        SIGHUP_FORK=\(shellSingleQuoted(forkBinaryPath))
        BREW_NATIVE=\(shellSingleQuoted(homebrewCodexPath))
        DESKTOP_APP_NATIVE=\(shellSingleQuoted(desktopAppNativePath))

        can_run() {
          local candidate="$1"
          [[ -x "$candidate" ]] || return 1
          "$candidate" --version >/dev/null 2>&1
        }

        codex_version_base() {
          local candidate="$1"
          "$candidate" --version 2>/dev/null | /usr/bin/awk '
            {
              for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+\\.[0-9]+\\.[0-9]+/) {
                  sub(/-.*/, "", $i)
                  print $i
                  exit
                }
              }
            }
          '
        }

        version_at_least_0128() {
          local version major minor patch
          version="$(codex_version_base "$1")"
          IFS=. read -r major minor patch <<< "$version"
          [[ "${major:-0}" =~ ^[0-9]+$ && "${minor:-0}" =~ ^[0-9]+$ && "${patch:-0}" =~ ^[0-9]+$ ]] || return 1
          (( major > 0 || minor > 128 || (minor == 128 && patch >= 0) ))
        }

        can_run_goal_capable() {
          local candidate="$1"
          can_run "$candidate" && version_at_least_0128 "$candidate"
        }

        has_sighup_patch() {
          local candidate="$1"
          [[ -r "$candidate" ]] || return 1
          /usr/bin/strings "$candidate" 2>/dev/null | /usr/bin/awk '
            /sighup-verified/ { has_marker = 1 }
            /SIGHUP: auth reloaded/ { has_reload = 1 }
            /hotswap-ack/ { has_ack = 1 }
            /CodexSwitch rotated accounts after a usage limit/ { has_usage_retry = 1 }
            /Auth changed, opening new WebSocket with fresh credentials/ { has_auth_ws = 1 }
            END { exit !(has_marker && has_reload && has_ack && has_usage_retry && has_auth_ws) }
          '
        }

        has_goal_support() {
          local candidate="$1"
          [[ -r "$candidate" ]] || return 1
          /usr/bin/strings "$candidate" 2>/dev/null | /usr/bin/awk '
            /Usage: \\/goal <objective>/ { has_goal_usage = 1 }
            /Pursuing goal/ { has_goal_status = 1 }
            /thread\\/goal\\/set/ { has_goal_rpc = 1 }
            END { exit !(has_goal_usage || (has_goal_status && has_goal_rpc)) }
          '
        }

        args_request_remote() {
          for arg in "$@"; do
            [[ "$arg" == "--remote" || "$arg" == --remote=* ]] && return 0
          done
          return 1
        }

        if args_request_remote "$@" && can_run_goal_capable "$SYNCED_CODEX"; then
          exec "$SYNCED_CODEX" "$@"
        fi

        if can_run_goal_capable "$PATCHED_CODEX" && has_sighup_patch "$PATCHED_CODEX" && has_goal_support "$PATCHED_CODEX"; then
          exec "$PATCHED_CODEX" -c 'plugins."computer-use@openai-bundled".enabled=false' "$@"
        fi

        if can_run_goal_capable "$SIGHUP_FORK" && has_sighup_patch "$SIGHUP_FORK" && has_goal_support "$SIGHUP_FORK"; then
          exec "$SIGHUP_FORK" -c 'plugins."computer-use@openai-bundled".enabled=false' "$@"
        fi

        if [[ -n "${CODEX_CLI_PATH:-}" && "${CODEX_CLI_PATH}" != "$0" ]] \
          && can_run_goal_capable "${CODEX_CLI_PATH}"; then
          exec "${CODEX_CLI_PATH}" "$@"
        fi

        if can_run_goal_capable "$SYNCED_CODEX"; then
          exec "$SYNCED_CODEX" "$@"
        fi

        if can_run_goal_capable "$BREW_NATIVE"; then
          exec "$BREW_NATIVE" "$@"
        fi

        if can_run_goal_capable "$DESKTOP_APP_NATIVE"; then
          exec "$DESKTOP_APP_NATIVE" "$@"
        fi

        echo "codex: no working goal-capable native binary found" >&2
        exit 1
        """
    }

    nonisolated static func homebrewBridgeScript(
        syncedClientPath: String = syncedClientPath,
        managedPatchedCodexPath: String = managedPatchedCodexPath,
        forkBinaryPath: String,
        originalEntryPath: String = homebrewNpmEntryPath,
        desktopAppNativePath: String = desktopAppNativePath
    ) -> String {
        """
        #!/bin/bash
        set -u
        SYNCED_CODEX=\(shellSingleQuoted(syncedClientPath))
        PATCHED_CODEX=\(shellSingleQuoted(managedPatchedCodexPath))
        SIGHUP_FORK=\(shellSingleQuoted(forkBinaryPath))
        ORIGINAL_NODE_ENTRY=\(shellSingleQuoted(originalEntryPath))
        DESKTOP_APP_NATIVE=\(shellSingleQuoted(desktopAppNativePath))

        can_run() {
          local candidate="$1"
          [[ -x "$candidate" ]] || return 1
          "$candidate" --version >/dev/null 2>&1
        }

        codex_version_base() {
          local candidate="$1"
          "$candidate" --version 2>/dev/null | /usr/bin/awk '
            {
              for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+\\.[0-9]+\\.[0-9]+/) {
                  sub(/-.*/, "", $i)
                  print $i
                  exit
                }
              }
            }
          '
        }

        version_at_least_0128() {
          local version major minor patch
          version="$(codex_version_base "$1")"
          IFS=. read -r major minor patch <<< "$version"
          [[ "${major:-0}" =~ ^[0-9]+$ && "${minor:-0}" =~ ^[0-9]+$ && "${patch:-0}" =~ ^[0-9]+$ ]] || return 1
          (( major > 0 || minor > 128 || (minor == 128 && patch >= 0) ))
        }

        can_run_goal_capable() {
          local candidate="$1"
          can_run "$candidate" && version_at_least_0128 "$candidate"
        }

        has_sighup_patch() {
          local candidate="$1"
          [[ -r "$candidate" ]] || return 1
          /usr/bin/strings "$candidate" 2>/dev/null | /usr/bin/awk '
            /sighup-verified/ { has_marker = 1 }
            /SIGHUP: auth reloaded/ { has_reload = 1 }
            /hotswap-ack/ { has_ack = 1 }
            /CodexSwitch rotated accounts after a usage limit/ { has_usage_retry = 1 }
            /Auth changed, opening new WebSocket with fresh credentials/ { has_auth_ws = 1 }
            END { exit !(has_marker && has_reload && has_ack && has_usage_retry && has_auth_ws) }
          '
        }

        has_goal_support() {
          local candidate="$1"
          [[ -r "$candidate" ]] || return 1
          /usr/bin/strings "$candidate" 2>/dev/null | /usr/bin/awk '
            /Usage: \\/goal <objective>/ { has_goal_usage = 1 }
            /Pursuing goal/ { has_goal_status = 1 }
            /thread\\/goal\\/set/ { has_goal_rpc = 1 }
            END { exit !(has_goal_usage || (has_goal_status && has_goal_rpc)) }
          '
        }

        args_request_remote() {
          for arg in "$@"; do
            [[ "$arg" == "--remote" || "$arg" == --remote=* ]] && return 0
          done
          return 1
        }

        if args_request_remote "$@" && can_run_goal_capable "$SYNCED_CODEX"; then
          exec "$SYNCED_CODEX" "$@"
        fi

        if can_run_goal_capable "$PATCHED_CODEX" && has_sighup_patch "$PATCHED_CODEX" && has_goal_support "$PATCHED_CODEX"; then
          exec "$PATCHED_CODEX" -c 'plugins."computer-use@openai-bundled".enabled=false' "$@"
        fi

        if can_run_goal_capable "$SIGHUP_FORK" && has_sighup_patch "$SIGHUP_FORK" && has_goal_support "$SIGHUP_FORK"; then
          exec "$SIGHUP_FORK" -c 'plugins."computer-use@openai-bundled".enabled=false' "$@"
        fi

        if can_run_goal_capable "$SYNCED_CODEX"; then
          exec "$SYNCED_CODEX" "$@"
        fi

        if [[ -x "$ORIGINAL_NODE_ENTRY" ]] && can_run_goal_capable "$ORIGINAL_NODE_ENTRY"; then
          exec "$ORIGINAL_NODE_ENTRY" "$@"
        fi

        echo "codex: no working goal-capable Homebrew Codex entry found" >&2
        exit 1
        """
    }

    nonisolated static func binaryHasSighupSupportData(_ data: Data) -> Bool {
        data.range(of: Data("sighup-verified".utf8)) != nil
            && data.range(of: Data("SIGHUP: auth reloaded".utf8)) != nil
            && data.range(of: Data("hotswap-ack".utf8)) != nil
            && data.range(of: Data("CodexSwitch rotated accounts after a usage limit".utf8)) != nil
            && data.range(of: Data("Auth changed, opening new WebSocket with fresh credentials".utf8)) != nil
    }

    nonisolated static func binaryHasGoalSupportData(_ data: Data) -> Bool {
        data.range(of: Data("Usage: /goal <objective>".utf8)) != nil
            || (
                data.range(of: Data("Pursuing goal".utf8)) != nil
                    && data.range(of: Data("thread/goal/set".utf8)) != nil
            )
    }

    private nonisolated static func repairSighupLauncherIfAvailable(force: Bool) -> CodexCLIRepairResult? {
        let preferredHotSwapBinary = preferredHotSwapBinaryPath()
        let health = preferredHotSwapBinary.map { _codexCLIHealth(at: $0) }
        if let health, !health.healthy {
            return CodexCLIRepairResult(
                attempted: true,
                success: false,
                message: "SIGHUP fork exists but failed launch health check"
            )
        }

        let launcherHotSwapPath = preferredHotSwapBinary ?? managedPatchedCodexPath
        let desired = launcherScript(
            managedPatchedCodexPath: launcherHotSwapPath,
            forkBinaryPath: forkBinaryPath
        )
        let desiredHomebrewBridge = homebrewBridgeScript(
            managedPatchedCodexPath: launcherHotSwapPath,
            forkBinaryPath: forkBinaryPath
        )
        let desiredLaunchctlPath: String
        if let preferredHotSwapBinary,
           FileManager.default.isExecutableFile(atPath: preferredHotSwapBinary) {
            desiredLaunchctlPath = preferredHotSwapBinary
        } else if FileManager.default.isExecutableFile(atPath: syncedClientPath) {
            desiredLaunchctlPath = syncedClientPath
        } else if FileManager.default.isExecutableFile(atPath: desktopAppNativePath) {
            desiredLaunchctlPath = desktopAppNativePath
        } else {
            desiredLaunchctlPath = forkBinaryPath
        }
        let current = (try? String(contentsOfFile: localLauncherPath, encoding: .utf8)) ?? ""
        let currentHomebrewBridge = (try? String(contentsOfFile: homebrewCodexPath, encoding: .utf8)) ?? ""
        let envCurrent = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["getenv", "CODEX_CLI_PATH"],
            timeout: 2
        ).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard force || current != desired || currentHomebrewBridge != desiredHomebrewBridge || envCurrent != desiredLaunchctlPath else {
            return CodexCLIRepairResult(
                attempted: false,
                success: true,
                message: "Codex launchers already route CLI to synced Codex and desktop to bundled Codex"
            )
        }

        do {
            let launcherURL = URL(fileURLWithPath: localLauncherPath)
            try FileManager.default.createDirectory(
                at: launcherURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try desired.write(to: launcherURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localLauncherPath)

            if FileManager.default.fileExists(atPath: homebrewCodexPath) {
                try FileManager.default.removeItem(atPath: homebrewCodexPath)
            }
            try desiredHomebrewBridge.write(
                to: URL(fileURLWithPath: homebrewCodexPath),
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: homebrewCodexPath)
        } catch {
            return CodexCLIRepairResult(
                attempted: true,
                success: false,
                message: "Failed to repair Codex launchers: \(error.localizedDescription)"
            )
        }

        _ = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["setenv", "CODEX_CLI_PATH", desiredLaunchctlPath],
            timeout: 3
        )
        SwapLog.append(.debug("CODEX_CLI_LAUNCHER_REPAIRED synced=\(syncedClientPath) hotswap=\(launcherHotSwapPath) fork=\(forkBinaryPath) version=\(health?.version ?? "unknown") homebrew_bridge=\(homebrewCodexPath) launchctl=\(desiredLaunchctlPath)"))
        return CodexCLIRepairResult(
            attempted: true,
            success: true,
            message: "Codex launchers route CLI to patched Codex and desktop to bundled Codex"
        )
    }

    private nonisolated static func preferredHotSwapBinaryPath() -> String? {
        let candidates = [
            latestPreparedHotSwapBinaryPath(),
            managedPatchedCodexPath,
            forkBinaryPath
        ].compactMap { $0 }

        for path in candidates {
            guard completeHotSwapBinaryIsLaunchable(at: path) else {
                continue
            }
            return path
        }
        if FileManager.default.fileExists(atPath: forkMarkerPath) {
            return nil
        }
        return nil
    }

    nonisolated static func latestPreparedHotSwapBinaryPath(
        rootPath: String = preparedCodexRootPath
    ) -> String? {
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: rootPath) else {
            return nil
        }

        return versions
            .filter { parseSemanticVersion($0) != nil }
            .sorted { compareSemanticVersions($0, $1) == .orderedDescending }
            .map { "\(rootPath)/\($0)/codex" }
            .first { completeHotSwapBinaryIsLaunchable(at: $0) }
    }

    nonisolated static func installedHotSwapVersion(
        preparedRootPath: String = preparedCodexRootPath,
        managedPatchedCodexPath: String = managedPatchedCodexPath,
        forkBinaryPath: String = forkBinaryPath
    ) -> String? {
        let candidates = [
            latestPreparedHotSwapBinaryPath(rootPath: preparedRootPath),
            managedPatchedCodexPath,
            forkBinaryPath
        ].compactMap { $0 }

        for path in candidates where completeHotSwapBinaryIsLaunchable(at: path) {
            let health = _codexCLIHealth(at: path)
            if let version = health.version, !version.isEmpty {
                return version
            }
        }
        return nil
    }

    private nonisolated static func completeHotSwapBinaryIsLaunchable(at path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              binaryHasSighupSupportData(data),
              binaryHasGoalSupportData(data) else {
            return false
        }
        return _codexCLIHealth(at: path).healthy
    }

    private nonisolated static func _codexCLIHealth(at path: String) -> CodexCLIHealth {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return CodexCLIHealth(healthy: false, version: nil, timedOut: false, terminationStatus: -1)
        }
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: path),
            arguments: ["--version"],
            timeout: 3
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return CodexCLIHealth(
                healthy: false,
                version: nil,
                timedOut: result.timedOut,
                terminationStatus: result.terminationStatus
            )
        }
        let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = output.replacingOccurrences(of: "codex-cli ", with: "")
        return CodexCLIHealth(healthy: !version.isEmpty, version: version, timedOut: false, terminationStatus: 0)
    }

    private nonisolated static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
        if let target = _getPreferredUpdateTarget() {
            return target.version
        }

        // Fall back to ~/.codex/version.json if npm dist-tags are unavailable.
        if let data = try? Data(contentsOf: URL(fileURLWithPath: versionJsonPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let latest = json["latest_version"] as? String {
            return latest
        }

        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/npm"),
            arguments: ["view", "@openai/codex", "version"],
            timeout: 8
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return "?"
        }
        let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "?" : output
    }

    private nonisolated static func _getPreferredUpdateTarget() -> CodexUpdateTarget? {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/npm"),
            arguments: ["view", "@openai/codex", "dist-tags", "--json"],
            timeout: 8
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return nil
        }
        let data = Data(result.stdoutString.utf8)
        guard let tags = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return preferredUpdateTarget(distTags: tags)
    }

    nonisolated static func preferredUpdateTarget(distTags: [String: String]) -> CodexUpdateTarget? {
        // Only install the stable npm channel automatically. Alpha/prerelease native
        // binaries can be valid npm packages while still being killed by macOS at
        // launch, which breaks every downstream tool that shells out to `codex`.
        guard let latest = distTags["latest"],
              !isPrereleaseVersion(latest) else {
            return nil
        }
        return CodexUpdateTarget(version: latest, npmSpecifier: "@openai/codex@latest")
    }

    private struct ActionResult {
        let success: Bool
        let message: String
    }

    private nonisolated static func _performNpmUpdate(
        target: CodexUpdateTarget?,
        allowRollback: Bool = true
    ) -> ActionResult {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let npmSpecifier = target?.npmSpecifier ?? "@openai/codex@latest"
        let previousVersion = _getNpmPackageVersion()

        let result = _npmInstallCodex(specifier: npmSpecifier, environment: env)
        if result.timedOut {
            return ActionResult(success: false, message: "npm update timed out")
        }
        guard result.terminationStatus == 0 else {
            return ActionResult(
                success: false,
                message: "npm update failed: \(String(result.stderrString.prefix(200)))"
            )
        }

        let health = _codexCLIHealth(at: homebrewCodexPath)
        guard health.healthy else {
            if allowRollback, !previousVersion.isEmpty, previousVersion != "?", !isPrereleaseVersion(previousVersion) {
                _ = _npmInstallCodex(specifier: "@openai/codex@\(previousVersion)", environment: env)
            }
            return ActionResult(
                success: false,
                message: "npm update produced an unusable Codex CLI (status=\(health.terminationStatus), timedOut=\(health.timedOut)); rolled back if a stable previous version was available"
            )
        }
        return ActionResult(success: true, message: "npm update succeeded and Codex CLI passed launch health check")
    }

    private nonisolated static func _npmInstallCodex(
        specifier: String,
        environment: [String: String]
    ) -> ProcessRunResult {
        ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/npm"),
            arguments: ["install", "-g", specifier],
            timeout: 600,
            environment: environment
        )
    }

    nonisolated static func replacingWorkspaceVersion(in content: String, with version: String) -> String? {
        guard let range = content.range(
            of: #"version = "\d+\.\d+\.\d+(?:-[^"]+)?""#,
            options: .regularExpression
        ) else {
            return nil
        }
        var updated = content
        updated.replaceSubrange(range, with: "version = \"\(version)\"")
        return updated
    }

    private nonisolated static func compareSemanticVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let left = parseSemanticVersion(lhs), let right = parseSemanticVersion(rhs) else {
            return lhs.compare(rhs, options: .numeric)
        }

        for pair in [(left.major, right.major), (left.minor, right.minor), (left.patch, right.patch)] {
            if pair.0 < pair.1 { return .orderedAscending }
            if pair.0 > pair.1 { return .orderedDescending }
        }

        switch (left.prerelease, right.prerelease) {
        case (nil, nil):
            return .orderedSame
        case (nil, _?):
            return .orderedDescending
        case (_?, nil):
            return .orderedAscending
        case let (leftPre?, rightPre?):
            return comparePrerelease(leftPre, rightPre)
        }
    }


    private nonisolated static func isPrereleaseVersion(_ version: String) -> Bool {
        parseSemanticVersion(version)?.prerelease != nil
    }

    private nonisolated static func cliRepairCooldownExpired(now: Date = Date()) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cliRepairCooldownPath),
              let modified = attrs[.modificationDate] as? Date else {
            return true
        }
        return now.timeIntervalSince(modified) >= cliRepairCooldownSeconds
    }

    private nonisolated static func markCLIRepairAttempt() {
        let path = URL(fileURLWithPath: cliRepairCooldownPath)
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path.path, contents: Data())
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
    }

    private nonisolated static func parseSemanticVersion(_ version: String) -> SemanticVersion? {
        let pattern = /^(\d+)\.(\d+)\.(\d+)(?:-([A-Za-z0-9.-]+))?$/
        guard let match = version.firstMatch(of: pattern) else { return nil }
        return SemanticVersion(
            major: Int(match.output.1) ?? 0,
            minor: Int(match.output.2) ?? 0,
            patch: Int(match.output.3) ?? 0,
            prerelease: match.output.4.map(String.init)
        )
    }

    private nonisolated static func comparePrerelease(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let leftParts = lhs.split(separator: ".").map(String.init)
        let rightParts = rhs.split(separator: ".").map(String.init)
        let count = max(leftParts.count, rightParts.count)

        for index in 0..<count {
            guard index < leftParts.count else { return .orderedAscending }
            guard index < rightParts.count else { return .orderedDescending }

            let left = leftParts[index]
            let right = rightParts[index]
            if let leftNumber = Int(left), let rightNumber = Int(right) {
                if leftNumber < rightNumber { return .orderedAscending }
                if leftNumber > rightNumber { return .orderedDescending }
            } else {
                let comparison = left.compare(right, options: .numeric)
                if comparison != .orderedSame { return comparison }
            }
        }
        return .orderedSame
    }

    private nonisolated static func _forkWorktreeIsClean() -> Bool {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", forkSourcePath, "status", "--porcelain"],
            timeout: 5
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return false
        }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Rebuild the SIGHUP fork binary against the current source with the given version.
    ///
    /// This intentionally does not install the rebuilt binary over the global
    /// Homebrew/npm Codex executable. A bad native binary there breaks Codex.app,
    /// Codex CLI, no-mistakes, and every subprocess that expects `codex` to launch.
    private nonisolated static func _rebuildFork(version: String) -> ActionResult {
        let cargoTomlPath = "\(forkSourcePath)/Cargo.toml"

        // Step 1: Only rebase a clean fork. The SIGHUP fork often has local patches,
        // and clobbering them would remove the hot-swap support CodexSwitch depends on.
        if _forkWorktreeIsClean() {
            _ = ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", forkSourcePath, "pull", "--rebase"],
                timeout: 120
            )
        } else {
            logger.info("Skipping fork rebase because codex-rs worktree has local changes")
        }

        // Step 2: Update version in workspace Cargo.toml (after any safe pull so it persists)
        do {
            let content = try String(contentsOfFile: cargoTomlPath, encoding: .utf8)
            guard let updated = replacingWorkspaceVersion(in: content, with: version) else {
                return ActionResult(success: false, message: "Failed to find workspace package version in Cargo.toml")
            }
            try updated.write(toFile: cargoTomlPath, atomically: true, encoding: .utf8)
        } catch {
            return ActionResult(success: false, message: "Failed to update Cargo.toml: \(error.localizedDescription)")
        }

        // Step 3: Rebuild
        var env = ProcessInfo.processInfo.environment
        let cargoDir = NSString("~/.cargo/bin").expandingTildeInPath
        env["PATH"] = "\(cargoDir):/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        let buildResult = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: NSString("~/.cargo/bin/cargo").expandingTildeInPath),
            arguments: ["build", "--release", "-p", "codex-cli"],
            timeout: 1800,
            environment: env,
            currentDirectoryURL: URL(fileURLWithPath: forkSourcePath)
        )

        if buildResult.timedOut {
            return ActionResult(success: false, message: "Cargo build timed out")
        }
        guard buildResult.terminationStatus == 0 else {
            return ActionResult(
                success: false,
                message: "Cargo build failed: \(String(buildResult.stderrString.suffix(300)))"
            )
        }

        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: forkBinaryPath)

            let markerPath = forkMarkerPath
            if FileManager.default.fileExists(atPath: markerPath) {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: markerPath
                )
            }

            logger.info("Fork binary rebuilt for v\(version); global CLI install intentionally unchanged")
            SwapLog.append(.debug("SIGHUP_FORK_REBUILT_NOT_INSTALLED version=\(version)"))
            return ActionResult(
                success: true,
                message: "Fork rebuilt for v\(version); global Codex CLI left unchanged for safety"
            )
        } catch {
            return ActionResult(success: false, message: "Fork validation failed: \(error.localizedDescription)")
        }
    }
}
