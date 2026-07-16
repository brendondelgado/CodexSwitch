import Darwin
import Foundation

protocol DesktopApplicationRuntimeObserving {
    func isRunning() -> Bool
}

struct DesktopClosureRuntimeObserver: DesktopApplicationRuntimeObserving {
    let observation: () -> Bool

    func isRunning() -> Bool { observation() }
}

enum DesktopStockRestoreSafety {
    static func performIfRuntimeStopped<Result>(
        observer: DesktopApplicationRuntimeObserving,
        operation: () throws -> Result
    ) rethrows -> Result? {
        guard !observer.isRunning() else { return nil }
        return try operation()
    }
}

enum CodexDesktopAppUpdater {
    private static let stateMachine = CodexDesktopUpdateStateMachine()
    private static let appcastURL = URL(
        string: "https://persistent.oaistatic.com/codex-app-prod/appcast.xml"
    )!
    private static let updateRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codexswitch")
        .appendingPathComponent("desktop-updates", isDirectory: true)
    private static let appcastCache = updateRoot.appendingPathComponent("appcast-cache.json")
    private static let trustValidator = DesktopBundleTrustValidator()
    private static let processRunner = DesktopUpdaterProcessRunner()
    private static let runtimeGate = DesktopUpdateRuntimeGate(processRunner: processRunner)
    private static let allowedDestinations = [
        URL(fileURLWithPath: "/Applications/ChatGPT.app"),
        URL(fileURLWithPath: "/Applications/Codex.app"),
    ]
    private static let operationLeaseURL = CodexDesktopPathSecurity
        .canonicalSystemTemporaryDirectory()
        .appendingPathComponent("com.codexswitch.desktop-update-\(getuid()).lock")
    private static let operationOwner = DesktopUpdateOperationOwner(
        stateMachine: stateMachine,
        leaseURL: operationLeaseURL,
        updateRoot: updateRoot,
        allowedDestinations: allowedDestinations
    )

    static func latestRelease(
        epoch: DesktopUpdateRunEpoch = .standalone()
    ) async -> CodexDesktopAppRelease? {
        guard case .acquired(let lifetime) = await operationOwner.acquire(
            .checking,
            epoch: epoch
        ) else { return nil }
        let result: CodexDesktopAppRelease?
        do {
            try lifetime.enter(.appcast)
            let release = try await makeAppcastClient().fetchLatestRelease()
            try Task.checkCancellation()
            try lifetime.mutationAuthority.requireCurrent()
            result = release
        } catch {
            result = nil
        }
        await finishOperation(lifetime)
        return result
    }

    static func transactionState() async -> CodexDesktopInstallationTransactionState {
        await stateMachine.transactionState()
    }

    static func applicationsDirectoryChangeDisposition() async
        -> CodexDesktopApplicationsChangeDisposition {
        await stateMachine.applicationsDirectoryChangeDisposition()
    }

    static func isReleaseNewer(bundleVersion: String, than installedBundleVersion: String) -> Bool {
        DesktopUpdateVersionPolicy.isReleaseNewer(
            bundleVersion: bundleVersion,
            than: installedBundleVersion
        )
    }

    static func versionDisposition(
        release: CodexDesktopAppRelease,
        installed: CodexDesktopAppInstall
    ) -> CodexDesktopVersionDisposition {
        DesktopUpdateVersionPolicy.disposition(release: release, installed: installed)
    }

    static func releaseMetadataMatches(
        _ release: CodexDesktopAppRelease,
        install: CodexDesktopAppInstall
    ) -> Bool {
        DesktopUpdateDownloader.metadataMatches(release, install: install)
    }

    static func installDecision(
        stagedBundleVersion: String,
        installedBundleVersion: String?,
        desktopRuntimeRunning: Bool
    ) -> CodexDesktopStagedInstallDecision {
        if let installedBundleVersion,
           !isReleaseNewer(
               bundleVersion: stagedBundleVersion,
               than: installedBundleVersion
           ) {
            return .discard
        }
        return desktopRuntimeRunning ? .waitForDesktopQuit : .install
    }

    static func hasEnoughDiskSpace(availableBytes: Int64) -> Bool {
        DesktopUpdateDownloader.hasEnoughDiskSpace(availableBytes: availableBytes)
    }

    static func cleanupUpdateStorage(
        now: Date = Date(),
        epoch: DesktopUpdateRunEpoch = .standalone()
    ) async throws -> CodexDesktopUpdateStorageCleanupReport {
        let acquisition = await operationOwner.acquire(.maintainingStorage, epoch: epoch)
        guard case .acquired(let lifetime) = acquisition else {
            throw operationError(acquisition, cancelledMessage: "Desktop cleanup was cancelled")
        }
        let result: Result<CodexDesktopUpdateStorageCleanupReport, Error>
        do {
            try lifetime.enter(.retention)
            result = .success(
                try CodexDesktopUpdateStorage.cleanupNonAuthoritativeArtifacts(
                    in: updateRoot,
                    installedBundleVersion: CodexDesktopAppLocator.locate()?.bundleVersion,
                    now: now,
                    isCancelled: { operationIsCancelled(lifetime) }
                )
            )
        } catch {
            result = .failure(error)
        }
        await finishOperation(lifetime)
        return try result.get()
    }

    static func recoverInterruptedInstall(
        epoch: DesktopUpdateRunEpoch = .standalone()
    ) async throws -> DesktopInstallRecoveryResult {
        let acquisition = await operationOwner.acquire(.recovering, epoch: epoch)
        guard case .acquired(let lifetime) = acquisition else {
            throw operationError(acquisition, cancelledMessage: "Desktop recovery was cancelled")
        }
        let result: Result<DesktopInstallRecoveryResult, Error>
        do {
            result = .success(
                try performInstallRecoveryHoldingLifetime(
                    lifetime: lifetime,
                    installer: makeInstaller(),
                    desktopRuntimeRunning: desktopRuntimeIsRunning,
                    validateOfficialBundle: { candidate, bundleVersion, shortVersion,
                            isCancelled in
                        trustValidator.validate(
                            appURL: candidate,
                            expectedBundleVersion: bundleVersion,
                            expectedShortVersion: shortVersion,
                            isCancelled: isCancelled
                        )
                    }
                )
            )
        } catch {
            result = .failure(error)
        }
        await finishOperation(lifetime)
        return try result.get()
    }

    static func performInstallRecoveryHoldingLifetime(
        lifetime: DesktopUpdateOperationLifetime,
        installer: DesktopBundleInstaller,
        desktopRuntimeRunning: () -> Bool,
        validateOfficialBundle: (
            URL,
            String,
            String,
            () -> Bool
        ) -> CodexDesktopBundleValidationResult
    ) throws -> DesktopInstallRecoveryResult {
        try lifetime.enter(.recovery)
        return try installer.recover(
            lifetime: lifetime,
            desktopRuntimeRunning: desktopRuntimeRunning,
            isCancelled: { operationIsCancelled(lifetime) },
            validate: validateOfficialBundle
        )
    }

    static func stageLatestUpdateIfNeeded(
        epoch: DesktopUpdateRunEpoch = .standalone()
    ) async -> CodexDesktopUpdatePreparationResult {
        let acquisition = await operationOwner.acquire(.staging, epoch: epoch)
        guard case .acquired(let lifetime) = acquisition else {
            return preparationResult(for: acquisition)
        }
        let result: CodexDesktopUpdatePreparationResult
        do {
            try lifetime.enter(.appcast)
            let release = try await makeAppcastClient().fetchLatestRelease()
            try lifetime.mutationAuthority.requireCurrent()
            let service = DesktopUpdateStagingService(root: updateRoot)
            result = await service.prepare(
                release: release,
                installed: CodexDesktopAppLocator.locate(),
                lifetime: lifetime,
                isCancelled: { operationIsCancelled(lifetime) },
                fullValidation: validateOfficialBundle,
                download: {
                    try lifetime.enter(.download)
                    return try await downloadGeneration(release, lifetime: lifetime)
                }
            )
        } catch is CancellationError {
            result = .deferred("Desktop update check was cancelled")
        } catch {
            result = .failed(error.localizedDescription)
        }
        await finishOperation(lifetime)
        return result
    }

    static func installStagedUpdateIfReady(
        epoch: DesktopUpdateRunEpoch = .standalone()
    ) async -> CodexDesktopStagedInstallResult {
        let acquisition = await operationOwner.acquire(.installingStagedUpdate, epoch: epoch)
        guard case .acquired(let lifetime) = acquisition else {
            return stagedInstallResult(for: acquisition)
        }
        let result = await installStagedUpdateHoldingLifetime(lifetime)
        await finishOperation(lifetime)
        return result
    }

    static func assumeNativeUpdateOwnership(
        defaultsProvider: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) -> CodexDesktopNativeUpdateOwnershipLease {
        CodexDesktopNativeUpdateOwnershipLease.acquire(defaultsProvider: defaultsProvider)
    }

    static func installLatestStock(
        _ release: CodexDesktopAppRelease,
        epoch: DesktopUpdateRunEpoch = .standalone()
    ) async -> CodexDesktopAppUpdateResult {
        let acquisition = await operationOwner.acquire(.restoringStock, epoch: epoch)
        guard case .acquired(let lifetime) = acquisition else {
            return CodexDesktopAppUpdateResult(
                success: false,
                message: operationMessage(
                    acquisition,
                    cancelledMessage: "Desktop stock restore was cancelled"
                )
            )
        }
        let result = await installLatestStockHoldingLifetime(release, lifetime: lifetime)
        await finishOperation(lifetime)
        return result
    }

    static func findDesktopApp(in root: URL) -> URL? {
        DesktopUpdateDownloader.findDesktopApp(in: root)
    }

    static func installationPath(for extractedApp: URL) -> String {
        "/Applications/\(extractedApp.lastPathComponent)"
    }

    private static func installStagedUpdateHoldingLifetime(
        _ lifetime: DesktopUpdateOperationLifetime
    ) async -> CodexDesktopStagedInstallResult {
        await performStagedInstallHoldingLifetime(
            lifetime,
            updateRoot: updateRoot,
            stateMachine: stateMachine,
            locateInstalled: { CodexDesktopAppLocator.locate() },
            installer: makeInstaller(),
            desktopRuntimeRunning: desktopRuntimeIsRunning,
            validateOfficialBundle: { candidate, bundleVersion, shortVersion, isCancelled in
                trustValidator.validate(
                    appURL: candidate,
                    expectedBundleVersion: bundleVersion,
                    expectedShortVersion: shortVersion,
                    isCancelled: isCancelled
                )
            }
        )
    }

    static func performStagedInstallHoldingLifetime(
        _ lifetime: DesktopUpdateOperationLifetime,
        updateRoot: URL,
        stateMachine: CodexDesktopUpdateStateMachine,
        locateInstalled: () -> CodexDesktopAppInstall?,
        installer: DesktopBundleInstaller,
        desktopRuntimeRunning: () -> Bool,
        validateOfficialBundle: (
            URL,
            String,
            String,
            () -> Bool
        ) -> CodexDesktopBundleValidationResult
    ) async -> CodexDesktopStagedInstallResult {
        do {
            try lifetime.enter(.discovery)
        } catch {
            return .deferred(error.localizedDescription)
        }
        guard let staged = CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: updateRoot) else {
            return .none
        }
        if operationIsCancelled(lifetime) {
            return .deferred("Staged desktop installation was cancelled")
        }
        let installed = locateInstalled()
        switch installDecision(
            stagedBundleVersion: staged.bundleVersion,
            installedBundleVersion: installed?.bundleVersion,
            desktopRuntimeRunning: desktopRuntimeIsRunning()
        ) {
        case .waitForDesktopQuit:
            return .waitingForDesktopQuit(staged)
        case .discard:
            if operationIsCancelled(lifetime) {
                return .deferred("Staged desktop installation was cancelled")
            }
            CodexDesktopUpdateStorage.discardAuthoritativeUpdate(
                staged,
                in: updateRoot,
                isCancelled: { operationIsCancelled(lifetime) }
            )
            if operationIsCancelled(lifetime) {
                return .deferred("Staged desktop installation was cancelled")
            }
            return .discarded(
                "Staged desktop build \(staged.bundleVersion) is no newer than the installed build"
            )
        case .install:
            break
        }

        do {
            try lifetime.enter(.bundleVerification)
        } catch {
            return .deferred(error.localizedDescription)
        }
        let validation = validateOfficialBundle(
            URL(fileURLWithPath: staged.appPath),
            staged.bundleVersion,
            staged.shortVersion,
            { operationIsCancelled(lifetime) }
        )
        if operationIsCancelled(lifetime) || validation == .cancelled {
            return .deferred("Staged desktop installation was cancelled")
        }
        switch validation {
        case .valid:
            break
        case .unavailable(let reason):
            return .deferred(
                "Staged ChatGPT validation is temporarily unavailable; preserving it: \(reason)"
            )
        case .invalid(let reason):
            do {
                if operationIsCancelled(lifetime) {
                    return .deferred("Staged desktop installation was cancelled")
                }
                try lifetime.enter(.rejectionLedger)
                try CodexDesktopUpdateStorage.recordRejectedRelease(
                    staged.release,
                    reasonClass: DesktopBundleTrustValidator.rejectionClass(
                        for: validation
                    ) ?? .bundleStructure,
                    in: updateRoot,
                    isCancelled: { operationIsCancelled(lifetime) }
                )
                if operationIsCancelled(lifetime) {
                    return .deferred("Staged desktop installation was cancelled")
                }
                _ = try CodexDesktopUpdateStorage.quarantineAuthoritativeUpdate(
                    staged,
                    in: updateRoot,
                    isCancelled: { operationIsCancelled(lifetime) }
                )
            } catch {
                return .failed(
                    "Staged ChatGPT update is invalid (\(reason)), but quarantine failed: "
                        + error.localizedDescription
                )
            }
            return .failed("Staged ChatGPT update failed verification: \(reason)")
        case .cancelled:
            return .deferred("Staged desktop installation was cancelled")
        }

        guard !desktopRuntimeIsRunning() else {
            return .waitingForDesktopQuit(staged)
        }
        if operationIsCancelled(lifetime) {
            return .deferred("Staged desktop installation was cancelled")
        }
        do {
            try lifetime.enter(.installation)
        } catch {
            return .deferred(error.localizedDescription)
        }
        guard case .success(let transactionIdentifier) = await stateMachine
            .beginInstallationTransaction(
            for: lifetime.permit,
            kind: .stagedUpdate
        ) else {
            return .deferred("Desktop install transaction bookkeeping is inconsistent")
        }
        if operationIsCancelled(lifetime) {
            _ = await stateMachine.finishInstallationTransaction(
                identifier: transactionIdentifier,
                permit: lifetime.permit,
                committed: false
            )
            return .deferred("Staged desktop installation was cancelled")
        }

        let destinationPath = installed?.appPath
            ?? installationPath(for: URL(fileURLWithPath: staged.appPath))
        do {
            let installResult = try installer.install(
                lifetime: lifetime,
                sourceApp: URL(fileURLWithPath: staged.appPath),
                destination: URL(fileURLWithPath: destinationPath),
                expectedBundleVersion: staged.bundleVersion,
                expectedShortVersion: staged.shortVersion,
                kind: .stagedUpdate,
                desktopRuntimeRunning: desktopRuntimeIsRunning,
                isCancelled: { operationIsCancelled(lifetime) },
                validate: validateOfficialBundle
            )
            switch installResult {
            case .busy:
                _ = await finish(
                    transactionIdentifier,
                    permit: lifetime.permit,
                    committed: false,
                    kind: .stagedUpdate,
                    stateMachine: stateMachine
                )
                return .deferred("Another desktop install process holds the updater lease")
            case .runtimeRunning:
                _ = await finish(
                    transactionIdentifier,
                    permit: lifetime.permit,
                    committed: false,
                    kind: .stagedUpdate,
                    stateMachine: stateMachine
                )
                return .waitingForDesktopQuit(staged)
            case .cancelledBeforeCommit:
                _ = await finish(
                    transactionIdentifier,
                    permit: lifetime.permit,
                    committed: false,
                    kind: .stagedUpdate,
                    stateMachine: stateMachine
                )
                return .deferred("Staged desktop installation was cancelled before commit")
            case .installed(_, let cleanupPending):
                let completion = await finish(
                    transactionIdentifier,
                    permit: lifetime.permit,
                    committed: true,
                    kind: .stagedUpdate,
                    cleanupPending: cleanupPending,
                    stateMachine: stateMachine
                )
                if (try? lifetime.mutationAuthority.requireCurrent(isCancelled: { false })) != nil {
                    CodexDesktopUpdateStorage.discardAuthoritativeUpdate(
                        staged,
                        in: updateRoot,
                        isCancelled: { false }
                    )
                }
                return .installed(
                    path: destinationPath,
                    release: staged.release,
                    transaction: completion,
                    cleanupPending: cleanupPending
                )
            }
        } catch {
            _ = await finish(
                transactionIdentifier,
                permit: lifetime.permit,
                committed: false,
                kind: .stagedUpdate,
                stateMachine: stateMachine
            )
            return .failed(error.localizedDescription)
        }
    }

    private static func installLatestStockHoldingLifetime(
        _ release: CodexDesktopAppRelease,
        lifetime: DesktopUpdateOperationLifetime
    ) async -> CodexDesktopAppUpdateResult {
        do {
            try lifetime.enter(.discovery)
            let runtimeObserver = DesktopClosureRuntimeObserver {
                desktopRuntimeIsRunning()
            }
            guard DesktopStockRestoreSafety.performIfRuntimeStopped(
                observer: runtimeObserver,
                operation: { true }
            ) == true else {
                return CodexDesktopAppUpdateResult(
                    success: false,
                    message: "Desktop stock restore is waiting for ChatGPT to quit"
                )
            }
            guard release.downloadURL.scheme == "https",
                  release.downloadURL.host == "persistent.oaistatic.com" else {
                throw updateError("The official appcast returned an unexpected download host")
            }
            let currentInstall = CodexDesktopAppLocator.locate()
            try lifetime.enter(.download)
            let downloaded = try await downloadGeneration(release, lifetime: lifetime)
            defer {
                CodexDesktopUpdateStorage.discardUnreferencedGeneration(
                    downloaded,
                    in: updateRoot,
                    isCancelled: { false }
                )
            }
            try lifetime.mutationAuthority.requireCurrent()
            let downloadedURL = URL(fileURLWithPath: downloaded.appPath)
            try lifetime.enter(.bundleVerification)
            let validation = validateOfficialBundle(
                downloadedURL,
                downloaded.bundleVersion,
                downloaded.shortVersion
            )
            try lifetime.mutationAuthority.requireCurrent()
            guard validation == .valid else {
                throw updateError("Downloaded ChatGPT \(release.versionLabel) failed verification")
            }

            guard !desktopRuntimeIsRunning() else {
                return CodexDesktopAppUpdateResult(
                    success: false,
                    message: "Desktop stock restore is waiting for ChatGPT to quit"
                )
            }
            try lifetime.enter(.installation)
            guard case .success(let identifier) = await stateMachine
                .beginInstallationTransaction(
                for: lifetime.permit,
                kind: .stockRestore
            ) else {
                throw updateError("Desktop stock transaction bookkeeping is inconsistent")
            }
            if operationIsCancelled(lifetime) {
                _ = await finish(
                    identifier,
                    permit: lifetime.permit,
                    committed: false,
                    kind: .stockRestore
                )
                throw CancellationError()
            }
            let destinationPath = currentInstall?.appPath ?? installationPath(for: downloadedURL)
            do {
                let installResult = try makeInstaller().install(
                    lifetime: lifetime,
                    sourceApp: downloadedURL,
                    destination: URL(fileURLWithPath: destinationPath),
                    expectedBundleVersion: release.bundleVersion,
                    expectedShortVersion: release.shortVersion,
                    kind: .stockRestore,
                    desktopRuntimeRunning: desktopRuntimeIsRunning,
                    isCancelled: { operationIsCancelled(lifetime) },
                    validate: { candidate, bundleVersion, shortVersion, isCancelled in
                        trustValidator.validate(
                            appURL: candidate,
                            expectedBundleVersion: bundleVersion,
                            expectedShortVersion: shortVersion,
                            isCancelled: isCancelled
                        )
                    }
                )
                switch installResult {
                case .installed(_, let cleanupPending):
                    _ = await finish(
                        identifier,
                        permit: lifetime.permit,
                        committed: true,
                        kind: .stockRestore,
                        cleanupPending: cleanupPending
                    )
                    return CodexDesktopAppUpdateResult(
                        success: true,
                        message: cleanupPending
                            ? "Installed stock ChatGPT \(release.versionLabel); cleanup pending"
                            : "Installed stock ChatGPT \(release.versionLabel)",
                        cleanupPending: cleanupPending
                    )
                case .runtimeRunning:
                    _ = await finish(
                        identifier,
                        permit: lifetime.permit,
                        committed: false,
                        kind: .stockRestore
                    )
                    return CodexDesktopAppUpdateResult(
                        success: false,
                        message: "Desktop stock restore is waiting for ChatGPT to quit"
                    )
                case .busy, .cancelledBeforeCommit:
                    _ = await finish(
                        identifier,
                        permit: lifetime.permit,
                        committed: false,
                        kind: .stockRestore
                    )
                    throw updateError("Desktop stock restore was deferred: \(installResult)")
                }
            } catch {
                if case .active(let activeIdentifier, _, _) = await stateMachine.transactionState(),
                   activeIdentifier == identifier {
                    _ = await finish(
                        identifier,
                        permit: lifetime.permit,
                        committed: false,
                        kind: .stockRestore
                    )
                }
                throw error
            }
        } catch {
            return CodexDesktopAppUpdateResult(
                success: false,
                message: "Desktop update failed: \(error.localizedDescription)"
            )
        }
    }

    private static func downloadGeneration(
        _ release: CodexDesktopAppRelease,
        lifetime: DesktopUpdateOperationLifetime? = nil
    ) async throws -> CodexDesktopStagedUpdate {
        try await DesktopUpdateDownloader(
            updateRoot: updateRoot,
            processRunner: processRunner
        ).downloadGeneration(release, lifetime: lifetime)
    }

    private static func validateOfficialBundle(
        _ appURL: URL,
        _ expectedBundleVersion: String,
        _ expectedShortVersion: String
    ) -> CodexDesktopBundleValidationResult {
        trustValidator.validate(
            appURL: appURL,
            expectedBundleVersion: expectedBundleVersion,
            expectedShortVersion: expectedShortVersion,
            isCancelled: { Task.isCancelled }
        )
    }

    private static func makeAppcastClient() -> DesktopAppcastClient {
        DesktopAppcastClient(appcastURL: appcastURL, cacheURL: appcastCache)
    }

    private static func makeInstaller() -> DesktopBundleInstaller {
        DesktopBundleInstaller(
            transactionRoot: updateRoot,
            processRunner: processRunner
        )
    }

    private static func finish(
        _ identifier: UInt64,
        permit: CodexDesktopUpdateStateMachine.Permit,
        committed: Bool,
        kind: CodexDesktopInstallationTransactionKind,
        cleanupPending: Bool = false,
        stateMachine transactionStateMachine: CodexDesktopUpdateStateMachine? = nil
    ) async -> CodexDesktopInstallationTransactionCompletion {
        let transactionStateMachine = transactionStateMachine ?? stateMachine
        let result = await transactionStateMachine.finishInstallationTransaction(
            identifier: identifier,
            permit: permit,
            committed: committed,
            cleanupPending: cleanupPending
        )
        switch result {
        case .success(let completion):
            return completion
        case .failure(let error):
            SwapLog.append(
                .debug("DESKTOP_UPDATE_TRANSACTION_INCONSISTENT message=\(error.localizedDescription)")
            )
            return CodexDesktopInstallationTransactionCompletion(
                identifier: identifier,
                kind: kind,
                committed: committed,
                cleanupPending: cleanupPending
            )
        }
    }

    private static func finishOperation(_ lifetime: DesktopUpdateOperationLifetime) async {
        _ = await operationOwner.finish(lifetime)
        withExtendedLifetime(lifetime) {}
    }

    private static func operationIsCancelled(
        _ lifetime: DesktopUpdateOperationLifetime
    ) -> Bool {
        if Task.isCancelled { return true }
        return (try? lifetime.mutationAuthority.requireCurrent(isCancelled: { false })) == nil
    }

    private static func desktopRuntimeIsRunning() -> Bool {
        runtimeGate.blocksActivation()
    }

    private static func preparationResult(
        for acquisition: DesktopUpdateOperationAcquisition
    ) -> CodexDesktopUpdatePreparationResult {
        switch acquisition {
        case .cancelled: return .deferred("Desktop update check was cancelled")
        case .busy: return .deferred("Desktop updater is busy")
        case .failed(let message): return .failed(message)
        case .acquired: return .failed("Desktop updater acquisition was inconsistent")
        }
    }

    private static func stagedInstallResult(
        for acquisition: DesktopUpdateOperationAcquisition
    ) -> CodexDesktopStagedInstallResult {
        switch acquisition {
        case .cancelled: return .deferred("Staged desktop installation was cancelled")
        case .busy: return .deferred("Desktop updater is busy")
        case .failed(let message): return .failed(message)
        case .acquired: return .failed("Desktop updater acquisition was inconsistent")
        }
    }

    private static func operationMessage(
        _ acquisition: DesktopUpdateOperationAcquisition,
        cancelledMessage: String
    ) -> String {
        switch acquisition {
        case .cancelled: return cancelledMessage
        case .busy: return "Desktop updater is busy"
        case .failed(let message): return message
        case .acquired: return "Desktop updater acquisition was inconsistent"
        }
    }

    private static func operationError(
        _ acquisition: DesktopUpdateOperationAcquisition,
        cancelledMessage: String
    ) -> Error {
        switch acquisition {
        case .cancelled: return CancellationError()
        case .busy: return updateError("Desktop updater is busy")
        case .failed(let message): return updateError(message)
        case .acquired: return updateError(cancelledMessage)
        }
    }

    private static func updateError(_ message: String) -> NSError {
        NSError(
            domain: "CodexDesktopAppUpdater",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
