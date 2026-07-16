import Darwin
import Foundation

actor CodexDesktopUpdateStateMachine {
    struct Permit: Equatable, Sendable {
        fileprivate let identifier: UUID
        let operation: CodexDesktopUpdateOperation
    }

    nonisolated static let watcherCompletionGracePeriod: TimeInterval = 2
    private static let maximumSuppressedCallbacksPerTransaction = 4

    private struct ActiveInstallationTransaction {
        let identifier: UInt64
        let kind: CodexDesktopInstallationTransactionKind
        var applicationsChangeObserved = false
    }

    private struct CompletedInstallationTransaction {
        let completion: CodexDesktopInstallationTransactionCompletion
        let expiresAt: Date
        var completionDelivered = false
        var suppressedCallbackCount = 0
    }

    private var activePermit: Permit?
    private var transactionSequence: UInt64 = 0
    private var activeInstallationTransaction: ActiveInstallationTransaction?
    private var completedInstallationTransactions: [CompletedInstallationTransaction] = []

    func acquire(_ operation: CodexDesktopUpdateOperation) -> Permit? {
        guard activePermit == nil, !Task.isCancelled else { return nil }
        let permit = Permit(identifier: UUID(), operation: operation)
        activePermit = permit
        return permit
    }

    func release(_ permit: Permit) {
        _ = releaseChecked(permit)
    }

    func releaseChecked(_ permit: Permit) -> Result<Void, DesktopUpdateOwnershipError> {
        guard activePermit == permit else { return .failure(.permitMismatch) }
        activePermit = nil
        return .success(())
    }

    func currentOperation() -> CodexDesktopUpdateOperation? {
        activePermit?.operation
    }

    func queuedOperationCount() -> Int { 0 }

    func beginInstallationTransaction(
        for permit: Permit,
        kind: CodexDesktopInstallationTransactionKind
    ) -> Result<UInt64, DesktopUpdateOwnershipError> {
        guard activePermit == permit else { return .failure(.permitMismatch) }
        guard activeInstallationTransaction == nil else { return .failure(.nestedTransaction) }
        transactionSequence &+= 1
        activeInstallationTransaction = ActiveInstallationTransaction(
            identifier: transactionSequence,
            kind: kind
        )
        return .success(transactionSequence)
    }

    func finishInstallationTransaction(
        identifier: UInt64,
        permit: Permit,
        committed: Bool,
        cleanupPending: Bool = false,
        now: Date = Date()
    ) -> Result<CodexDesktopInstallationTransactionCompletion, DesktopUpdateOwnershipError> {
        guard activePermit == permit else { return .failure(.permitMismatch) }
        guard let active = activeInstallationTransaction, active.identifier == identifier else {
            return .failure(.inactiveTransaction)
        }
        let completion = CodexDesktopInstallationTransactionCompletion(
            identifier: identifier,
            kind: active.kind,
            committed: committed,
            cleanupPending: cleanupPending
        )
        activeInstallationTransaction = nil
        completedInstallationTransactions.append(
            CompletedInstallationTransaction(
                completion: completion,
                expiresAt: now.addingTimeInterval(Self.watcherCompletionGracePeriod)
            )
        )
        pruneExpiredTransactionCompletions(now: now)
        return .success(completion)
    }

    func transactionState() -> CodexDesktopInstallationTransactionState {
        guard let active = activeInstallationTransaction else { return .idle }
        return .active(
            identifier: active.identifier,
            kind: active.kind,
            applicationsChangeObserved: active.applicationsChangeObserved
        )
    }

    func applicationsDirectoryChangeDisposition(
        now: Date = Date()
    ) -> CodexDesktopApplicationsChangeDisposition {
        pruneExpiredTransactionCompletions(now: now)
        if activeInstallationTransaction != nil {
            activeInstallationTransaction?.applicationsChangeObserved = true
            return .internalTransactionChangeSuppressed(
                identifier: activeInstallationTransaction?.identifier ?? 0
            )
        }
        if let index = completedInstallationTransactions.firstIndex(where: {
            !$0.completionDelivered
        }) {
            completedInstallationTransactions[index].completionDelivered = true
            return .internalTransactionCompleted(
                completedInstallationTransactions[index].completion
            )
        }
        guard let index = completedInstallationTransactions.indices.last else {
            return .externalChange
        }
        let identifier = completedInstallationTransactions[index].completion.identifier
        completedInstallationTransactions[index].suppressedCallbackCount += 1
        if completedInstallationTransactions[index].suppressedCallbackCount
            >= Self.maximumSuppressedCallbacksPerTransaction {
            completedInstallationTransactions.remove(at: index)
        }
        return .internalTransactionChangeSuppressed(identifier: identifier)
    }

    private func pruneExpiredTransactionCompletions(now: Date) {
        completedInstallationTransactions.removeAll { $0.expiresAt < now }
    }
}

final class CodexDesktopNativeUpdateOwnershipLease {
    static let bundleIdentifiers = ["com.openai.chat", "com.openai.codex"]
    static let sparkleKeys = ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate"]

    private struct PreviousValue {
        let wasPresent: Bool
        let value: Any?
    }

    private struct SuiteSnapshot {
        let defaults: UserDefaults
        let valuesByKey: [String: PreviousValue]
    }

    private var snapshots: [SuiteSnapshot]
    private var restored = false

    private init(snapshots: [SuiteSnapshot]) {
        self.snapshots = snapshots
    }

    static func acquire(
        defaultsProvider: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) -> CodexDesktopNativeUpdateOwnershipLease {
        var snapshots: [SuiteSnapshot] = []
        for bundleIdentifier in bundleIdentifiers {
            guard let defaults = defaultsProvider(bundleIdentifier) else { continue }
            var valuesByKey: [String: PreviousValue] = [:]
            for key in sparkleKeys {
                let value = defaults.object(forKey: key)
                valuesByKey[key] = PreviousValue(wasPresent: value != nil, value: value)
                defaults.set(false, forKey: key)
            }
            defaults.synchronize()
            snapshots.append(SuiteSnapshot(defaults: defaults, valuesByKey: valuesByKey))
        }
        return CodexDesktopNativeUpdateOwnershipLease(snapshots: snapshots)
    }

    func restore() {
        guard !restored else { return }
        restored = true
        for snapshot in snapshots {
            for key in Self.sparkleKeys {
                guard snapshot.defaults.object(forKey: key) as? Bool == false,
                      let previous = snapshot.valuesByKey[key] else { continue }
                if previous.wasPresent {
                    snapshot.defaults.set(previous.value, forKey: key)
                } else {
                    snapshot.defaults.removeObject(forKey: key)
                }
            }
            snapshot.defaults.synchronize()
        }
        snapshots.removeAll()
    }
}

protocol CodexDesktopUpdateExecuting: Sendable {
    func recoverInterruptedInstall(epoch: DesktopUpdateRunEpoch) async throws
        -> DesktopInstallRecoveryResult

    func performStartupMaintenance(
        temporaryRoot: URL,
        now: Date,
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopStartupMaintenanceReport

    func prepareLatestUpdate(epoch: DesktopUpdateRunEpoch) async
        -> CodexDesktopUpdatePreparationResult
    func installStagedUpdateIfReady(epoch: DesktopUpdateRunEpoch) async
        -> CodexDesktopStagedInstallResult
}

extension CodexDesktopUpdateExecuting {
    func recoverInterruptedInstall(
        epoch: DesktopUpdateRunEpoch
    ) async throws -> DesktopInstallRecoveryResult {
        .none
    }
}

actor CodexDesktopUpdateBackgroundExecutor: CodexDesktopUpdateExecuting {
    static let shared = CodexDesktopUpdateBackgroundExecutor()

    func recoverInterruptedInstall(
        epoch: DesktopUpdateRunEpoch
    ) async throws -> DesktopInstallRecoveryResult {
        try await CodexDesktopAppUpdater.recoverInterruptedInstall(epoch: epoch)
    }

    func performStartupMaintenance(
        temporaryRoot: URL,
        now: Date,
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopStartupMaintenanceReport {
        if Task.isCancelled || !epoch.isCurrent() { return .empty }
        let recovery: DesktopInstallRecoveryResult?
        let recoveryFailure: String?
        do {
            recovery = try await recoverInterruptedInstall(epoch: epoch)
            recoveryFailure = nil
        } catch is CancellationError {
            return .empty
        } catch {
            recovery = nil
            recoveryFailure = error.localizedDescription
        }

        if Task.isCancelled || !epoch.isCurrent() { return .empty }
        let temporaryWorkspace: CodexDesktopTemporaryWorkspaceCleanupReport?
        let temporaryWorkspaceFailure: String?
        do {
            temporaryWorkspace = try CodexDesktopTemporaryWorkspace.cleanupStaleDirectories(
                in: temporaryRoot,
                now: now,
                isCancelled: { Task.isCancelled || !epoch.isCurrent() }
            )
            temporaryWorkspaceFailure = nil
        } catch {
            temporaryWorkspace = nil
            temporaryWorkspaceFailure = error.localizedDescription
        }

        if Task.isCancelled || !epoch.isCurrent() { return .empty }
        let updateStorage: CodexDesktopUpdateStorageCleanupReport?
        let updateStorageFailure: String?
        do {
            updateStorage = try await CodexDesktopAppUpdater.cleanupUpdateStorage(
                now: now,
                epoch: epoch
            )
            if Task.isCancelled || !epoch.isCurrent() { return .empty }
            updateStorageFailure = nil
        } catch is CancellationError {
            return .empty
        } catch {
            updateStorage = nil
            updateStorageFailure = error.localizedDescription
        }

        return CodexDesktopStartupMaintenanceReport(
            installRecovery: recovery,
            installRecoveryFailure: recoveryFailure,
            temporaryWorkspace: temporaryWorkspace,
            temporaryWorkspaceFailure: temporaryWorkspaceFailure,
            updateStorage: updateStorage,
            updateStorageFailure: updateStorageFailure
        )
    }

    func prepareLatestUpdate(
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopUpdatePreparationResult {
        let result = await CodexDesktopAppUpdater.stageLatestUpdateIfNeeded(epoch: epoch)
        return Task.isCancelled ? .deferred("Desktop update check was cancelled") : result
    }

    func installStagedUpdateIfReady(
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopStagedInstallResult {
        let result = await CodexDesktopAppUpdater.installStagedUpdateIfReady(epoch: epoch)
        return Task.isCancelled ? .deferred("Staged desktop installation was cancelled") : result
    }
}

@MainActor
final class CodexDesktopUpdateCoordinator {
    nonisolated static let checkInterval: TimeInterval = 60

    private enum LoggedPreparationState: Equatable {
        case current(String)
        case staged(String)
        case deferred(String)
        case failed(String)
    }

    private struct OwnedTask {
        let epoch: UInt64
        let identifier: UUID
        let task: Task<Void, Never>
    }

    private let temporaryRoot: URL
    private let currentDate: () -> Date
    private let executor: any CodexDesktopUpdateExecuting
    private let nativeUpdateOwnershipProvider: () -> CodexDesktopNativeUpdateOwnershipLease?
    private var timer: Timer?
    private var checkTask: OwnedTask?
    private var maintenanceTask: OwnedTask?
    private var installTask: OwnedTask?
    private var applicationsChangeTask: OwnedTask?
    private var checkBackoff = CodexDesktopUpdateBackoff()
    private var loggedPreparationState: LoggedPreparationState?
    private var loggedRecoveryState: DesktopInstallRecoveryResult?
    private var loggedRecoveryFailure: String?
    private var nativeUpdateOwnership: CodexDesktopNativeUpdateOwnershipLease?
    private var isRunning = false
    private var runEpoch: UInt64 = 0
    private var runToken: DesktopUpdateRunEpoch?

    init(
        temporaryRoot: URL? = nil,
        currentDate: @escaping () -> Date = { Date() },
        executor: any CodexDesktopUpdateExecuting = CodexDesktopUpdateBackgroundExecutor.shared,
        nativeUpdateOwnershipProvider: @escaping () -> CodexDesktopNativeUpdateOwnershipLease? = {
            CodexDesktopAppUpdater.assumeNativeUpdateOwnership()
        }
    ) {
        self.temporaryRoot = temporaryRoot
            ?? CodexDesktopPathSecurity.canonicalSystemTemporaryDirectory()
        self.currentDate = currentDate
        self.executor = executor
        self.nativeUpdateOwnershipProvider = nativeUpdateOwnershipProvider
    }

    func start() {
        guard !isRunning else { return }
        runEpoch &+= 1
        runToken = DesktopUpdateRunEpoch()
        nativeUpdateOwnership = nativeUpdateOwnershipProvider()
        isRunning = true
        checkBackoff.recordSuccess()
        loggedPreparationState = nil
        loggedRecoveryState = nil
        loggedRecoveryFailure = nil
        startInitialMaintenanceAndCheck()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.checkNow(reason: "periodic") }
        }
    }

    func stop() {
        runToken?.invalidate()
        runEpoch &+= 1
        isRunning = false
        timer?.invalidate()
        timer = nil
        checkTask?.task.cancel()
        checkTask = nil
        maintenanceTask?.task.cancel()
        maintenanceTask = nil
        installTask?.task.cancel()
        installTask = nil
        applicationsChangeTask?.task.cancel()
        applicationsChangeTask = nil
        nativeUpdateOwnership?.restore()
        nativeUpdateOwnership = nil
        loggedPreparationState = nil
        loggedRecoveryState = nil
        loggedRecoveryFailure = nil
        runToken = nil
    }

    private func startInitialMaintenanceAndCheck() {
        guard let runToken else { return }
        let epoch = runEpoch
        let identifier = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearMaintenanceTask(epoch: epoch, identifier: identifier) }
            await Task.yield()
            guard !Task.isCancelled, self.ownsRun(epoch) else { return }
            let report = await self.executor.performStartupMaintenance(
                temporaryRoot: self.temporaryRoot,
                now: self.currentDate(),
                epoch: runToken
            )
            guard !Task.isCancelled, self.ownsRun(epoch) else { return }
            self.logMaintenance(report)
            self.checkNow(reason: "launch")
        }
        maintenanceTask = OwnedTask(epoch: epoch, identifier: identifier, task: task)
    }

    func checkNow(reason: String) {
        guard isRunning, let runToken else { return }
        guard checkTask == nil else { return }
        let epoch = runEpoch
        let identifier = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearCheckTask(epoch: epoch, identifier: identifier) }
            await Task.yield()
            guard !Task.isCancelled, self.ownsRun(epoch) else { return }
            await self.recoverCommittedCleanup(epoch: epoch, runToken: runToken)
            guard !Task.isCancelled, self.ownsRun(epoch) else { return }
            let now = self.currentDate()
            guard self.checkBackoff.permitsAttempt(at: now) else {
                if reason != "periodic" {
                    let remaining = max(
                        0,
                        self.checkBackoff.retryNotBefore?.timeIntervalSince(now) ?? 0
                    )
                    SwapLog.append(
                        .debug(
                            "DESKTOP_UPDATE_CHECK_BACKOFF reason=\(reason) "
                                + "remaining_seconds=\(Int(remaining.rounded(.up)))"
                        )
                    )
                }
                return
            }
            let result = await self.executor.prepareLatestUpdate(epoch: runToken)
            guard !Task.isCancelled, self.ownsRun(epoch) else { return }
            switch result {
            case .upToDate(let version):
                self.checkBackoff.recordSuccess()
                self.logPreparationStateIfChanged(
                    .current(version),
                    message: "DESKTOP_UPDATE_CURRENT version=\(version) reason=\(reason)"
                )
            case .alreadyStaged(let update):
                self.checkBackoff.recordSuccess()
                self.logPreparationStateIfChanged(
                    .staged(update.bundleVersion),
                    message: "DESKTOP_UPDATE_STAGED version=\(update.bundleVersion) reason=\(reason)"
                )
            case .staged(let update):
                self.checkBackoff.recordSuccess()
                self.loggedPreparationState = .staged(update.bundleVersion)
                SwapLog.append(
                    .debug(
                        "DESKTOP_UPDATE_DOWNLOADED version=\(update.bundleVersion) "
                            + "install=next_safe_quit"
                    )
                )
            case .deferred(let message):
                let retryDelay = self.checkBackoff.recordFailure(at: self.currentDate())
                self.logPreparationStateIfChanged(
                    .deferred(message),
                    message: "DESKTOP_UPDATE_DEFERRED reason=\(reason) "
                        + "retry_seconds=\(Int(retryDelay)) message=\(message)"
                )
            case .failed(let message):
                let retryDelay = self.checkBackoff.recordFailure(at: self.currentDate())
                self.logPreparationStateIfChanged(
                    .failed(message),
                    message: "DESKTOP_UPDATE_CHECK_FAILED reason=\(reason) "
                        + "retry_seconds=\(Int(retryDelay)) message=\(message)"
                )
            }
        }
        checkTask = OwnedTask(epoch: epoch, identifier: identifier, task: task)
    }

    func applicationsDirectoryDidChange(
        completion: @escaping @MainActor (CodexDesktopApplicationsChangeDisposition) -> Void
    ) {
        guard isRunning, applicationsChangeTask == nil else { return }
        let epoch = runEpoch
        let identifier = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.clearApplicationsChangeTask(epoch: epoch, identifier: identifier)
            }
            await Task.yield()
            guard !Task.isCancelled, self.ownsRun(epoch) else { return }
            let disposition = await CodexDesktopAppUpdater.applicationsDirectoryChangeDisposition()
            guard !Task.isCancelled, self.ownsRun(epoch) else { return }
            completion(disposition)
        }
        applicationsChangeTask = OwnedTask(
            epoch: epoch,
            identifier: identifier,
            task: task
        )
    }

    func desktopAppDidTerminate(
        completion: @escaping @MainActor (
            _ installedUpdate: Bool,
            _ transaction: CodexDesktopInstallationTransactionCompletion?
        ) -> Void
    ) {
        guard isRunning, installTask == nil, let runToken else { return }
        let epoch = runEpoch
        let identifier = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearInstallTask(epoch: epoch, identifier: identifier) }
            await Task.yield()
            guard !Task.isCancelled, self.ownsRun(epoch) else { return }
            await self.recoverCommittedCleanup(epoch: epoch, runToken: runToken)
            guard !Task.isCancelled, self.ownsRun(epoch) else { return }
            for attempt in 0..<CodexDesktopInstallRetryPolicy.maximumAttempts {
                let delay = CodexDesktopInstallRetryPolicy.delayBeforeAttempt(attempt)
                if delay > 0 {
                    do {
                        try await Task.sleep(for: .milliseconds(Int64(delay * 1_000)))
                    } catch { return }
                }
                guard !Task.isCancelled, self.ownsRun(epoch) else { return }
                let result = await self.executor.installStagedUpdateIfReady(epoch: runToken)
                guard !Task.isCancelled, self.ownsRun(epoch) else { return }
                switch result {
                case .none:
                    completion(false, nil)
                    return
                case .waitingForDesktopQuit(let update):
                    let remaining = CodexDesktopInstallRetryPolicy.maximumAttempts - attempt - 1
                    SwapLog.append(
                        .debug(
                            "DESKTOP_UPDATE_WAITING version=\(update.bundleVersion) "
                                + "reason=runtime_still_running attempt=\(attempt + 1) "
                                + "attempts_remaining=\(remaining)"
                        )
                    )
                    if remaining == 0 {
                        completion(false, nil)
                        return
                    }
                case .deferred(let message):
                    SwapLog.append(.debug("DESKTOP_UPDATE_INSTALL_DEFERRED message=\(message)"))
                    completion(false, nil)
                    return
                case .discarded(let message):
                    SwapLog.append(.debug("DESKTOP_UPDATE_DISCARDED message=\(message)"))
                    completion(false, nil)
                    return
                case .installed(let path, let release, let transaction, let cleanupPending):
                    SwapLog.append(
                        .debug(
                            "DESKTOP_UPDATE_INSTALLED version=\(release.versionLabel) path=\(path) "
                                + "cleanup=\(cleanupPending ? "pending" : "complete")"
                        )
                    )
                    completion(true, transaction)
                    return
                case .failed(let message):
                    SwapLog.append(.debug("DESKTOP_UPDATE_INSTALL_FAILED message=\(message)"))
                    completion(false, nil)
                    return
                }
            }
        }
        installTask = OwnedTask(epoch: epoch, identifier: identifier, task: task)
    }

    private func recoverCommittedCleanup(
        epoch: UInt64,
        runToken: DesktopUpdateRunEpoch
    ) async {
        do {
            let result = try await executor.recoverInterruptedInstall(epoch: runToken)
            guard !Task.isCancelled, ownsRun(epoch) else { return }
            loggedRecoveryFailure = nil
            if result == .none {
                loggedRecoveryState = nil
                return
            }
            guard loggedRecoveryState != result else { return }
            loggedRecoveryState = result
            SwapLog.append(
                .debug(
                    "DESKTOP_UPDATE_INSTALL_RECOVERY result=\(String(describing: result))"
                )
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, ownsRun(epoch) else { return }
            let message = error.localizedDescription
            guard loggedRecoveryFailure != message else { return }
            loggedRecoveryFailure = message
            SwapLog.append(.debug("DESKTOP_UPDATE_INSTALL_RECOVERY_FAILED message=\(message)"))
        }
    }

    private func ownsRun(_ epoch: UInt64) -> Bool {
        isRunning && runEpoch == epoch && runToken?.isCurrent() == true
    }

    private func clearCheckTask(epoch: UInt64, identifier: UUID) {
        guard checkTask?.epoch == epoch, checkTask?.identifier == identifier else { return }
        checkTask = nil
    }

    private func clearMaintenanceTask(epoch: UInt64, identifier: UUID) {
        guard maintenanceTask?.epoch == epoch,
              maintenanceTask?.identifier == identifier else { return }
        maintenanceTask = nil
    }

    private func clearInstallTask(epoch: UInt64, identifier: UUID) {
        guard installTask?.epoch == epoch, installTask?.identifier == identifier else { return }
        installTask = nil
    }

    private func clearApplicationsChangeTask(epoch: UInt64, identifier: UUID) {
        guard applicationsChangeTask?.epoch == epoch,
              applicationsChangeTask?.identifier == identifier else { return }
        applicationsChangeTask = nil
    }

    private func logPreparationStateIfChanged(
        _ state: LoggedPreparationState,
        message: String
    ) {
        guard loggedPreparationState != state else { return }
        loggedPreparationState = state
        SwapLog.append(.debug(message))
    }

    private func logMaintenance(_ report: CodexDesktopStartupMaintenanceReport) {
        if let recovery = report.installRecovery, recovery != .none {
            SwapLog.append(.debug("DESKTOP_UPDATE_INSTALL_RECOVERY result=\(String(describing: recovery))"))
        }
        if let failure = report.installRecoveryFailure {
            SwapLog.append(.debug("DESKTOP_UPDATE_INSTALL_RECOVERY_FAILED message=\(failure)"))
        }
        if let cleanup = report.temporaryWorkspace, cleanup.removedDirectoryCount > 0 {
            SwapLog.append(
                .debug(
                    "DESKTOP_UPDATE_TEMP_CLEANUP reclaimed_count=\(cleanup.removedDirectoryCount) "
                        + "reclaimed_bytes=\(cleanup.reclaimedBytes)"
                )
            )
        }
        if let failure = report.temporaryWorkspaceFailure {
            SwapLog.append(.debug("DESKTOP_UPDATE_TEMP_CLEANUP_FAILED message=\(failure)"))
        }
        if let cleanup = report.updateStorage, cleanup.removedArtifactCount > 0 {
            SwapLog.append(
                .debug(
                    "DESKTOP_UPDATE_STORAGE_CLEANUP reclaimed_count=\(cleanup.removedArtifactCount) "
                        + "reclaimed_bytes=\(cleanup.reclaimedBytes)"
                )
            )
        }
        if let failure = report.updateStorageFailure {
            SwapLog.append(.debug("DESKTOP_UPDATE_STORAGE_CLEANUP_FAILED message=\(failure)"))
        }
    }
}

@MainActor
final class DesktopInstallationWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var onChange: (() -> Void)?

    func start(path: String = "/Applications", onChange: @escaping () -> Void) {
        stop()
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            SwapLog.append(.debug("DESKTOP_INSTALLATION_WATCH_FAILED path=\(path) errno=\(errno)"))
            return
        }
        fileDescriptor = descriptor
        self.onChange = onChange
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 { fileDescriptor = -1 }
        onChange = nil
    }
}
