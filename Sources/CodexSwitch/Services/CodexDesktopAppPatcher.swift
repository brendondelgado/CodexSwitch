import AppKit
import Foundation
import os

private let desktopPatchLogger = Logger(
    subsystem: "com.codexswitch",
    category: "DesktopAppPatcher"
)

struct CodexDesktopAppInstall: Equatable, Sendable {
    let appPath: String
    let asarPath: String
    let bundleVersion: String
    let shortVersion: String

    var versionLabel: String {
        "\(shortVersion) (\(bundleVersion))"
    }
}

struct CodexDesktopPatchedAppState: Codable, Equatable, Sendable {
    let bundleVersion: String
    let asarPath: String
}

enum CodexDesktopAppUsageState: Equatable, Sendable {
    case notRunning
    case backgroundServiceOnly
    case appRunning

    var runtimeLabel: String {
        switch self {
        case .notRunning:
            return "Codex desktop app is not running"
        case .backgroundServiceOnly:
            return "Detached Codex app-server is running"
        case .appRunning:
            return "Codex desktop app is running"
        }
    }
}

struct CodexDesktopAppStatusSummary: Sendable {
    let installedVersionLabel: String
    let runtimeLabel: String
    let patchLabel: String
    let patchHealthy: Bool
    let canPatchNow: Bool
}

struct CodexDesktopAppInspection: Sendable {
    let install: CodexDesktopAppInstall
    let savedState: CodexDesktopPatchedAppState?
    let patchMarkerPresent: Bool
    let legacyPatchMarkerPresent: Bool
    let usageState: CodexDesktopAppUsageState
    let bundleIsValid: Bool
    let signatureStatus: CodexDesktopAppSignatureStatus
    let decision: CodexDesktopAppPatchRepairDecision
}

enum CodexDesktopAppPatchStateStore {
    private static let statePath = NSString("~/.codexswitch/patched-desktop-app.json")
        .expandingTildeInPath

    static func load() -> CodexDesktopPatchedAppState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)) else {
            return nil
        }

        return try? JSONDecoder().decode(CodexDesktopPatchedAppState.self, from: data)
    }

    static func save(_ state: CodexDesktopPatchedAppState) throws {
        let parent = URL(fileURLWithPath: statePath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }
}

enum CodexDesktopAppPatchRepairDecision: Equatable, Sendable {
    case noRepairNeeded
    case deferWhileRunning
    case repairNeeded
}

enum CodexDesktopAppSignatureStatus: Equatable, Sendable {
    case officialOpenAI
    case adHoc
    case nonOpenAISigned
    case unreadable
}

enum CodexDesktopAppPatchRepairDecider {
    static func decision(
        currentInstall: CodexDesktopAppInstall,
        savedState: CodexDesktopPatchedAppState?,
        patchMarkerPresent: Bool,
        legacyPatchMarkerPresent: Bool,
        usageState: CodexDesktopAppUsageState,
        bundleIsValid: Bool,
        signatureStatus: CodexDesktopAppSignatureStatus
    ) -> CodexDesktopAppPatchRepairDecision {
        let savedStateMatches = savedState?.bundleVersion == currentInstall.bundleVersion
            && savedState?.asarPath == currentInstall.asarPath

        if bundleIsValid,
           patchMarkerPresent,
           !legacyPatchMarkerPresent,
           savedStateMatches,
           signatureStatus == .adHoc {
            return .noRepairNeeded
        }

        if usageState == .appRunning {
            return .deferWhileRunning
        }

        return .repairNeeded
    }
}

enum CodexDesktopAppProcessClassifier {
    static func usageState(
        appPath: String,
        processCommands: [String]? = nil
    ) -> CodexDesktopAppUsageState {
        let commands = processCommands ?? runningCommands(appPath: appPath)
        let appContentsPrefix = "\(appPath)/Contents/"
        let relevantCommands = commands.filter { $0.contains(appContentsPrefix) }

        guard !relevantCommands.isEmpty else {
            return .notRunning
        }

        let isBackgroundOnly = relevantCommands.allSatisfy {
            $0.contains("\(appPath)/Contents/Resources/codex app-server")
        }
        if isBackgroundOnly {
            return .backgroundServiceOnly
        }

        return .appRunning
    }

    static func runningCommands(appPath: String) -> [String] {
        guard let output = ProcessRunner.run(
            executablePath: "/usr/bin/pgrep",
            arguments: ["-af", "\(appPath)/Contents"],
            timeout: 1.5
        ) else {
            return []
        }
        guard !output.timedOut, output.terminationStatus == 0 else {
            return []
        }

        return output.stdout
            .split(separator: "\n")
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let splitIndex = trimmed.firstIndex(of: " ") else {
                    return trimmed
                }
                return trimmed[trimmed.index(after: splitIndex)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    static func stopDetachedAppServer(appPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "\(appPath)/Contents/Resources/codex app-server"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        // pkill returns 1 when the process already exited between inspection and shutdown.
        if process.terminationStatus != 0 && process.terminationStatus != 1 {
            return false
        }

        for _ in 0..<20 {
            if usageState(appPath: appPath) != .backgroundServiceOnly {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        return usageState(appPath: appPath) != .backgroundServiceOnly
    }
}

enum CodexDesktopAppLocator {
    static let appBundleIdentifier = "com.openai.codex"
    private static let defaultAppPath = "/Applications/Codex.app"
    private static let requiredPatchMarkers = [
        "_bundledFastModels",
    ]
    private static let legacyPatchMarkers = [
        "_invalidateAccountQueries",
    ]

    static func locate(appPath: String = defaultAppPath) -> CodexDesktopAppInstall? {
        let appURL = URL(fileURLWithPath: appPath)
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let asarURL = appURL.appendingPathComponent("Contents/Resources/app.asar")

        guard FileManager.default.fileExists(atPath: infoURL.path),
              FileManager.default.fileExists(atPath: asarURL.path),
              let plist = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            return nil
        }

        let bundleVersion = plist["CFBundleVersion"] as? String ?? "?"
        let shortVersion = plist["CFBundleShortVersionString"] as? String ?? "?"

        return CodexDesktopAppInstall(
            appPath: appPath,
            asarPath: asarURL.path,
            bundleVersion: bundleVersion,
            shortVersion: shortVersion
        )
    }

    static func patchMarkerPresent(install: CodexDesktopAppInstall) -> Bool {
        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: install.asarPath),
            options: [.mappedIfSafe]
        ) else {
            return false
        }

        let hasAllRequiredMarkers = requiredPatchMarkers.allSatisfy { marker in
            data.range(of: Data(marker.utf8)) != nil
        }
        let hasLegacyMarkers = legacyPatchMarkers.contains { marker in
            data.range(of: Data(marker.utf8)) != nil
        }
        return hasAllRequiredMarkers && !hasLegacyMarkers
    }

    static func legacyPatchMarkerPresent(install: CodexDesktopAppInstall) -> Bool {
        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: install.asarPath),
            options: [.mappedIfSafe]
        ) else {
            return false
        }

        return legacyPatchMarkers.contains { marker in
            data.range(of: Data(marker.utf8)) != nil
        }
    }

    static func bundleIsValid(appPath: String = defaultAppPath) -> Bool {
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", "--verbose=2", appPath]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            _ = stdout.fileHandleForReading.readDataToEndOfFile()
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func signatureStatus(appPath: String = defaultAppPath) -> CodexDesktopAppSignatureStatus {
        guard let output = ProcessRunner.run(
            executablePath: "/usr/bin/codesign",
            arguments: ["-dvvv", appPath],
            timeout: 5
        ), !output.timedOut, output.terminationStatus == 0 else {
            return .unreadable
        }

        return signatureStatus(from: output.stdout + "\n" + output.stderr)
    }

    static func signatureStatus(from output: String) -> CodexDesktopAppSignatureStatus {
        if output.contains("Signature=adhoc") {
            return .adHoc
        }
        if output.contains("TeamIdentifier=2DC432GLL2") {
            return .officialOpenAI
        }
        if output.contains("TeamIdentifier=") {
            return .nonOpenAISigned
        }
        return .unreadable
    }

    static func isCodexApplication(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == appBundleIdentifier
    }
}

struct CodexDesktopAppPatchResult: Sendable {
    let success: Bool
    let message: String
}

enum CodexDesktopAppPatcher {
    private nonisolated static let patchScriptEnvironmentKey = "CODEXSWITCH_PATCH_ASAR_SCRIPT"

    nonisolated static func currentStatusSummary() -> CodexDesktopAppStatusSummary {
        guard let install = CodexDesktopAppLocator.locate() else {
            return CodexDesktopAppStatusSummary(
                installedVersionLabel: "Not installed",
                runtimeLabel: "Codex desktop app not found",
                patchLabel: "Install the official Codex.app first",
                patchHealthy: false,
                canPatchNow: false
            )
        }

        let inspection = inspect(install: install)
        return CodexDesktopAppStatusSummary(
            installedVersionLabel: install.versionLabel,
            runtimeLabel: inspection.usageState.runtimeLabel,
            patchLabel: patchStatusLabel(for: inspection),
            patchHealthy: inspection.decision == .noRepairNeeded,
            canPatchNow: inspection.decision == .repairNeeded
                && inspection.usageState != .appRunning
        )
    }

    nonisolated static func repairInstalledAppIfNeeded() -> CodexDesktopAppPatchResult? {
        guard let install = CodexDesktopAppLocator.locate() else {
            return nil
        }

        let inspection = inspect(install: install)

        switch inspection.decision {
        case .noRepairNeeded, .deferWhileRunning:
            return nil
        case .repairNeeded:
            if let preparationFailure = prepareForRestore(
                usageState: inspection.usageState,
                appPath: install.appPath
            ) {
                return preparationFailure
            }
            return patchInstalledApp(install: install)
        }
    }

    nonisolated static func restoreInstalledAppNow() async -> CodexDesktopAppPatchResult {
        guard let install = CodexDesktopAppLocator.locate() else {
            return CodexDesktopAppPatchResult(
                success: false,
                message: "Could not locate /Applications/Codex.app"
            )
        }

        let usageState = CodexDesktopAppProcessClassifier.usageState(appPath: install.appPath)
        if let preparationFailure = prepareForRestore(
            usageState: usageState,
            appPath: install.appPath
        ) {
            return preparationFailure
        }

        guard let release = await CodexDesktopAppUpdater.latestRelease() else {
            return CodexDesktopAppPatchResult(
                success: false,
                message: "Could not determine the latest official Codex desktop build"
            )
        }

        let result = await CodexDesktopAppUpdater.installLatestStock(release)
        return CodexDesktopAppPatchResult(
            success: result.success,
            message: result.message
        )
    }

    nonisolated static func prepareForRestore(
        usageState: CodexDesktopAppUsageState,
        appPath: String,
        stopDetachedAppServer: (String) -> Bool = CodexDesktopAppProcessClassifier.stopDetachedAppServer
    ) -> CodexDesktopAppPatchResult? {
        switch usageState {
        case .appRunning:
            return CodexDesktopAppPatchResult(
                success: false,
                message: "Quit Codex.app before applying the desktop patch"
            )
        case .backgroundServiceOnly:
            guard stopDetachedAppServer(appPath) else {
                return CodexDesktopAppPatchResult(
                    success: false,
                    message: "Failed to stop the detached Codex app-server before patching the desktop bundle"
                )
            }
            return nil
        case .notRunning:
            return nil
        }
    }

    nonisolated static func patchInstalledAppNow() -> CodexDesktopAppPatchResult {
        guard let install = CodexDesktopAppLocator.locate() else {
            return CodexDesktopAppPatchResult(
                success: false,
                message: "Could not locate /Applications/Codex.app"
            )
        }

        let usageState = CodexDesktopAppProcessClassifier.usageState(appPath: install.appPath)
        if let preparationFailure = prepareForRestore(
            usageState: usageState,
            appPath: install.appPath
        ) {
            return preparationFailure
        }

        return patchInstalledApp(install: install)
    }

    private nonisolated static func patchInstalledApp(
        install: CodexDesktopAppInstall,
        processRunner: (
            _ executablePath: String,
            _ arguments: [String],
            _ timeout: TimeInterval,
            _ environment: [String: String]
        ) -> ProcessRunnerOutput? = { executablePath, arguments, timeout, environment in
            ProcessRunner.run(
                executablePath: executablePath,
                arguments: arguments,
                timeout: timeout,
                environment: environment
            )
        }
    ) -> CodexDesktopAppPatchResult {
        guard let scriptPath = patchScriptPath() else {
            return CodexDesktopAppPatchResult(
                success: false,
                message: "Could not locate bundled patch-asar.py"
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_APP"] = install.appPath
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        guard let result = processRunner(
            "/usr/bin/python3",
            [scriptPath],
            600,
            environment
        ) else {
            return CodexDesktopAppPatchResult(
                success: false,
                message: "Failed to start desktop patcher"
            )
        }

        guard !result.timedOut else {
            return CodexDesktopAppPatchResult(
                success: false,
                message: "Desktop patcher timed out"
            )
        }

        guard result.terminationStatus == 0 else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexDesktopAppPatchResult(
                success: false,
                message: "Desktop patch failed: \(String(detail.suffix(300)))"
            )
        }

        guard let patchedInstall = CodexDesktopAppLocator.locate(appPath: install.appPath),
              CodexDesktopAppLocator.patchMarkerPresent(install: patchedInstall),
              !CodexDesktopAppLocator.legacyPatchMarkerPresent(install: patchedInstall),
              CodexDesktopAppLocator.bundleIsValid(appPath: patchedInstall.appPath) else {
            return CodexDesktopAppPatchResult(
                success: false,
                message: "Desktop patch completed but verification failed"
            )
        }

        do {
            try CodexDesktopAppPatchStateStore.save(
                CodexDesktopPatchedAppState(
                    bundleVersion: patchedInstall.bundleVersion,
                    asarPath: patchedInstall.asarPath
                )
            )
        } catch {
            return CodexDesktopAppPatchResult(
                success: false,
                message: "Desktop patch applied but state save failed: \(error.localizedDescription)"
            )
        }

        return CodexDesktopAppPatchResult(
            success: true,
            message: "Patched Codex.app \(patchedInstall.versionLabel) for CodexSwitch desktop compatibility"
        )
    }

    private nonisolated static func patchScriptPath() -> String? {
        if let override = ProcessInfo.processInfo.environment[patchScriptEnvironmentKey],
           FileManager.default.isReadableFile(atPath: override) {
            return override
        }

        if let resourcePath = Bundle.main.resourcePath {
            let bundled = URL(fileURLWithPath: resourcePath)
                .appendingPathComponent("patch-asar.py")
                .path
            if FileManager.default.isReadableFile(atPath: bundled) {
                return bundled
            }
        }

        let developerCheckout = NSString("~/Developer/CodexSwitch/scripts/patch-asar.py")
            .expandingTildeInPath
        if FileManager.default.isReadableFile(atPath: developerCheckout) {
            return developerCheckout
        }

        let currentDirectoryCheckout = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/patch-asar.py")
            .path
        if FileManager.default.isReadableFile(atPath: currentDirectoryCheckout) {
            return currentDirectoryCheckout
        }

        return nil
    }

    private nonisolated static func inspect(
        install: CodexDesktopAppInstall
    ) -> CodexDesktopAppInspection {
        let savedState = CodexDesktopAppPatchStateStore.load()
        let patchMarkerPresent = CodexDesktopAppLocator.patchMarkerPresent(install: install)
        let legacyPatchMarkerPresent = CodexDesktopAppLocator.legacyPatchMarkerPresent(install: install)
        let usageState = CodexDesktopAppProcessClassifier.usageState(appPath: install.appPath)
        let bundleIsValid = CodexDesktopAppLocator.bundleIsValid(appPath: install.appPath)
        let signatureStatus = CodexDesktopAppLocator.signatureStatus(appPath: install.appPath)
        let decision = CodexDesktopAppPatchRepairDecider.decision(
            currentInstall: install,
            savedState: savedState,
            patchMarkerPresent: patchMarkerPresent,
            legacyPatchMarkerPresent: legacyPatchMarkerPresent,
            usageState: usageState,
            bundleIsValid: bundleIsValid,
            signatureStatus: signatureStatus
        )

        return CodexDesktopAppInspection(
            install: install,
            savedState: savedState,
            patchMarkerPresent: patchMarkerPresent,
            legacyPatchMarkerPresent: legacyPatchMarkerPresent,
            usageState: usageState,
            bundleIsValid: bundleIsValid,
            signatureStatus: signatureStatus,
            decision: decision
        )
    }

    private nonisolated static func patchStatusLabel(
        for inspection: CodexDesktopAppInspection
    ) -> String {
        switch inspection.decision {
        case .noRepairNeeded:
            return "Desktop bundle is patched and ready"
        case .deferWhileRunning:
            if inspection.legacyPatchMarkerPresent {
                return "Quit Codex.app to repair the legacy desktop patch"
            }
            if !inspection.patchMarkerPresent {
                return "Quit Codex.app to apply the desktop patch"
            }
            if inspection.signatureStatus == .adHoc {
                return "Quit Codex.app to verify the desktop patch state"
            }
            if inspection.signatureStatus == .nonOpenAISigned {
                return "Quit Codex.app to repair the desktop bundle signature"
            }
            return "Quit Codex.app before repairing the desktop bundle"
        case .repairNeeded:
            if inspection.legacyPatchMarkerPresent {
                return "Legacy desktop patch found — auto-repair required"
            }
            if inspection.patchMarkerPresent,
               inspection.signatureStatus == .adHoc,
               !inspection.bundleIsValid {
                return "Desktop patch signature is invalid — auto-repair required"
            }
            if inspection.patchMarkerPresent {
                return "Desktop patch state is stale — auto-repair required"
            }
            if inspection.signatureStatus == .adHoc {
                return "Desktop bundle is ad-hoc signed without a valid patch marker"
            }
            if inspection.signatureStatus == .nonOpenAISigned {
                return "Desktop bundle signature is not from OpenAI — repair required"
            }
            if inspection.usageState == .backgroundServiceOnly {
                return "Detached Codex app-server will be stopped before patching"
            }
            if !inspection.bundleIsValid {
                return "Desktop bundle signature is invalid — repair required"
            }
            return "Desktop patch will be applied automatically"
        }
    }
}

@MainActor
final class CodexAutoPatchMonitor {
    private var workspaceObserver: NSObjectProtocol?
    private var periodicTimer: Timer?
    private var repairTask: Task<Void, Never>?
    private var lastForkMessage: String?
    private var lastDesktopMessage: String?

    func start() {
        attemptRepair(reason: "launch")

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
                CodexDesktopAppLocator.isCodexApplication(app) else {
                return
            }

            Task { @MainActor [weak self] in
                self?.attemptRepair(reason: "codex-exit")
            }
        }

        periodicTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.attemptRepair(reason: "periodic")
            }
        }
    }

    func stop() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        periodicTimer?.invalidate()
        periodicTimer = nil
        repairTask?.cancel()
        repairTask = nil
    }

    private func attemptRepair(reason: String) {
        guard repairTask == nil else { return }

        repairTask = Task.detached { [weak self] in
            let desktopResult = CodexDesktopAppPatcher.repairInstalledAppIfNeeded()
            let forkResult = CodexVersionChecker.repairInstalledForkIfNeeded()

            await MainActor.run {
                self?.repairTask = nil
                self?.log(forkResult: forkResult, desktopResult: desktopResult, reason: reason)
            }
        }
    }

    private func log(
        forkResult: CodexVersionChecker.ActionResult?,
        desktopResult: CodexDesktopAppPatchResult?,
        reason: String
    ) {
        if let forkResult, forkResult.message != lastForkMessage {
            if forkResult.success {
                desktopPatchLogger.info(
                    "Auto-repaired Codex CLI (\(reason, privacy: .public)): \(forkResult.message, privacy: .public)"
                )
            } else {
                desktopPatchLogger.error(
                    "Codex CLI auto-repair failed (\(reason, privacy: .public)): \(forkResult.message, privacy: .public)"
                )
            }
            lastForkMessage = forkResult.message
        }

        if let desktopResult, desktopResult.message != lastDesktopMessage {
            if desktopResult.success {
                desktopPatchLogger.info(
                    "Desktop app status changed (\(reason, privacy: .public)): \(desktopResult.message, privacy: .public)"
                )
            } else {
                desktopPatchLogger.error(
                    "Codex desktop auto-patch failed (\(reason, privacy: .public)): \(desktopResult.message, privacy: .public)"
                )
            }
            lastDesktopMessage = desktopResult.message
        }
    }
}
