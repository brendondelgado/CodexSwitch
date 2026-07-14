import Foundation

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

    private nonisolated static let forkMarkerPath = NSString("~/.codexswitch/sighup-enabled").expandingTildeInPath
    private nonisolated static let preparedCodexRootPath = NSString("~/.local/share/codexswitch/prepared-codex").expandingTildeInPath
    private nonisolated static let localLauncherPath = NSString("~/.local/bin/codex").expandingTildeInPath
    nonisolated static let updaterCLIPath = NSString("~/.local/bin/codexswitch-cli").expandingTildeInPath
    private nonisolated static let updaterCheckTimeout: TimeInterval = 60
    private nonisolated static let updaterStatusTimeout: TimeInterval = 10
    private nonisolated static let updaterInstallTimeout: TimeInterval = 10 * 60
    private nonisolated static let preparedInstallCommand = "codexswitch-cli install-prepared-codex"
    nonisolated static let automaticUpdateCheckInterval: TimeInterval = 15 * 60
    nonisolated static let automaticUpdateFailureBackoff: TimeInterval = 6 * 60 * 60
    nonisolated static let automaticRuntimeRepairInterval: TimeInterval = 5 * 60
    private nonisolated static let homebrewCodexPath = "/opt/homebrew/bin/codex"

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

    enum CodexUpdateStatus: String, Decodable, Sendable, Equatable {
        case idle
        case checking
        case preparing
        case installing
        case readyToInstall = "ready_to_install"
        case installed
        case failed
    }

    struct CodexUpdateReport: Decodable, Sendable, Equatable {
        let status: CodexUpdateStatus
        let summary: String
        let lastCheckedAt: String?
        let latestStableVersion: String?
        let installedVersion: String?
        let preparedVersion: String?
        let preparedSourcePath: String?
        let preparedBinaryPath: String?
        let installCommand: String?
        let error: String?
    }

    enum CodexUpdaterOperation: Sendable, Equatable {
        case check(force: Bool)
        case status
        case installPrepared
    }

    struct CodexUpdaterCommand: Sendable, Equatable {
        let executablePath: String
        let arguments: [String]
        let timeout: TimeInterval
        let environmentOverrides: [String: String]
    }

    enum CodexUpdaterInvocationResult: Sendable, Equatable {
        case report(CodexUpdateReport)
        case failure(String)
    }

    struct CodexUpdateOutcome: Sendable, Equatable {
        let success: Bool
        let installedVersion: String?
        let message: String
    }

    struct CodexExplicitUpdateResult: Sendable, Equatable {
        let preparationReport: CodexUpdateReport?
        let installationReport: CodexUpdateReport?
        let outcome: CodexUpdateOutcome
    }

    enum PreparedBinaryPathValidation: Sendable, Equatable {
        case valid(String)
        case invalid(String)
    }

    enum AutomaticUpdateDisposition: Sendable, Equatable {
        case upToDate(version: String)
        case deferred(String)
        case failed(String)
    }

    func checkVersions(force: Bool = false) {
        if isChecking || isUpdating {
            return
        }
        let now = Date()
        if !force, let lastCheckStarted, now.timeIntervalSince(lastCheckStarted) < 60 {
            return
        }
        lastCheckStarted = now
        isChecking = true
        updateResult = nil
        updateSucceeded = false

        Task.detached {
            let checkResult = Self._runUpdater(.check(force: force))
            let report: CodexUpdateReport?
            let failureMessage: String?
            switch checkResult {
            case .report(let checkedReport):
                report = checkedReport
                failureMessage = nil
            case .failure(let message):
                failureMessage = message
                if case .report(let statusReport) = Self._runUpdater(.status) {
                    report = statusReport
                } else {
                    report = nil
                }
            }

            let installed = Self._getInstalledVersion()
            let latest = Self.nonEmptyString(report?.latestStableVersion) ?? "?"
            let hasFork = FileManager.default.fileExists(atPath: Self.forkMarkerPath)
            let finishedAt = Date()

            await MainActor.run { [weak self] in
                self?.installedVersion = installed
                self?.latestVersion = latest
                self?.lastChecked = finishedAt
                self?.isChecking = false
                self?.forkInstalled = hasFork
                self?.updateAvailable = Self.shouldOfferUpdate(
                    installedVersion: installed,
                    latestVersion: latest
                )
                self?.updateResult = failureMessage.map { "Update check failed: \($0)" }
            }
        }
    }

    func runUpdate() {
        if isUpdating || isChecking {
            return
        }
        isUpdating = true
        updateResult = nil
        updateSucceeded = false
        forkRebuilding = false

        Task.detached {
            let result = Self.performExplicitUpdate()
            let installed = result.outcome.installedVersion ?? Self._getInstalledVersion()
            let latest = Self.nonEmptyString(result.installationReport?.latestStableVersion)
                ?? Self.nonEmptyString(result.preparationReport?.latestStableVersion)
                ?? "?"

            await MainActor.run { [weak self] in
                self?.installedVersion = installed
                self?.latestVersion = latest
                self?.isUpdating = false
                self?.forkRebuilding = false
                self?.updateAvailable = Self.shouldOfferUpdate(
                    installedVersion: installed,
                    latestVersion: latest
                )
                self?.updateSucceeded = result.outcome.success
                self?.updateResult = result.outcome.message
                self?.lastChecked = Date()
            }
        }
    }

    // MARK: - Private (nonisolated for background execution)

    private nonisolated static func _getInstalledVersion() -> String {
        installedHotSwapVersion() ?? "?"
    }

    nonisolated static func shouldOfferUpdate(
        installedVersion: String,
        latestVersion: String
    ) -> Bool {
        if installedVersion == "?" {
            return true
        }
        return latestVersion != "?" && installedVersion != latestVersion
    }

    nonisolated static func automaticMetadataDisposition(
        report: CodexUpdateReport,
        installedHotSwapVersion: String?
    ) -> AutomaticUpdateDisposition {
        guard let latestVersion = nonEmptyString(report.latestStableVersion) else {
            return .deferred("stable update version is unavailable")
        }
        if installedHotSwapVersion == latestVersion {
            return .upToDate(version: latestVersion)
        }

        switch report.status {
        case .checking, .preparing, .installing:
            return .deferred("Codex update is already in progress")
        case .failed:
            return .deferred(nonEmptyString(report.error) ?? report.summary)
        case .readyToInstall, .idle, .installed:
            return .deferred(
                "Codex \(latestVersion) is available; use the explicit Update command to install it"
            )
        }
    }

    nonisolated static func automaticUpdateShouldStart(
        now: Date,
        lastAttemptAt: Date?,
        lastFailureAt: Date?,
        isInFlight: Bool,
        runtimeRepairRequired: Bool = false,
        checkInterval: TimeInterval = automaticUpdateCheckInterval,
        failureBackoff: TimeInterval = automaticUpdateFailureBackoff,
        runtimeRepairInterval: TimeInterval = automaticRuntimeRepairInterval
    ) -> Bool {
        guard !isInFlight else { return false }
        let effectiveCheckInterval = runtimeRepairRequired
            ? min(checkInterval, runtimeRepairInterval)
            : checkInterval
        let effectiveFailureBackoff = runtimeRepairRequired
            ? min(failureBackoff, runtimeRepairInterval)
            : failureBackoff
        if let lastFailureAt, now.timeIntervalSince(lastFailureAt) < effectiveFailureBackoff {
            return false
        }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < effectiveCheckInterval {
            return false
        }
        return true
    }

    nonisolated static func performAutomaticUpdateIfNeeded(
        runUpdater: (CodexUpdaterOperation) -> CodexUpdaterInvocationResult = { operation in
            _runUpdater(operation)
        },
        installedVersionProvider: () -> String? = {
            installedHotSwapVersion()
        }
    ) -> AutomaticUpdateDisposition {
        let checkResult = runUpdater(.check(force: false))
        guard case .report(let report) = checkResult else {
            if case .failure(let message) = checkResult {
                return .failed(message)
            }
            return .failed("Codex update check returned no report")
        }

        return automaticMetadataDisposition(
            report: report,
            installedHotSwapVersion: installedVersionProvider()
        )
    }

    nonisolated static func performExplicitUpdate(
        runUpdater: (CodexUpdaterOperation) -> CodexUpdaterInvocationResult = { operation in
            _runUpdater(operation)
        },
        validatePreparedBinary: (CodexUpdateReport) -> PreparedBinaryPathValidation = { report in
            validatePreparedBinaryPath(in: report)
        },
        repairLauncher: (String) -> CodexCLIRepairResult = { preparedBinaryPath in
            verifyInstalledLauncherRoute(expectedPreparedBinaryPath: preparedBinaryPath)
        },
        installedVersionProvider: () -> String? = {
            installedHotSwapVersion()
        }
    ) -> CodexExplicitUpdateResult {
        let statusInvocation = runUpdater(.status)
        let preparationInvocation: CodexUpdaterInvocationResult
        if case .report(let statusReport) = statusInvocation,
           statusReport.status == .installing {
            // The native installer owns activation-journal recovery. Do not let
            // a metadata check overwrite an interrupted transaction first.
            preparationInvocation = .report(statusReport)
        } else {
            preparationInvocation = runUpdater(.check(force: true))
        }
        guard case .report(let preparationReport) = preparationInvocation else {
            let detail: String
            if case .failure(let message) = preparationInvocation {
                detail = message
            } else {
                detail = "Codex preparation returned no report"
            }
            return CodexExplicitUpdateResult(
                preparationReport: nil,
                installationReport: nil,
                outcome: CodexUpdateOutcome(
                    success: false,
                    installedVersion: nil,
                    message: "Codex preparation failed: \(detail)"
                )
            )
        }

        guard preparationReport.status == .readyToInstall
            || preparationReport.status == .installing else {
            return CodexExplicitUpdateResult(
                preparationReport: preparationReport,
                installationReport: nil,
                outcome: CodexUpdateOutcome(
                    success: false,
                    installedVersion: nil,
                    message: "Codex preparation did not produce a ready runtime (status: \(preparationReport.status.rawValue)): \(preparationReport.summary)"
                )
            )
        }
        if preparationReport.status == .readyToInstall,
           nonEmptyString(preparationReport.installCommand) != preparedInstallCommand {
            return CodexExplicitUpdateResult(
                preparationReport: preparationReport,
                installationReport: nil,
                outcome: CodexUpdateOutcome(
                    success: false,
                    installedVersion: nil,
                    message: "Codex preparation did not authorize the guarded install-prepared-codex command"
                )
            )
        }

        var preparedBinaryPath: String?
        if preparationReport.status == .readyToInstall {
            switch validatePreparedBinary(preparationReport) {
            case .valid(let path):
                preparedBinaryPath = path
            case .invalid(let message):
                return CodexExplicitUpdateResult(
                    preparationReport: preparationReport,
                    installationReport: nil,
                    outcome: CodexUpdateOutcome(
                        success: false,
                        installedVersion: nil,
                        message: "Codex prepared runtime is invalid: \(message)"
                    )
                )
            }
        }

        let installationInvocation = runUpdater(.installPrepared)
        guard case .report(let installationReport) = installationInvocation else {
            let detail: String
            if case .failure(let message) = installationInvocation {
                detail = message
            } else {
                detail = "Codex installation returned no report"
            }
            return CodexExplicitUpdateResult(
                preparationReport: preparationReport,
                installationReport: nil,
                outcome: CodexUpdateOutcome(
                    success: false,
                    installedVersion: nil,
                    message: "Codex update failed: \(detail)"
                )
            )
        }

        guard installationReport.status == .installed else {
            return CodexExplicitUpdateResult(
                preparationReport: preparationReport,
                installationReport: installationReport,
                outcome: verifiedUpdateOutcome(
                    report: installationReport,
                    launcherRepair: nil,
                    installedHotSwapVersion: nil
                )
            )
        }
        if preparedBinaryPath == nil {
            switch validatePreparedBinary(preparationReport) {
            case .valid(let path):
                preparedBinaryPath = path
            case .invalid(let message):
                return CodexExplicitUpdateResult(
                    preparationReport: preparationReport,
                    installationReport: installationReport,
                    outcome: CodexUpdateOutcome(
                        success: false,
                        installedVersion: nil,
                        message: "Codex recovered activation, but its prepared runtime is invalid: \(message)"
                    )
                )
            }
        }
        guard let preparedBinaryPath else {
            return CodexExplicitUpdateResult(
                preparationReport: preparationReport,
                installationReport: installationReport,
                outcome: CodexUpdateOutcome(
                    success: false,
                    installedVersion: nil,
                    message: "Codex recovered activation without a prepared runtime path"
                )
            )
        }
        guard let preparedVersion = nonEmptyString(preparationReport.preparedVersion),
              nonEmptyString(installationReport.installedVersion) == preparedVersion else {
            return CodexExplicitUpdateResult(
                preparationReport: preparationReport,
                installationReport: installationReport,
                outcome: CodexUpdateOutcome(
                    success: false,
                    installedVersion: nil,
                    message: "Codex installer reported installed without the prepared version"
                )
            )
        }
        if let installedPreparedPath = nonEmptyString(installationReport.preparedBinaryPath),
           installedPreparedPath != preparedBinaryPath {
            return CodexExplicitUpdateResult(
                preparationReport: preparationReport,
                installationReport: installationReport,
                outcome: CodexUpdateOutcome(
                    success: false,
                    installedVersion: nil,
                    message: "Codex installer changed the prepared runtime path; launcher repair was refused"
                )
            )
        }
        switch validatePreparedBinary(preparationReport) {
        case .valid(let revalidatedPath) where revalidatedPath == preparedBinaryPath:
            break
        case .valid:
            return CodexExplicitUpdateResult(
                preparationReport: preparationReport,
                installationReport: installationReport,
                outcome: CodexUpdateOutcome(
                    success: false,
                    installedVersion: nil,
                    message: "Codex prepared runtime path changed after installation; launcher repair was refused"
                )
            )
        case .invalid(let message):
            return CodexExplicitUpdateResult(
                preparationReport: preparationReport,
                installationReport: installationReport,
                outcome: CodexUpdateOutcome(
                    success: false,
                    installedVersion: nil,
                    message: "Codex installed runtime failed path revalidation: \(message)"
                )
            )
        }

        let launcherRepair = repairLauncher(preparedBinaryPath)
        let verifiedVersion = launcherRepair.success ? installedVersionProvider() : nil
        return CodexExplicitUpdateResult(
            preparationReport: preparationReport,
            installationReport: installationReport,
            outcome: verifiedUpdateOutcome(
                report: installationReport,
                launcherRepair: launcherRepair,
                installedHotSwapVersion: verifiedVersion
            )
        )
    }

    nonisolated static func validatePreparedBinaryPath(
        in report: CodexUpdateReport,
        preparedRootPath: String = preparedCodexRootPath,
        fileManager: FileManager = .default
    ) -> PreparedBinaryPathValidation {
        guard report.status == .readyToInstall || report.status == .installing else {
            return .invalid("updater status does not identify a prepared activation")
        }
        guard let preparedVersion = nonEmptyString(report.preparedVersion),
              isStableVersion(preparedVersion) else {
            return .invalid("preparedVersion is missing or is not a stable version")
        }
        guard let rawPath = report.preparedBinaryPath,
              rawPath == rawPath.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty,
              !rawPath.contains("\0"),
              (rawPath as NSString).isAbsolutePath else {
            return .invalid("preparedBinaryPath must be a non-empty absolute path")
        }

        let normalizedRoot = (preparedRootPath as NSString).standardizingPath
        let normalizedPath = (rawPath as NSString).standardizingPath
        guard (normalizedRoot as NSString).isAbsolutePath,
              normalizedPath == rawPath else {
            return .invalid("preparedBinaryPath must already be normalized")
        }
        guard let relativeComponents = relativePathComponents(
            of: normalizedPath,
            under: normalizedRoot
        ), relativeComponents.count == 3,
           relativeComponents[0] == preparedVersion,
           isSimpleUUID(relativeComponents[1]),
           relativeComponents[2] == "codex" else {
            return .invalid("preparedBinaryPath is not the reported attempt-scoped generation")
        }

        let rootURL = URL(fileURLWithPath: normalizedRoot, isDirectory: true)
        let binaryURL = URL(fileURLWithPath: normalizedPath, isDirectory: false)
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedBinary = binaryURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard relativePathComponents(of: resolvedBinary, under: resolvedRoot) == relativeComponents else {
            return .invalid("preparedBinaryPath escapes its generation through a symlink")
        }

        do {
            let values = try binaryURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return .invalid("preparedBinaryPath is not a regular file")
            }
        } catch {
            return .invalid("preparedBinaryPath could not be inspected as a regular file")
        }
        guard fileManager.isExecutableFile(atPath: normalizedPath) else {
            return .invalid("preparedBinaryPath is not executable")
        }
        return .valid(normalizedPath)
    }

    nonisolated static func updaterCommand(
        for operation: CodexUpdaterOperation,
        executablePath: String = updaterCLIPath
    ) -> CodexUpdaterCommand {
        switch operation {
        case .check(let force):
            return CodexUpdaterCommand(
                executablePath: executablePath,
                arguments: force
                    ? ["check-codex-update", "--force", "--json"]
                    : ["check-codex-update", "--json"],
                timeout: updaterCheckTimeout,
                environmentOverrides: [:]
            )
        case .status:
            return CodexUpdaterCommand(
                executablePath: executablePath,
                arguments: ["codex-update-status", "--json"],
                timeout: updaterStatusTimeout,
                environmentOverrides: [:]
            )
        case .installPrepared:
            return CodexUpdaterCommand(
                executablePath: executablePath,
                arguments: ["install-prepared-codex", "--json"],
                timeout: updaterInstallTimeout,
                environmentOverrides: [:]
            )
        }
    }

    nonisolated static func updaterCLIIsNativeExecutable(at path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return false
        }
        return binaryIsMachOExecutableData(data)
    }

    nonisolated static func decodeUpdaterReport(_ data: Data) throws -> CodexUpdateReport {
        try JSONDecoder().decode(CodexUpdateReport.self, from: data)
    }

    nonisolated static func interpretUpdaterResult(
        _ result: ProcessRunResult,
        command: CodexUpdaterCommand
    ) -> CodexUpdaterInvocationResult {
        let operation = command.arguments.first ?? "codex updater"
        if result.timedOut {
            return .failure("\(operation) timed out after \(Int(command.timeout)) seconds")
        }
        guard result.terminationStatus == 0 else {
            let detail = updaterDiagnostic(from: result)
            return .failure("\(operation) exited with status \(result.terminationStatus): \(detail)")
        }

        let report: CodexUpdateReport
        do {
            report = try decodeUpdaterReport(result.stdout)
        } catch {
            return .failure("\(operation) returned invalid JSON: \(error.localizedDescription)")
        }
        if report.status == .failed {
            return .failure(nonEmptyString(report.error) ?? report.summary)
        }
        return .report(report)
    }

    nonisolated static func verifiedUpdateOutcome(
        report: CodexUpdateReport,
        launcherRepair: CodexCLIRepairResult?,
        installedHotSwapVersion: String?
    ) -> CodexUpdateOutcome {
        guard report.status == .installed else {
            return CodexUpdateOutcome(
                success: false,
                installedVersion: nil,
                message: "Codex updater did not install a hot-swap runtime (status: \(report.status.rawValue)): \(report.summary)"
            )
        }
        guard let reportedVersion = nonEmptyString(report.installedVersion) else {
            return CodexUpdateOutcome(
                success: false,
                installedVersion: nil,
                message: "Codex updater reported installed without an installedVersion"
            )
        }
        guard let launcherRepair, launcherRepair.success else {
            let detail = launcherRepair?.message ?? "launcher verification was unavailable"
            return CodexUpdateOutcome(
                success: false,
                installedVersion: nil,
                message: "Codex update could not verify the journaled launcher route: \(detail)"
            )
        }
        guard let verifiedVersion = nonEmptyString(installedHotSwapVersion) else {
            return CodexUpdateOutcome(
                success: false,
                installedVersion: nil,
                message: "Codex update completed, but no installed hot-swap version could be verified"
            )
        }
        guard verifiedVersion == reportedVersion else {
            return CodexUpdateOutcome(
                success: false,
                installedVersion: nil,
                message: "Codex updater reported v\(reportedVersion), but the installed launcher route verifies v\(verifiedVersion)"
            )
        }
        if let latestVersion = nonEmptyString(report.latestStableVersion),
           latestVersion != verifiedVersion {
            return CodexUpdateOutcome(
                success: false,
                installedVersion: nil,
                message: "Codex updater reported latest v\(latestVersion), but the installed launcher route verifies v\(verifiedVersion)"
            )
        }
        return CodexUpdateOutcome(
            success: true,
            installedVersion: verifiedVersion,
            message: "Installed and verified Codex hot-swap runtime v\(verifiedVersion)"
        )
    }

    private nonisolated static func _runUpdater(
        _ operation: CodexUpdaterOperation
    ) -> CodexUpdaterInvocationResult {
        let command = updaterCommand(for: operation)
        guard updaterCLIIsNativeExecutable(at: command.executablePath) else {
            return .failure("native updater unavailable at \(command.executablePath)")
        }

        let environment = updaterEnvironment(
            overrides: command.environmentOverrides
        )
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: command.executablePath),
            arguments: command.arguments,
            timeout: command.timeout,
            environment: environment
        )
        return interpretUpdaterResult(result, command: command)
    }

    nonisolated static func updaterEnvironment(
        overrides: [String: String],
        base: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String: String] {
        var environment = base
        environment["HOME"] = homeDirectory
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    private nonisolated static func updaterDiagnostic(from result: ProcessRunResult) -> String {
        let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = stderr.isEmpty ? stdout : stderr
        return detail.isEmpty ? "no diagnostic output" : String(detail.prefix(400))
    }

    private nonisolated static func nonEmptyString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func relativePathComponents(
        of candidatePath: String,
        under rootPath: String
    ) -> [String]? {
        let rootComponents = URL(fileURLWithPath: rootPath, isDirectory: true).pathComponents
        let candidateComponents = URL(fileURLWithPath: candidatePath, isDirectory: false).pathComponents
        guard candidateComponents.count > rootComponents.count,
              candidateComponents.starts(with: rootComponents) else {
            return nil
        }
        return Array(candidateComponents.dropFirst(rootComponents.count))
    }

    private nonisolated static func isSimpleUUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 32 else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private nonisolated static func isStableVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 3 && components.allSatisfy { UInt64($0) != nil }
    }

    @discardableResult
    nonisolated static func repairBrokenGlobalCLIIfNeeded(force _: Bool = false) -> CodexCLIRepairResult {
        if let version = installedHotSwapVersion() {
            return CodexCLIRepairResult(
                attempted: false,
                success: true,
                message: "Managed Codex launcher route verifies v\(version)"
            )
        }
        return CodexCLIRepairResult(
            attempted: false,
            success: false,
            message: "No complete native Codex hot-swap runtime is installed"
        )
    }

    private nonisolated static let goalMarkers = [
        "Usage: /goal <objective>",
        "Pursuing goal",
        "thread/goal/set",
    ]

    nonisolated static func binaryHasSighupSupportData(_ data: Data) -> Bool {
        RuntimeHotSwapContract.fullMarkers.allSatisfy { marker in
            data.range(of: Data(marker.utf8)) != nil
        }
    }

    nonisolated static func binaryHasGoalSupportData(_ data: Data) -> Bool {
        data.range(of: Data("Usage: /goal <objective>".utf8)) != nil
            || (
                data.range(of: Data("Pursuing goal".utf8)) != nil
                    && data.range(of: Data("thread/goal/set".utf8)) != nil
            )
    }

    nonisolated static func binaryIsMachOExecutableData(_ data: Data) -> Bool {
        guard let magic = readUInt32(from: data, at: 0, bigEndian: true) else {
            return false
        }

        switch magic {
        case 0xCEFAEDFE, 0xCFFAEDFE:
            return readUInt32(from: data, at: 12, bigEndian: false) == 2
        case 0xFEEDFACE, 0xFEEDFACF:
            return readUInt32(from: data, at: 12, bigEndian: true) == 2
        case 0xCAFEBABE:
            return fatMachOContainsOnlyExecutables(data, is64Bit: false, bigEndian: true)
        case 0xBEBAFECA:
            return fatMachOContainsOnlyExecutables(data, is64Bit: false, bigEndian: false)
        case 0xCAFEBABF:
            return fatMachOContainsOnlyExecutables(data, is64Bit: true, bigEndian: true)
        case 0xBFBAFECA:
            return fatMachOContainsOnlyExecutables(data, is64Bit: true, bigEndian: false)
        default:
            return false
        }
    }

    nonisolated static func localHotSwapUnitIsStructurallyValid(at path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path),
              binaryFileHasRequiredRuntimeMarkers(at: path) else {
            return false
        }

        let companionPath = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appending(path: "codex-code-mode-host")
            .path
        return FileManager.default.isExecutableFile(atPath: companionPath)
    }

    nonisolated static func binaryFileHasRequiredRuntimeMarkers(
        at path: String,
        chunkSize: Int = 1024 * 1024
    ) -> Bool {
        guard chunkSize > 0,
              let handle = FileHandle(forReadingAtPath: path) else {
            return false
        }
        defer { try? handle.close() }

        do {
            let header = try handle.read(upToCount: 4096) ?? Data()
            guard binaryIsMachOExecutableData(header) else { return false }
            try handle.seek(toOffset: 0)

            let hotSwapMarkers = RuntimeHotSwapContract.fullMarkers.map { Data($0.utf8) }
            let goalMarkerData = goalMarkers.map { Data($0.utf8) }
            var hotSwapFound = Array(repeating: false, count: hotSwapMarkers.count)
            var goalFound = Array(repeating: false, count: goalMarkerData.count)
            let longestMarker = (hotSwapMarkers + goalMarkerData).map(\.count).max() ?? 1
            let overlapCount = max(0, longestMarker - 1)
            var overlap = Data()

            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                var window = Data()
                window.reserveCapacity(overlap.count + chunk.count)
                window.append(overlap)
                window.append(chunk)

                for index in hotSwapMarkers.indices where !hotSwapFound[index] {
                    hotSwapFound[index] = window.range(of: hotSwapMarkers[index]) != nil
                }
                for index in goalMarkerData.indices where !goalFound[index] {
                    goalFound[index] = window.range(of: goalMarkerData[index]) != nil
                }

                let hasGoalSupport = goalFound[0] || (goalFound[1] && goalFound[2])
                if hotSwapFound.allSatisfy({ $0 }) && hasGoalSupport {
                    return true
                }
                overlap = Data(window.suffix(overlapCount))
            }
        } catch {
            return false
        }
        return false
    }

    private nonisolated static func verifyInstalledLauncherRoute(
        expectedPreparedBinaryPath: String
    ) -> CodexCLIRepairResult {
        let expected = (expectedPreparedBinaryPath as NSString).standardizingPath
        guard let routed = routedHotSwapBinaryPath(
            localLauncherPath: localLauncherPath,
            homebrewBridgePath: homebrewCodexPath
        ), routed == expected else {
            return CodexCLIRepairResult(
                attempted: false,
                success: false,
                message: "The Rust activation transaction did not publish the expected launcher route"
            )
        }
        guard completeHotSwapBinaryIsLaunchable(at: routed) else {
            return CodexCLIRepairResult(
                attempted: false,
                success: false,
                message: "The installed prepared Codex runtime is not complete and launchable"
            )
        }

        let launchctl = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["setenv", "CODEX_CLI_PATH", localLauncherPath],
            timeout: 3
        )
        guard !launchctl.timedOut, launchctl.terminationStatus == 0 else {
            return CodexCLIRepairResult(
                attempted: true,
                success: false,
                message: "The launcher route is valid, but CODEX_CLI_PATH could not be published"
            )
        }
        SwapLog.append(.debug(
            "CODEX_CLI_ROUTE_VERIFIED target=\(routed) local=\(localLauncherPath) homebrew=\(homebrewCodexPath)"
        ))
        return CodexCLIRepairResult(
            attempted: true,
            success: true,
            message: "Verified the journaled Codex launcher route"
        )
    }

    nonisolated static func installedHotSwapVersion(
        localLauncherPath: String = CodexVersionChecker.localLauncherPath,
        homebrewBridgePath: String = CodexVersionChecker.homebrewCodexPath
    ) -> String? {
        guard let path = routedHotSwapBinaryPath(
            localLauncherPath: localLauncherPath,
            homebrewBridgePath: homebrewBridgePath
        ), completeHotSwapBinaryIsLaunchable(at: path) else {
            return nil
        }
        return _codexCLIHealth(at: path).version
    }

    nonisolated static func routedHotSwapBinaryPath(
        localLauncherPath: String,
        homebrewBridgePath: String
    ) -> String? {
        guard let localScript = try? String(contentsOfFile: localLauncherPath, encoding: .utf8),
              let bridgeScript = try? String(contentsOfFile: homebrewBridgePath, encoding: .utf8),
              let localManaged = launcherManagedCodexTarget(from: localScript),
              let bridgeManaged = launcherManagedCodexTarget(from: bridgeScript) else {
            return nil
        }

        let normalizedLocalManaged = (localManaged as NSString).standardizingPath
        let normalizedBridgeManaged = (bridgeManaged as NSString).standardizingPath
        guard normalizedLocalManaged == normalizedBridgeManaged,
              let managedScript = try? String(
                contentsOfFile: normalizedLocalManaged,
                encoding: .utf8
              ),
              let runtimeTarget = launcherPatchedCodexTarget(from: managedScript) else {
            return nil
        }
        return (runtimeTarget as NSString).standardizingPath
    }

    nonisolated static func launcherManagedCodexTarget(from script: String) -> String? {
        let lines = script.components(separatedBy: "\n")
        guard lines.count == 9,
              let managed = launcherSingleQuotedValue(
                in: lines[2],
                prefix: "MANAGED_CODEX="
              ), let normalizedManaged = normalizedAbsoluteLauncherPath(managed),
              script == rustBridgeLauncherScript(managedLauncher: normalizedManaged) else {
            return nil
        }
        return normalizedManaged
    }

    nonisolated static func launcherPatchedCodexTarget(from script: String) -> String? {
        let lines = script.components(separatedBy: "\n")
        guard lines.count == 25,
              let patched = launcherSingleQuotedValue(
                in: lines[2],
                prefix: "\tPATCHED_CODEX="
              ), let normalizedPatched = normalizedAbsoluteLauncherPath(patched),
              let helper = launcherSingleQuotedValue(
                in: lines[3],
                prefix: "\tPATCHED_HELPER="
              ), let normalizedHelper = normalizedAbsoluteLauncherPath(helper),
              let runtimeSHA256 = launcherSingleQuotedValue(
                in: lines[4],
                prefix: "\tEXPECTED_CODEX_SHA256="
              ), isLowercaseSHA256(runtimeSHA256),
              let helperSHA256 = launcherSingleQuotedValue(
                in: lines[5],
                prefix: "\tEXPECTED_HELPER_SHA256="
              ), isLowercaseSHA256(helperSHA256) else {
            return nil
        }
        let expectedHelper = URL(fileURLWithPath: normalizedPatched)
            .deletingLastPathComponent()
            .appending(path: "codex-code-mode-host")
            .path
        guard normalizedHelper == expectedHelper,
              script == rustManagedLauncherScript(
                patchedBinary: normalizedPatched,
                runtimeSHA256: runtimeSHA256,
                helperSHA256: helperSHA256
              ) else {
            return nil
        }
        return normalizedPatched
    }

    private nonisolated static func launcherSingleQuotedValue(
        in line: String,
        prefix: String
    ) -> String? {
        let quotedPrefix = "\(prefix)'"
        guard line.hasPrefix(quotedPrefix), line.hasSuffix("'") else {
            return nil
        }
        let value = String(line.dropFirst(quotedPrefix.count).dropLast())
        guard !value.isEmpty,
              !value.contains("'"),
              !value.contains("\0"),
              !value.contains("\r") else {
            return nil
        }
        return value
    }

    private nonisolated static func normalizedAbsoluteLauncherPath(_ path: String) -> String? {
        guard (path as NSString).isAbsolutePath,
              (path as NSString).standardizingPath == path else {
            return nil
        }
        return path
    }

    private nonisolated static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private nonisolated static func rustBridgeLauncherScript(
        managedLauncher: String
    ) -> String {
        [
            "#!/usr/bin/env bash",
            "set -euo pipefail",
            "MANAGED_CODEX='\(managedLauncher)'",
            #"if [[ ! -x "$MANAGED_CODEX" || -L "$MANAGED_CODEX" ]]; then"#,
            #"  echo "codex: managed CodexSwitch launcher is unavailable at $MANAGED_CODEX; run 'codexswitch-cli codex-update-status'" >&2"#,
            "  exit 1",
            "fi",
            #"exec "$MANAGED_CODEX" "$@""#,
            "",
        ].joined(separator: "\n")
    }

    private nonisolated static func rustManagedLauncherScript(
        patchedBinary: String,
        runtimeSHA256: String,
        helperSHA256: String
    ) -> String {
        let helper = URL(fileURLWithPath: patchedBinary)
            .deletingLastPathComponent()
            .appending(path: "codex-code-mode-host")
            .path
        return [
            "#!/usr/bin/env bash",
            "\tset -euo pipefail",
            "\tPATCHED_CODEX='\(patchedBinary)'",
            "\tPATCHED_HELPER='\(helper)'",
            "\tEXPECTED_CODEX_SHA256='\(runtimeSHA256)'",
            "\tEXPECTED_HELPER_SHA256='\(helperSHA256)'",
            #"\tCODEX_VPS="${CODEXSWITCH_CODEX_VPS:-$HOME/.local/bin/codex-vps}""#,
            "",
            #"\tif [[ "${1:-}" == "--remote" ]]; then"#,
            "\t  shift",
            #"\t  if [[ ! -x "$CODEX_VPS" ]]; then"#,
            #"\t    echo "codex: --remote requires the provenance-checked codex-vps synced client: $CODEX_VPS" >&2"#,
            "\t    exit 1",
            "\t  fi",
            #"\t  exec "$CODEX_VPS" --remote-client "$@""#,
            "\tfi",
            "",
            #"\tif [[ -x "$PATCHED_CODEX" && -x "$PATCHED_HELPER" ]] \"#,
            #"\t  && [[ ! -L "$PATCHED_CODEX" && ! -L "$PATCHED_HELPER" ]]; then"#,
            #"\t  exec "$PATCHED_CODEX" "$@""#,
            "\tfi",
            "",
            #"echo "codex: local runtime failed complete provenance/hot-swap validation at $PATCHED_CODEX; run 'codexswitch-cli codex-update-status' and explicitly prepare/install a verified runtime" >&2"#,
            "exit 1",
            "",
        ].joined(separator: "\n")
    }

    private nonisolated static func completeHotSwapBinaryIsLaunchable(at path: String) -> Bool {
        guard localHotSwapUnitIsStructurallyValid(at: path) else {
            return false
        }
        return _codexCLIHealth(at: path).healthy
    }

    private nonisolated static func fatMachOContainsOnlyExecutables(
        _ data: Data,
        is64Bit: Bool,
        bigEndian: Bool
    ) -> Bool {
        guard let architectureCount = readUInt32(from: data, at: 4, bigEndian: bigEndian),
              architectureCount > 0,
              architectureCount <= 64 else {
            return false
        }

        let entrySize = is64Bit ? 32 : 20
        guard data.count >= 8 + Int(architectureCount) * entrySize else {
            return false
        }

        for index in 0..<Int(architectureCount) {
            let entryOffset = 8 + index * entrySize
            let sliceOffset: UInt64?
            if is64Bit {
                sliceOffset = readUInt64(from: data, at: entryOffset + 8, bigEndian: bigEndian)
            } else {
                sliceOffset = readUInt32(from: data, at: entryOffset + 8, bigEndian: bigEndian).map(UInt64.init)
            }

            guard let sliceOffset,
                  sliceOffset <= UInt64(Int.max - 16),
                  thinMachOIsExecutable(data, at: Int(sliceOffset)) else {
                return false
            }
        }
        return true
    }

    private nonisolated static func thinMachOIsExecutable(_ data: Data, at offset: Int) -> Bool {
        guard offset >= 0,
              data.count >= 16,
              offset <= data.count - 16,
              let magic = readUInt32(from: data, at: offset, bigEndian: true) else {
            return false
        }
        switch magic {
        case 0xCEFAEDFE, 0xCFFAEDFE:
            return readUInt32(from: data, at: offset + 12, bigEndian: false) == 2
        case 0xFEEDFACE, 0xFEEDFACF:
            return readUInt32(from: data, at: offset + 12, bigEndian: true) == 2
        default:
            return false
        }
    }

    private nonisolated static func readUInt32(
        from data: Data,
        at offset: Int,
        bigEndian: Bool
    ) -> UInt32? {
        guard offset >= 0, data.count >= 4, offset <= data.count - 4 else {
            return nil
        }
        let bytes = (0..<4).map { data[data.index(data.startIndex, offsetBy: offset + $0)] }
        if bigEndian {
            return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
        }
        return bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private nonisolated static func readUInt64(
        from data: Data,
        at offset: Int,
        bigEndian: Bool
    ) -> UInt64? {
        guard offset >= 0, data.count >= 8, offset <= data.count - 8 else {
            return nil
        }
        let bytes = (0..<8).map { data[data.index(data.startIndex, offsetBy: offset + $0)] }
        if bigEndian {
            return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
        }
        return bytes.reversed().reduce(0) { ($0 << 8) | UInt64($1) }
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

}
