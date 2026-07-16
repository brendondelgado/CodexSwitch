import Foundation
import Testing
@testable import CodexSwitch

@Suite("Codex version checker")
struct CodexVersionCheckerTests {
    @Test("Updater commands use only the exact native CLI contract")
    func updaterCommandsUseOnlyExactNativeCLIContract() {
        let path = "/Users/test/.local/bin/codexswitch-cli"
        let check = CodexVersionChecker.updaterCommand(
            for: .check(force: false),
            executablePath: path
        )
        let forcedCheck = CodexVersionChecker.updaterCommand(
            for: .check(force: true),
            executablePath: path
        )
        let status = CodexVersionChecker.updaterCommand(
            for: .status,
            executablePath: path
        )
        let install = CodexVersionChecker.updaterCommand(
            for: .installPrepared,
            executablePath: path
        )
        let productionStatus = CodexVersionChecker.updaterCommand(for: .status)

        #expect(check.executablePath == path)
        #expect(check.arguments == ["check-codex-update", "--json"])
        #expect(forcedCheck.arguments == ["check-codex-update", "--force", "--json"])
        #expect(status.arguments == ["codex-update-status", "--json"])
        #expect(install.arguments == ["install-prepared-codex", "--json"])
        #expect(install.environmentOverrides.isEmpty)
        #expect(install.timeout == 10 * 60)
        #expect(
            productionStatus.executablePath
                == NSString("~/.local/bin/codexswitch-cli").expandingTildeInPath
        )

        for command in [check, forcedCheck, status, install] {
            #expect(command.executablePath == path)
            #expect(!command.executablePath.localizedCaseInsensitiveContains("npm"))
            #expect(!command.arguments.joined(separator: " ").localizedCaseInsensitiveContains("npm"))
        }
    }

    @Test("GUI updater environment always provides canonical HOME")
    func guiUpdaterEnvironmentProvidesHome() {
        let environment = CodexVersionChecker.updaterEnvironment(
            overrides: ["CARGO_BUILD_JOBS": "1"],
            base: ["PATH": "/usr/bin:/bin"],
            homeDirectory: "/Users/test"
        )

        #expect(environment["HOME"] == "/Users/test")
        #expect(environment["PATH"] == "/usr/bin:/bin")
        #expect(environment["CARGO_BUILD_JOBS"] == "1")
    }

    @Test("Unverified installed route remains eligible for repair")
    func unverifiedInstalledRouteRemainsEligibleForRepair() {
        #expect(
            CodexVersionChecker.shouldOfferUpdate(
                installedVersion: "?",
                latestVersion: "?"
            )
        )
        #expect(
            CodexVersionChecker.shouldOfferUpdate(
                installedVersion: "?",
                latestVersion: "0.144.1"
            )
        )
        #expect(
            CodexVersionChecker.shouldOfferUpdate(
                installedVersion: "0.143.0",
                latestVersion: "0.144.1"
            )
        )
        #expect(
            CodexVersionChecker.shouldOfferUpdate(
                installedVersion: "0.144.1",
                latestVersion: "0.144.1"
            ) == false
        )
        #expect(
            CodexVersionChecker.shouldOfferUpdate(
                installedVersion: "0.144.1",
                latestVersion: "?"
            ) == false
        )
    }

    @Test("Automatic updates perform metadata checks and never invoke installation")
    func automaticUpdatesAreMetadataOnly() throws {
        let idle = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "idle",
                summary: "stable update available",
                latestVersion: "0.145.0",
                installedVersion: "0.144.1"
            )
        )
        let ready = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "ready_to_install",
                summary: "patched runtime prepared",
                latestVersion: "0.145.0",
                installedVersion: "0.144.1",
                preparedVersion: "0.145.0"
            )
        )
        var operations: [CodexVersionChecker.CodexUpdaterOperation] = []
        let disposition = CodexVersionChecker.performAutomaticUpdateIfNeeded(
            runUpdater: { operation in
                operations.append(operation)
                return .report(ready)
            },
            installedVersionProvider: { "0.144.1" }
        )

        #expect(operations == [.check(force: false)])
        guard case .deferred(let reason) = disposition else {
            Issue.record("Expected the available update to require explicit installation")
            return
        }
        #expect(reason.contains("explicit Update command"))
        #expect(
            CodexVersionChecker.automaticMetadataDisposition(
                report: idle,
                installedHotSwapVersion: "0.144.1"
            ) == .deferred(
                "Codex 0.145.0 is available; use the explicit Update command to install it"
            )
        )
        #expect(
            CodexVersionChecker.automaticMetadataDisposition(
                report: idle,
                installedHotSwapVersion: "0.145.0"
            ) == .upToDate(version: "0.145.0")
        )
    }

    @Test("Prepared runtime binding uses the exact attempt generation and never guesses the legacy path")
    func preparedRuntimeBindingUsesExactAttemptGeneration() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "codexswitch-prepared-binding-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let version = "0.145.0"
        let attemptID = "0123456789abcdef0123456789abcdef"
        let exactBinary = root
            .appending(path: version)
            .appending(path: attemptID)
            .appending(path: "codex")
        let guessedLegacyBinary = root
            .appending(path: version)
            .appending(path: "codex")
        try writeRecordingExecutable(at: exactBinary, label: "attempt")
        try writeRecordingExecutable(at: guessedLegacyBinary, label: "legacy")

        let report = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "ready_to_install",
                summary: "prepared Codex \(version)",
                latestVersion: version,
                installedVersion: "0.144.1",
                preparedVersion: version,
                preparedBinaryPath: exactBinary.path,
                installCommand: "codexswitch-cli install-prepared-codex"
            )
        )

        #expect(
            CodexVersionChecker.validatePreparedBinaryPath(
                in: report,
                preparedRootPath: root.path
            ) == .valid(exactBinary.path)
        )
        let interruptedReport = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "installing",
                summary: "interrupted activation",
                latestVersion: version,
                installedVersion: "0.144.1",
                preparedVersion: version,
                preparedBinaryPath: exactBinary.path
            )
        )
        #expect(
            CodexVersionChecker.validatePreparedBinaryPath(
                in: interruptedReport,
                preparedRootPath: root.path
            ) == .valid(exactBinary.path)
        )

        try FileManager.default.removeItem(at: exactBinary)
        guard case .invalid = CodexVersionChecker.validatePreparedBinaryPath(
            in: report,
            preparedRootPath: root.path
        ) else {
            Issue.record("Missing exact generation unexpectedly fell back to <version>/codex")
            return
        }
        #expect(FileManager.default.isExecutableFile(atPath: guessedLegacyBinary.path))

        try FileManager.default.createDirectory(at: exactBinary, withIntermediateDirectories: true)
        guard case .invalid(let reason) = CodexVersionChecker.validatePreparedBinaryPath(
            in: report,
            preparedRootPath: root.path
        ) else {
            Issue.record("Directory at preparedBinaryPath unexpectedly passed regular-file validation")
            return
        }
        #expect(reason.contains("regular file"))
    }

    @Test("Explicit Update installs a staged runtime and verifies only after installed")
    func explicitUpdateUsesGuardedInstallBeforeLauncherVerification() throws {
        let version = "0.145.0"
        let preparedPath = "/Users/test/.local/share/codexswitch/prepared-codex/0.145.0/0123456789abcdef0123456789abcdef/codex"
        let prepared = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "ready_to_install",
                summary: "prepared Codex \(version)",
                latestVersion: version,
                installedVersion: "0.144.1",
                preparedVersion: version,
                preparedBinaryPath: preparedPath,
                installCommand: "codexswitch-cli install-prepared-codex"
            )
        )
        let installed = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "installed",
                summary: "installed Codex \(version)",
                latestVersion: version,
                installedVersion: version
            )
        )
        var operations: [CodexVersionChecker.CodexUpdaterOperation] = []
        var repairedPaths: [String] = []
        var validationCalls = 0

        let result = CodexVersionChecker.performExplicitUpdate(
            runUpdater: { operation in
                operations.append(operation)
                switch operation {
                case .check(force: true):
                    return .report(prepared)
                case .installPrepared:
                    return .report(installed)
                default:
                    return .failure("unexpected operation")
                }
            },
            validatePreparedBinary: { _ in
                validationCalls += 1
                return .valid(preparedPath)
            },
            repairLauncher: { path in
                repairedPaths.append(path)
                return CodexVersionChecker.CodexCLIRepairResult(
                    attempted: true,
                    success: true,
                    message: "launchers verified"
                )
            },
            installedVersionProvider: { version }
        )

        #expect(operations == [.status, .check(force: true), .installPrepared])
        #expect(validationCalls == 2)
        #expect(repairedPaths == [preparedPath])
        #expect(result.outcome.success)
        #expect(result.outcome.installedVersion == version)

        operations.removeAll()
        repairedPaths.removeAll()
        let stillReady = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "ready_to_install",
                summary: "runtime remains active",
                latestVersion: version,
                installedVersion: "0.144.1",
                preparedVersion: version,
                preparedBinaryPath: preparedPath,
                installCommand: "codexswitch-cli install-prepared-codex"
            )
        )
        let deferred = CodexVersionChecker.performExplicitUpdate(
            runUpdater: { operation in
                operations.append(operation)
                return operation == .installPrepared ? .report(stillReady) : .report(prepared)
            },
            validatePreparedBinary: { _ in .valid(preparedPath) },
            repairLauncher: { path in
                repairedPaths.append(path)
                return CodexVersionChecker.CodexCLIRepairResult(
                    attempted: true,
                    success: true,
                    message: "must not run"
                )
            },
            installedVersionProvider: { version }
        )

        #expect(operations == [.status, .check(force: true), .installPrepared])
        #expect(repairedPaths.isEmpty)
        #expect(deferred.outcome.success == false)
        #expect(deferred.outcome.message.contains("did not install"))
    }

    @Test("Explicit Update recovers an interrupted macOS activation before metadata checks")
    func explicitUpdateRecoversInterruptedMacOSActivation() throws {
        let version = "0.145.0"
        let preparedPath = "/Users/test/.local/share/codexswitch/prepared-codex/0.145.0/0123456789abcdef0123456789abcdef/codex"
        let interrupted = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "installing",
                summary: "interrupted macOS activation is journaled",
                latestVersion: version,
                installedVersion: "0.144.1",
                preparedVersion: version,
                preparedBinaryPath: preparedPath
            )
        )
        let installed = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "installed",
                summary: "recovered and installed Codex \(version)",
                latestVersion: version,
                installedVersion: version
            )
        )
        var operations: [CodexVersionChecker.CodexUpdaterOperation] = []
        var recoveryFinished = false
        var validationCalls = 0
        var repairedPaths: [String] = []

        let result = CodexVersionChecker.performExplicitUpdate(
            runUpdater: { operation in
                operations.append(operation)
                switch operation {
                case .status:
                    return .report(interrupted)
                case .installPrepared:
                    recoveryFinished = true
                    return .report(installed)
                case .check:
                    return .failure("metadata check must not run before journal recovery")
                }
            },
            validatePreparedBinary: { report in
                #expect(recoveryFinished)
                #expect(report.status == .installing)
                validationCalls += 1
                return .valid(preparedPath)
            },
            repairLauncher: { path in
                repairedPaths.append(path)
                return CodexVersionChecker.CodexCLIRepairResult(
                    attempted: true,
                    success: true,
                    message: "launchers verified"
                )
            },
            installedVersionProvider: { version }
        )

        #expect(operations == [.status, .installPrepared])
        #expect(validationCalls == 2)
        #expect(repairedPaths == [preparedPath])
        #expect(result.outcome.success)
        #expect(result.outcome.installedVersion == version)
    }

    @Test("Explicit Update defers when the native macOS activation owner is still live")
    func explicitUpdateDefersForLiveMacOSActivationOwner() throws {
        let interrupted = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "installing",
                summary: "macOS activation is still owned",
                latestVersion: "0.145.0",
                installedVersion: "0.144.1",
                preparedVersion: "0.145.0",
                preparedBinaryPath: "/Users/test/.local/share/codexswitch/prepared-codex/0.145.0/0123456789abcdef0123456789abcdef/codex"
            )
        )
        var operations: [CodexVersionChecker.CodexUpdaterOperation] = []
        var validationCalled = false
        var repairCalled = false

        let result = CodexVersionChecker.performExplicitUpdate(
            runUpdater: { operation in
                operations.append(operation)
                return .report(interrupted)
            },
            validatePreparedBinary: { _ in
                validationCalled = true
                return .invalid("must not validate a live transaction")
            },
            repairLauncher: { _ in
                repairCalled = true
                return CodexVersionChecker.CodexCLIRepairResult(
                    attempted: true,
                    success: true,
                    message: "must not run"
                )
            }
        )

        #expect(operations == [.status, .installPrepared])
        #expect(!validationCalled)
        #expect(!repairCalled)
        #expect(!result.outcome.success)
        #expect(result.outcome.message.contains("status: installing"))
    }

    @Test("Explicit Update recovers an activation that becomes installing during preparation")
    func explicitUpdateRecoversPreparationRace() throws {
        let version = "0.145.0"
        let preparedPath = "/Users/test/.local/share/codexswitch/prepared-codex/0.145.0/0123456789abcdef0123456789abcdef/codex"
        let idle = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "idle",
                summary: "no operation owns the updater",
                latestVersion: version,
                installedVersion: "0.144.1"
            )
        )
        let interrupted = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "installing",
                summary: "activation interrupted during preparation",
                latestVersion: version,
                installedVersion: "0.144.1",
                preparedVersion: version,
                preparedBinaryPath: preparedPath
            )
        )
        let installed = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "installed",
                summary: "recovered Codex \(version)",
                latestVersion: version,
                installedVersion: version
            )
        )
        var operations: [CodexVersionChecker.CodexUpdaterOperation] = []

        let result = CodexVersionChecker.performExplicitUpdate(
            runUpdater: { operation in
                operations.append(operation)
                switch operation {
                case .status:
                    return .report(idle)
                case .check(force: true):
                    return .report(interrupted)
                case .installPrepared:
                    return .report(installed)
                case .check(force: false):
                    return .failure("unexpected automatic check")
                }
            },
            validatePreparedBinary: { _ in .valid(preparedPath) },
            repairLauncher: { _ in
                CodexVersionChecker.CodexCLIRepairResult(
                    attempted: true,
                    success: true,
                    message: "launchers verified"
                )
            },
            installedVersionProvider: { version }
        )

        #expect(operations == [.status, .check(force: true), .installPrepared])
        #expect(result.outcome.success)
    }

    @Test("Automatic update scheduling throttles checks and backs off failures")
    func automaticUpdateSchedulingHonorsCadenceAndFailureBackoff() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(CodexVersionChecker.automaticUpdateShouldStart(
            now: now,
            lastAttemptAt: nil,
            lastFailureAt: nil,
            isInFlight: false
        ))
        #expect(!CodexVersionChecker.automaticUpdateShouldStart(
            now: now,
            lastAttemptAt: now.addingTimeInterval(-14 * 60),
            lastFailureAt: nil,
            isInFlight: false
        ))
        #expect(CodexVersionChecker.automaticUpdateShouldStart(
            now: now,
            lastAttemptAt: now.addingTimeInterval(-15 * 60),
            lastFailureAt: nil,
            isInFlight: false
        ))
        #expect(!CodexVersionChecker.automaticUpdateShouldStart(
            now: now,
            lastAttemptAt: now.addingTimeInterval(-24 * 60 * 60),
            lastFailureAt: now.addingTimeInterval(-(6 * 60 * 60) + 1),
            isInFlight: false
        ))
        #expect(CodexVersionChecker.automaticUpdateShouldStart(
            now: now,
            lastAttemptAt: now.addingTimeInterval(-24 * 60 * 60),
            lastFailureAt: now.addingTimeInterval(-6 * 60 * 60),
            isInFlight: false
        ))
        #expect(!CodexVersionChecker.automaticUpdateShouldStart(
            now: now,
            lastAttemptAt: nil,
            lastFailureAt: nil,
            isInFlight: true
        ))

        #expect(!CodexVersionChecker.automaticUpdateShouldStart(
            now: now,
            lastAttemptAt: now.addingTimeInterval(-(5 * 60) + 1),
            lastFailureAt: nil,
            isInFlight: false,
            runtimeRepairRequired: true
        ))
        #expect(CodexVersionChecker.automaticUpdateShouldStart(
            now: now,
            lastAttemptAt: now.addingTimeInterval(-5 * 60),
            lastFailureAt: now.addingTimeInterval(-5 * 60),
            isInFlight: false,
            runtimeRepairRequired: true
        ))
        #expect(!CodexVersionChecker.automaticUpdateShouldStart(
            now: now,
            lastAttemptAt: now.addingTimeInterval(-24 * 60 * 60),
            lastFailureAt: now.addingTimeInterval(-(5 * 60) + 1),
            isInFlight: false,
            runtimeRepairRequired: true
        ))
    }

    @Test("Updater report decodes Rust camelCase fields")
    func updaterReportDecodesRustCamelCaseFields() throws {
        let report = try CodexVersionChecker.decodeUpdaterReport(
            Data(
                """
                {
                  "status": "ready_to_install",
                  "summary": "patched Codex 0.144.1 is ready",
                  "lastCheckedAt": "2026-07-12T12:00:00Z",
                  "latestStableVersion": "0.144.1",
                  "installedVersion": "0.143.0",
                  "preparedVersion": "0.144.1",
                  "preparedSourcePath": "/tmp/source",
                  "preparedBinaryPath": "/tmp/prepared/codex",
                  "installCommand": "codexswitch-cli install-prepared-codex",
                  "error": null
                }
                """.utf8
            )
        )

        #expect(report.status == .readyToInstall)
        #expect(report.latestStableVersion == "0.144.1")
        #expect(report.installedVersion == "0.143.0")
        #expect(report.preparedVersion == "0.144.1")
        #expect(report.preparedBinaryPath == "/tmp/prepared/codex")
        #expect(report.installCommand == "codexswitch-cli install-prepared-codex")
    }

    @Test("Updater subprocess and report failures stay terminal")
    func updaterSubprocessAndReportFailuresStayTerminal() {
        let command = CodexVersionChecker.updaterCommand(
            for: .installPrepared,
            executablePath: "/Users/test/.local/bin/codexswitch-cli"
        )
        let timedOut = CodexVersionChecker.interpretUpdaterResult(
            ProcessRunResult(
                terminationStatus: 15,
                stdout: Data(),
                stderr: Data(),
                timedOut: true
            ),
            command: command
        )
        let failed = CodexVersionChecker.interpretUpdaterResult(
            ProcessRunResult(
                terminationStatus: 7,
                stdout: Data(),
                stderr: Data("build failed".utf8),
                timedOut: false
            ),
            command: command
        )
        let malformed = CodexVersionChecker.interpretUpdaterResult(
            ProcessRunResult(
                terminationStatus: 0,
                stdout: Data("not-json".utf8),
                stderr: Data(),
                timedOut: false
            ),
            command: command
        )
        let failedReport = CodexVersionChecker.interpretUpdaterResult(
            ProcessRunResult(
                terminationStatus: 0,
                stdout: Self.reportData(
                    status: "failed",
                    summary: "update failed",
                    latestVersion: "0.144.1",
                    installedVersion: "0.143.0",
                    error: "patch validation failed"
                ),
                stderr: Data(),
                timedOut: false
            ),
            command: command
        )

        #expect(timedOut == .failure("install-prepared-codex timed out after 600 seconds"))
        #expect(failed == .failure("install-prepared-codex exited with status 7: build failed"))
        guard case .failure(let malformedMessage) = malformed else {
            Issue.record("Malformed JSON unexpectedly succeeded")
            return
        }
        #expect(malformedMessage.contains("returned invalid JSON"))
        #expect(failedReport == .failure("patch validation failed"))
    }

    @Test("Only repaired and independently verified installed reports succeed")
    func onlyRepairedAndIndependentlyVerifiedInstalledReportsSucceed() throws {
        let repairSuccess = CodexVersionChecker.CodexCLIRepairResult(
            attempted: true,
            success: true,
            message: "launchers repaired"
        )
        let repairFailure = CodexVersionChecker.CodexCLIRepairResult(
            attempted: true,
            success: false,
            message: "Homebrew bridge write failed"
        )
        let staged = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "ready_to_install",
                summary: "patched Codex is prepared",
                latestVersion: "0.144.1",
                installedVersion: "0.143.0",
                preparedVersion: "0.144.1"
            )
        )
        let installed = try CodexVersionChecker.decodeUpdaterReport(
            Self.reportData(
                status: "installed",
                summary: "installed Codex 0.144.1",
                latestVersion: "0.144.1",
                installedVersion: "0.144.1"
            )
        )

        let stagedOutcome = CodexVersionChecker.verifiedUpdateOutcome(
            report: staged,
            launcherRepair: repairSuccess,
            installedHotSwapVersion: "0.144.1"
        )
        let launcherFailure = CodexVersionChecker.verifiedUpdateOutcome(
            report: installed,
            launcherRepair: repairFailure,
            installedHotSwapVersion: "0.144.1"
        )
        let mismatch = CodexVersionChecker.verifiedUpdateOutcome(
            report: installed,
            launcherRepair: repairSuccess,
            installedHotSwapVersion: "0.143.0"
        )
        let verified = CodexVersionChecker.verifiedUpdateOutcome(
            report: installed,
            launcherRepair: repairSuccess,
            installedHotSwapVersion: "0.144.1"
        )

        #expect(stagedOutcome.success == false)
        #expect(stagedOutcome.installedVersion == nil)
        #expect(stagedOutcome.message.contains("did not install"))
        #expect(launcherFailure.success == false)
        #expect(launcherFailure.installedVersion == nil)
        #expect(launcherFailure.message.contains("could not verify the journaled launcher route"))
        #expect(mismatch.success == false)
        #expect(mismatch.installedVersion == nil)
        #expect(mismatch.message.contains("reported v0.144.1"))
        #expect(mismatch.message.contains("verifies v0.143.0"))
        #expect(verified.success)
        #expect(verified.installedVersion == "0.144.1")
        #expect(verified.message == "Installed and verified Codex hot-swap runtime v0.144.1")
    }

    @Test("Updater CLI availability rejects scripts and missing paths")
    func updaterCLIAvailabilityRejectsScriptsAndMissingPaths() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "codexswitch-updater-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let native = try writeSyntheticMachOExecutable(at: root.appending(path: "native"))
        let script = try writeForwardingWrapper(at: root.appending(path: "script"))

        #expect(CodexVersionChecker.updaterCLIIsNativeExecutable(at: native.path))
        #expect(CodexVersionChecker.updaterCLIIsNativeExecutable(at: script.path) == false)
        #expect(
            CodexVersionChecker.updaterCLIIsNativeExecutable(
                at: root.appending(path: "missing/codexswitch-cli").path
            ) == false
        )
    }

    @Test("Installed route requires exact generated launchers with matching targets")
    func installedRouteRequiresExactGeneratedLauncherTargets() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "codexswitch-routes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let local = root.appending(path: "local-codex")
        let bridge = root.appending(path: "homebrew-codex")
        let managed = root.appending(path: "managed/codex")
        let otherManaged = root.appending(path: "other-managed/codex")
        let target = root.appending(path: "prepared/codex").path
        try FileManager.default.createDirectory(
            at: managed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.rustManagedLauncherScript(patchedBinary: target).write(
            to: managed,
            atomically: true,
            encoding: .utf8
        )

        try Self.rustBridgeLauncherScript(managedLauncher: managed.path).write(
            to: local,
            atomically: true,
            encoding: .utf8
        )
        try Self.rustBridgeLauncherScript(managedLauncher: otherManaged.path).write(
            to: bridge,
            atomically: true,
            encoding: .utf8
        )
        #expect(
            CodexVersionChecker.routedHotSwapBinaryPath(
                localLauncherPath: local.path,
                homebrewBridgePath: bridge.path
            ) == nil
        )

        try Self.rustBridgeLauncherScript(managedLauncher: managed.path).write(
            to: bridge,
            atomically: true,
            encoding: .utf8
        )
        #expect(
            CodexVersionChecker.routedHotSwapBinaryPath(
                localLauncherPath: local.path,
                homebrewBridgePath: bridge.path
            ) == (target as NSString).standardizingPath
        )
        #expect(
            CodexVersionChecker.managedRuntimeRoute(
                localLauncherPath: local.path,
                homebrewBridgePath: bridge.path
            ) == CodexVersionChecker.ManagedRuntimeRoute(
                managedLauncherPath: managed.path,
                runtimePath: (target as NSString).standardizingPath,
                helperPath: root.appending(path: "prepared/codex-code-mode-host").path,
                runtimeSHA256: String(repeating: "a", count: 64),
                helperSHA256: String(repeating: "b", count: 64)
            )
        )
    }

    @Test("Launcher target parsing accepts only the exact generated grammar")
    func launcherTargetParsingRequiresExactGeneratedGrammar() {
        let runtime = "/tmp/prepared-codex/0.144.1/0123456789abcdef0123456789abcdef/codex"
        let managed = "/tmp/managed/codex"
        let validManaged = Self.rustManagedLauncherScript(patchedBinary: runtime)
        let validBridge = Self.rustBridgeLauncherScript(managedLauncher: managed)

        #expect(
            CodexVersionChecker.launcherPatchedCodexTarget(
                from: "#!/bin/bash\nexec '/tmp/prepared-codex/0.144.1/codex' \"$@\"\n"
            ) == nil
        )
        #expect(
            CodexVersionChecker.launcherPatchedCodexTarget(
                from: "#!/bin/bash\nPATCHED_CODEX='/tmp/prepared-codex/0.144.1/codex'\n"
            ) == nil
        )
        #expect(
            CodexVersionChecker.launcherManagedCodexTarget(
                from: "#!/bin/bash\nMANAGED_CODEX='/tmp/managed/codex'\n"
            ) == nil
        )
        #expect(CodexVersionChecker.launcherPatchedCodexTarget(from: validManaged) == runtime)
        #expect(CodexVersionChecker.launcherManagedCodexTarget(from: validBridge) == managed)
    }

    @Test("Launcher grammar rejects malicious commands and fallback execution")
    func launcherGrammarRejectsExtraCommandsAndFallbacks() {
        let runtime = "/tmp/prepared-codex/0.144.1/0123456789abcdef0123456789abcdef/codex"
        let managed = "/tmp/managed/codex"
        let validManaged = Self.rustManagedLauncherScript(patchedBinary: runtime)
        let validBridge = Self.rustBridgeLauncherScript(managedLauncher: managed)
        let managedWithExtraCommand = validManaged + "touch /tmp/launcher-owned\n"
        let bridgeWithExtraCommand = validBridge + "printf compromised\n"
        let managedWithFallback = validManaged.replacingOccurrences(
            of: "echo \"codex: local runtime failed complete provenance/hot-swap validation at $PATCHED_CODEX; run 'codexswitch-cli codex-update-status' and explicitly prepare/install a verified runtime\" >&2\nexit 1\n",
            with: "exec /usr/bin/codex \"$@\"\n"
        )
        let bridgeWithFallback = validBridge.replacingOccurrences(
            of: "exec \"$MANAGED_CODEX\" \"$@\"\n",
            with: "exec /opt/homebrew/bin/codex \"$@\"\n"
        )

        #expect(CodexVersionChecker.launcherPatchedCodexTarget(from: managedWithExtraCommand) == nil)
        #expect(CodexVersionChecker.launcherManagedCodexTarget(from: bridgeWithExtraCommand) == nil)
        #expect(CodexVersionChecker.launcherPatchedCodexTarget(from: managedWithFallback) == nil)
        #expect(CodexVersionChecker.launcherManagedCodexTarget(from: bridgeWithFallback) == nil)
        #expect(
            CodexVersionChecker.launcherManagedCodexTarget(
                from: "MANAGED_CODEX='/one'\nMANAGED_CODEX='/two'\n"
            ) == nil
        )
    }

    @Test("SIGHUP support requires the complete convergence v3 marker contract")
    func sighupSupportRequiresCompleteConvergenceV3Markers() {
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
            ) == false
        )
        #expect(
            CodexVersionChecker.binaryHasSighupSupportData(
                Data("abc sighup-verified xyz SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit CodexSwitch rotated accounts after an auth failure Auth changed, opening new WebSocket with fresh credentials CodexSwitch account/updated frontend write acknowledged after auth reload".utf8)
            ) == false
        )
        #expect(
            CodexVersionChecker.binaryHasSighupSupportData(
                Data("abc sighup-verified xyz SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit CodexSwitch rotated accounts after an auth failure Auth changed, opening new WebSocket with fresh credentials codexswitch-runtime-convergence-v3 codexswitch-runtime-rotation-handoff-v1 CodexSwitch account/updated frontend write acknowledged after auth reload codexswitch-hotswap-contract-v3".utf8)
            ) == false
        )
        #expect(
            CodexVersionChecker.binaryHasSighupSupportData(
                Data("abc sighup-verified xyz SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit CodexSwitch rotated accounts after an auth failure Auth changed, opening new WebSocket with fresh credentials codexswitch-runtime-convergence-v3 codexswitch-runtime-rotation-handoff-v1 CodexSwitch account/updated frontend write acknowledged after auth reload codexswitch-hotswap-contract-v3 codexswitch-hotswap-cli-contract-v3".utf8)
            )
        )
    }

    @Test("Every convergence v3 marker is mandatory")
    func everyConvergenceV3MarkerIsMandatory() {
        let required = [
            "sighup-verified",
            "SIGHUP: auth reloaded",
            "hotswap-ack",
            "CodexSwitch rotated accounts after a usage limit",
            "CodexSwitch rotated accounts after an auth failure",
            "Auth changed, opening new WebSocket with fresh credentials",
            "codexswitch-runtime-convergence-v3",
            "codexswitch-runtime-rotation-handoff-v1",
            "CodexSwitch account/updated frontend write acknowledged after auth reload",
            "codexswitch-hotswap-contract-v3",
            "codexswitch-hotswap-cli-contract-v3",
        ]

        for marker in required {
            let incomplete = Self.completeHotSwapMarkers.replacingOccurrences(
                of: marker,
                with: "missing-marker"
            )
            #expect(!CodexVersionChecker.binaryHasSighupSupportData(Data(incomplete.utf8)))
        }
    }

    @Test("Goal support marker accepts slash command or app-server goal RPC markers")
    func goalSupportMarkerAcceptsSlashCommandOrAppServerGoalRPCMarkers() {
        #expect(CodexVersionChecker.binaryHasGoalSupportData(Data("Usage: /goal <objective>".utf8)))
        #expect(CodexVersionChecker.binaryHasGoalSupportData(Data("Pursuing goal thread/goal/set".utf8)))
        #expect(CodexVersionChecker.binaryHasGoalSupportData(Data("Pursuing goal".utf8)) == false)
    }

    @Test("Local hot-swap structural validation rejects forwarding shell wrappers")
    func localHotSwapStructuralValidationRejectsForwardingShellWrappers() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "codexswitch-wrapper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapper = try writeForwardingWrapper(at: root)
        try writeCompanion(at: root, executable: true)
        let data = try Data(contentsOf: wrapper)

        #expect(CodexVersionChecker.binaryHasSighupSupportData(data))
        #expect(CodexVersionChecker.binaryHasGoalSupportData(data))
        #expect(CodexVersionChecker.binaryIsMachOExecutableData(data) == false)
        #expect(CodexVersionChecker.localHotSwapUnitIsStructurallyValid(at: wrapper.path) == false)
    }

    @Test("Local hot-swap structural validation requires an executable code-mode companion")
    func localHotSwapStructuralValidationRequiresExecutableCodeModeCompanion() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "codexswitch-companion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let binary = try writeSyntheticMachOExecutable(at: root)
        let data = try Data(contentsOf: binary)

        #expect(CodexVersionChecker.binaryIsMachOExecutableData(data))
        #expect(CodexVersionChecker.localHotSwapUnitIsStructurallyValid(at: binary.path) == false)

        try writeCompanion(at: root, executable: false)
        #expect(CodexVersionChecker.localHotSwapUnitIsStructurallyValid(at: binary.path) == false)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: root.appending(path: "codex-code-mode-host").path
        )
        #expect(CodexVersionChecker.localHotSwapUnitIsStructurallyValid(at: binary.path))
    }

    @Test("Runtime marker scan handles chunk boundaries without loading the whole binary")
    func runtimeMarkerScanHandlesChunkBoundaries() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "codexswitch-streaming-markers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let binary = try writeSyntheticMachOExecutable(at: root)
        #expect(CodexVersionChecker.binaryFileHasRequiredRuntimeMarkers(at: binary.path, chunkSize: 17))

        let incomplete = Self.completeHotSwapMarkers.replacingOccurrences(
            of: "codexswitch-hotswap-contract-v3",
            with: "missing-contract"
        )
        _ = try writeSyntheticMachOExecutable(at: root, markers: incomplete)
        #expect(!CodexVersionChecker.binaryFileHasRequiredRuntimeMarkers(at: binary.path, chunkSize: 17))
    }

    private static func rustBridgeLauncherScript(managedLauncher: String) -> String {
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

    private static func rustManagedLauncherScript(patchedBinary: String) -> String {
        let helper = URL(fileURLWithPath: patchedBinary)
            .deletingLastPathComponent()
            .appending(path: "codex-code-mode-host")
            .path
        return [
            "#!/usr/bin/env bash",
            "\tset -euo pipefail",
            "\tPATCHED_CODEX='\(patchedBinary)'",
            "\tPATCHED_HELPER='\(helper)'",
            "\tEXPECTED_CODEX_SHA256='\(String(repeating: "a", count: 64))'",
            "\tEXPECTED_HELPER_SHA256='\(String(repeating: "b", count: 64))'",
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

    private func writeForwardingWrapper(at root: URL, sentinel: URL? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appending(path: "codex")
        let sentinelCommand = sentinel.map { #": > "\#($0.path)""# } ?? ":"
        try """
        #!/bin/sh
        # \(Self.completeHotSwapMarkers)
        \(sentinelCommand)
        echo 'codex-cli 0.144.1'
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    private func writeRecordingExecutable(at url: URL, label: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        printf '%s:%s\\n' '\(label)' "$*"
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func writeSyntheticMachOExecutable(
        at root: URL,
        markers: String = Self.completeHotSwapMarkers
    ) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appending(path: "codex")
        var data = Data([
            0xCF, 0xFA, 0xED, 0xFE,
            0x0C, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])
        data.append(Data(markers.utf8))
        try data.write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    private func writeCompanion(at root: URL, executable: Bool) throws {
        let companion = root.appending(path: "codex-code-mode-host")
        try Data().write(to: companion)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: companion.path
        )
    }

    private static func reportData(
        status: String,
        summary: String,
        latestVersion: String?,
        installedVersion: String?,
        preparedVersion: String? = nil,
        preparedBinaryPath: String? = nil,
        installCommand: String? = nil,
        error: String? = nil
    ) -> Data {
        var report: [String: Any] = [
            "status": status,
            "summary": summary,
        ]
        report["latestStableVersion"] = latestVersion ?? NSNull()
        report["installedVersion"] = installedVersion ?? NSNull()
        report["preparedVersion"] = preparedVersion ?? NSNull()
        report["preparedBinaryPath"] = preparedBinaryPath ?? NSNull()
        report["installCommand"] = installCommand ?? NSNull()
        report["error"] = error ?? NSNull()
        return try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    }

    private static let completeHotSwapMarkers = "sighup-verified SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit CodexSwitch rotated accounts after an auth failure Auth changed, opening new WebSocket with fresh credentials codexswitch-runtime-convergence-v3 codexswitch-runtime-rotation-handoff-v1 CodexSwitch account/updated frontend write acknowledged after auth reload codexswitch-hotswap-contract-v3 codexswitch-hotswap-cli-contract-v3 Usage: /goal <objective>"
}
