import AppKit
import Dispatch
import SwiftUI
import os
import Darwin

private let logger = Logger(subsystem: "com.codexswitch", category: "AppDelegate")
private let linuxDevboxLastCredentialSyncFingerprintKey = "linuxDevboxLastCredentialSyncFingerprint"
private let linuxDevboxCredentialSyncUnresolvedFingerprintKey = "linuxDevboxCredentialSyncUnresolvedFingerprint"
private let linuxDevboxCredentialSyncUnresolvedReasonKey = "linuxDevboxCredentialSyncUnresolvedReason"

struct LinuxDevboxCredentialSyncRetryPlan: Equatable, Sendable {
    let context: String
    let fingerprint: String
    let delay: TimeInterval
}

enum AppDelegateAccountsPersistenceOutcome: Equatable, Sendable {
    case persisted
    case failed(String)

    var succeeded: Bool {
        self == .persisted
    }
}

enum AppDelegateDesktopPatchRetryDisposition: Equatable, Sendable {
    case retry
    case stop
    case relaunch
}

enum AppDelegateDurableConfigurationStatus: Equatable, Sendable {
    case matches
    case mismatch
    case unavailable
}

struct ExternalAuthObservationContext: Equatable, Sendable {
    let configuredAccountId: UUID?
    let swapGeneration: UInt64
    let activationGeneration: UUID?
}

struct RateLimitResetInventoryObservation: Equatable, Sendable {
    let transition: RateLimitResetInventoryTransition
    let externalHoldUntil: Date?
}

enum ManualRateLimitResetSwapSuppression: Equatable, Sendable {
    case pending
    case durable
}

private final class RateLimitResetSubmissionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var expectations: [String: RateLimitResetSubmissionExpectation] = [:]

    func begin(attempt: RateLimitResetAttempt) {
        guard let providerAccountId = attempt.normalizedProviderAccountId else { return }
        lock.lock()
        expectations[providerAccountId] = RateLimitResetSubmissionExpectation(attempt: attempt)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        expectations.removeAll()
        lock.unlock()
    }

    func clear(providerAccountId: String) {
        guard let providerAccountId = RateLimitResetProviderAccountIdentity.normalize(
            providerAccountId
        ) else {
            return
        }
        lock.lock()
        expectations[providerAccountId] = nil
        lock.unlock()
    }

    func reconcile(
        providerAccountId: String,
        unresolvedAttempt: RateLimitResetAttempt?
    ) {
        guard let providerAccountId = RateLimitResetProviderAccountIdentity.normalize(
            providerAccountId
        ) else {
            return
        }
        lock.lock()
        if let expectation = expectations[providerAccountId] {
            expectations[providerAccountId] = expectation.retained(while: unresolvedAttempt)
        }
        lock.unlock()
    }

    func classify(
        previousBank: RateLimitResetBank?,
        refreshedBank: RateLimitResetBank,
        observedProviderAccountId: String,
        now: Date
    ) -> RateLimitResetInventoryTransition {
        lock.lock()
        defer { lock.unlock() }
        let providerAccountId = RateLimitResetProviderAccountIdentity.normalize(
            observedProviderAccountId
        )
        let transition = RateLimitResetInventoryTransition.classify(
            previousBank: previousBank,
            refreshedBank: refreshedBank,
            localExpectation: providerAccountId.flatMap { expectations[$0] },
            observedProviderAccountId: observedProviderAccountId,
            now: now
        )
        if let providerAccountId {
            expectations[providerAccountId] = transition.updatedExpectation
        }
        return transition
    }
}

private struct PreparedAccountActivation: Sendable {
    let swapGeneration: UInt64
    let activationGeneration: UUID
    let expectedConfiguredAccountId: UUID?
    let previousActivationState: AccountActivationState?
    let lease: AccountMutationLease
}

private enum AccountActivationPreparationResult: Sendable {
    case prepared(PreparedAccountActivation)
    case retrySameTarget
    case blocked
}

private enum ScopedAccountActivationResult: Sendable {
    case completed(Bool)
    case retrySameTarget
    case blocked
}

/// Write crash info to ~/.codexswitch/logs/crash.log for debugging
private func writeCrashLog(_ message: String) {
    let dir = NSString("~/.codexswitch/logs").expandingTildeInPath
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = "\(dir)/crash.log"
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Install global crash handlers to catch uncaught exceptions and signals
private func installCrashHandlers() {
    NSSetUncaughtExceptionHandler { exception in
        writeCrashLog("UNCAUGHT EXCEPTION: \(exception.name.rawValue) — \(exception.reason ?? "no reason")")
        writeCrashLog("STACK: \(exception.callStackSymbols.joined(separator: "\n"))")
    }
    // Signal handlers use only async-signal-safe POSIX write(2).
    // Foundation APIs (heap alloc, formatters, FileManager) are NOT safe here.
    // Pre-built static message — no heap allocation or string interpolation.
    for sig: Int32 in [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP] {
        signal(sig) { _ in
            let msg: StaticString = "FATAL SIGNAL\n"
            msg.withUTF8Buffer { buf in
                _ = Darwin.write(STDERR_FILENO, buf.baseAddress, buf.count)
            }
            Darwin.signal(SIGABRT, SIG_DFL)
            Darwin.raise(SIGABRT)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let manualOverrideAccountIdKey = "manualOverrideAccountId"
    private static let automaticCodexUpdateLastAttemptKey = "automaticCodexUpdateLastAttemptAt"
    private static let automaticCodexUpdateLastFailureKey = "automaticCodexUpdateLastFailureAt"
    nonisolated private static let codexAuthPath = NSString("~/.codex/auth.json").expandingTildeInPath
    nonisolated static let externalRateLimitResetRedemptionCooldown: TimeInterval = 15 * 60
    nonisolated static let rateLimitResetBackgroundFreshnessInterval: TimeInterval = 5 * 60
    nonisolated static let rateLimitResetDecisionFreshnessInterval: TimeInterval = 60
    nonisolated static let configMaintenanceInterval: TimeInterval = 15 * 60
    nonisolated static let linuxDevboxCredentialSyncRetryDelay: TimeInterval = 5
    nonisolated static let retryExhaustedTopologyCheckInterval: TimeInterval = 15
    nonisolated static let automaticPolicyGateTimeout: TimeInterval = 30

    // Set in applicationDidFinishLaunching before any other access
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var statusBarController: StatusBarController!
    private var settingsWindow: NSWindow?
    private var popoverContentInstalled = false
    private var popoverLocalEventMonitor: Any?
    private var popoverGlobalEventMonitor: Any?

    let accountManager = AccountManager()
    private let accountActivationCoordinator = AccountActivationCoordinator()
    private let accountMutationTransaction = AccountActivationTransaction()
    private let accountActivationCredentialCommitter = AccountActivationCredentialCommitter()
    private let accountActivationReloadTransaction = AccountActivationReloadTransaction()
    private let accountActivationConfirmationTransaction = AccountActivationConfirmationTransaction()
    private let accountPersistence = AccountPersistenceCoordinator(store: KeychainStore())
    private let quotaPoller = QuotaPoller()
    private let rateLimitResetService = RateLimitResetService()
    private let rateLimitResetSubmissionTracker = RateLimitResetSubmissionTracker()
    private let externalRateLimitResetHoldStore = ExternalRateLimitResetHoldPersistence()
    private let tokenSavingsStore = CodexTokenSavingsStore()
    private let weeklyPrimer = WeeklyPrimer()
    private let subscriptionInfoFetcher = SubscriptionInfoFetcher()
    private let oauthManager = OAuthLoginManager()
    private let singleInstanceLock = SingleInstanceLock()
    private let desktopUpdateCoordinator = CodexDesktopUpdateCoordinator()
    private let desktopInstallationWatcher = DesktopInstallationWatcher()
    private let linuxDevboxCredentialSyncJournal = LinuxDevboxCredentialSyncJournal()

    private var monitorTask: Task<Void, Never>?
    private var idleAccountPrimeTask: Task<Void, Never>?
    private var idleAccountPrimePassPending = false
    private var rateLimitResetRefreshTasks: [UUID: Task<Void, Never>] = [:] {
        didSet { publishRateLimitResetPresentations() }
    }
    private var rateLimitResetDecisionPending: Set<UUID> = []
    private var rateLimitResetRedemptionTask: Task<Void, Never>?
    private var rateLimitResetOperationProviderAccountId: String? {
        didSet { publishRateLimitResetPresentations() }
    }
    private var rateLimitResetRedemptionBlockedUntil: [UUID: Date] = [:]
    private var manualRateLimitResetSwapSuppressions: [
        String: ManualRateLimitResetSwapSuppression
    ] = [:]
    private var manualRateLimitResetSwapSuppressionRevisions: [String: UInt64] = [:]
    private var manualRateLimitResetReleaseProviderAccountIds: Set<String> = []
    private var rateLimitResetJournalStateIsReadable = false {
        didSet { publishRateLimitResetPresentations() }
    }
    private var rateLimitResetJournalFailureLogged = false
    private var externalRateLimitResetRedemptionBlockedUntil: [UUID: Date] = [:] {
        didSet { publishRateLimitResetPresentations() }
    }
    private var externalRateLimitResetHoldStateIsReadable = false
    private var externalRateLimitResetHoldFailureLogged = false
    private var rateLimitResetRecoveryUntil: [UUID: Date] = [:]
    private var rateLimitResetInventoryRetryAfter: [UUID: Date] = [:]
    private var rateLimitResetManualErrors: [UUID: String] = [:] {
        didSet { publishRateLimitResetPresentations() }
    }
    private var rateLimitResetUnresolvedProviderAccountIds: Set<String> = [] {
        didSet { publishRateLimitResetPresentations() }
    }
    private var iconUpdateTimer: Timer?
    private var configMaintenanceTimer: Timer?
    private var configMaintenanceTask: Task<Void, Never>?
    private var manualOverrideAccountId: UUID? = {
        guard let stored = UserDefaults.standard.string(forKey: AppDelegate.manualOverrideAccountIdKey) else {
            return nil
        }
        return UUID(uuidString: stored)
    }()
    private var linuxDevboxMonitorTimer: Timer?
    private var tokenUsageMetricsTimer: Timer?
    private var tokenUsageRefreshSequence = 0
    private var tokenUsageRefreshInFlight = false
    private var lastLinuxDevboxReady: Bool?
    private var lastLinuxDevboxFullCheckAt: Date?
    private var lastLinuxDevboxAccountMirrorSucceededAt: Date?
    private var linuxDevboxReadinessCheckInFlight = false
    private var linuxDevboxReadinessGeneration: UInt64 = 0
    private var linuxDevboxReadinessTaskContext: LinuxDevboxReadinessTaskContext?
    private var linuxDevboxConsecutiveIssueChecks = 0
    private var lastSubscriptionRefresh: Date?
    private var lastCLIRepairCheck: Date?
    private var globalCLIRepairInFlight = false
    private var completeCodexHotSwapRuntimeMissing = false
    private var automaticCodexUpdateTask: Task<Void, Never>?
    private var lastAutomaticCodexUpdateAttemptAt = UserDefaults.standard.object(
        forKey: AppDelegate.automaticCodexUpdateLastAttemptKey
    ) as? Date
    private var lastAutomaticCodexUpdateFailureAt = UserDefaults.standard.object(
        forKey: AppDelegate.automaticCodexUpdateLastFailureKey
    ) as? Date
    private var lastDesktopPatchCheck: Date?
    private var lastDesktopPatchInstallationFingerprint: DesktopPatchManager.InstallationFingerprint?
    private var hasObservedDesktopPatchInstallationFingerprint = false
    private var lastCodexBrowserSessionRepairCheck: Date?
    private var lastLinuxDevboxAccountRefreshByKey: [String: Date] = [:]
    private var linuxDevboxCredentialSyncInFlight = false
    private var linuxDevboxCredentialSyncReconciliationInFlight = false
    private var pendingLinuxDevboxCredentialSyncFingerprint: String?
    private var lastLinuxDevboxCredentialSyncAttemptAt: Date?
    private var linuxDevboxCredentialSyncRetryTask: Task<Void, Never>?
    private var exhaustedPoolAlertGate = ExhaustedPoolAlertGate()
    private var codexAppTerminationObserver: NSObjectProtocol?
    private var codexAppTerminationTask: Task<Void, Never>?
    private var codexAppTerminationTaskIdentifier: UUID?
    private var desktopPatchRetryTask: Task<Void, Never>?
    private var handledDesktopUpdateTransactionIdentifiers: Set<UInt64> = []
    private var swapGeneration: UInt64 = 0
    private var pendingSwapTargetAccountId: UUID?
    private var swapConvergenceTask: Task<Void, Never>?
    private var automaticPolicyGateTask: Task<Void, Never>?
    private var automaticPolicyGateWatchdogTask: Task<Void, Never>?
    private var automaticPolicyLeaseState = AccountAutomaticPolicyLeaseState()
    private var retryExhaustedTopologyCheckTask: Task<Void, Never>?
    private var lastRetryExhaustedTopologyCheckAt: Date?
    private var lastAttemptedRetryExhaustedTopology: CodexLocalCLIRuntimeTopology?
    private var isExiting = false
    private var terminationFlushTask: Task<Void, Never>?
    private var terminationFlushCompleted = false
    private var accountPersistenceRevision: UInt64 = 0
    private var externalAuthReconciliationInFlight = false
    private var externalAuthReconciliationPending = false

    private func installStatusItem() {
        if let existingStatusItem = statusItem {
            existingStatusItem.menu = nil
            NSStatusBar.system.removeStatusItem(existingStatusItem)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        statusBarController = StatusBarController(statusItem: statusItem, manager: accountManager)
        configureStatusButton()
        statusBarController.updateIcon()
        SwapLog.append(.debug("STATUS_ITEM_INSTALLED length=\(statusItem.length) visible=\(statusItem.isVisible)"))
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else {
            SwapLog.append(.debug("STATUS_ITEM_BUTTON_MISSING"))
            return
        }
        button.action = #selector(statusBarClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.toolTip = "CodexSwitch"
        button.setAccessibilityLabel("CodexSwitch")
    }

    private func ensureStatusItemHealthy() {
        guard let statusItem else {
            installStatusItem()
            return
        }

        var repaired = false
        if statusItem.length != NSStatusItem.squareLength {
            statusItem.length = NSStatusItem.squareLength
            repaired = true
        }
        if !statusItem.isVisible {
            statusItem.isVisible = true
            repaired = true
        }
        if statusItem.button == nil {
            installStatusItem()
            return
        }

        configureStatusButton()
        if repaired {
            SwapLog.append(.debug("STATUS_ITEM_REPAIRED length=\(statusItem.length) visible=\(statusItem.isVisible)"))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installCrashHandlers()
        writeCrashLog("LAUNCH: applicationDidFinishLaunching started")
        guard singleInstanceLock.acquire() else {
            writeCrashLog("LAUNCH: duplicate CodexSwitch instance exiting before services start")
            SwapLog.append(.debug("APP_DUPLICATE_INSTANCE_EXIT reason=single_instance_lock"))
            NSApp.terminate(nil)
            return
        }

        DesktopPatchManager.registerDefaults()
        UserDefaults.standard.register(defaults: [
            RateLimitResetSettings.automaticRedemptionDefaultsKey: true,
        ])
        _ = Self.installKeepAliveOffMainActor()
        let desktopBridgeInstallation = Self.installDesktopBridgeOffMainActor()
        scheduleConfigMaintenanceIfNeeded(removeStaleCopies: true)
        configMaintenanceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.configMaintenanceInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleConfigMaintenanceIfNeeded()
            }
        }
        scheduleGlobalCLIRepairIfNeeded(force: true)
        scheduleCodexBrowserSessionRepairIfNeeded(force: true)
        codexAppTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleIdentifier = app?.bundleIdentifier
            let bundlePath = app?.bundleURL?.path
            MainActor.assumeIsolated {
                self?.handleCodexAppDidTerminate(
                    bundleIdentifier: bundleIdentifier,
                    bundlePath: bundlePath
                )
            }
        }
        desktopUpdateCoordinator.start()
        desktopInstallationWatcher.start { [weak self] in
            guard let self else { return }
            self.desktopUpdateCoordinator.applicationsDirectoryDidChange { [weak self] disposition in
                self?.handleDesktopApplicationsDirectoryChange(disposition)
            }
        }

        NSApp.setActivationPolicy(.accessory)
        NotificationManager.requestPermission()

        installStatusItem()

        // Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 620, height: 760)
        popover.behavior = .transient
        popover.delegate = self
        updatePopoverContent()

        // Load accounts from Keychain (async for file I/O), then start services
        Task { @MainActor [self] in
            await loadAccounts()
            await desktopBridgeInstallation.value
            await recoverManualReviewActivationOnLaunch()
            await restoreExternalRateLimitResetHolds()

            // Prune old diagnostic logs (>7 days)
            SwapLog.pruneOldLogs()

            // Start polling + monitoring
            startAllPolling()
            for account in accountManager.accounts {
                scheduleRateLimitResetRefresh(for: account.id)
            }
            primeIdleAccountsIfNeeded()
            refreshSubscriptionInfoIfNeeded(force: true)
            startSwapMonitor()
            startLinuxDevboxMonitor()
            startTokenUsageMetricsMonitor()
            scheduleDesktopPatchCheckIfNeeded(force: true)
            scheduleAutomaticCodexUpdateIfNeeded()
            retryActivationConvergenceIfDue(at: Date())

            // Update icon + status checks periodically
            writeCrashLog("LAUNCH: all services started, \(accountManager.accounts.count) accounts loaded, configured=\(accountManager.configuredAccount?.email ?? "none")")

            CLIStatusChecker.refresh(activeAccountId: accountManager.configuredAccount?.accountId)
            iconUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.reconcileExternalAuthIfNeeded()
                    self?.ensureStatusItemHealthy()
                    self?.statusBarController.updateIcon()
                    self?.updatePopoverContent()
                    self?.refreshSubscriptionInfoIfNeeded()
                    self?.scheduleGlobalCLIRepairIfNeeded()
                    self?.scheduleAutomaticCodexUpdateIfNeeded()
                    self?.scheduleCodexBrowserSessionRepairIfNeeded()
                    self?.scheduleRetryExhaustedTopologyRecoveryIfNeeded()
                    CLIStatusChecker.refresh(activeAccountId: self?.accountManager.configuredAccount?.accountId) { [weak self] in
                        self?.updatePopoverContent()
                    }
                    self?.scheduleDesktopPatchCheckIfNeeded()
                }
            }
        }
    }

    private func reconcileExternalAuthIfNeeded() async {
        guard !isExiting else { return }
        guard !externalAuthReconciliationInFlight else {
            externalAuthReconciliationPending = true
            return
        }
        externalAuthReconciliationInFlight = true
        defer { externalAuthReconciliationInFlight = false }

        repeat {
            externalAuthReconciliationPending = false
            await reconcileExternalAuthObservation()
        } while externalAuthReconciliationPending && !isExiting
    }

    private func reconcileExternalAuthObservation() async {
        let capturedContext = externalAuthObservationContext()

        let observation = await Task.detached(priority: .utility) {
            AccountImporter.observeCurrentAccount()
        }.value
        guard !isExiting else { return }
        let currentContext = externalAuthObservationContext()
        guard Self.externalAuthObservationIsCurrent(
            captured: capturedContext,
            current: currentContext
        ) else {
            externalAuthReconciliationPending = true
            SwapLog.append(.debug(
                "EXTERNAL_AUTH_OBSERVATION_DISCARDED reason=activation_context_changed captured_swap_generation=\(capturedContext.swapGeneration) current_swap_generation=\(currentContext.swapGeneration)"
            ))
            return
        }
        let imported: CodexAccount
        switch observation {
        case .absent:
            guard accountManager.configuredAccount != nil else { return }
            if accountManager.activationState?.detail != .externalAuthAbsent {
                await enterActivationManualReview(
                    targetAccountId: accountManager.configuredAccount?.id,
                    detail: .externalAuthAbsent
                )
            }
            return
        case .invalid(let reason) where reason.isRetryableObservationFailure:
            SwapLog.append(.debug(
                "EXTERNAL_AUTH_OBSERVATION_DEFERRED reason=\(reason.rawValue)"
            ))
            return
        case .invalid:
            guard accountManager.configuredAccount != nil else { return }
            if accountManager.activationState?.detail != .externalAuthInvalid {
                await enterActivationManualReview(
                    targetAccountId: accountManager.configuredAccount?.id,
                    detail: .externalAuthInvalid
                )
            }
            return
        case .unreadable(let reason):
            SwapLog.append(.debug(
                "EXTERNAL_AUTH_OBSERVATION_DEFERRED reason=\(reason.rawValue)"
            ))
            return
        case .valid(let account):
            imported = account
        }
        guard let existing = accountManager.accounts.first(where: {
            $0.accountId == imported.accountId
        }) else {
            if accountManager.activationState?.phase == .manualReview,
               accountManager.activationState?.detail == .externalAuthTargetUnknown {
                return
            }
            await enterActivationManualReview(
                targetAccountId: nil,
                detail: .externalAuthTargetUnknown
            )
            SwapLog.append(.debug(
                "EXTERNAL_AUTH_BLOCKED reason=unknown_target provider_account=present"
            ))
            return
        }

        var target = existing
        target.email = imported.email
        target.accessToken = imported.accessToken
        target.refreshToken = imported.refreshToken
        target.idToken = imported.idToken
        target.accountId = imported.accountId
        target.lastRefreshed = imported.lastRefreshed ?? Date()
        target.runtimeUnusableUntil = nil
        target.runtimeUnusableReason = nil

        let configured = accountManager.configuredAccount
        let targetChanged = configured?.id != target.id
        let credentialsChanged = existing.accountId != target.accountId
            || existing.accessToken != target.accessToken
            || existing.refreshToken != target.refreshToken
            || existing.idToken != target.idToken
        if !targetChanged, !credentialsChanged {
            guard Self.verifiedExternalAuthRecoveryTarget(
                state: accountManager.activationState,
                configuredAccountId: configured?.id,
                observedTargetAccountId: target.id
            ) != nil else {
                return
            }
            await startSameTargetRuntimeRetry(
                to: target,
                source: "external_auth_recovered"
            )
            return
        }

        if let state = accountManager.activationState,
           state.phase != .confirmed,
           state.configuredAccountId != target.id {
            swapGeneration &+= 1
            accountMutationTransaction.invalidateCurrentActivationSynchronously()
            if let convergenceTask = swapConvergenceTask {
                convergenceTask.cancel()
                await convergenceTask.value
            }
            await enterActivationManualReview(
                targetAccountId: state.configuredAccountId,
                detail: .externalAuthConflict
            )
            SwapLog.append(.debug(
                "EXTERNAL_AUTH_BLOCKED reason=conflicting_activation_target"
            ))
            return
        }

        if let pendingSwapTargetAccountId,
           pendingSwapTargetAccountId != target.id || swapConvergenceTask == nil {
            swapGeneration &+= 1
            accountMutationTransaction.invalidateCurrentActivationSynchronously()
            if let convergenceTask = swapConvergenceTask {
                convergenceTask.cancel()
                await convergenceTask.value
            }
            await enterActivationManualReview(
                targetAccountId: target.id,
                detail: .externalAuthConflict
            )
            SwapLog.append(.debug(
                "EXTERNAL_AUTH_BLOCKED reason=credential_commit_in_flight"
            ))
            return
        }

        let from = configured ?? target
        _ = await withPreparedActiveCredentialMutation(
            targetAccountId: target.id,
            expectedConfiguredAccountId: configured?.id,
            source: "external-auth",
            isManual: false
        ) { [weak self] prepared in
            guard let self else { return false }
            return await self.commitConfiguredCredentialMutation(
                from: from,
                to: target,
                reason: .manual,
                mutationRoute: .externalAuthObservation,
                persistenceContext: "external-auth-observed",
                authAlreadyConfigured: true,
                swapStart: Date(),
                prepared: prepared,
                recordsSwap: false,
                committedDetail: .externalAuthObserved
            )
        }
    }

    private func externalAuthObservationContext() -> ExternalAuthObservationContext {
        ExternalAuthObservationContext(
            configuredAccountId: accountManager.configuredAccount?.id,
            swapGeneration: swapGeneration,
            activationGeneration: accountManager.activationState?.activationGeneration
        )
    }

    nonisolated static func externalAuthObservationIsCurrent(
        captured: ExternalAuthObservationContext,
        current: ExternalAuthObservationContext
    ) -> Bool {
        captured == current
    }

    private func scheduleGlobalCLIRepairIfNeeded(force: Bool = false) {
        guard !globalCLIRepairInFlight, automaticCodexUpdateTask == nil else { return }
        let now = Date()
        if !force, let lastCLIRepairCheck, now.timeIntervalSince(lastCLIRepairCheck) < 5 * 60 {
            return
        }
        lastCLIRepairCheck = now
        globalCLIRepairInFlight = true
        let finish: @MainActor @Sendable (
            CodexVersionChecker.CodexCLIRepairResult
        ) -> Void = { [weak self] result in
            self?.finishGlobalCLIRepair(result)
        }
        Task.detached {
            let result = CodexVersionChecker.repairBrokenGlobalCLIIfNeeded(force: force)
            if result.attempted {
                SwapLog.append(.debug("GLOBAL_CODEX_CLI_REPAIR success=\(result.success) message=\(result.message)"))
            }
            await finish(result)
        }
    }

    private func finishGlobalCLIRepair(
        _ result: CodexVersionChecker.CodexCLIRepairResult
    ) {
        completeCodexHotSwapRuntimeMissing = !result.success
            && result.message == "No complete native Codex hot-swap runtime is installed"
        globalCLIRepairInFlight = false
        if completeCodexHotSwapRuntimeMissing {
            scheduleAutomaticCodexUpdateIfNeeded()
        }
    }

    private func scheduleAutomaticCodexUpdateIfNeeded(now: Date = Date()) {
        guard !globalCLIRepairInFlight else { return }
        guard CodexVersionChecker.automaticUpdateShouldStart(
            now: now,
            lastAttemptAt: lastAutomaticCodexUpdateAttemptAt,
            lastFailureAt: lastAutomaticCodexUpdateFailureAt,
            isInFlight: automaticCodexUpdateTask != nil,
            runtimeRepairRequired: completeCodexHotSwapRuntimeMissing
        ) else { return }

        lastAutomaticCodexUpdateAttemptAt = now
        UserDefaults.standard.set(now, forKey: Self.automaticCodexUpdateLastAttemptKey)
        let finish: @MainActor @Sendable (
            CodexVersionChecker.AutomaticUpdateDisposition
        ) -> Void = { [weak self] disposition in
            self?.finishAutomaticCodexUpdate(disposition)
        }
        automaticCodexUpdateTask = Task.detached(priority: .utility) {
            let disposition = CodexVersionChecker.performAutomaticUpdateIfNeeded()
            await finish(disposition)
        }
    }

    private func finishAutomaticCodexUpdate(
        _ disposition: CodexVersionChecker.AutomaticUpdateDisposition
    ) {
        automaticCodexUpdateTask = nil
        guard !isExiting else { return }

        switch disposition {
        case .upToDate(let version):
            completeCodexHotSwapRuntimeMissing = false
            clearAutomaticCodexUpdateFailure()
            SwapLog.append(.debug("CODEX_AUTO_UPDATE status=up_to_date version=\(version)"))
        case .deferred(let reason):
            clearAutomaticCodexUpdateFailure()
            SwapLog.append(.debug("CODEX_AUTO_UPDATE status=deferred reason=\(reason)"))
        case .failed(let reason):
            let failedAt = Date()
            lastAutomaticCodexUpdateFailureAt = failedAt
            UserDefaults.standard.set(
                failedAt,
                forKey: Self.automaticCodexUpdateLastFailureKey
            )
            SwapLog.append(.debug("CODEX_AUTO_UPDATE status=failed backoff_hours=6 reason=\(reason)"))
        }
    }

    private func clearAutomaticCodexUpdateFailure() {
        lastAutomaticCodexUpdateFailureAt = nil
        UserDefaults.standard.removeObject(forKey: Self.automaticCodexUpdateLastFailureKey)
    }

    private func scheduleDesktopPatchCheckIfNeeded(force: Bool = false) {
        let installationChanged = recordDesktopPatchInstallationFingerprintChange()
        let effectiveForce = force || installationChanged
        let now = Date()
        if !effectiveForce, let lastDesktopPatchCheck, now.timeIntervalSince(lastDesktopPatchCheck) < 15 * 60 {
            return
        }
        lastDesktopPatchCheck = now
        if installationChanged {
            SwapLog.append(.debug("DESKTOP_PATCH_INSTALLATION_CHANGED"))
        }
        Task.detached {
            let outcome = DesktopPatchManager.checkAndPatchIfPossible(
                ignoreCooldown: effectiveForce,
                ignorePermissionDeniedBackoff: effectiveForce
            )
            if installationChanged {
                SwapLog.append(.debug("DESKTOP_PATCH_INSTALLATION_CHANGE_CHECK outcome=\(outcome.logValue)"))
            }
        }
    }

    private func recordDesktopPatchInstallationFingerprintChange() -> Bool {
        let currentFingerprint = DesktopPatchManager.installationFingerprint()
        defer {
            lastDesktopPatchInstallationFingerprint = currentFingerprint
            hasObservedDesktopPatchInstallationFingerprint = true
        }

        guard hasObservedDesktopPatchInstallationFingerprint else {
            return false
        }
        guard currentFingerprint != nil else {
            return false
        }
        return lastDesktopPatchInstallationFingerprint != currentFingerprint
    }

    private func handleDesktopApplicationsDirectoryChange(
        _ disposition: CodexDesktopApplicationsChangeDisposition
    ) {
        switch disposition {
        case .externalChange:
            scheduleDesktopPatchCheckIfNeeded()
            desktopUpdateCoordinator.checkNow(reason: "applications-directory-change")
        case .internalTransactionCompleted(let transaction):
            handleDesktopUpdateTransactionCompletion(transaction)
        case .internalTransactionChangeSuppressed(let identifier):
            SwapLog.append(
                .debug("DESKTOP_INSTALLATION_WATCH_SUPPRESSED transaction=\(identifier)")
            )
        }
    }

    private func handleDesktopUpdateTransactionCompletion(
        _ transaction: CodexDesktopInstallationTransactionCompletion
    ) {
        guard transaction.committed else {
            SwapLog.append(
                .debug("DESKTOP_UPDATE_TRANSACTION_ROLLED_BACK transaction=\(transaction.identifier)")
            )
            return
        }
        guard handledDesktopUpdateTransactionIdentifiers.insert(transaction.identifier).inserted else {
            return
        }
        if handledDesktopUpdateTransactionIdentifiers.count > 128,
           let oldest = handledDesktopUpdateTransactionIdentifiers.min() {
            handledDesktopUpdateTransactionIdentifiers.remove(oldest)
        }

        switch transaction.kind {
        case .stagedUpdate:
            scheduleDesktopPatchRetryBurst(
                reason: "desktop_update_installed",
                relaunchAfterCompletion: true
            )
        case .stockRestore:
            scheduleDesktopPatchCheckIfNeeded(force: true)
        }
    }

    private func scheduleDesktopPatchRetryBurst(
        reason: String,
        relaunchAfterCompletion: Bool = false
    ) {
        desktopPatchRetryTask?.cancel()
        desktopPatchRetryTask = Task.detached {
            let retryDelays = DesktopPatchManager.postQuitPatchRetryDelaysSeconds
            for (index, delaySeconds) in retryDelays.enumerated() {
                let nanoseconds = UInt64(delaySeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }

                let outcome = DesktopPatchManager.checkAndPatchIfPossible(
                    ignoreCooldown: true,
                    ignorePermissionDeniedBackoff: true
                )
                SwapLog.append(
                    .debug(
                        "DESKTOP_PATCH_RETRY reason=\(reason) delay_seconds=\(Int(delaySeconds)) outcome=\(outcome.logValue)"
                    )
                )
                switch Self.desktopPatchRetryDisposition(
                    after: outcome,
                    hasRemainingAttempts: index + 1 < retryDelays.count,
                    relaunchAfterCompletion: relaunchAfterCompletion
                ) {
                case .retry:
                    continue
                case .stop:
                    return
                case .relaunch:
                    Self.relaunchDesktopAppAfterUpdate()
                    return
                }
            }
        }
    }

    nonisolated static func desktopPatchRetryDisposition(
        after outcome: DesktopPatchAttemptOutcome,
        hasRemainingAttempts: Bool,
        relaunchAfterCompletion: Bool
    ) -> AppDelegateDesktopPatchRetryDisposition {
        switch outcome {
        case .completed, .notNeeded:
            return relaunchAfterCompletion ? .relaunch : .stop
        default:
            guard !outcome.shouldStopPostQuitRetry, hasRemainingAttempts else {
                return .stop
            }
            return .retry
        }
    }

    nonisolated static func desktopUpdateRelaunchArguments(appPath: String) -> [String] {
        ["-g", appPath]
    }

    nonisolated private static func relaunchDesktopAppAfterUpdate() {
        guard let appPath = CodexDesktopAppLocator.locate()?.appPath else { return }
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: desktopUpdateRelaunchArguments(appPath: appPath),
            timeout: 15
        )
        SwapLog.append(
            .debug(
                "DESKTOP_UPDATE_RELAUNCH path=\(appPath) status=\(result.terminationStatus) timed_out=\(result.timedOut)"
            )
        )
    }

    private func scheduleCodexBrowserSessionRepairIfNeeded(force: Bool = false) {
        let now = Date()
        if !force,
           let lastCodexBrowserSessionRepairCheck,
           now.timeIntervalSince(lastCodexBrowserSessionRepairCheck) < 60 * 60 {
            return
        }
        lastCodexBrowserSessionRepairCheck = now
        Task.detached {
            let result = CodexBrowserSessionRepair.repairStalePartitionIfSafe()
            switch result {
            case .repaired(let backupPath):
                SwapLog.append(.debug("CODEX_BROWSER_SESSION_REPAIRED backup=\(backupPath)"))
            case .skipped(let reason):
                SwapLog.append(.debug("CODEX_BROWSER_SESSION_REPAIR_SKIPPED reason=\(reason)"))
            case .failed(let message):
                SwapLog.append(.debug("CODEX_BROWSER_SESSION_REPAIR_FAILED message=\(message)"))
            case .notNeeded:
                break
            }
        }
    }

    private func scheduleConfigMaintenanceIfNeeded(removeStaleCopies: Bool = false) {
        guard configMaintenanceTask == nil else { return }
        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            self?.finishConfigMaintenance()
        }
        configMaintenanceTask = Task.detached(priority: .utility) {
            CodexConfigRepair.repairDefaultConfigIfNeeded(removeStaleCopies: removeStaleCopies)
            await finish()
        }
    }

    private func finishConfigMaintenance() {
        configMaintenanceTask = nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationFlushCompleted { return .terminateNow }
        guard terminationFlushTask == nil else { return .terminateLater }

        let persistence = accountPersistence
        let accounts = accountManager.accounts
        accountPersistenceRevision &+= 1
        let revision = accountPersistenceRevision
        terminationFlushTask = Task { @MainActor [weak self, weak sender] in
            do {
                try await persistence.persistDurably(accounts, revision: revision)
                SwapLog.append(.debug(
                    "ACCOUNTS_PERSISTED context=termination-flush revision=\(revision)"
                ))
            } catch {
                logger.error("Final account persistence flush failed: \(error.localizedDescription)")
                SwapLog.append(.debug(
                    "ACCOUNTS_PERSIST_FAILED context=termination-flush error=\(error.localizedDescription)"
                ))
            }
            guard let self else { return }
            self.terminationFlushCompleted = true
            self.terminationFlushTask = nil
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let codexAppTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(codexAppTerminationObserver)
            self.codexAppTerminationObserver = nil
        }
        desktopInstallationWatcher.stop()
        desktopUpdateCoordinator.stop()
        cleanupBeforeExit()
        let poller = quotaPoller
        Task {
            await poller.stopAll()
        }
    }

    private func handleCodexAppDidTerminate(bundleIdentifier: String?, bundlePath: String?) {
        guard bundleIdentifier == "com.openai.codex"
            || CodexDesktopAppLocator.defaultAppPaths.contains(bundlePath ?? "") else {
            return
        }

        codexAppTerminationTask?.cancel()
        let taskIdentifier = UUID()
        codexAppTerminationTaskIdentifier = taskIdentifier
        codexAppTerminationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.codexAppTerminationTaskIdentifier == taskIdentifier {
                    self.codexAppTerminationTask = nil
                    self.codexAppTerminationTaskIdentifier = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            guard !Task.isCancelled, !self.isExiting else { return }
            let result = CodexBrowserSessionRepair.repairStalePartitionIfSafe()
            switch result {
            case .repaired(let backupPath):
                SwapLog.append(.debug("CODEX_BROWSER_SESSION_REPAIRED backup=\(backupPath) reason=codex_app_terminated"))
            case .skipped(let reason):
                SwapLog.append(.debug("CODEX_BROWSER_SESSION_REPAIR_SKIPPED reason=\(reason) trigger=codex_app_terminated"))
            case .failed(let message):
                SwapLog.append(.debug("CODEX_BROWSER_SESSION_REPAIR_FAILED message=\(message) trigger=codex_app_terminated"))
            case .notNeeded:
                break
            }
            self.desktopUpdateCoordinator.desktopAppDidTerminate { [weak self] installedUpdate, transaction in
                guard let self else { return }
                if let transaction {
                    self.handleDesktopUpdateTransactionCompletion(transaction)
                } else {
                    self.scheduleDesktopPatchRetryBurst(
                        reason: installedUpdate ? "desktop_update_installed" : "codex_app_terminated"
                    )
                }
            }
        }
    }

    // MARK: - Account Management

    private func loadAccounts() async {
        do {
            let accounts = try await accountPersistence.loadAll()
            guard accountManager.restorePersistedAccounts(accounts) else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "persisted accounts cannot replace an initialized account manager"
                )
            }
            await restoreAccountActivationState()
            _ = await restoreRateLimitResetJournalState()
            let primedDates = await weeklyPrimer.persistedFiveHourPrimedAt()
            for (id, date) in primedDates {
                if accountManager.accounts.first(where: { $0.id == id })?.realQuotaSnapshot?.fiveHour != nil {
                    accountManager.markFiveHourPrimed(for: id, at: date)
                }
            }
        } catch {
            logger.error("Failed to load accounts: \(error.localizedDescription)")
        }
    }

    private func restoreRateLimitResetJournalState() async -> Bool {
        let capturedSuppressionRevisions = manualRateLimitResetSwapSuppressionRevisions
        do {
            let attempts = try await rateLimitResetService.allAttempts()
            rateLimitResetUnresolvedProviderAccountIds = Set(attempts.compactMap { attempt in
                attempt.state.isTerminal ? nil : attempt.normalizedProviderAccountId
            })
            applyRestoredManualRateLimitResetSwapSuppressions(
                Self.manualRateLimitResetSwapSuppressions(attempts: attempts),
                capturedRevisions: capturedSuppressionRevisions
            )
            rateLimitResetJournalStateIsReadable = true
            rateLimitResetJournalFailureLogged = false
            return true
        } catch {
            rateLimitResetJournalStateIsReadable = false
            if !rateLimitResetJournalFailureLogged {
                rateLimitResetJournalFailureLogged = true
                SwapLog.append(.debug(
                    "RESET_JOURNAL_UNAVAILABLE automatic_routing=suppressed error=\(error.localizedDescription)"
                ))
            }
            return false
        }
    }

    private func ensureRateLimitResetJournalStateIsReadable() async -> Bool {
        if rateLimitResetJournalStateIsReadable { return true }
        return await restoreRateLimitResetJournalState()
    }

    private func recordRateLimitResetJournalFailureIfNeeded(
        _ error: Error,
        context: String
    ) {
        guard let serviceError = error as? RateLimitResetServiceError,
              case .journalUnavailable = serviceError else {
            return
        }
        rateLimitResetJournalStateIsReadable = false
        if !rateLimitResetJournalFailureLogged {
            rateLimitResetJournalFailureLogged = true
            SwapLog.append(.debug(
                "RESET_JOURNAL_UNAVAILABLE context=\(context) automatic_routing=suppressed error=\(error.localizedDescription)"
            ))
        }
    }

    private func restoreAccountActivationState() async {
        let recovered: AccountActivationState
        do {
            guard let stored = try await accountActivationCoordinator.load() else {
                await bootstrapActivationWithoutJournal()
                return
            }
            guard stored.phase != .manualReview else {
                if stored.detail == .fileCommitFailed,
                   let durableTarget = accountManager.configuredAccount,
                   Self.accountStoreMatches(
                       account: durableTarget,
                       accounts: accountManager.accounts
                   ),
                   Self.authFileMatches(
                       account: durableTarget,
                       atPath: Self.codexAuthPath
                   ) {
                    let recovered = try await accountActivationCoordinator
                        .recoverFileCommitFailure(
                            targetAccountId: durableTarget.id
                        )
                    clearManualOverride()
                    accountManager.publishActivationState(recovered)
                    SwapLog.append(.debug(
                        "ACTIVATION_FILE_COMMIT_FAILURE_RECOVERED target=\(durableTarget.id.uuidString) previous_target=\(stored.configuredAccountId?.uuidString ?? "none")"
                    ))
                    return
                }
                if !AccountActivationRecoveryCoordinator
                    .manualReviewSelectionIsUnambiguous(
                        accounts: accountManager.accounts,
                        targetAccountId: stored.configuredAccountId
                    ) {
                    accountManager.clearConfiguredAccount()
                }
                accountManager.publishActivationState(stored)
                return
            }
            guard let targetAccountId = stored.configuredAccountId,
                  let target = accountManager.accounts.first(where: { $0.id == targetAccountId }) else {
                await enterActivationManualReview(
                    targetAccountId: stored.configuredAccountId,
                    detail: .configuredTargetMissing
                )
                return
            }
            let authObservation = await Task.detached(priority: .userInitiated) {
                AccountImporter.observeCurrentAccount()
            }.value
            switch authObservation {
            case .absent:
                await enterActivationManualReview(
                    targetAccountId: target.id,
                    detail: .externalAuthAbsent
                )
                return
            case .invalid:
                await enterActivationManualReview(
                    targetAccountId: target.id,
                    detail: .externalAuthInvalid
                )
                return
            case .unreadable:
                await enterActivationManualReview(
                    targetAccountId: target.id,
                    detail: .externalAuthUnreadable
                )
                return
            case .valid(let observed) where !Self.credentialsMatch(target, observed):
                await enterActivationManualReview(
                    targetAccountId: target.id,
                    detail: .configuredFilesInconsistent
                )
                return
            case .valid:
                break
            }
            let selectedIds = accountManager.accounts.filter(\.isActive).map(\.id)
            guard selectedIds == [target.id],
                  Self.authFileMatches(account: target, atPath: Self.codexAuthPath) else {
                await enterActivationManualReview(
                    targetAccountId: target.id,
                    detail: .configuredFilesInconsistent
                )
                return
            }

            if stored.phase == .preparing {
                recovered = try await accountActivationCoordinator.markCommittedDegraded(
                    targetAccountId: target.id,
                    discoveredRuntimeCount: 0,
                    acknowledgedRuntimeCount: 0,
                    detail: .restartRecoveredCommittedFiles
                )
            } else {
                recovered = stored
            }
            accountManager.publishActivationState(recovered)
            SwapLog.append(.debug(
                "ACTIVATION_JOURNAL_RECOVERED phase=\(recovered.phase.rawValue) target=\(target.id.uuidString)"
            ))
        } catch {
            accountManager.publishActivationState(.manualReview(
                targetAccountId: nil,
                detail: .journalUnavailable,
                at: Date()
            ))
            SwapLog.append(.debug(
                "ACTIVATION_JOURNAL_RECOVERY_FAILED automatic_mutation=blocked error=\(error.localizedDescription)"
            ))
        }
    }

    private func bootstrapActivationWithoutJournal() async {
        let observation = await Task.detached(priority: .userInitiated) {
            AccountImporter.observeCurrentAccount()
        }.value
        let observedAccount: CodexAccount?
        switch observation {
        case .absent:
            observedAccount = nil
        case .valid(let account):
            observedAccount = account
        case .invalid:
            await enterActivationManualReview(
                targetAccountId: accountManager.configuredAccount?.id,
                detail: .externalAuthInvalid
            )
            return
        case .unreadable:
            await enterActivationManualReview(
                targetAccountId: accountManager.configuredAccount?.id,
                detail: .externalAuthUnreadable
            )
            return
        }

        if let observedAccount,
           !accountManager.accounts.contains(where: {
               $0.accountId == observedAccount.accountId
           }) {
            await enterActivationManualReview(
                targetAccountId: nil,
                detail: .externalAuthTargetUnknown
            )
            return
        }

        let previousConfigured = accountManager.configuredAccount
        let recovery = accountManager.restoreConfiguredAccount(
            observedProviderAccountId: observedAccount?.accountId
        )
        if recovery == .ambiguous {
            await enterActivationManualReview(
                targetAccountId: nil,
                detail: .configuredFilesInconsistent
            )
            return
        }
        guard var target = accountManager.configuredAccount else {
            accountManager.publishActivationState(nil)
            return
        }
        guard observedAccount != nil else {
            await enterActivationManualReview(
                targetAccountId: target.id,
                detail: .externalAuthAbsent
            )
            return
        }
        if let observedAccount {
            target.email = observedAccount.email
            target.accountId = observedAccount.accountId
            target.accessToken = observedAccount.accessToken
            target.refreshToken = observedAccount.refreshToken
            target.idToken = observedAccount.idToken
            target.lastRefreshed = observedAccount.lastRefreshed ?? target.lastRefreshed
        }

        do {
            let durableAccounts = try await accountPersistence.loadAll()
            if Self.accountStoreMatches(account: target, accounts: durableAccounts),
               Self.authFileMatches(account: target, atPath: Self.codexAuthPath) {
                let state = try await accountActivationCoordinator.bootstrapCommittedDegraded(
                    targetAccountId: target.id,
                    detail: .launchRuntimeEvidenceExpired
                )
                accountManager.publishActivationState(state)
                return
            }

            _ = await withPreparedActiveCredentialMutation(
                targetAccountId: target.id,
                expectedConfiguredAccountId: accountManager.configuredAccount?.id,
                source: "launch-activation-bootstrap",
                isManual: false
            ) { [weak self] prepared in
                guard let self else { return false }
                return await self.commitConfiguredCredentialMutation(
                    from: previousConfigured ?? target,
                    to: target,
                    reason: .manual,
                    mutationRoute: .externalAuthObservation,
                    persistenceContext: "launch-activation-bootstrap",
                    authAlreadyConfigured: true,
                    swapStart: Date(),
                    prepared: prepared,
                    recordsSwap: false,
                    committedDetail: .launchRuntimeEvidenceExpired
                )
            }
        } catch {
            await enterActivationManualReview(
                targetAccountId: target.id,
                detail: .journalUnavailable
            )
            SwapLog.append(.debug(
                "ACTIVATION_BOOTSTRAP_FAILED target=\(target.id.uuidString) error=\(error.localizedDescription)"
            ))
        }
    }

    private func enterActivationManualReview(
        targetAccountId: UUID?,
        detail: AccountActivationDetail,
        authorizeEffect: @escaping AccountActivationCoordinator.StateEffectAuthorization = {
            _ in true
        }
    ) async {
        do {
            let state = try await accountActivationCoordinator.markManualReview(
                targetAccountId: targetAccountId,
                detail: detail,
                authorizeEffect: authorizeEffect
            )
            accountManager.publishActivationState(state)
        } catch AccountActivationCoordinatorError.authorizationRevoked {
            SwapLog.append(.debug(
                "ACTIVATION_MANUAL_REVIEW_SKIPPED detail=\(detail.rawValue) reason=authorization_revoked"
            ))
        } catch {
            guard authorizeEffect(accountManager.activationState) else {
                SwapLog.append(.debug(
                    "ACTIVATION_MANUAL_REVIEW_SKIPPED detail=\(detail.rawValue) reason=authorization_revoked_after_failure"
                ))
                return
            }
            accountManager.publishActivationState(.manualReview(
                targetAccountId: targetAccountId,
                detail: detail,
                activationGeneration: accountManager.activationState?.activationGeneration
                    ?? UUID(),
                retryAttempt: accountManager.activationState?.retryAttempt ?? 0,
                at: Date()
            ))
            SwapLog.append(.debug(
                "ACTIVATION_MANUAL_REVIEW_PERSIST_FAILED detail=\(detail.rawValue) error=\(error.localizedDescription)"
            ))
        }
        statusBarController?.updateIcon()
        updatePopoverContent()
    }

    nonisolated static func persistAccountsSnapshot(
        _ accounts: [CodexAccount],
        using save: ([CodexAccount]) throws -> Void
    ) -> AppDelegateAccountsPersistenceOutcome {
        do {
            try save(accounts)
            return .persisted
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    nonisolated static func installKeepAliveOffMainActor(
        operation: @escaping @Sendable () -> Void = {
            CodexSwitchKeepAlive.installIfNeeded()
        }
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            operation()
        }
    }

    @discardableResult
    nonisolated static func installDesktopBridgeOffMainActor(
        operation: @escaping @Sendable () -> Void = {
            CodexDesktopBridgeKeepAlive.installIfNeeded()
        }
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            operation()
        }
    }

    nonisolated static func authFileMatches(
        account: CodexAccount,
        atPath path: String
    ) -> Bool {
        guard case .valid(let observed) = AccountImporter.observeCurrentAccount(from: path) else {
            return false
        }
        return credentialsMatch(account, observed)
    }

    nonisolated static func durableConfiguredFilesStatus(
        account: CodexAccount,
        accounts: [CodexAccount],
        authObservation: AccountAuthObservation
    ) -> AppDelegateDurableConfigurationStatus {
        guard accountStoreMatches(account: account, accounts: accounts) else {
            return .mismatch
        }

        switch authObservation {
        case .valid(let observed):
            return credentialsMatch(account, observed) ? .matches : .mismatch
        case .unreadable:
            return .unavailable
        case .invalid(.ancestorChanged), .invalid(.changedDuringRead):
            return .unavailable
        case .absent, .invalid:
            return .mismatch
        }
    }

    nonisolated static func accountStoreMatches(
        account: CodexAccount,
        accounts: [CodexAccount]
    ) -> Bool {
        guard accounts.filter(\.isActive).map(\.id) == [account.id],
              let persisted = accounts.first(where: { $0.id == account.id }) else {
            return false
        }
        return persisted.accountId == account.accountId
            && persisted.accessToken == account.accessToken
            && persisted.refreshToken == account.refreshToken
            && persisted.idToken == account.idToken
    }

    nonisolated static func accountStoreHasNoConfiguredAccount(
        _ accounts: [CodexAccount]
    ) -> Bool {
        accounts.allSatisfy { !$0.isActive }
    }

    nonisolated static func credentialsMatch(
        _ lhs: CodexAccount,
        _ rhs: CodexAccount
    ) -> Bool {
        lhs.accountId == rhs.accountId
            && lhs.accessToken == rhs.accessToken
            && lhs.refreshToken == rhs.refreshToken
            && lhs.idToken == rhs.idToken
    }

    nonisolated static func reauthenticationPreservesStableProviderIdentity(
        original: CodexAccount,
        observed: CodexAccount
    ) -> Bool {
        !original.accountId.isEmpty && original.accountId == observed.accountId
    }

    nonisolated static func activeCredentialMutationSource(
        existing: CodexAccount?,
        imported: CodexAccount
    ) -> CodexAccount {
        existing ?? imported
    }

    private func durableConfiguredFilesStatus(
        _ account: CodexAccount
    ) async -> AppDelegateDurableConfigurationStatus {
        do {
            let accounts = try await accountPersistence.loadAll()
            let status = Self.durableConfiguredFilesStatus(
                account: account,
                accounts: accounts,
                authObservation: AccountImporter.observeCurrentAccount(
                    from: Self.codexAuthPath
                )
            )
            if status == .unavailable {
                SwapLog.append(.debug(
                    "ACTIVATION_DURABLE_READ_UNAVAILABLE target=\(account.id.uuidString) source=auth"
                ))
            }
            return status
        } catch {
            SwapLog.append(.debug(
                "ACTIVATION_DURABLE_READ_FAILED target=\(account.id.uuidString) error=\(error.localizedDescription)"
            ))
            return .unavailable
        }
    }

    private func durableConfiguredFilesMatch(_ account: CodexAccount) async -> Bool {
        await durableConfiguredFilesStatus(account) == .matches
    }

    static func runtimePermitAllowsDurableConfiguration(
        _ status: AppDelegateDurableConfigurationStatus,
        requiredPhase: AccountActivationPhase,
        enterManualReview: () async -> Void
    ) async -> Bool {
        switch status {
        case .matches:
            return true
        case .unavailable where requiredPhase == .confirmed:
            return false
        case .mismatch, .unavailable:
            await enterManualReview()
            return false
        }
    }

    private func durableConfigurationAllowsRuntimePermit(
        for account: CodexAccount,
        activationGeneration: UUID,
        requiredPhase: AccountActivationPhase,
        policyAuthority: AccountAutomaticPolicyAuthority? = nil
    ) async -> Bool {
        guard policyAuthority?.authorizes() ?? true else { return false }
        let status = await durableConfiguredFilesStatus(account)
        guard policyAuthority?.authorizes() ?? true else { return false }
        if status == .unavailable, requiredPhase == .confirmed {
            SwapLog.append(.debug(
                "ACTIVATION_CONFIRMED_EVIDENCE_REFRESH_DEFERRED target=\(account.id.uuidString) reason=durable_read_unavailable"
            ))
        }
        return await Self.runtimePermitAllowsDurableConfiguration(
            status,
            requiredPhase: requiredPhase
        ) {
            guard policyAuthority?.authorizes() ?? true else { return }
            guard self.accountManager.activationState?.phase == requiredPhase,
                  self.accountManager.activationState?.configuredAccountId == account.id,
                  self.accountManager.activationState?.activationGeneration
                    == activationGeneration else {
                return
            }
            await self.enterActivationManualReview(
                targetAccountId: account.id,
                detail: .durableConfigurationChanged
            )
        }
    }

    private func durableAccountStoreMatches(_ account: CodexAccount) async -> Bool {
        do {
            return Self.accountStoreMatches(
                account: account,
                accounts: try await accountPersistence.loadAll()
            )
        } catch {
            SwapLog.append(.debug(
                "ACTIVATION_DURABLE_STORE_READ_FAILED target=\(account.id.uuidString) error=\(error.localizedDescription)"
            ))
            return false
        }
    }

    private func durableAccountStoreHasNoConfiguredAccount() async -> Bool {
        do {
            return Self.accountStoreHasNoConfiguredAccount(
                try await accountPersistence.loadAll()
            )
        } catch {
            SwapLog.append(.debug(
                "ACTIVATION_DURABLE_STORE_READ_FAILED target=none error=\(error.localizedDescription)"
            ))
            return false
        }
    }

    private func captureFreshLocalRuntimeEvidence(
        for account: CodexAccount,
        policyAuthority: AccountAutomaticPolicyAuthority? = nil
    ) async -> AccountActivationRuntimeEvidenceDecision {
        guard policyAuthority?.authorizes() ?? true else {
            return .denied(
                detail: .runtimeEvidenceExpired,
                discoveredRuntimeCount: 0,
                acknowledgedRuntimeCount: 0
            )
        }
        let expectedAuthIdentity: CodexAuthFileIdentity? = await Task.detached(priority: .userInitiated) {
            let authURL = URL(fileURLWithPath: Self.codexAuthPath)
            guard Self.authFileMatches(account: account, atPath: Self.codexAuthPath),
                  let expectedAuthIdentity = SwapEngine.authFileIdentity(
                      at: authURL,
                      requiredOwnerUID: UInt32(getuid())
                  ) else {
                return nil
            }
            return expectedAuthIdentity
        }.value
        guard policyAuthority?.authorizes() ?? true,
              let expectedAuthIdentity else {
            return .denied(
                detail: .durableConfigurationChanged,
                discoveredRuntimeCount: 0,
                acknowledgedRuntimeCount: 0
            )
        }

        let decision = await AccountActivationRuntimeEvidencePreflight.renewAndEvaluate(
            expectedAccountId: account.id,
            expectedAuthIdentity: expectedAuthIdentity,
            renew: {
                await AccountActivationRuntimeEvidencePreflight.performRenewal(
                    desktopReload: {
                        guard policyAuthority?.authorizes() ?? true else {
                            return .failed("automatic policy lease expired")
                        }
                        return await DesktopRuntimeReloadClient().reloadAuth(
                            account: account,
                            authorizeEffect: {
                                policyAuthority?.authorizes() ?? true
                            }
                        )
                    },
                    cliReload: {
                        guard policyAuthority?.authorizes() ?? true else {
                            return CodexReloadSummary(
                                discoveredRuntimeCount: 0,
                                acknowledgedRuntimeCount: 0,
                                operationFailed: true
                            )
                        }
                        return await Task.detached(priority: .userInitiated) {
                            SwapEngine.signalCodexReload(
                                authorizeEffect: {
                                    policyAuthority?.authorizes() ?? true
                                }
                            )
                        }.value
                    }
                )
            },
            capture: {
                guard policyAuthority?.authorizes() ?? true else { return nil }
                let snapshots = await Task.detached(priority: .userInitiated) { () -> AccountActivationRuntimeSnapshotSet? in
                    let authURL = URL(fileURLWithPath: Self.codexAuthPath)
                    guard Self.authFileMatches(
                        account: account,
                        atPath: Self.codexAuthPath
                    ), SwapEngine.authFileIdentity(
                        at: authURL,
                        requiredOwnerUID: UInt32(getuid())
                    ) == expectedAuthIdentity else {
                        return nil
                    }
                    return AccountActivationRuntimeSnapshotSet(
                        cli: SwapEngine.localRuntimeEvidenceSnapshot(
                            runtimeKind: .localInteractiveCLI
                        ),
                        desktop: SwapEngine.localRuntimeEvidenceSnapshot(
                            runtimeKind: .externalAppServer
                        ),
                        observedAt: Date()
                    )
                }.value
                guard policyAuthority?.authorizes() ?? true else { return nil }
                return snapshots
            },
            runtimeBindingIsCurrent: { binding in
                SwapEngine.reloadBindingIsCurrent(binding)
            }
        )
        guard policyAuthority?.authorizes() ?? true else {
            return .denied(
                detail: .runtimeEvidenceExpired,
                discoveredRuntimeCount: 0,
                acknowledgedRuntimeCount: 0
            )
        }
        return decision
    }

    private func revalidatedRuntimeEvidence(
        _ expected: AccountActivationRuntimeEvidence,
        for account: CodexAccount
    ) async -> AccountActivationRuntimeEvidence? {
        guard case .confirmed(let current) = await captureFreshLocalRuntimeEvidence(
            for: account
        ), expected.hasSameRuntimeTopology(as: current) else {
            return nil
        }
        return current
    }

    private func activationStateForRequest(
        at _: Date = Date(),
        policyAuthority: AccountAutomaticPolicyAuthority? = nil
    ) async -> AccountActivationState? {
        do {
            let durable = try await accountActivationCoordinator.load()
            guard policyAuthority?.authorizes() ?? true else { return nil }
            if durable != accountManager.activationState {
                accountManager.publishActivationState(durable)
                statusBarController?.updateIcon()
                updatePopoverContent()
            }
            return durable
        } catch {
            guard policyAuthority?.authorizes() ?? true else { return nil }
            await enterActivationManualReview(
                targetAccountId: accountManager.activationState?.configuredAccountId,
                detail: .journalUnavailable
            )
            return nil
        }
    }

    private func requireFreshLocalRuntimePermit(
        for account: CodexAccount,
        activationGeneration: UUID,
        requiredPhase: AccountActivationPhase,
        policyAuthority: AccountAutomaticPolicyAuthority? = nil
    ) async -> AccountActivationRuntimePermit? {
        guard policyAuthority?.authorizes() ?? true,
              accountManager.activationState?.phase == requiredPhase,
              accountManager.activationState?.configuredAccountId == account.id,
              accountManager.activationState?.activationGeneration == activationGeneration,
              accountManager.configuredAccount?.id == account.id else {
            guard policyAuthority?.authorizes() ?? true else { return nil }
            await enterActivationManualReview(
                targetAccountId: account.id,
                detail: .durableConfigurationChanged
            )
            return nil
        }
        guard await durableConfigurationAllowsRuntimePermit(
            for: account,
            activationGeneration: activationGeneration,
            requiredPhase: requiredPhase,
            policyAuthority: policyAuthority
        ) else {
            return nil
        }

        let decision = await captureFreshLocalRuntimeEvidence(
            for: account,
            policyAuthority: policyAuthority
        )
        guard policyAuthority?.authorizes() ?? true,
              accountManager.activationState?.phase == requiredPhase,
              accountManager.activationState?.configuredAccountId == account.id,
              accountManager.activationState?.activationGeneration == activationGeneration,
              accountManager.configuredAccount?.id == account.id else {
            guard policyAuthority?.authorizes() ?? true else { return nil }
            await enterActivationManualReview(
                targetAccountId: account.id,
                detail: .durableConfigurationChanged
            )
            return nil
        }
        guard await durableConfigurationAllowsRuntimePermit(
            for: account,
            activationGeneration: activationGeneration,
            requiredPhase: requiredPhase,
            policyAuthority: policyAuthority
        ) else {
            return nil
        }

        switch decision {
        case .confirmed(let evidence):
            guard evidence.runtimeCurrentAccountId == account.id else {
                return nil
            }
            if requiredPhase == .confirmed {
                guard policyAuthority?.authorizes() ?? true else { return nil }
                do {
                    let refreshed = try await accountActivationCoordinator
                        .refreshConfirmedRuntimeEvidence(
                            targetAccountId: account.id,
                            expectedActivationGeneration: activationGeneration,
                            evidence: evidence,
                            authorizeEffect: { state in
                                (policyAuthority?.authorizes() ?? true)
                                    && state?.phase == requiredPhase
                                    && state?.configuredAccountId == account.id
                                    && state?.activationGeneration == activationGeneration
                            }
                        )
                    guard policyAuthority?.authorizes() ?? true else { return nil }
                    guard refreshed.phase == requiredPhase,
                          refreshed.configuredAccountId == account.id,
                          refreshed.activationGeneration == activationGeneration else {
                        return nil
                    }
                    accountManager.publishActivationState(refreshed)
                } catch {
                    guard policyAuthority?.authorizes() ?? true else { return nil }
                    await enterActivationManualReview(
                        targetAccountId: account.id,
                        detail: .runtimeEvidencePersistFailed
                    )
                    return nil
                }
            }
            let permit = AccountActivationRuntimePermit(
                targetAccountId: account.id,
                activationGeneration: activationGeneration,
                requiredPhase: requiredPhase,
                evidence: evidence
            )
            guard permit.authorizes(state: accountManager.activationState, at: Date()) else {
                return nil
            }
            return permit
        case .denied(let detail, let discovered, let acknowledged):
            guard requiredPhase != .confirmed,
                  policyAuthority?.authorizes() ?? true else {
                return nil
            }
            do {
                let degraded = try await accountActivationCoordinator.demoteForRuntimeEvidenceLoss(
                    targetAccountId: account.id,
                    expectedActivationGeneration: activationGeneration,
                    detail: detail,
                    discoveredRuntimeCount: discovered,
                    acknowledgedRuntimeCount: acknowledged
                )
                accountManager.publishActivationState(degraded)
            } catch {
                guard policyAuthority?.authorizes() ?? true else { return nil }
                await enterActivationManualReview(
                    targetAccountId: account.id,
                    detail: .runtimeEvidencePersistFailed
                )
            }
            return nil
        }
    }

    @discardableResult
    private func commitActiveAuthFile(
        for account: CodexAccount,
        reason: String,
        permit: AccountActivationEffectPermit
    ) async -> Bool {
        let result = await accountActivationCredentialCommitter.persistAuth(
            for: account,
            path: Self.codexAuthPath,
            permit: permit
        )
        switch result {
        case .committed:
            SwapLog.append(.authFileWritten(accountId: account.accountId))
            return true
        case .authorizationLost:
            surfaceActiveAuthCommitFailure(
                account: account,
                reason: reason,
                detail: "activation authorization changed before auth persistence"
            )
            return false
        case .failed(let detail):
            surfaceActiveAuthCommitFailure(
                account: account,
                reason: reason,
                detail: detail
            )
            return false
        }
    }

    private func surfaceActiveAuthCommitFailure(
        account: CodexAccount,
        reason: String,
        detail: String
    ) {
        let message = "Auth update failed; runtime reload skipped"
        accountManager.updatePollingError(for: account.id, error: message)
        SwapLog.append(.authFileError(error: "\(reason): \(detail)"))
        logger.error("Active auth commit failed for \(account.email, privacy: .private), reason=\(reason, privacy: .public): \(detail, privacy: .public)")
        statusBarController?.updateIcon()
        updatePopoverContent()
    }

    nonisolated static func requestOwnedMutationTaskCancellation(
        _ task: Task<Void, Never>?
    ) {
        task?.cancel()
    }

    nonisolated static func vpsStatusPreservingReadinessIdentity(
        _ readinessStatus: LinuxDevboxStatus,
        summary: String
    ) -> LinuxDevboxStatus {
        LinuxDevboxStatus(
            state: .ready,
            summary: summary,
            activeEmail: readinessStatus.activeEmail,
            activeProviderAccountId: readinessStatus.activeProviderAccountId
        )
    }

    @discardableResult
    private func persistAccountsSnapshot(context: String, log: Bool = true) async -> Bool {
        let accounts = accountManager.accounts
        accountPersistenceRevision &+= 1
        let revision = accountPersistenceRevision
        let outcome: AppDelegateAccountsPersistenceOutcome
        do {
            try await accountPersistence.persistDurably(accounts, revision: revision)
            outcome = .persisted
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        switch outcome {
        case .persisted:
            if log {
                SwapLog.append(.debug("ACCOUNTS_PERSISTED context=\(context) configured=\(accountManager.configuredAccount?.email ?? "none")"))
            }
            scheduleLinuxDevboxCredentialSyncIfNeeded(context: context)
            return true
        case .failed(let message):
            logger.warning("Failed to persist accounts snapshot (\(context)): \(message)")
            SwapLog.append(.debug("ACCOUNTS_PERSIST_FAILED context=\(context) error=\(message)"))
            return false
        }
    }

    @discardableResult
    private func persistAuthorizedAccountsSnapshot(
        context: String,
        permit: AccountActivationEffectPermit
    ) async -> Bool {
        let accounts = accountManager.accounts
        accountPersistenceRevision &+= 1
        let revision = accountPersistenceRevision
        do {
            try await accountPersistence.persistDurably(
                accounts,
                revision: revision,
                authorizeEffect: { permit.isCurrentlyAuthorized() }
            )
            SwapLog.append(.debug(
                "ACCOUNTS_PERSISTED context=\(context) configured=\(accountManager.configuredAccount?.email ?? "none")"
            ))
            scheduleLinuxDevboxCredentialSyncIfNeeded(context: context)
            return true
        } catch {
            logger.warning(
                "Failed to persist authorized accounts snapshot (\(context)): \(error.localizedDescription)"
            )
            SwapLog.append(.debug(
                "ACCOUNTS_PERSIST_FAILED context=\(context) error=\(error.localizedDescription)"
            ))
            return false
        }
    }

    private func queueTelemetryPersistence(context _: String) {
        let accounts = accountManager.accounts
        accountPersistenceRevision &+= 1
        let revision = accountPersistenceRevision
        let persistence = accountPersistence
        Task {
            await persistence.queueTelemetry(accounts, revision: revision)
        }
    }

    private func scheduleLinuxDevboxCredentialSyncIfNeeded(context: String) {
        guard Self.shouldSyncLinuxDevboxCredentials(for: context) else { return }
        let settings = LinuxDevboxMonitor.settings()
        guard settings.isConfigured else { return }
        let accounts = accountManager.accounts
        guard !accounts.isEmpty else { return }

        let fingerprint = LinuxDevboxMonitor.credentialSyncFingerprint(accounts: accounts)
        if linuxDevboxCredentialSyncInFlight {
            pendingLinuxDevboxCredentialSyncFingerprint = fingerprint
            SwapLog.append(.debug("LINUX_DEVBOX_CREDENTIAL_SYNC_QUEUED context=\(context)"))
            return
        }
        if linuxDevboxCredentialSyncReconciliationInFlight {
            pendingLinuxDevboxCredentialSyncFingerprint = fingerprint
            SwapLog.append(.debug(
                "LINUX_DEVBOX_CREDENTIAL_SYNC_QUEUED context=\(context) reason=reconciliation_in_flight"
            ))
            return
        }
        do {
            if let operation = try linuxDevboxCredentialSyncJournal.load() {
                surfaceLinuxDevboxCredentialSyncHold(
                    operation: operation,
                    context: context
                )
                reconcileLinuxDevboxCredentialSyncIfNeeded(
                    operation: operation,
                    settings: settings
                )
                return
            }
        } catch {
            surfaceLinuxDevboxCredentialSyncHold(
                fingerprint: fingerprint,
                reason: "Credential-sync journal is unavailable: \(error.localizedDescription)",
                context: context
            )
            return
        }
        if let unresolved = UserDefaults.standard.string(
            forKey: linuxDevboxCredentialSyncUnresolvedFingerprintKey
        ) {
            let reason = UserDefaults.standard.string(
                forKey: linuxDevboxCredentialSyncUnresolvedReasonKey
            ) ?? "Legacy credential-sync hold requires manual reconciliation"
            surfaceLinuxDevboxCredentialSyncHold(
                fingerprint: unresolved,
                reason: reason,
                context: context
            )
            return
        }
        if UserDefaults.standard.string(forKey: linuxDevboxLastCredentialSyncFingerprintKey) == fingerprint {
            return
        }
        if linuxDevboxCredentialSyncRetryTask != nil {
            pendingLinuxDevboxCredentialSyncFingerprint = fingerprint
            SwapLog.append(.debug("LINUX_DEVBOX_CREDENTIAL_SYNC_RETRY_PENDING context=\(context)"))
            return
        }
        let now = Date()
        if !Self.shouldBypassLinuxDevboxCredentialSyncThrottle(for: context),
           let lastLinuxDevboxCredentialSyncAttemptAt,
           now.timeIntervalSince(lastLinuxDevboxCredentialSyncAttemptAt) < Self.linuxDevboxCredentialSyncThrottleInterval(for: context) {
            pendingLinuxDevboxCredentialSyncFingerprint = fingerprint
            SwapLog.append(.debug("LINUX_DEVBOX_CREDENTIAL_SYNC_THROTTLED context=\(context)"))
            return
        }

        linuxDevboxCredentialSyncInFlight = true
        lastLinuxDevboxCredentialSyncAttemptAt = now
        pendingLinuxDevboxCredentialSyncFingerprint = nil
        let journal = linuxDevboxCredentialSyncJournal
        let deferSync: @MainActor @Sendable () -> Void = { [weak self] in
            self?.deferLinuxDevboxCredentialSync(
                fingerprint: fingerprint,
                context: context
            )
        }
        let finishSync: @MainActor @Sendable (
            Result<String, LinuxDevboxMonitorFailure>
        ) -> Void = { [weak self] result in
            self?.finishLinuxDevboxCredentialSync(
                result: result,
                fingerprint: fingerprint,
                accountsCount: accounts.count,
                context: context
            )
        }
        Task.detached {
            if !Self.shouldBypassLinuxDevboxCredentialSyncNetworkBackoff(for: context),
               await NetworkBackoffGuard.shared.shouldDeferNonCriticalProbe(
                   operation: "linux_devbox_credential_sync"
               ) {
                await deferSync()
                return
            }

            let baseline: LinuxDevboxCredentialStateEvidence
            switch LinuxDevboxMonitor.captureCredentialStateEvidence(settings: settings) {
            case .success(let evidence):
                baseline = evidence
            case .failure(let failure):
                await finishSync(.failure(failure))
                return
            }

            let synchronizedAccounts: [CodexAccount]
            switch LinuxDevboxMonitor.credentialSyncAccountsPreservingRemoteActive(
                accounts: accounts,
                remoteActiveProviderAccountId: baseline.activeProviderAccountId
            ) {
            case .success(let value):
                synchronizedAccounts = value
            case .failure(let failure):
                await finishSync(.failure(failure))
                return
            }
            let synchronizedFingerprint = LinuxDevboxMonitor.credentialSyncFingerprint(
                accounts: synchronizedAccounts
            )

            let operation: LinuxDevboxCredentialSyncOperation
            switch LinuxDevboxMonitor.makeCredentialSyncOperation(
                settings: settings,
                accounts: synchronizedAccounts,
                credentialFingerprint: synchronizedFingerprint,
                baseline: baseline
            ) {
            case .success(let value):
                operation = value
            case .failure(let failure):
                await finishSync(.failure(failure))
                return
            }

            do {
                try journal.begin(operation)
            } catch {
                await finishSync(.failure(LinuxDevboxMonitorFailure(
                    message: "Credential-sync journal could not be committed; no remote mutation was attempted: \(error.localizedDescription)",
                    credentialSyncDisposition: .rejected
                )))
                return
            }

            var result = LinuxDevboxMonitor.syncCredentials(
                settings: settings,
                accounts: synchronizedAccounts,
                operation: operation
            )
            do {
                switch result {
                case .success:
                    try journal.clear(operationID: operation.operationID)
                case .failure(let failure) where failure.credentialSyncDisposition.requiresPersistentHold:
                    try journal.markUnresolved(
                        operationID: operation.operationID,
                        reason: LinuxDevboxMonitor.credentialSyncHoldReason(for: failure)
                    )
                case .failure:
                    try journal.clear(operationID: operation.operationID)
                }
            } catch {
                result = .failure(LinuxDevboxMonitorFailure(
                    message: "Credential-sync outcome could not be resolved in the durable journal: \(error.localizedDescription)",
                    credentialSyncDisposition: .outcomeUnknown
                ))
            }

            await finishSync(result)
        }
    }

    private func deferLinuxDevboxCredentialSync(
        fingerprint: String,
        context: String
    ) {
        linuxDevboxCredentialSyncInFlight = false
        pendingLinuxDevboxCredentialSyncFingerprint = fingerprint
        SwapLog.append(.debug("LINUX_DEVBOX_CREDENTIAL_SYNC_DEFERRED context=\(context)"))
    }

    private func finishLinuxDevboxCredentialSync(
        result: Result<String, LinuxDevboxMonitorFailure>,
        fingerprint: String,
        accountsCount: Int,
        context: String
    ) {
        linuxDevboxCredentialSyncInFlight = false
        let queuedFingerprint = pendingLinuxDevboxCredentialSyncFingerprint
        switch result {
        case .success(let output):
            UserDefaults.standard.set(fingerprint, forKey: linuxDevboxLastCredentialSyncFingerprintKey)
            clearLegacyLinuxDevboxCredentialSyncHold()
            pendingLinuxDevboxCredentialSyncFingerprint = nil
            Task {
                await NetworkBackoffGuard.shared.recordSuccess(operation: "linux_devbox_credential_sync")
            }
            SwapLog.append(.debug(
                "LINUX_DEVBOX_CREDENTIAL_SYNCED context=\(context) accounts=\(accountsCount) output=\(output)"
            ))
            checkLinuxDevboxReadiness(force: true)
        case .failure(let failure):
            if failure.credentialSyncDisposition.requiresPersistentHold {
                let holdReason = LinuxDevboxMonitor.credentialSyncHoldReason(for: failure)
                UserDefaults.standard.set(
                    fingerprint,
                    forKey: linuxDevboxCredentialSyncUnresolvedFingerprintKey
                )
                UserDefaults.standard.set(
                    holdReason,
                    forKey: linuxDevboxCredentialSyncUnresolvedReasonKey
                )
                surfaceLinuxDevboxCredentialSyncHold(
                    fingerprint: fingerprint,
                    reason: holdReason,
                    context: context
                )
            } else if let retryPlan = Self.linuxDevboxCredentialSyncRetryPlan(
                after: failure,
                originalContext: context,
                fingerprint: fingerprint
            ) {
                clearLegacyLinuxDevboxCredentialSyncHold()
                scheduleLinuxDevboxCredentialSyncRetry(retryPlan)
            } else {
                clearLegacyLinuxDevboxCredentialSyncHold()
                pendingLinuxDevboxCredentialSyncFingerprint = nil
            }
            Task {
                await NetworkBackoffGuard.shared.recordFailure(
                    failure.message,
                    operation: "linux_devbox_credential_sync"
                )
            }
            SwapLog.append(.debug(
                "LINUX_DEVBOX_CREDENTIAL_SYNC_FAILED context=\(context) disposition=\(failure.credentialSyncDisposition.rawValue) error=\(failure.message)"
            ))
        }

        if case .success = result,
           queuedFingerprint != nil,
           queuedFingerprint != UserDefaults.standard.string(forKey: linuxDevboxLastCredentialSyncFingerprintKey) {
            pendingLinuxDevboxCredentialSyncFingerprint = queuedFingerprint
            scheduleLinuxDevboxCredentialSyncIfNeeded(context: "queued-after-\(context)")
        }
    }

    private func reconcileLinuxDevboxCredentialSyncIfNeeded(
        operation: LinuxDevboxCredentialSyncOperation,
        settings: LinuxDevboxMonitorSettings
    ) {
        guard !linuxDevboxCredentialSyncInFlight,
              !linuxDevboxCredentialSyncReconciliationInFlight else { return }
        linuxDevboxCredentialSyncReconciliationInFlight = true
        let journal = linuxDevboxCredentialSyncJournal
        let finish: @MainActor @Sendable (
            LinuxDevboxCredentialSyncReconciliation
        ) -> Void = { [weak self] reconciliation in
            self?.finishLinuxDevboxCredentialSyncReconciliation(
                reconciliation,
                operation: operation
            )
        }
        Task.detached {
            var reconciliation = LinuxDevboxMonitor.reconcileCredentialSync(
                settings: settings,
                operation: operation
            )
            do {
                switch reconciliation {
                case .committed, .safeToRetry:
                    try journal.clear(operationID: operation.operationID)
                case .unresolved(let reason):
                    try journal.markUnresolved(
                        operationID: operation.operationID,
                        reason: reason
                    )
                }
            } catch {
                reconciliation = .unresolved(
                    "Credential-sync reconciliation could not update its journal: \(error.localizedDescription)"
                )
            }
            await finish(reconciliation)
        }
    }

    private func finishLinuxDevboxCredentialSyncReconciliation(
        _ reconciliation: LinuxDevboxCredentialSyncReconciliation,
        operation: LinuxDevboxCredentialSyncOperation
    ) {
        linuxDevboxCredentialSyncReconciliationInFlight = false
        switch reconciliation {
        case .committed:
            UserDefaults.standard.set(
                operation.credentialFingerprint,
                forKey: linuxDevboxLastCredentialSyncFingerprintKey
            )
            clearLegacyLinuxDevboxCredentialSyncHold()
            SwapLog.append(.debug(
                "LINUX_DEVBOX_CREDENTIAL_SYNC_RECONCILED operation=\(operation.operationID) outcome=committed"
            ))
            scheduleLinuxDevboxCredentialSyncIfNeeded(context: "load-restore")
        case .safeToRetry:
            clearLegacyLinuxDevboxCredentialSyncHold()
            let fingerprint = LinuxDevboxMonitor.credentialSyncFingerprint(
                accounts: accountManager.accounts
            )
            scheduleLinuxDevboxCredentialSyncRetry(
                LinuxDevboxCredentialSyncRetryPlan(
                    context: "credential-retry-reconciled",
                    fingerprint: fingerprint,
                    delay: Self.linuxDevboxCredentialSyncRetryDelay
                )
            )
        case .unresolved(let reason):
            UserDefaults.standard.set(
                operation.credentialFingerprint,
                forKey: linuxDevboxCredentialSyncUnresolvedFingerprintKey
            )
            UserDefaults.standard.set(
                reason,
                forKey: linuxDevboxCredentialSyncUnresolvedReasonKey
            )
            surfaceLinuxDevboxCredentialSyncHold(
                fingerprint: operation.credentialFingerprint,
                reason: reason,
                context: "reconciliation"
            )
        }
    }

    private func scheduleLinuxDevboxCredentialSyncRetry(
        _ plan: LinuxDevboxCredentialSyncRetryPlan
    ) {
        guard linuxDevboxCredentialSyncRetryTask == nil else { return }
        pendingLinuxDevboxCredentialSyncFingerprint = plan.fingerprint
        linuxDevboxCredentialSyncRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(plan.delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.linuxDevboxCredentialSyncRetryTask = nil
            self.scheduleLinuxDevboxCredentialSyncIfNeeded(context: plan.context)
        }
    }

    private func surfaceLinuxDevboxCredentialSyncHold(
        operation: LinuxDevboxCredentialSyncOperation,
        context: String
    ) {
        surfaceLinuxDevboxCredentialSyncHold(
            fingerprint: operation.credentialFingerprint,
            reason: operation.reason,
            context: context
        )
    }

    private func surfaceLinuxDevboxCredentialSyncHold(
        fingerprint: String,
        reason: String,
        context: String
    ) {
        let summary = Self.linuxDevboxCredentialSyncHoldSummary(reason: reason)
        publishLinuxDevboxInvalidation(
            .barrierBlocked,
            summary: summary
        )
        SwapLog.append(.debug(
            "LINUX_DEVBOX_CREDENTIAL_SYNC_HELD context=\(context) unresolved_fingerprint=\(fingerprint) reason=\(reason)"
        ))
    }

    private func publishLinuxDevboxInvalidation(
        _ invalidation: LinuxDevboxStatus.Invalidation,
        summary: String
    ) {
        invalidateLinuxDevboxReadinessTask()
        switch invalidation {
        case .activeSessionUnverified, .deferred, .expired:
            lastLinuxDevboxReady = nil
        case .negative, .failed, .decodedInvalid, .barrierBlocked:
            lastLinuxDevboxReady = false
        }
        lastLinuxDevboxAccountMirrorSucceededAt = nil
        accountManager.invalidateLinuxDevboxRuntimeEvidence()
        accountManager.linuxDevboxStatus = .invalidated(
            by: invalidation,
            summary: summary
        )
    }

    private func beginLinuxDevboxReadinessTask(
        settings: LinuxDevboxMonitorSettings
    ) -> LinuxDevboxReadinessTaskContext {
        linuxDevboxReadinessGeneration &+= 1
        let context = LinuxDevboxReadinessTaskContext(
            generation: linuxDevboxReadinessGeneration,
            settings: settings
        )
        linuxDevboxReadinessTaskContext = context
        linuxDevboxReadinessCheckInFlight = true
        return context
    }

    private func linuxDevboxReadinessTaskIsCurrent(
        _ context: LinuxDevboxReadinessTaskContext
    ) -> Bool {
        linuxDevboxReadinessTaskContext == context
            && context.authorizesPublication(
                currentGeneration: linuxDevboxReadinessGeneration,
                currentSettings: LinuxDevboxMonitor.settings()
            )
    }

    private func finishLinuxDevboxReadinessTask(
        _ context: LinuxDevboxReadinessTaskContext
    ) {
        guard linuxDevboxReadinessTaskContext == context else { return }
        linuxDevboxReadinessTaskContext = nil
        linuxDevboxReadinessCheckInFlight = false
    }

    private func invalidateLinuxDevboxReadinessTask() {
        linuxDevboxReadinessGeneration &+= 1
        linuxDevboxReadinessTaskContext = nil
        linuxDevboxReadinessCheckInFlight = false
    }

    private func clearLegacyLinuxDevboxCredentialSyncHold() {
        UserDefaults.standard.removeObject(forKey: linuxDevboxCredentialSyncUnresolvedFingerprintKey)
        UserDefaults.standard.removeObject(forKey: linuxDevboxCredentialSyncUnresolvedReasonKey)
    }

    nonisolated static func linuxDevboxCredentialSyncHoldSummary(reason: String) -> String {
        let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Credential sync paused: \(normalized.isEmpty ? "reconciliation required" : normalized)"
    }

    nonisolated static func linuxDevboxCredentialSyncRetryPlan(
        after failure: LinuxDevboxMonitorFailure,
        originalContext: String,
        fingerprint: String
    ) -> LinuxDevboxCredentialSyncRetryPlan? {
        guard failure.credentialSyncDisposition == .retryablePreExecution,
              !originalContext.hasPrefix("credential-retry-") else {
            return nil
        }
        return LinuxDevboxCredentialSyncRetryPlan(
            context: "credential-retry-\(originalContext)",
            fingerprint: fingerprint,
            delay: linuxDevboxCredentialSyncRetryDelay
        )
    }

    nonisolated static func shouldAutomaticallyRetryLinuxDevboxCredentialSync(
        after failure: LinuxDevboxMonitorFailure
    ) -> Bool {
        failure.credentialSyncDisposition.allowsAutomaticRetry
    }

    nonisolated static func shouldSyncLinuxDevboxCredentials(for context: String) -> Bool {
        switch context {
        case "add-account",
             "auth-json-token-import",
             "auth-json-sync",
             "load-restore",
             "reauth-account",
             "reauth-added-different-account",
             "subscription-info",
             "reset-consumed",
             "swap",
             "token-refresh":
            return true
        default:
            if context.hasPrefix("credential-retry-") {
                return true
            }
            let prefix = "queued-after-"
            if context.hasPrefix(prefix) {
                let originalContext = String(context.dropFirst(prefix.count))
                return shouldSyncLinuxDevboxCredentials(for: originalContext)
            }
            return false
        }
    }

    nonisolated static func linuxDevboxCredentialSyncThrottleInterval(for context: String) -> TimeInterval {
        switch context {
        case "quota-primed",
             "quota-update",
             "reset-consumed",
             "subscription-info":
            return 60
        default:
            if context.hasPrefix("credential-retry-") {
                return 0
            }
            let prefix = "queued-after-"
            if context.hasPrefix(prefix) {
                let originalContext = String(context.dropFirst(prefix.count))
                return linuxDevboxCredentialSyncThrottleInterval(for: originalContext)
            }
            return 10 * 60
        }
    }

    nonisolated static func shouldBypassLinuxDevboxCredentialSyncThrottle(for context: String) -> Bool {
        switch context {
        case "add-account",
             "auth-json-token-import",
             "reauth-account",
             "reauth-added-different-account",
             "swap",
             "token-refresh":
            return true
        default:
            if context.hasPrefix("credential-retry-") {
                return true
            }
            let prefix = "queued-after-"
            if context.hasPrefix(prefix) {
                let originalContext = String(context.dropFirst(prefix.count))
                return shouldBypassLinuxDevboxCredentialSyncThrottle(for: originalContext)
            }
            return false
        }
    }

    nonisolated static func shouldBypassLinuxDevboxCredentialSyncNetworkBackoff(
        for context: String
    ) -> Bool {
        context.hasPrefix("credential-retry-")
    }

    private func addAccount() {
        guard !isExiting else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.isExiting else { return }
            do {
                var account = try await self.oauthManager.performLogin()
                guard !self.isExiting else { return }
                let duplicate = self.accountManager.accounts.first(where: {
                    $0.accountId == account.accountId
                })
                if let duplicate {
                    var canonical = duplicate
                    canonical.email = account.email
                    canonical.accountId = account.accountId
                    canonical.accessToken = account.accessToken
                    canonical.refreshToken = account.refreshToken
                    canonical.idToken = account.idToken
                    canonical.lastRefreshed = account.lastRefreshed ?? Date()
                    canonical.runtimeUnusableUntil = nil
                    canonical.runtimeUnusableReason = nil
                    account = canonical
                }
                let activatesFirstAccount = accountManager.accounts.isEmpty
                if activatesFirstAccount || duplicate?.isActive == true {
                    account.isActive = true
                    let committed = await withPreparedActiveCredentialMutation(
                        targetAccountId: account.id,
                        expectedConfiguredAccountId: activatesFirstAccount ? nil : duplicate?.id,
                        source: activatesFirstAccount ? "first-account" : "duplicate-active-account",
                        isManual: true
                    ) { [weak self] prepared in
                        guard let self else { return false }
                        return await self.commitConfiguredCredentialMutation(
                            from: Self.activeCredentialMutationSource(
                                existing: duplicate,
                                imported: account
                            ),
                            to: account,
                            reason: .manual,
                            mutationRoute: activatesFirstAccount
                                ? .firstActivation
                                : .activeReauthentication,
                            persistenceContext: "add-account",
                            authAlreadyConfigured: false,
                            swapStart: Date(),
                            prepared: prepared,
                            recordsSwap: false,
                            committedDetail: .activeCredentialMutation
                        )
                    }
                    guard committed else { return }
                } else {
                    let previousAccounts = accountManager.accounts
                    let result = accountManager.upsertInactiveAccount(account)
                    if case .rejectedConfiguredAccount = result {
                        accountManager.accounts = previousAccounts
                        return
                    }
                    guard await persistAccountsSnapshot(context: "add-account") else {
                        accountManager.accounts = previousAccounts
                        return
                    }
                }
                startPollingForAccount(account.id)
                scheduleRateLimitResetRefresh(for: account.id)
                refreshSubscriptionInfoIfNeeded(force: true)
                statusBarController.updateIcon()
                updatePopoverContent()

                // Show popover to confirm the account was added
                if let button = statusItem.button {
                    showPopover(from: button)
                    NSApp.activate()
                }

                SwapLog.append(.accountAdded(email: account.email))
                logger.info("Account added: \(account.email)")
            } catch {
                logger.error("Login failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Polling

    private func startAllPolling() {
        for account in accountManager.accounts {
            startPollingForAccount(account.id)
        }
    }

    private func startPollingForAccount(_ accountId: UUID) {
        if let account = accountManager.accounts.first(where: { $0.id == accountId }),
           account.hasHardRuntimeBlock {
            Task { await quotaPoller.stopPolling(for: accountId) }
            SwapLog.append(.debug("POLL_SKIPPED_HARD_RUNTIME_BLOCK email=\(account.email)"))
            return
        }
        let manager = accountManager
        let poller = quotaPoller
        Task { [poller, weak self] in
            await poller.startPolling(
                for: accountId,
                accountProvider: { @Sendable id in
                    await MainActor.run {
                        manager.accounts.first { $0.id == id }
                    }
                },
                onUpdate: { [weak self] id, snapshot, planType in
                    Task { @MainActor in
                        let previousPlan = self?.accountManager.accounts.first(where: { $0.id == id })?.planType
                        let email = self?.accountManager.accounts.first(where: { $0.id == id })?.email
                        self?.accountManager.updateQuota(for: id, snapshot: snapshot, planType: planType)
                        let now = Date()
                        await self?.clearExternalRateLimitResetHoldIfQuotaRecovered(
                            for: id,
                            snapshot: snapshot,
                            at: now
                        )
                        let requiresDecisionEvidence = AppDelegate
                            .rateLimitResetQuotaRequiresDecisionEvidence(snapshot, at: now)
                        self?.scheduleRateLimitResetRefresh(
                            for: id,
                            checkSwapAfter: requiresDecisionEvidence
                        )
                        self?.queueTelemetryPersistence(context: "quota-update")
                        self?.statusBarController.updateIcon()
                        self?.updatePopoverContent()
                        self?.primeIdleAccountsIfNeeded()
                        if let email,
                           self?.shouldPushLinuxDevboxPlanRefresh(previousPlan: previousPlan, newPlan: planType) == true {
                            self?.pushLinuxDevboxAccountRefresh(email: email, reason: "plan_changed:\(previousPlan ?? "unknown")->\(planType)")
                        }
                    }
                },
                onError: { [weak self] id, error in
                    Task { @MainActor in
                        let email = self?.accountManager.accounts.first(where: { $0.id == id })?.email ?? "unknown"
                        let errorMsg: String
                        switch error {
                        case .tokenExpired:
                            errorMsg = "Token expired — refreshing..."
                            SwapLog.append(.pollError(accountEmail: email, error: "token_expired"))
                            await self?.refreshToken(for: id)
                            return
                        case .rateLimited:
                            errorMsg = "Rate limited — backing off"
                        case .usageUnavailable:
                            errorMsg = "Rate limits unavailable — keeping last known usage"
                        case .httpError(let code):
                            errorMsg = "API error (HTTP \(code))"
                        case .invalidResponse:
                            errorMsg = "Invalid response"
                        case .networkError(let msg):
                            errorMsg = "Network error: \(msg)"
                        }
                        if case .usageUnavailable = error,
                           let account = self?.accountManager.accounts.first(where: { $0.id == id }),
                           let snapshot = account.realQuotaSnapshot,
                           account.isQuotaImmediatelyUsable(at: Date()),
                           snapshot.isImmediatelyUsable {
                            self?.accountManager.clearPollingError(for: id)
                            SwapLog.append(.debug("POLL_USAGE_UNAVAILABLE_SUPPRESSED account=\(email) reason=trusted_real_snapshot"))
                            if account.isActive {
                                self?.checkAndSwapAfterUsageUnavailable(accountId: id)
                            }
                            return
                        }
                        SwapLog.append(.pollError(accountEmail: email, error: errorMsg))
                        logger.error("Polling error for \(id): \(errorMsg)")
                        self?.accountManager.updatePollingError(for: id, error: errorMsg)
                        if case .usageUnavailable = error {
                            self?.checkAndSwapAfterUsageUnavailable(accountId: id)
                        }
                    }
                }
            )
        }
    }

    private func checkAndSwapAfterUsageUnavailable(accountId: UUID) {
        checkAndSwapIfNeeded(trigger: .usageUnavailable(accountId: accountId))
    }

    private func refreshToken(for accountId: UUID) async {
        guard !isExiting else { return }
        guard let account = accountManager.accounts.first(where: { $0.id == accountId }) else { return }
        guard !account.isRuntimeUnusable else {
            await quotaPoller.stopPolling(for: accountId)
            return
        }
        let shouldNotifyRefreshFailure = !account.requiresReauthentication
        if accountManager.configuredAccount?.id == accountId {
            guard let activationState = await activationStateForRequest(),
                  activationState.phase == .confirmed,
                  await requireFreshLocalRuntimePermit(
                      for: account,
                      activationGeneration: activationState.activationGeneration,
                      requiredPhase: .confirmed
                  ) != nil else {
                return
            }
            let committed = await withPreparedActiveCredentialMutation(
                targetAccountId: account.id,
                expectedConfiguredAccountId: account.id,
                source: "token-refresh",
                isManual: false
            ) { [weak self] prepared in
                guard let self else { return false }
                do {
                    let refreshed = try await AccountCredentialMutationBoundary.performAsync(
                        route: .tokenRefresh,
                        authorize: { [weak self] in
                            guard let self else { return nil }
                            return await self.revalidateCredentialMutation(
                                route: .tokenRefresh,
                                from: account,
                                to: account,
                                reason: .manual,
                                authAlreadyConfigured: false,
                                prepared: prepared
                            )
                        },
                        mutation: { _ in
                            try await TokenRefresher.refresh(account)
                        }
                    )
                    guard let refreshed else {
                        await self.failConfiguredCredentialMutation(
                            target: account,
                            prepared: prepared,
                            stage: .mutationAuthorization,
                            detail: .runtimeEvidenceExpired,
                            failure: "active token refresh authorization changed before submission"
                        )
                        return false
                    }
                    return await self.commitConfiguredCredentialMutation(
                        from: account,
                        to: refreshed,
                        reason: .manual,
                        mutationRoute: .tokenRefresh,
                        persistenceContext: "token-refresh",
                        authAlreadyConfigured: false,
                        swapStart: Date(),
                        prepared: prepared,
                        recordsSwap: false,
                        committedDetail: .activeCredentialMutation
                    )
                } catch {
                    await self.failConfiguredCredentialMutation(
                        target: account,
                        prepared: prepared,
                        stage: .credentialMutation,
                        detail: .fileCommitFailed,
                        failure: "active token refresh failed or was cancelled before commit"
                    )
                    await self.handleTokenRefreshFailure(
                        account: account,
                        error: error,
                        shouldNotify: shouldNotifyRefreshFailure
                    )
                    return false
                }
            }
            guard committed else { return }
            refreshSubscriptionInfoIfNeeded(force: true)
            SwapLog.append(.tokenRefreshed(email: account.email))
            startPollingForAccount(accountId)
            return
        }

        do {
            let updated = try await TokenRefresher.refresh(account)
            if case .rejectedConfiguredAccount = accountManager.upsertInactiveAccount(updated) {
                return
            }
            guard await persistAccountsSnapshot(context: "token-refresh") else { return }
            refreshSubscriptionInfoIfNeeded(force: true)
            SwapLog.append(.tokenRefreshed(email: account.email))
            startPollingForAccount(accountId)
        } catch {
            await handleTokenRefreshFailure(
                account: account,
                error: error,
                shouldNotify: shouldNotifyRefreshFailure
            )
        }
    }

    private func handleTokenRefreshFailure(
        account: CodexAccount,
        error: Error,
        shouldNotify: Bool
    ) async {
            SwapLog.append(.tokenRefreshFailed(email: account.email, error: error.localizedDescription))
            accountManager.markRuntimeUnusable(
                for: account.id,
                reason: "token_expired",
                until: Date().addingTimeInterval(30 * 24 * 60 * 60)
            )
            accountManager.updatePollingError(for: account.id, error: "Re-authentication required")
            _ = await persistAccountsSnapshot(context: "token-refresh-failed")
            updatePopoverContent()
            if shouldNotify {
                NotificationManager.notifyTokenRefreshFailed(account: account)
            }
            if account.isActive,
               accountManager.configuredAccount?.id == account.id {
                checkAndSwapIfNeeded(trigger: .tokenInvalidated(accountId: account.id))
            }
    }

    private func primeIdleAccountsIfNeeded() {
        guard !accountManager.accounts.isEmpty else { return }
        guard idleAccountPrimeTask == nil else {
            idleAccountPrimePassPending = true
            return
        }

        let manager = accountManager
        let primer = weeklyPrimer
        idleAccountPrimeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.idleAccountPrimeTask = nil
                self.idleAccountPrimePassPending = false
            }

            repeat {
                self.idleAccountPrimePassPending = false
                let accounts = manager.accounts
                guard !accounts.isEmpty else { return }

                let primeResults = await primer.primeIfNeeded(
                    accounts: accounts,
                    accountProvider: { @Sendable id in
                        await MainActor.run {
                            manager.accounts.first { $0.id == id }
                        }
                    }
                )
                guard !Task.isCancelled else { return }

                for result in primeResults {
                    if result.fiveHourPrimed {
                        self.accountManager.markFiveHourPrimed(for: result.accountId)
                    } else if result.fiveHourUnconfirmed {
                        self.accountManager.clearFiveHourPrimed(
                            for: result.accountId,
                            reason: "primer_unconfirmed"
                        )
                    }
                    self.queueTelemetryPersistence(context: "quota-primed")
                    self.startPollingForAccount(result.accountId)
                }
            } while self.idleAccountPrimePassPending
        }
    }

    private func refreshSubscriptionInfoIfNeeded(force: Bool = false) {
        if !force,
           let lastSubscriptionRefresh,
           Date().timeIntervalSince(lastSubscriptionRefresh) < 3600 {
            return
        }
        lastSubscriptionRefresh = Date()

        let accounts = accountManager.accounts
        let fetcher = subscriptionInfoFetcher
        Task { [weak self] in
            for account in accounts {
                do {
                    let info = try await fetcher.fetch(for: account)
                    await MainActor.run {
                        self?.accountManager.updateSubscriptionInfo(for: account.id, info: info)
                        self?.queueTelemetryPersistence(context: "subscription-info")
                        self?.updatePopoverContent()
                    }
                } catch {
                    logger.warning("Failed to refresh subscription info for \(account.email, privacy: .private): \(error.localizedDescription)")
                }
            }
        }
    }

    private func pushLinuxDevboxAccountRefresh(email: String, reason: String) {
        let settings = LinuxDevboxMonitor.settings()
        guard settings.isConfigured else { return }
        if let plans = planChangeReasonPlans(reason),
           !shouldPushLinuxDevboxPlanRefresh(previousPlan: plans.previous, newPlan: plans.new) {
            return
        }
        let now = Date()
        let refreshKey = "\(email.lowercased())|\(reason)"
        if let lastRefresh = lastLinuxDevboxAccountRefreshByKey[refreshKey],
           now.timeIntervalSince(lastRefresh) < 10 * 60 {
            return
        }
        lastLinuxDevboxAccountRefreshByKey[refreshKey] = now
        Task.detached {
            if await NetworkBackoffGuard.shared.shouldDeferNonCriticalProbe(operation: "linux_devbox_account_refresh") {
                return
            }
            let result = LinuxDevboxMonitor.pollAccount(settings: settings, selector: email)
            switch result {
            case .success(let output):
                await NetworkBackoffGuard.shared.recordSuccess(operation: "linux_devbox_account_refresh")
                SwapLog.append(.debug("LINUX_DEVBOX_ACCOUNT_REFRESH email=\(email) reason=\(reason) output=\(output)"))
            case .failure(let failure):
                await NetworkBackoffGuard.shared.recordFailure(failure.message, operation: "linux_devbox_account_refresh")
                SwapLog.append(.debug("LINUX_DEVBOX_ACCOUNT_REFRESH_FAILED email=\(email) reason=\(reason) error=\(failure.message)"))
            }
        }
    }

    private func shouldPushLinuxDevboxPlanRefresh(previousPlan: String?, newPlan: String) -> Bool {
        let previousNormalized = previousPlan?.lowercased()
        let newNormalized = newPlan.lowercased()
        guard previousNormalized != newNormalized else { return false }
        return planPriority(for: newPlan) > planPriority(for: previousPlan)
    }

    private func planChangeReasonPlans(_ reason: String) -> (previous: String?, new: String)? {
        guard reason.hasPrefix("plan_changed:") else { return nil }
        let body = String(reason.dropFirst("plan_changed:".count))
        let parts = body.split(separator: "->", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let previous = String(parts[0])
        return (previous == "unknown" ? nil : previous, String(parts[1]))
    }

    private func planPriority(for planType: String?) -> Int {
        CodexAccount(
            email: "__plan_priority_probe__",
            accessToken: "",
            refreshToken: "",
            idToken: "",
            accountId: "",
            planType: planType
        ).planPriority
    }

    // MARK: - Banked Rate-Limit Resets

    private func publishRateLimitResetPresentations(at now: Date = Date()) {
        let presentations = Dictionary(uniqueKeysWithValues: accountManager.accounts.map { account in
            let bank = account.rateLimitResetBank
            let providerAccountId = account.normalizedProviderAccountId
            let presentation = RateLimitResetInventoryPresentation.resolve(
                availableCount: bank?.availableCount ?? 0,
                nextExpiration: bank?.nextExpiration(at: now),
                inventoryIsFresh: Self.rateLimitResetBankIsFresh(
                    bank,
                    at: now,
                    requiresDecisionEvidence: false
                ),
                isRedeeming: providerAccountId.map {
                    rateLimitResetOperationProviderAccountId == $0
                } ?? false,
                isReconciling: providerAccountId.map {
                    rateLimitResetUnresolvedProviderAccountIds.contains($0)
                } ?? false,
                error: rateLimitResetManualErrors[account.id],
                externalHoldUntil: externalRateLimitResetRedemptionBlockedUntil[account.id],
                isRefreshing: rateLimitResetRefreshTasks[account.id] != nil,
                now: now
            )
            return (account.id, presentation)
        })
        accountManager.publishRateLimitResetPresentations(presentations)
    }

    private func rateLimitResetCoordinatorAuthorization(
        for accountId: UUID,
        at now: Date = Date()
    ) -> RateLimitResetCoordinatorAuthorization {
        guard !isExiting else {
            return .blocked("CodexSwitch is shutting down")
        }
        guard Self.rateLimitResetJournalAllowsAutomaticRouting(
            isReadable: rateLimitResetJournalStateIsReadable
        ) else {
            return .blocked("Reset journal is unavailable; redemption is paused")
        }
        guard let account = accountManager.accounts.first(where: { $0.id == accountId }) else {
            return .blocked("This account is no longer available")
        }
        let configuredAccount = accountManager.configuredAccount
        let activationState = accountManager.activationState
        return .resolve(
            state: RateLimitResetCoordinatorState(
                externalHoldStateIsReadable: externalRateLimitResetHoldStateIsReadable,
                redemptionIsInProgress: rateLimitResetRedemptionTask != nil
                    || rateLimitResetOperationProviderAccountId != nil,
                configuredAccountIsAvailable: configuredAccount != nil,
                activationAllowsManualRedemption: configuredAccount.map { configured in
                    activationState?.configuredAccountId == configured.id
                        && activationState.map {
                            Self.rateLimitResetActivationStateAllows($0, reason: .manual)
                        } == true
                } ?? false,
                accountHasUnresolvedAttempt: rateLimitResetUnresolvedProviderAccountIds
                    .contains(account.normalizedProviderAccountId ?? ""),
                externalHoldUntil: externalRateLimitResetRedemptionBlockedUntil[accountId],
                localHoldUntil: rateLimitResetRedemptionBlockedUntil[accountId]
            ),
            now: now
        )
    }

    private func redeemRateLimitResetManually(for accountId: UUID) {
        guard let account = accountManager.accounts.first(where: { $0.id == accountId }) else {
            SwapLog.append(.debug(
                "RESET_MANUAL_REDEMPTION_REJECTED account_id=\(accountId.uuidString) reason=account_missing"
            ))
            return
        }
        let now = Date()
        let coordinatorAuthorization = rateLimitResetCoordinatorAuthorization(
            for: accountId,
            at: now
        )
        guard coordinatorAuthorization.isAuthorized else {
            recordManualRateLimitResetError(
                coordinatorAuthorization.unavailableReason
                    ?? "Manual reset redemption is unavailable",
                for: accountId,
                reason: .manual
            )
            return
        }
        guard let bank = account.rateLimitResetBank else {
            recordManualRateLimitResetError(
                "Reset inventory is unavailable; refresh and try again",
                for: accountId,
                reason: .manual
            )
            scheduleRateLimitResetRefresh(for: accountId, force: true)
            return
        }
        if let reason = RateLimitResetPolicy.manualRedemptionUnavailableReason(
            for: account,
            bank: bank,
            now: now
        ) {
            recordManualRateLimitResetError(reason, for: accountId, reason: .manual)
            if !Self.rateLimitResetBankIsFresh(
                bank,
                at: now,
                requiresDecisionEvidence: true
            ) {
                scheduleRateLimitResetRefresh(for: accountId, force: true)
            }
            return
        }

        recordManualRateLimitResetError(nil, for: accountId, reason: .manual)
        startRateLimitResetRedemption(
            account: account,
            bank: bank,
            reason: .manual
        )
    }

    private func clearPendingManualRateLimitResetSwapHold(
        forProviderAccountId providerAccountId: String,
        reason: RateLimitResetRedemptionReason
    ) {
        guard reason == .manual else { return }
        setManualRateLimitResetSwapSuppression(
            Self.manualRateLimitResetSwapSuppressionAfterClearingPending(
                manualRateLimitResetSwapSuppressions[providerAccountId]
            ),
            forProviderAccountId: providerAccountId
        )
    }

    private func recordSuccessfulManualRateLimitResetSwapHold(
        attempt: RateLimitResetAttempt,
        at _: Date
    ) {
        guard attempt.redemptionReason == .manual,
              let providerAccountId = attempt.normalizedProviderAccountId else {
            return
        }
        setManualRateLimitResetSwapSuppression(
            Self.manualRateLimitResetSwapSuppressionAfterSuccess(
                manualRateLimitResetSwapSuppressions[providerAccountId],
                attempt: attempt
            ),
            forProviderAccountId: providerAccountId
        )
    }

    private func activeManualRateLimitResetSwapExclusions(at _: Date) -> Set<UUID> {
        Set(accountManager.accounts.compactMap { account in
            guard let providerAccountId = account.normalizedProviderAccountId,
                  manualRateLimitResetSwapSuppressions[providerAccountId] != nil else {
                return nil
            }
            return account.id
        })
    }

    private func releaseManualRateLimitResetSwapSuppressionIfNeeded(
        for account: CodexAccount
    ) async {
        guard let providerAccountId = account.normalizedProviderAccountId else {
            return
        }
        manualRateLimitResetReleaseProviderAccountIds.insert(providerAccountId)
        manualRateLimitResetSwapSuppressionRevisions[providerAccountId, default: 0] &+= 1
        let observedSuppressionRevision = manualRateLimitResetSwapSuppressionRevisions[
            providerAccountId,
            default: 0
        ]
        defer {
            manualRateLimitResetReleaseProviderAccountIds.remove(providerAccountId)
        }
        do {
            let released = try await rateLimitResetService.releaseManualSwapSuppression(
                for: providerAccountId
            )
            guard released else {
                SwapLog.append(.debug(
                    "RESET_MANUAL_ROUTE_SUPPRESSION_RELEASE_SKIPPED account=\(account.email) reason=no_matching_attempt"
                ))
                return
            }
            let currentSuppressionRevision = manualRateLimitResetSwapSuppressionRevisions[
                providerAccountId,
                default: 0
            ]
            guard Self.manualRateLimitResetReleaseMayClearLiveSuppression(
                observedRevision: observedSuppressionRevision,
                currentRevision: currentSuppressionRevision
            ) else {
                SwapLog.append(.debug(
                    "RESET_MANUAL_ROUTE_SUPPRESSION_RELEASE_PRESERVED account=\(account.email) reason=newer_local_state"
                ))
                return
            }
            setManualRateLimitResetSwapSuppression(
                nil,
                forProviderAccountId: providerAccountId
            )
            SwapLog.append(.debug(
                "RESET_MANUAL_ROUTE_SUPPRESSION_RELEASED account=\(account.email)"
            ))
        } catch {
            rateLimitResetJournalStateIsReadable = false
            SwapLog.append(.debug(
                "RESET_MANUAL_ROUTE_SUPPRESSION_RELEASE_FAILED account=\(account.email) error=\(error.localizedDescription) automatic_routing=suppressed"
            ))
        }
    }

    private func recordManualRateLimitResetError(
        _ message: String?,
        for accountId: UUID,
        reason: RateLimitResetRedemptionReason
    ) {
        guard reason == .manual else { return }
        rateLimitResetManualErrors[accountId] = message
        guard let message else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self,
                  self.rateLimitResetManualErrors[accountId] == message else {
                return
            }
            if let providerAccountId = self.accountManager.accounts.first(where: {
                $0.id == accountId
            })?.normalizedProviderAccountId,
               self.rateLimitResetUnresolvedProviderAccountIds.contains(providerAccountId) {
                return
            }
            self.rateLimitResetManualErrors[accountId] = nil
        }
    }

    private func notifyRateLimitResetExpirationIfNeeded(
        for accountId: UUID,
        bank: RateLimitResetBank,
        now: Date
    ) {
        guard let expiration = bank.nextExpiration(at: now),
              let account = accountManager.accounts.first(where: { $0.id == accountId }) else {
            return
        }
        NotificationManager.notifyResetExpiration(
            account: account,
            expiration: expiration,
            now: now
        )
    }

    private var automaticRateLimitResetRedemptionEnabled: Bool {
        Self.automaticRateLimitResetRedemptionIsEnabled(
            preferenceEnabled: RateLimitResetSettings.automaticRedemptionEnabled(
                in: .standard
            ),
            externalHoldStateIsReadable: externalRateLimitResetHoldStateIsReadable
        )
    }

    nonisolated static func automaticRateLimitResetRedemptionIsEnabled(
        preferenceEnabled: Bool,
        externalHoldStateIsReadable: Bool
    ) -> Bool {
        preferenceEnabled && externalHoldStateIsReadable
    }

    private func restoreExternalRateLimitResetHolds(at now: Date = Date()) async {
        let activeHolds: [String: ExternalRateLimitResetHoldStore.Hold]
        do {
            activeHolds = try await externalRateLimitResetHoldStore.activeHolds(at: now)
        } catch {
            markExternalRateLimitResetHoldStateUnavailable(
                error,
                context: "restore"
            )
            return
        }
        var restored: [UUID: Date] = [:]
        for account in accountManager.accounts {
            if let hold = activeHolds[account.accountId] {
                restored[account.id] = hold.blockedUntil
            }
        }
        let providerAccountIdByLocalId = Dictionary(
            uniqueKeysWithValues: accountManager.accounts.map { ($0.id, $0.accountId) }
        )
        let isMissingKnownActiveHold = externalRateLimitResetRedemptionBlockedUntil.contains {
            localAccountId, blockedUntil in
            guard blockedUntil > now,
                  let providerAccountId = providerAccountIdByLocalId[localAccountId] else {
                return false
            }
            guard let persisted = activeHolds[providerAccountId] else { return true }
            return persisted.blockedUntil < blockedUntil
        }
        guard !isMissingKnownActiveHold else {
            markExternalRateLimitResetHoldStateUnavailable(
                ExternalRateLimitResetHoldStoreError.readbackMismatch,
                context: "restore-readback"
            )
            return
        }
        externalRateLimitResetRedemptionBlockedUntil = restored
        markExternalRateLimitResetHoldStateReadable()
    }

    private func clearExternalRateLimitResetHoldIfQuotaRecovered(
        for accountId: UUID,
        snapshot: QuotaSnapshot,
        at now: Date
    ) async {
        guard let account = accountManager.accounts.first(where: { $0.id == accountId }) else {
            return
        }
        let hold: ExternalRateLimitResetHoldStore.Hold?
        do {
            hold = try await externalRateLimitResetHoldStore.clearIfQuotaRecovered(
                providerAccountId: account.accountId,
                snapshot: snapshot,
                at: now
            )
        } catch {
            markExternalRateLimitResetHoldStateUnavailable(
                error,
                context: "quota-recovery"
            )
            return
        }
        guard let hold else { return }
        externalRateLimitResetRedemptionBlockedUntil[accountId] = nil
        await restoreExternalRateLimitResetHolds(at: now)
        SwapLog.append(.debug(
            "RESET_EXTERNAL_REDEMPTION_HOLD_CLEARED account=\(account.email) blocked_until=\(Int(hold.blockedUntil.timeIntervalSince1970)) quota_fetched=\(Int(snapshot.fetchedAt.timeIntervalSince1970)) reason=quota_recovered"
        ))
    }

    private func markExternalRateLimitResetHoldStateReadable() {
        externalRateLimitResetHoldStateIsReadable = true
        publishRateLimitResetPresentations()
        accountManager.requestUIRefresh()
        guard externalRateLimitResetHoldFailureLogged else { return }
        externalRateLimitResetHoldFailureLogged = false
        SwapLog.append(.debug(
            "RESET_EXTERNAL_HOLD_STATE_RECONCILED automatic_redemption=restored"
        ))
    }

    private func markExternalRateLimitResetHoldStateUnavailable(
        _ error: Error,
        context: String
    ) {
        externalRateLimitResetHoldStateIsReadable = false
        publishRateLimitResetPresentations()
        accountManager.requestUIRefresh()
        guard !externalRateLimitResetHoldFailureLogged else { return }
        externalRateLimitResetHoldFailureLogged = true
        logger.warning(
            "External reset hold state unavailable (\(context)): \(error.localizedDescription)"
        )
        SwapLog.append(.debug(
            "RESET_EXTERNAL_HOLD_STATE_UNAVAILABLE context=\(context) error=\(error.localizedDescription) automatic_redemption=disabled"
        ))
    }

    private func observeRateLimitResetBank(
        for account: CodexAccount,
        previousBank: RateLimitResetBank?,
        refreshedBank: RateLimitResetBank,
        source: String,
        at now: Date
    ) async -> RateLimitResetInventoryObservation {
        let transition = rateLimitResetSubmissionTracker.classify(
            previousBank: previousBank,
            refreshedBank: refreshedBank,
            observedProviderAccountId: account.accountId,
            now: now
        )
        var externalHoldUntil: Date?
        if transition.observedExternalRedemption {
            let proposedHoldUntil = now.addingTimeInterval(
                Self.externalRateLimitResetRedemptionCooldown
            )
            do {
                let persistedHold = try await externalRateLimitResetHoldStore.record(
                    providerAccountId: account.accountId,
                    observedAt: now,
                    blockedUntil: proposedHoldUntil
                )
                externalHoldUntil = persistedHold?.blockedUntil ?? proposedHoldUntil
            } catch {
                markExternalRateLimitResetHoldStateUnavailable(
                    error,
                    context: "record-\(source)"
                )
                externalHoldUntil = proposedHoldUntil
            }
            externalRateLimitResetRedemptionBlockedUntil[account.id] = externalHoldUntil
            await restoreExternalRateLimitResetHolds(at: now)
            SwapLog.append(.debug(
                "RESET_EXTERNAL_REDEMPTION_OBSERVED account=\(account.email) previous_available=\(previousBank?.availableCount ?? 0) available=\(refreshedBank.availableCount) source=\(source) automatic_redemption=suppressed cooldown_seconds=\(Int(Self.externalRateLimitResetRedemptionCooldown)) blocked_until=\(Int((externalHoldUntil ?? proposedHoldUntil).timeIntervalSince1970)) quota_refresh=required"
            ))
        }

        let inventoryChanged = Self.rateLimitResetInventorySemanticallyChanged(
            previous: previousBank,
            refreshed: refreshedBank
        )
        accountManager.updateRateLimitResetBank(for: account.id, bank: refreshedBank)
        notifyRateLimitResetExpirationIfNeeded(
            for: account.id,
            bank: refreshedBank,
            now: now
        )
        if inventoryChanged {
            queueTelemetryPersistence(context: "reset-bank-\(source)")
            statusBarController.updateIcon()
            updatePopoverContent()
        }
        return RateLimitResetInventoryObservation(
            transition: transition,
            externalHoldUntil: externalHoldUntil
        )
    }

    private func scheduleRateLimitResetRefresh(
        for accountId: UUID,
        force: Bool = false,
        checkSwapAfter: Bool = false
    ) {
        let now = Date()
        if !force,
           let retryAfter = rateLimitResetInventoryRetryAfter[accountId],
           retryAfter > now {
            return
        }
        if !force,
           let storedAccount = accountManager.accounts.first(where: { $0.id == accountId }),
           Self.rateLimitResetBankIsFresh(
               storedAccount.rateLimitResetBank,
               at: now,
               requiresDecisionEvidence: checkSwapAfter
           ),
           !(storedAccount.normalizedProviderAccountId.map {
               rateLimitResetUnresolvedProviderAccountIds.contains($0)
           } ?? false) {
            if checkSwapAfter {
                checkAndSwapIfNeeded()
            }
            return
        }
        if checkSwapAfter {
            rateLimitResetDecisionPending.insert(accountId)
        }
        if rateLimitResetRefreshTasks[accountId] != nil {
            return
        }
        guard let account = accountManager.accounts.first(where: { $0.id == accountId }) else {
            rateLimitResetDecisionPending.remove(accountId)
            return
        }

        let service = rateLimitResetService
        let poller = quotaPoller
        rateLimitResetRefreshTasks[accountId] = Task { @MainActor [weak self] in
            guard let self else { return }
            var refreshSucceeded = false
            var externalRedemptionObserved = false
            do {
                let isReconciling = account.normalizedProviderAccountId.map {
                    self.rateLimitResetUnresolvedProviderAccountIds.contains($0)
                } ?? false
                let bank = try await service.fetchBank(
                    for: account,
                    force: force || isReconciling
                )
                refreshSucceeded = true
                self.rateLimitResetInventoryRetryAfter[accountId] = nil
                let previous = self.accountManager.accounts
                    .first(where: { $0.id == accountId })?
                    .rateLimitResetBank
                let unresolvedAttempt = try await service.unresolvedAttempt(
                    for: account.accountId
                )
                self.rateLimitResetSubmissionTracker.reconcile(
                    providerAccountId: account.accountId,
                    unresolvedAttempt: unresolvedAttempt
                )
                let observedAt = Date()
                let observation = await self.observeRateLimitResetBank(
                    for: account,
                    previousBank: previous,
                    refreshedBank: bank,
                    source: "inventory-refresh",
                    at: observedAt
                )
                externalRedemptionObserved = observation.transition
                    .observedExternalRedemption
                SwapLog.append(.debug(
                    "RESET_BANK_REFRESHED account=\(account.email) available=\(bank.availableCount)"
                ))

                if unresolvedAttempt != nil {
                    if let providerAccountId = account.normalizedProviderAccountId {
                        self.rateLimitResetUnresolvedProviderAccountIds.insert(providerAccountId)
                    }
                    let reconciled = await self.reconcileRateLimitResetAttempt(
                        account: account,
                        bank: bank,
                        observation: observation,
                        source: "inventory-refresh"
                    )
                    if !reconciled {
                        self.rateLimitResetInventoryRetryAfter[accountId] = Date().addingTimeInterval(60)
                    }
                } else {
                    if let providerAccountId = account.normalizedProviderAccountId {
                        self.rateLimitResetUnresolvedProviderAccountIds.remove(providerAccountId)
                    }
                    self.rateLimitResetManualErrors[accountId] = nil
                    if externalRedemptionObserved {
                        let quotaAccount = self.accountManager.accounts
                            .first(where: { $0.id == accountId }) ?? account
                        do {
                            let quota = try await poller.fetchQuota(for: quotaAccount)
                            self.accountManager.updateQuota(
                                for: accountId,
                                snapshot: quota.snapshot,
                                planType: quota.planType
                            )
                            await self.clearExternalRateLimitResetHoldIfQuotaRecovered(
                                for: accountId,
                                snapshot: quota.snapshot,
                                at: Date()
                            )
                            self.queueTelemetryPersistence(context: "quota-update")
                            self.statusBarController.updateIcon()
                            self.updatePopoverContent()
                            SwapLog.append(.debug(
                                "RESET_EXTERNAL_REDEMPTION_QUOTA_REFRESHED account=\(account.email) fetched=\(Int(quota.snapshot.fetchedAt.timeIntervalSince1970))"
                            ))
                        } catch {
                            SwapLog.append(.debug(
                                "RESET_EXTERNAL_REDEMPTION_QUOTA_REFRESH_FAILED account=\(account.email) error=\(error.localizedDescription)"
                            ))
                        }
                    }
                }
            } catch {
                self.recordRateLimitResetJournalFailureIfNeeded(
                    error,
                    context: "inventory-refresh"
                )
                self.rateLimitResetInventoryRetryAfter[accountId] = Date().addingTimeInterval(60)
                SwapLog.append(.debug(
                    "RESET_BANK_REFRESH_FAILED account=\(account.email) error=\(error.localizedDescription)"
                ))
            }

            self.rateLimitResetRefreshTasks[accountId] = nil
            let shouldCheckSwap = self.rateLimitResetDecisionPending.remove(accountId) != nil
            if shouldCheckSwap {
                if !refreshSucceeded {
                    self.rateLimitResetRedemptionBlockedUntil[accountId] = Date().addingTimeInterval(60)
                }
                self.checkAndSwapIfNeeded()
            }
        }
    }

    private func reconcileRateLimitResetAttempt(
        account: CodexAccount,
        bank: RateLimitResetBank,
        observation suppliedObservation: RateLimitResetInventoryObservation? = nil,
        source: String
    ) async -> Bool {
        let accountId = account.id
        guard let providerAccountId = account.normalizedProviderAccountId else { return false }
        let quotaAccount = accountManager.accounts.first(where: { $0.id == accountId }) ?? account
        let observation: RateLimitResetInventoryObservation
        if let suppliedObservation {
            observation = suppliedObservation
        } else {
            observation = await observeRateLimitResetBank(
                for: account,
                previousBank: accountManager.accounts.first(where: { $0.id == accountId })?
                    .rateLimitResetBank,
                refreshedBank: bank,
                source: source,
                at: Date()
            )
        }
        do {
            let quota = try await quotaPoller.fetchQuota(for: quotaAccount)
            accountManager.updateQuota(
                for: accountId,
                snapshot: quota.snapshot,
                planType: quota.planType
            )
            if !observation.transition.observedExternalRedemption {
                await clearExternalRateLimitResetHoldIfQuotaRecovered(
                    for: accountId,
                    snapshot: quota.snapshot,
                    at: Date()
                )
            }
            let outcome = try await rateLimitResetService.reconcile(
                for: account,
                bank: bank,
                snapshot: quota.snapshot
            )
            switch outcome {
            case .pendingPersistence(let attempt):
                accountManager.clearRuntimeUnusable(for: accountId)
                guard await persistAccountsSnapshot(context: "reset-reconciled") else {
                    SwapLog.append(.debug(
                        "RESET_RECONCILIATION_PERSISTENCE_PENDING account=\(account.email) attempt=\(attempt.id.uuidString) source=\(source) automatic_redemption=suppressed"
                    ))
                    return false
                }
                let succeeded = try await rateLimitResetService
                    .finalizeReconciliationAfterPersistence(attemptId: attempt.id)
                rateLimitResetUnresolvedProviderAccountIds.remove(providerAccountId)
                rateLimitResetSubmissionTracker.reconcile(
                    providerAccountId: providerAccountId,
                    unresolvedAttempt: nil
                )
                rateLimitResetRecoveryUntil[accountId] = Date().addingTimeInterval(60)
                rateLimitResetRedemptionBlockedUntil[accountId] = nil
                rateLimitResetInventoryRetryAfter[accountId] = nil
                rateLimitResetManualErrors[accountId] = nil
                recordSuccessfulManualRateLimitResetSwapHold(
                    attempt: succeeded,
                    at: Date()
                )
                startPollingForAccount(accountId)
                statusBarController.updateIcon()
                updatePopoverContent()
                SwapLog.append(.debug(
                    "RESET_RECONCILIATION_COMPLETED account=\(account.email) attempt=\(succeeded.id.uuidString) source=\(source) remaining=\(bank.availableCount)"
                ))
                return true
            case .unresolved(let attempt):
                rateLimitResetUnresolvedProviderAccountIds.insert(providerAccountId)
                rateLimitResetSubmissionTracker.reconcile(
                    providerAccountId: providerAccountId,
                    unresolvedAttempt: attempt
                )
                queueTelemetryPersistence(context: "reset-reconciling")
                statusBarController.updateIcon()
                updatePopoverContent()
                SwapLog.append(.debug(
                    "RESET_RECONCILIATION_PENDING account=\(account.email) attempt=\(attempt.id.uuidString) source=\(source) inventory_fetched=\(Int(bank.fetchedAt.timeIntervalSince1970)) quota_fetched=\(Int(quota.snapshot.fetchedAt.timeIntervalSince1970))"
                ))
                return false
            case .noAttempt:
                rateLimitResetUnresolvedProviderAccountIds.remove(providerAccountId)
                rateLimitResetSubmissionTracker.reconcile(
                    providerAccountId: providerAccountId,
                    unresolvedAttempt: nil
                )
                clearPendingManualRateLimitResetSwapHold(
                    forProviderAccountId: providerAccountId,
                    reason: .manual
                )
                return false
            }
        } catch {
            recordRateLimitResetJournalFailureIfNeeded(
                error,
                context: "reconciliation"
            )
            rateLimitResetUnresolvedProviderAccountIds.insert(providerAccountId)
            SwapLog.append(.debug(
                "RESET_RECONCILIATION_FAILED account=\(account.email) source=\(source) error=\(error.localizedDescription)"
            ))
            return false
        }
    }

    private func startRateLimitResetRedemption(
        account: CodexAccount,
        bank: RateLimitResetBank,
        reason: RateLimitResetRedemptionReason,
        policyAuthority: AccountAutomaticPolicyAuthority? = nil
    ) {
        guard !isExiting,
              policyAuthority?.authorizes() ?? true else {
            recordManualRateLimitResetError(
                "CodexSwitch is shutting down",
                for: account.id,
                reason: reason
            )
            return
        }
        guard account.hasCompleteRuntimeCredentials,
              let providerAccountId = account.normalizedProviderAccountId else {
            recordManualRateLimitResetError(
                "Complete runtime credentials are required to redeem a reset",
                for: account.id,
                reason: reason
            )
            return
        }
        guard rateLimitResetRedemptionTask == nil else {
            recordManualRateLimitResetError(
                "Another reset redemption is already in progress",
                for: account.id,
                reason: reason
            )
            return
        }
        guard !rateLimitResetUnresolvedProviderAccountIds.contains(providerAccountId) else {
            recordManualRateLimitResetError(
                "This account already has a reset awaiting reconciliation",
                for: account.id,
                reason: reason
            )
            return
        }
        guard let configured = accountManager.configuredAccount,
              accountManager.activationState != nil else {
            recordManualRateLimitResetError(
                "The active runtime is not ready; wait for account activation to finish",
                for: account.id,
                reason: reason
            )
            return
        }
        let service = rateLimitResetService
        let submissionTracker = rateLimitResetSubmissionTracker
        recordManualRateLimitResetError(nil, for: account.id, reason: reason)
        rateLimitResetOperationProviderAccountId = providerAccountId
        rateLimitResetUnresolvedProviderAccountIds.insert(providerAccountId)
        if reason == .manual {
            setManualRateLimitResetSwapSuppression(
                Self.manualRateLimitResetSwapSuppressionAfterStarting(
                    manualRateLimitResetSwapSuppressions[providerAccountId]
                ),
                forProviderAccountId: providerAccountId
            )
        }
        SwapLog.append(.debug(
            "RESET_REDEMPTION_STARTED account=\(account.email) reason=\(reason.rawValue) available=\(bank.availableCount)"
        ))

        rateLimitResetRedemptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !self.isExiting,
                  policyAuthority?.authorizes() ?? true else {
                self.rateLimitResetUnresolvedProviderAccountIds.remove(providerAccountId)
                self.rateLimitResetOperationProviderAccountId = nil
                self.rateLimitResetRedemptionTask = nil
                return
            }
            guard let activationState = await self.activationStateForRequest(
                policyAuthority: policyAuthority
            ),
                  policyAuthority?.authorizes() ?? true,
                  Self.rateLimitResetActivationStateAllows(
                      activationState,
                      reason: reason
                  ),
                  !self.isExiting,
                  self.accountManager.configuredAccount?.id == configured.id else {
                do {
                    let unresolvedAttempt = try await service.unresolvedAttempt(
                        for: providerAccountId
                    )
                    submissionTracker.reconcile(
                        providerAccountId: providerAccountId,
                        unresolvedAttempt: unresolvedAttempt
                    )
                    if unresolvedAttempt == nil {
                        self.rateLimitResetUnresolvedProviderAccountIds.remove(providerAccountId)
                        self.clearPendingManualRateLimitResetSwapHold(
                            forProviderAccountId: providerAccountId,
                            reason: reason
                        )
                    } else {
                        self.rateLimitResetUnresolvedProviderAccountIds.insert(providerAccountId)
                    }
                } catch {
                    self.recordRateLimitResetJournalFailureIfNeeded(
                        error,
                        context: "redemption-preflight"
                    )
                    self.rateLimitResetUnresolvedProviderAccountIds.insert(providerAccountId)
                }
                self.recordManualRateLimitResetError(
                    "The active runtime changed before redemption could begin",
                    for: account.id,
                    reason: reason
                )
                self.rateLimitResetOperationProviderAccountId = nil
                self.rateLimitResetRedemptionTask = nil
                return
            }
            let shouldResumeSwap = await self.accountMutationTransaction.withResetLease(
                accountId: account.id,
                activationGeneration: activationState.activationGeneration
            ) { [weak self] lease in
                guard let self,
                      !self.isExiting,
                      policyAuthority?.authorizes() ?? true else {
                    return false
                }
                return await self.performRateLimitResetRedemption(
                    account: account,
                    configured: configured,
                    bank: bank,
                    reason: reason,
                    requiredActivationPhase: activationState.phase,
                    service: service,
                    submissionTracker: submissionTracker,
                    lease: lease,
                    policyAuthority: policyAuthority
                )
            }
            if shouldResumeSwap == nil {
                self.rateLimitResetUnresolvedProviderAccountIds.remove(providerAccountId)
                self.clearPendingManualRateLimitResetSwapHold(
                    forProviderAccountId: providerAccountId,
                    reason: reason
                )
                self.recordManualRateLimitResetError(
                    "Account state changed before redemption could begin",
                    for: account.id,
                    reason: reason
                )
            }
            self.rateLimitResetOperationProviderAccountId = nil
            do {
                let unresolvedAttempt = try await service.unresolvedAttempt(
                    for: providerAccountId
                )
                submissionTracker.reconcile(
                    providerAccountId: providerAccountId,
                    unresolvedAttempt: unresolvedAttempt
                )
                if unresolvedAttempt == nil {
                    self.rateLimitResetUnresolvedProviderAccountIds.remove(providerAccountId)
                    self.clearPendingManualRateLimitResetSwapHold(
                        forProviderAccountId: providerAccountId,
                        reason: reason
                    )
                } else {
                    self.rateLimitResetUnresolvedProviderAccountIds.insert(providerAccountId)
                }
            } catch {
                self.recordRateLimitResetJournalFailureIfNeeded(
                    error,
                    context: "redemption-cleanup"
                )
                SwapLog.append(.debug(
                    "RESET_SUBMISSION_EXPECTATION_RETAINED account=\(account.email) reason=journal_unavailable"
                ))
            }
            self.rateLimitResetRedemptionTask = nil
            if reason == .manual,
               self.rateLimitResetManualErrors[account.id] != nil,
               !self.isExiting {
                self.scheduleRateLimitResetRefresh(
                    for: account.id,
                    force: true
                )
            }
            if Self.automaticSwapMayResume(
                after: reason,
                operationRequestedResume: shouldResumeSwap == true
            ), !self.isExiting {
                self.checkAndSwapIfNeeded()
            }
        }
    }

    private func performRateLimitResetRedemption(
        account: CodexAccount,
        configured: CodexAccount,
        bank: RateLimitResetBank,
        reason: RateLimitResetRedemptionReason,
        requiredActivationPhase: AccountActivationPhase,
        service: RateLimitResetService,
        submissionTracker: RateLimitResetSubmissionTracker,
        lease: AccountMutationLease,
        policyAuthority: AccountAutomaticPolicyAuthority? = nil
    ) async -> Bool {
        let accountId = account.id
        guard account.hasCompleteRuntimeCredentials,
              let providerAccountId = account.normalizedProviderAccountId else {
            recordManualRateLimitResetError(
                "Complete runtime credentials are required to redeem a reset",
                for: accountId,
                reason: reason
            )
            return true
        }
        do {
            guard let authorized = await revalidateRateLimitResetRedemption(
                account: account,
                configuredAccount: configured,
                authorizedBank: bank,
                reason: reason,
                requiredActivationPhase: requiredActivationPhase,
                lease: lease,
                policyAuthority: policyAuthority
            ) else {
                recordManualRateLimitResetError(
                    "Account eligibility changed before the reset was submitted",
                    for: accountId,
                    reason: reason
                )
                return false
            }
            let result = try await service.consume(
                for: authorized.account,
                bank: authorized.bank,
                redemptionReason: reason,
                authorizeSubmission: { [weak self] attempt in
                    guard let self else { return nil }
                    return await self.resetSubmissionStillAuthorized(
                        account: authorized.account,
                        configuredAccount: configured,
                        bank: authorized.bank,
                        reason: reason,
                        requiredActivationPhase: requiredActivationPhase,
                        lease: lease,
                        attempt: attempt,
                        policyAuthority: policyAuthority
                    )
                },
                submissionWillStart: { attempt in
                    submissionTracker.begin(attempt: attempt)
                }
            )
            switch result {
            case .reconciliationRequired(let attemptId):
                do {
                    let refreshedBank = try await service.fetchBank(for: account, force: true)
                    let reconciled = await reconcileRateLimitResetAttempt(
                        account: account,
                        bank: refreshedBank,
                        source: "consume-response"
                    )
                    if !reconciled {
                        rateLimitResetInventoryRetryAfter[accountId] = Date().addingTimeInterval(60)
                    }
                } catch {
                    rateLimitResetInventoryRetryAfter[accountId] = Date().addingTimeInterval(60)
                    SwapLog.append(.debug(
                        "RESET_RECONCILIATION_INVENTORY_FAILED account=\(account.email) attempt=\(attemptId.uuidString) error=\(error.localizedDescription)"
                    ))
                }
            case .noCredit, .nothingToReset:
                rateLimitResetUnresolvedProviderAccountIds.remove(providerAccountId)
                submissionTracker.clear(providerAccountId: providerAccountId)
                clearPendingManualRateLimitResetSwapHold(
                    forProviderAccountId: providerAccountId,
                    reason: reason
                )
                rateLimitResetRedemptionBlockedUntil[accountId] = Date().addingTimeInterval(60)
                scheduleRateLimitResetRefresh(
                    for: accountId,
                    force: true,
                    checkSwapAfter: Self.automaticSwapMayResume(
                        after: reason,
                        operationRequestedResume: true
                    )
                )
                recordManualRateLimitResetError(
                    "No redeemable reset remained when the request was submitted",
                    for: accountId,
                    reason: reason
                )
                SwapLog.append(.debug(
                    "RESET_REDEMPTION_INAPPLICABLE account=\(account.email) result=\(String(describing: result))"
                ))
            }
            return false
        } catch {
            let journalUnavailable: Bool
            if let serviceError = error as? RateLimitResetServiceError,
               case .journalUnavailable = serviceError {
                journalUnavailable = true
            } else {
                journalUnavailable = false
            }
            let journalReportsUnresolved: Bool
            do {
                journalReportsUnresolved = try await service
                    .unresolvedAttempt(for: account.accountId) != nil
            } catch {
                journalReportsUnresolved = true
            }
            if journalReportsUnresolved || journalUnavailable {
                if journalUnavailable {
                    recordRateLimitResetJournalFailureIfNeeded(
                        error,
                        context: "redemption"
                    )
                }
                rateLimitResetUnresolvedProviderAccountIds.insert(providerAccountId)
                rateLimitResetInventoryRetryAfter[accountId] = Date().addingTimeInterval(60)
                if journalUnavailable {
                    accountManager.updatePollingError(
                        for: accountId,
                        error: "Reset journal unavailable; automatic redemption blocked"
                    )
                }
                SwapLog.append(.debug(
                    "RESET_REDEMPTION_UNCERTAIN account=\(account.email) error=\(error.localizedDescription) automatic_redemption=suppressed"
                ))
                return false
            }
            rateLimitResetUnresolvedProviderAccountIds.remove(providerAccountId)
            submissionTracker.clear(providerAccountId: providerAccountId)
            clearPendingManualRateLimitResetSwapHold(
                forProviderAccountId: providerAccountId,
                reason: reason
            )
            rateLimitResetRedemptionBlockedUntil[accountId] = Date().addingTimeInterval(60)
            recordManualRateLimitResetError(
                error.localizedDescription,
                for: accountId,
                reason: reason
            )
            SwapLog.append(.debug(
                "RESET_REDEMPTION_FAILED_BEFORE_SUBMISSION account=\(account.email) error=\(error.localizedDescription)"
            ))
            return true
        }
    }

    private func revalidateRateLimitResetRedemption(
        account: CodexAccount,
        configuredAccount: CodexAccount,
        authorizedBank initialAuthorizedBank: RateLimitResetBank,
        reason: RateLimitResetRedemptionReason,
        requiredActivationPhase: AccountActivationPhase,
        lease: AccountMutationLease,
        policyAuthority: AccountAutomaticPolicyAuthority? = nil
    ) async -> (account: CodexAccount, bank: RateLimitResetBank)? {
        let activationGeneration = lease.purpose.activationGeneration
        guard policyAuthority?.authorizes() ?? true,
              await accountMutationTransaction.owns(lease),
              policyAuthority?.authorizes() ?? true,
              accountManager.activationState?.phase == requiredActivationPhase,
              accountManager.activationState.map({
                  Self.rateLimitResetActivationStateAllows($0, reason: reason)
              }) == true,
              accountManager.activationState?.configuredAccountId == configuredAccount.id,
              accountManager.activationState?.activationGeneration == activationGeneration else {
            return nil
        }

        do {
            let unresolvedAttempt = try await rateLimitResetService.unresolvedAttempt(
                for: account.accountId
            )
            guard policyAuthority?.authorizes() ?? true else { return nil }
            rateLimitResetSubmissionTracker.reconcile(
                providerAccountId: account.accountId,
                unresolvedAttempt: unresolvedAttempt
            )
            guard unresolvedAttempt == nil else {
                if let providerAccountId = account.normalizedProviderAccountId {
                    rateLimitResetUnresolvedProviderAccountIds.insert(providerAccountId)
                }
                return nil
            }
            let quota = try await quotaPoller.fetchQuota(for: account)
            guard policyAuthority?.authorizes() ?? true else { return nil }
            accountManager.updateQuota(
                for: account.id,
                snapshot: quota.snapshot,
                planType: quota.planType
            )
            let refreshedBank = try await rateLimitResetService.fetchBank(
                for: account,
                force: true
            )
            guard policyAuthority?.authorizes() ?? true else { return nil }
            let now = Date()
            let observation = await observeRateLimitResetBank(
                for: account,
                previousBank: initialAuthorizedBank,
                refreshedBank: refreshedBank,
                source: "redemption-preflight",
                at: now
            )
            guard !observation.transition.observedExternalRedemption,
                  Self.rateLimitResetAvailableInventoryMatches(
                      initialAuthorizedBank,
                      refreshedBank,
                      at: now
                  ) else {
                return nil
            }
            guard let refreshedAccount = accountManager.accounts.first(where: {
                $0.id == account.id
            }) else {
                return nil
            }

            if reason == .manual {
                guard RateLimitResetPolicy.canManuallyRedeem(
                    for: refreshedAccount,
                    bank: initialAuthorizedBank,
                    now: now
                ) else {
                    return nil
                }
            } else {
                guard let selection = RateLimitResetPolicy.selectRedemptionCandidate(
                    from: accountManager.accounts,
                    excluding: [],
                    now: now
                ),
                selection.accountId == account.id,
                selection.reason == reason,
                Self.rateLimitResetAvailableInventoryMatches(
                    selection.bank,
                    initialAuthorizedBank,
                    at: now
                ) else {
                    return nil
                }
            }

            let orchestrationPlan = RateLimitResetOrchestrationPlan(reason: reason)
            let runtimePermit = await orchestrationPlan.requestRuntimeAuthorization {
                await requireFreshLocalRuntimePermit(
                    for: configuredAccount,
                    activationGeneration: activationGeneration,
                    requiredPhase: requiredActivationPhase,
                    policyAuthority: policyAuthority
                )
            }
            guard policyAuthority?.authorizes() ?? true,
                  initialAuthorizedBank.isFresh(
                at: now,
                maxAge: Self.rateLimitResetDecisionFreshnessInterval
            ),
                  !orchestrationPlan.requiresRuntimeAuthorization || runtimePermit != nil else {
                return nil
            }
            guard await durableConfiguredFilesMatch(configuredAccount),
                  policyAuthority?.authorizes() ?? true,
                  try await rateLimitResetService.unresolvedAttempt(
                      for: account.accountId
                  ) == nil,
                  policyAuthority?.authorizes() ?? true,
                  await accountMutationTransaction.owns(lease),
                  policyAuthority?.authorizes() ?? true,
                  accountManager.activationState?.phase == requiredActivationPhase,
                  accountManager.activationState.map({
                      Self.rateLimitResetActivationStateAllows($0, reason: reason)
                  }) == true,
                  accountManager.activationState?.configuredAccountId == configuredAccount.id,
                  accountManager.activationState?.activationGeneration == activationGeneration else {
                return nil
            }
            return (refreshedAccount, initialAuthorizedBank)
        } catch {
            SwapLog.append(.debug(
                "RESET_REDEMPTION_REVALIDATION_FAILED account=\(account.email) error=\(error.localizedDescription)"
            ))
            return nil
        }
    }

    private func resetSubmissionStillAuthorized(
        account: CodexAccount,
        configuredAccount: CodexAccount,
        bank authorizedBank: RateLimitResetBank,
        reason: RateLimitResetRedemptionReason,
        requiredActivationPhase: AccountActivationPhase,
        lease: AccountMutationLease,
        attempt: RateLimitResetAttempt,
        policyAuthority: AccountAutomaticPolicyAuthority? = nil
    ) async -> RateLimitResetSubmissionPermit? {
        guard !isExiting,
              policyAuthority?.authorizes() ?? true else {
            return nil
        }
        let activationGeneration = lease.purpose.activationGeneration
        let refreshedBank: RateLimitResetBank
        do {
            let quota = try await quotaPoller.fetchQuota(for: account)
            guard policyAuthority?.authorizes() ?? true else { return nil }
            accountManager.updateQuota(
                for: account.id,
                snapshot: quota.snapshot,
                planType: quota.planType
            )
            refreshedBank = try await rateLimitResetService.fetchBank(
                for: account,
                force: true
            )
            guard policyAuthority?.authorizes() ?? true else { return nil }
        } catch {
            return nil
        }
        let now = Date()
        let observation = await observeRateLimitResetBank(
            for: account,
            previousBank: authorizedBank,
            refreshedBank: refreshedBank,
            source: "submission-authorization",
            at: now
        )
        guard !observation.transition.observedExternalRedemption else { return nil }

        let orchestrationPlan = RateLimitResetOrchestrationPlan(reason: reason)
        let runtimePermit = await orchestrationPlan.requestRuntimeAuthorization {
            await requireFreshLocalRuntimePermit(
                for: configuredAccount,
                activationGeneration: activationGeneration,
                requiredPhase: requiredActivationPhase,
                policyAuthority: policyAuthority
            )
        }
        guard !orchestrationPlan.requiresRuntimeAuthorization || runtimePermit != nil else {
            return nil
        }
        let durableConfiguredTargetMatches = await durableConfiguredFilesMatch(
            configuredAccount
        )
        let journalAttempt: RateLimitResetAttempt?
        do {
            journalAttempt = try await rateLimitResetService.unresolvedAttempt(
                for: account.accountId
            )
        } catch {
            return nil
        }
        let currentAccount = accountManager.accounts.first(where: { $0.id == account.id })
        let quotaIsFresh = currentAccount?.realQuotaSnapshot?.isFresh(at: now) == true
            && refreshedBank.isFresh(
                at: now,
                maxAge: Self.rateLimitResetDecisionFreshnessInterval
            )
        let inventoryStillMatches = Self.rateLimitResetInventoryStillAuthorizesSubmission(
            attempt: attempt,
            authorizedBank: authorizedBank,
            refreshedBank: refreshedBank,
            now: now
        )
        let candidateStillMatches: Bool
        if reason == .manual {
            candidateStillMatches = currentAccount.map {
                RateLimitResetPolicy.canManuallyRedeem(
                    for: $0,
                    bank: refreshedBank,
                    now: now
                )
            } == true
        } else {
            let selection = RateLimitResetPolicy.selectRedemptionCandidate(
                from: accountManager.accounts,
                excluding: [],
                now: now
            )
            candidateStillMatches = selection?.accountId == account.id
                && selection?.reason == reason
                && selection?.bank == refreshedBank
        }
        let resetJournalMatches = journalAttempt == attempt && attempt.state == .submitted
        let runtimeAuthorizationStillValid = runtimePermit.map {
            $0.authorizes(state: accountManager.activationState, at: now)
        } ?? true

        guard !isExiting,
              policyAuthority?.authorizes() ?? true,
              externalRateLimitResetHoldStateIsReadable,
              !Self.rateLimitResetRedemptionIsBlocked(
                  until: externalRateLimitResetRedemptionBlockedUntil[account.id],
                  at: now
              ),
              !Self.rateLimitResetRedemptionIsBlocked(
                  until: rateLimitResetRedemptionBlockedUntil[account.id],
                  at: now
              ),
              durableConfiguredTargetMatches,
              quotaIsFresh,
              inventoryStillMatches,
              candidateStillMatches,
              resetJournalMatches,
              accountManager.configuredAccount?.id == configuredAccount.id,
              accountManager.activationState?.phase == requiredActivationPhase,
              accountManager.activationState.map({
                  Self.rateLimitResetActivationStateAllows($0, reason: reason)
              }) == true,
              runtimeAuthorizationStillValid,
              lease.purpose.accountId == account.id,
              lease.purpose.activationGeneration == activationGeneration,
              let activationEffectPermit = accountMutationTransaction.makeEffectPermit(
                  lease: lease,
                  targetAccountId: configuredAccount.id,
                  activationGeneration: activationGeneration,
                  requiredPhase: requiredActivationPhase,
                  runtimePermit: runtimePermit,
                  journal: accountActivationCoordinator,
                  at: now
              ) else {
            return nil
        }
        return RateLimitResetSubmissionPermit(
            attemptId: attempt.id,
            providerAccountId: account.accountId,
            creditId: attempt.creditId,
            targetAccountId: configuredAccount.id,
            activationGeneration: activationGeneration,
            leaseGeneration: lease.generation,
            runtimeAuthorizationRequired: orchestrationPlan.requiresRuntimeAuthorization,
            runtimePermit: runtimePermit,
            activationEffectPermit: activationEffectPermit,
            issuedAt: now
        )
    }

    nonisolated static func rateLimitResetActivationStateAllows(
        _ state: AccountActivationState,
        reason: RateLimitResetRedemptionReason
    ) -> Bool {
        switch reason {
        case .manual:
            state.phase == .confirmed || state.phase == .committedDegraded
        default:
            state.phase == .confirmed
        }
    }

    nonisolated static func rateLimitResetInventoryStillAuthorizesSubmission(
        attempt: RateLimitResetAttempt,
        authorizedBank: RateLimitResetBank,
        refreshedBank: RateLimitResetBank,
        now: Date
    ) -> Bool {
        return authorizedBank.availableCount == attempt.startingAvailableCount
            && authorizedBank.fetchedAt == attempt.startingBankFetchedAt
            && attempt.creditExpiresAt.map { $0 > now } == true
            && authorizedBank.credits.first(where: {
                $0.normalizedRedemptionIdentifier == attempt.creditId
            })?.expiresAt == attempt.creditExpiresAt
            && refreshedBank.availableCount == attempt.startingAvailableCount
            && Self.rateLimitResetAvailableInventoryMatches(
                authorizedBank,
                refreshedBank,
                at: now
            )
            && refreshedBank.oldestExpiringCredit(at: now)?.id == attempt.creditId
    }

    nonisolated static func rateLimitResetAvailableInventoryMatches(
        _ lhs: RateLimitResetBank,
        _ rhs: RateLimitResetBank,
        at now: Date
    ) -> Bool {
        guard let lhsCredits = lhs.structurallyValidAvailableCredits(at: now),
              let rhsCredits = rhs.structurallyValidAvailableCredits(at: now) else {
            return false
        }
        return lhs.availableCount == rhs.availableCount && lhsCredits == rhsCredits
    }

    nonisolated static func rateLimitResetInventorySemanticallyChanged(
        previous: RateLimitResetBank?,
        refreshed: RateLimitResetBank
    ) -> Bool {
        guard let previous else { return true }
        return previous.availableCount != refreshed.availableCount
            || previous.totalEarnedCount != refreshed.totalEarnedCount
            || previous.credits != refreshed.credits
    }

    nonisolated static func automaticSwapMayResume(
        after reason: RateLimitResetRedemptionReason,
        operationRequestedResume: Bool
    ) -> Bool {
        reason != .manual && operationRequestedResume
    }

    nonisolated static func rateLimitResetJournalAllowsAutomaticRouting(
        isReadable: Bool
    ) -> Bool {
        isReadable
    }

    nonisolated static func manualRateLimitResetSwapSuppressionAfterStarting(
        _ existing: ManualRateLimitResetSwapSuppression?
    ) -> ManualRateLimitResetSwapSuppression {
        existing == .durable ? .durable : .pending
    }

    nonisolated static func manualRateLimitResetSwapSuppressionAfterClearingPending(
        _ existing: ManualRateLimitResetSwapSuppression?
    ) -> ManualRateLimitResetSwapSuppression? {
        existing == .pending ? nil : existing
    }

    nonisolated static func manualRateLimitResetSwapSuppressionAfterSuccess(
        _ existing: ManualRateLimitResetSwapSuppression?,
        attempt: RateLimitResetAttempt
    ) -> ManualRateLimitResetSwapSuppression? {
        guard attempt.redemptionReason == .manual else { return existing }
        return attempt.routineSwapSuppressionReleasedAt == nil ? .durable : nil
    }

    nonisolated static func manualRateLimitResetReleaseMayClearLiveSuppression(
        observedRevision: UInt64,
        currentRevision: UInt64
    ) -> Bool {
        observedRevision == currentRevision
    }

    nonisolated static func manualRateLimitResetRestoreMayApply(
        capturedRevision: UInt64,
        currentRevision: UInt64,
        releaseInFlight: Bool,
        currentSuppression: ManualRateLimitResetSwapSuppression?,
        restoredSuppression: ManualRateLimitResetSwapSuppression?
    ) -> Bool {
        guard capturedRevision == currentRevision, !releaseInFlight else { return false }
        return currentSuppression != .pending || restoredSuppression != nil
    }

    private func setManualRateLimitResetSwapSuppression(
        _ suppression: ManualRateLimitResetSwapSuppression?,
        forProviderAccountId providerAccountId: String
    ) {
        manualRateLimitResetSwapSuppressions[providerAccountId] = suppression
        manualRateLimitResetSwapSuppressionRevisions[providerAccountId, default: 0] &+= 1
    }

    private func applyRestoredManualRateLimitResetSwapSuppressions(
        _ suppressions: [String: ManualRateLimitResetSwapSuppression],
        capturedRevisions: [String: UInt64]
    ) {
        let providerAccountIds = Set(manualRateLimitResetSwapSuppressions.keys)
            .union(suppressions.keys)
            .union(capturedRevisions.keys)
        for providerAccountId in providerAccountIds {
            let capturedRevision = capturedRevisions[providerAccountId, default: 0]
            let currentRevision = manualRateLimitResetSwapSuppressionRevisions[
                providerAccountId,
                default: 0
            ]
            let currentSuppression = manualRateLimitResetSwapSuppressions[providerAccountId]
            let restoredSuppression = suppressions[providerAccountId]
            guard Self.manualRateLimitResetRestoreMayApply(
                capturedRevision: capturedRevision,
                currentRevision: currentRevision,
                releaseInFlight: manualRateLimitResetReleaseProviderAccountIds.contains(
                    providerAccountId
                ),
                currentSuppression: currentSuppression,
                restoredSuppression: restoredSuppression
            ) else {
                continue
            }
            setManualRateLimitResetSwapSuppression(
                restoredSuppression,
                forProviderAccountId: providerAccountId
            )
        }
    }

    nonisolated static func manualRateLimitResetSwapSuppressions(
        attempts: [RateLimitResetAttempt]
    ) -> [String: ManualRateLimitResetSwapSuppression] {
        var suppressions: [String: ManualRateLimitResetSwapSuppression] = [:]
        for attempt in attempts where
            attempt.redemptionReason == .manual
                && attempt.routineSwapSuppressionReleasedAt == nil {
            guard let providerAccountId = attempt.normalizedProviderAccountId else {
                continue
            }

            let suppression: ManualRateLimitResetSwapSuppression
            switch attempt.state {
            case .prepared, .submitted, .reconciling, .pendingPersistence:
                suppression = .pending
            case .succeeded:
                suppression = .durable
            case .notApplied:
                continue
            }
            if suppressions[providerAccountId] != .durable {
                suppressions[providerAccountId] = suppression
            }
        }
        return suppressions
    }

    nonisolated static func rateLimitResetBankIsFresh(
        _ bank: RateLimitResetBank?,
        at now: Date,
        requiresDecisionEvidence: Bool
    ) -> Bool {
        let maximumAge = requiresDecisionEvidence
            ? rateLimitResetDecisionFreshnessInterval
            : rateLimitResetBackgroundFreshnessInterval
        guard let bank,
              bank.isFresh(at: now, maxAge: maximumAge) else {
            return false
        }
        return bank.structurallyValidAvailableCredits(at: now) != nil
    }

    nonisolated static func rateLimitResetQuotaRequiresDecisionEvidence(
        _ snapshot: QuotaSnapshot?,
        at now: Date
    ) -> Bool {
        guard let snapshot, snapshot.isFresh(at: now) else { return false }
        return snapshot.isDenied
            || snapshot.needsSwap
            || snapshot.blockingWindows.contains(where: \.isExhausted)
    }

    nonisolated static func rateLimitResetRedemptionIsBlocked(
        until blockedUntil: Date?,
        at now: Date
    ) -> Bool {
        blockedUntil.map { $0 > now } ?? false
    }

    // MARK: - Swap Monitor

    private func startSwapMonitor() {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await MainActor.run {
                    self.checkAndSwapIfNeeded()
                }
            }
        }
    }

    private func checkAndSwapIfNeeded(
        trigger: AccountAutomaticPolicyTrigger = .routine
    ) {
        guard !isExiting,
              automaticPolicyGateTask == nil,
              automaticPolicyLeaseState.current == nil else {
            return
        }
        let now = Date()
        guard pendingSwapTargetAccountId == nil,
              swapConvergenceTask == nil else {
            return
        }
        guard let configured = accountManager.configuredAccount else { return }
        guard let lease = automaticPolicyLeaseState.begin(
            at: now,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            timeout: Self.automaticPolicyGateTimeout
        ) else { return }
        automaticPolicyGateTask = Task { @MainActor [weak self] in
            guard let self else {
                lease.authority.revoke()
                return
            }
            defer {
                self.finishAutomaticPolicyEvaluation(
                    lease,
                    trigger: trigger,
                    cancelled: Task.isCancelled || self.isExiting
                )
            }
            guard !self.isExiting else { return }
            guard self.automaticPolicyEvaluationIsCurrent(lease) else { return }
            let resetJournalIsReadable = await self.ensureRateLimitResetJournalStateIsReadable()
            guard self.automaticPolicyEvaluationIsCurrent(lease),
                  Self.rateLimitResetJournalAllowsAutomaticRouting(
                isReadable: resetJournalIsReadable
            ) else {
                return
            }
            guard let activationState = await self.activationStateForRequest(
                at: now,
                policyAuthority: lease.authority
            ),
                  self.automaticPolicyEvaluationIsCurrent(lease),
                  activationState.phase == .confirmed else {
                if self.automaticPolicyEvaluationIsCurrent(lease) {
                    self.retryActivationConvergenceIfDue(at: now)
                }
                return
            }
            let activationGeneration = activationState.activationGeneration
            guard let permit = await self.requireFreshLocalRuntimePermit(
                for: configured,
                activationGeneration: activationGeneration,
                requiredPhase: .confirmed,
                policyAuthority: lease.authority
            ),
            self.automaticPolicyEvaluationIsCurrent(lease),
            AccountAutomaticPolicyGate.authorizes(
                trigger: trigger,
                configuredAccountId: self.accountManager.configuredAccount?.id,
                state: self.accountManager.activationState,
                permit: permit,
                at: Date()
            ) else {
                return
            }
            await self.checkAndSwapWithFreshRuntimePermit(
                permit,
                trigger: trigger,
                policyLease: lease
            )
        }
        startAutomaticPolicyWatchdog(for: lease, trigger: trigger)
    }

    private func automaticPolicyEvaluationIsCurrent(
        _ lease: AccountAutomaticPolicyLease
    ) -> Bool {
        !Task.isCancelled
            && !isExiting
            && automaticPolicyLeaseState.authorizes(
                lease,
                uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
    }

    private func finishAutomaticPolicyEvaluation(
        _ lease: AccountAutomaticPolicyLease,
        trigger: AccountAutomaticPolicyTrigger,
        cancelled: Bool
    ) {
        if cancelled {
            guard automaticPolicyLeaseState.cancel(lease) else { return }
            automaticPolicyGateWatchdogTask?.cancel()
            automaticPolicyGateWatchdogTask = nil
            automaticPolicyGateTask = nil
            return
        }
        let finished = automaticPolicyLeaseState.finish(
            lease,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        guard finished != .stale else { return }
        automaticPolicyGateWatchdogTask?.cancel()
        automaticPolicyGateWatchdogTask = nil
        automaticPolicyGateTask = nil
        if finished == .expired {
            recordAutomaticPolicyTimeout(lease, trigger: trigger)
        }
    }

    private func startAutomaticPolicyWatchdog(
        for lease: AccountAutomaticPolicyLease,
        trigger: AccountAutomaticPolicyTrigger
    ) {
        automaticPolicyGateWatchdogTask?.cancel()
        automaticPolicyGateWatchdogTask = Task { @MainActor [weak self] in
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < lease.deadlineUptimeNanoseconds else { break }
                let remaining = TimeInterval(
                    lease.deadlineUptimeNanoseconds - now
                ) / 1_000_000_000
                do {
                    try await Task.sleep(for: .seconds(remaining))
                } catch {
                    return
                }
            }
            guard let self,
                  !self.isExiting,
                  self.automaticPolicyLeaseState.expire(
                    lease,
                    uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                  ) else {
                return
            }
            self.automaticPolicyGateTask?.cancel()
            self.automaticPolicyGateTask = nil
            self.automaticPolicyGateWatchdogTask = nil
            self.recordAutomaticPolicyTimeout(lease, trigger: trigger)
        }
    }

    private func recordAutomaticPolicyTimeout(
        _ lease: AccountAutomaticPolicyLease,
        trigger: AccountAutomaticPolicyTrigger
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedMilliseconds = now >= lease.startedAtUptimeNanoseconds
            ? (now - lease.startedAtUptimeNanoseconds) / 1_000_000
            : 0
        SwapLog.append(.debug(
            "AUTOMATIC_POLICY_GATE_TIMEOUT generation=\(lease.generation.uuidString) trigger=\(Self.automaticPolicyTriggerDescription(trigger)) elapsed_ms=\(elapsedMilliseconds)"
        ))
    }

    nonisolated private static func automaticPolicyTriggerDescription(
        _ trigger: AccountAutomaticPolicyTrigger
    ) -> String {
        switch trigger {
        case .routine:
            return "routine"
        case .usageUnavailable(let accountId):
            return "usage_unavailable:\(accountId.uuidString)"
        case .tokenInvalidated(let accountId):
            return "token_invalidated:\(accountId.uuidString)"
        }
    }

    private func checkAndSwapWithFreshRuntimePermit(
        _ permit: AccountActivationRuntimePermit,
        trigger: AccountAutomaticPolicyTrigger,
        policyLease: AccountAutomaticPolicyLease
    ) async {
        let now = Date()
        guard automaticPolicyEffectIsAuthorized(
            permit: permit,
            trigger: trigger,
            policyLease: policyLease,
            at: now
        ) else {
            return
        }
        await restoreExternalRateLimitResetHolds(at: now)
        guard automaticPolicyEffectIsAuthorized(
            permit: permit,
            trigger: trigger,
            policyLease: policyLease,
            at: Date()
        ) else { return }
        guard let active = accountManager.configuredAccount else { return }
        switch trigger {
        case .routine:
            break
        case .usageUnavailable(let accountId):
            guard active.id == accountId else { return }
            if let snapshot = active.realQuotaSnapshot,
               active.isQuotaImmediatelyUsable(at: now),
               snapshot.isImmediatelyUsable {
                SwapLog.append(.debug(
                    "AUTO_SWAP_USAGE_UNAVAILABLE_SKIPPED active=\(active.email) reason=trusted_healthy_snapshot"
                ))
                return
            }
            if let upgrade = SwapEngine.selectPlanUpgradeCandidate(
                active: active,
                from: accountManager.accounts,
                now: now
            ) {
                executeSwap(
                    from: active,
                    to: upgrade,
                    reason: .usageUnavailable,
                    automaticPermit: permit,
                    automaticPolicyLease: policyLease
                )
                return
            }
            guard let best = SwapEngine.selectAutoSwapCandidate(
                from: accountManager.accounts,
                now: now
            ) else {
                return
            }
            executeSwap(
                from: active,
                to: best,
                reason: .usageUnavailable,
                automaticPermit: permit,
                automaticPolicyLease: policyLease
            )
            return
        case .tokenInvalidated(let accountId):
            guard active.id == accountId,
                  let best = SwapEngine.selectAutoSwapCandidate(
                      from: accountManager.accounts,
                      now: now
                  ) else {
                return
            }
            executeSwap(
                from: active,
                to: best,
                reason: .tokenInvalidated,
                automaticPermit: permit,
                automaticPolicyLease: policyLease
            )
            return
        }
        if let recoveryUntil = rateLimitResetRecoveryUntil[active.id] {
            if recoveryUntil <= now {
                rateLimitResetRecoveryUntil[active.id] = nil
            }
        }
        guard rateLimitResetOperationProviderAccountId == nil,
              rateLimitResetDecisionPending.isEmpty else {
            return
        }

        let activeSnapshot = active.realQuotaSnapshot
        let activeNeedsRelief = active.needsQuotaRelief(at: now)
        if manualOverrideAccountId != nil, manualOverrideAccountId != active.id {
            clearManualOverride()
        }
        if manualOverrideAccountId == active.id, activeNeedsRelief {
            clearManualOverride()
        }

        let manualOverrideActive = SwapEngine.shouldHonorManualOverride(
            activeAccountId: active.id,
            manualOverrideAccountId: manualOverrideAccountId,
            activeNeedsRelief: activeNeedsRelief
        )

        if automaticRateLimitResetRedemptionEnabled {
            let excludedAccountIds = Set(accountManager.accounts.compactMap { account -> UUID? in
                let redemptionBlocked = Self.rateLimitResetRedemptionIsBlocked(
                    until: rateLimitResetRedemptionBlockedUntil[account.id],
                    at: now
                )
                let externalRedemptionBlocked = Self.rateLimitResetRedemptionIsBlocked(
                    until: externalRateLimitResetRedemptionBlockedUntil[account.id],
                    at: now
                )
                let inventoryBlocked = rateLimitResetInventoryRetryAfter[account.id].map { $0 > now } ?? false
                let recovering = rateLimitResetRecoveryUntil[account.id].map { $0 > now } ?? false
                return redemptionBlocked
                    || externalRedemptionBlocked
                    || inventoryBlocked
                    || recovering
                    || rateLimitResetDecisionPending.contains(account.id)
                    || (account.normalizedProviderAccountId.map {
                        rateLimitResetUnresolvedProviderAccountIds.contains($0)
                    } ?? true)
                    ? account.id
                    : nil
            })

            if let selection = RateLimitResetPolicy.selectRedemptionCandidate(
                from: accountManager.accounts,
                excluding: excludedAccountIds,
                now: now
            ),
               let account = accountManager.accounts.first(where: { $0.id == selection.accountId }) {
                guard automaticPolicyEffectIsAuthorized(
                    permit: permit,
                    trigger: trigger,
                    policyLease: policyLease,
                    at: Date()
                ) else { return }
                startRateLimitResetRedemption(
                    account: account,
                    bank: selection.bank,
                    reason: selection.reason,
                    policyAuthority: policyLease.authority
                )
                return
            }

            let activeRedemptionBlocked = Self.rateLimitResetRedemptionIsBlocked(
                until: rateLimitResetRedemptionBlockedUntil[active.id],
                at: now
            ) || Self.rateLimitResetRedemptionIsBlocked(
                until: externalRateLimitResetRedemptionBlockedUntil[active.id],
                at: now
            )
            let activeInventoryBlocked = rateLimitResetInventoryRetryAfter[active.id].map { $0 > now } ?? false
            if activeNeedsRelief,
               !activeRedemptionBlocked,
               !activeInventoryBlocked,
               !Self.rateLimitResetBankIsFresh(
                   active.rateLimitResetBank,
                   at: now,
                   requiresDecisionEvidence: true
               ) {
                guard automaticPolicyEffectIsAuthorized(
                    permit: permit,
                    trigger: trigger,
                    policyLease: policyLease,
                    at: Date()
                ) else { return }
                scheduleRateLimitResetRefresh(
                    for: active.id,
                    checkSwapAfter: true
                )
                return
            }
        }

        let manualResetSwapExclusions = activeManualRateLimitResetSwapExclusions(at: now)
        if !manualOverrideActive,
           let upgrade = SwapEngine.selectPlanUpgradeCandidate(
               active: active,
               from: accountManager.accounts,
               excluding: manualResetSwapExclusions,
               now: now
           ) {
            exhaustedPoolAlertGate.markRecovered()
            SwapLog.append(.debug(
                "AUTO_SWAP_PLAN_UPGRADE active=\(active.email) active_plan=\(active.normalizedPlanType) target=\(upgrade.email) target_plan=\(upgrade.normalizedPlanType)"
            ))
            executeSwap(
                from: active,
                to: upgrade,
                reason: .higherPlanAvailable,
                automaticPermit: permit,
                automaticPolicyLease: policyLease
            )
            return
        }

        guard let snapshot = activeSnapshot else { return }

        guard activeNeedsRelief else {
            exhaustedPoolAlertGate.markRecovered()
            return
        }

        let quotaSummary = snapshot.orderedPolicyWindows.map {
            "\($0.kind.rawValue)=\(Int($0.effectiveRemainingPercent))"
        }.joined(separator: " ")
        SwapLog.append(.debug(
            "AUTO_SWAP_CHECK active=\(active.email) denied=\(snapshot.isDenied) windows=\(quotaSummary.isEmpty ? "none" : quotaSummary)"
        ))

        guard let best = SwapEngine.selectAutoSwapCandidate(
            from: accountManager.accounts,
            now: now
        ) else {
            guard automaticPolicyEffectIsAuthorized(
                permit: permit,
                trigger: trigger,
                policyLease: policyLease,
                at: Date()
            ) else { return }
            if exhaustedPoolAlertGate.shouldNotifyNoCandidate() {
                NotificationManager.notifyAllExhausted(
                    nextReset: SwapEngine.earliestUsableReset(
                        from: accountManager.accounts,
                        now: now
                    )
                )
                SwapLog.append(.debug("AUTO_SWAP_NO_READY_CANDIDATE active=\(active.email) notified=true"))
            } else {
                SwapLog.append(.debug("AUTO_SWAP_NO_READY_CANDIDATE active=\(active.email) notified=false"))
            }
            return
        }

        exhaustedPoolAlertGate.markRecovered()
        executeSwap(
            from: active,
            to: best,
            reason: .quotaExhausted,
            automaticPermit: permit,
            automaticPolicyLease: policyLease
        )
    }

    private func automaticPolicyEffectIsAuthorized(
        permit: AccountActivationRuntimePermit,
        trigger: AccountAutomaticPolicyTrigger,
        policyLease: AccountAutomaticPolicyLease,
        at date: Date
    ) -> Bool {
        automaticPolicyEvaluationIsCurrent(policyLease)
            && policyLease.authority.authorizes()
            && AccountAutomaticPolicyGate.authorizes(
                trigger: trigger,
                configuredAccountId: accountManager.configuredAccount?.id,
                state: accountManager.activationState,
                permit: permit,
                at: date
            )
    }

    private func withPreparedActiveCredentialMutation(
        targetAccountId: UUID,
        expectedConfiguredAccountId: UUID?,
        source: String,
        isManual: Bool,
        policyAuthority: AccountAutomaticPolicyAuthority? = nil,
        operation: @escaping @MainActor @Sendable (PreparedAccountActivation) async -> Bool
    ) async -> Bool {
        guard !isExiting,
              policyAuthority?.authorizes() ?? true else {
            return false
        }
        if pendingSwapTargetAccountId != nil || swapConvergenceTask != nil {
            accountManager.publishActivationNotice(
                "Mac activation is already converging; retry after it completes"
            )
            return false
        }

        let activationGeneration = UUID()
        let scoped = await accountMutationTransaction.withActivationLease(
            targetAccountId: targetAccountId,
            activationGeneration: activationGeneration
        ) { [weak self] lease in
            guard let self,
                  policyAuthority?.authorizes() ?? true else {
                return ScopedAccountActivationResult.blocked
            }
            switch await self.prepareActiveCredentialMutation(
                targetAccountId: targetAccountId,
                expectedConfiguredAccountId: expectedConfiguredAccountId,
                source: source,
                isManual: isManual,
                activationGeneration: activationGeneration,
                lease: lease,
                policyAuthority: policyAuthority
            ) {
            case .prepared(let prepared):
                return .completed(await operation(prepared))
            case .retrySameTarget:
                return .retrySameTarget
            case .blocked:
                return .blocked
            }
        }

        guard let scoped else {
            accountManager.publishActivationNotice(
                "Another account mutation is already in progress"
            )
            return false
        }
        switch scoped {
        case .completed(let succeeded):
            return succeeded
        case .retrySameTarget:
            if isManual,
               let target = accountManager.accounts.first(where: { $0.id == targetAccountId }) {
                await startSameTargetRuntimeRetry(to: target, source: "manual")
            }
            return false
        case .blocked:
            return false
        }
    }

    private func prepareActiveCredentialMutation(
        targetAccountId: UUID,
        expectedConfiguredAccountId: UUID?,
        source: String,
        isManual: Bool,
        activationGeneration: UUID,
        lease: AccountMutationLease,
        policyAuthority: AccountAutomaticPolicyAuthority? = nil
    ) async -> AccountActivationPreparationResult {
        guard !isExiting,
              policyAuthority?.authorizes() ?? true,
              accountManager.configuredAccount?.id == expectedConfiguredAccountId,
              await accountMutationTransaction.owns(lease) else {
            accountManager.publishActivationNotice(
                "Configured account changed before activation could begin"
            )
            return .blocked
        }

        do {
            let requestKind: AccountActivationRequestKind = isManual ? .manual : .automatic
            let decision = try await accountActivationCoordinator
                .beginAuthorizedCredentialMutation(
                targetAccountId: targetAccountId,
                kind: requestKind,
                requestedActivationGeneration: activationGeneration,
                authorizeEffect: { [accountMutationTransaction] _ in
                    (policyAuthority?.authorizes() ?? true)
                        && accountMutationTransaction.leaseAuthorizes(
                            lease,
                            targetAccountId: targetAccountId,
                            activationGeneration: activationGeneration
                        )
                }
            )
            let preparing: AccountActivationState
            let previousActivationState: AccountActivationState?
            switch decision {
            case .prepared(let state, let previousState):
                preparing = state
                previousActivationState = previousState
            case .retrySameTarget(let state):
                accountManager.publishActivationState(state)
                accountManager.publishActivationNotice(
                    "Mac runtime is not confirmed; reconciling the configured account"
                )
                return .retrySameTarget
            case .blocked(let state, let message):
                if let state {
                    accountManager.publishActivationState(state)
                }
                accountManager.publishActivationNotice(message)
                SwapLog.append(.debug(
                    "ACTIVATION_CREDENTIAL_MUTATION_BLOCKED target=\(targetAccountId.uuidString) source=\(source) reason=policy message=\(message)"
                ))
                return .blocked
            }

            let leaseOwned = await accountMutationTransaction.owns(lease)
            guard !isExiting,
                  preparing.phase == .preparing,
                  preparing.activationGeneration == activationGeneration,
                  leaseOwned,
                  accountManager.configuredAccount?.id == expectedConfiguredAccountId else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "account mutation lease or activation generation changed"
                )
            }
            accountManager.publishActivationState(preparing)
            swapGeneration &+= 1
            let generation = swapGeneration
            pendingSwapTargetAccountId = targetAccountId
            SwapLog.append(.debug(
                "ACTIVATION_CREDENTIAL_MUTATION_PREPARED target=\(targetAccountId.uuidString) source=\(source) generation=\(generation)"
            ))
            return .prepared(PreparedAccountActivation(
                swapGeneration: generation,
                activationGeneration: activationGeneration,
                expectedConfiguredAccountId: expectedConfiguredAccountId,
                previousActivationState: previousActivationState,
                lease: lease
            ))
        } catch {
            let recoveryAuthorization: AccountActivationCoordinator.StateEffectAuthorization = {
                [accountMutationTransaction] _ in
                (policyAuthority?.authorizes() ?? true)
                    && accountMutationTransaction.leaseAuthorizes(
                        lease,
                        targetAccountId: targetAccountId,
                        activationGeneration: activationGeneration
                    )
            }
            let authorizationIsCurrent = recoveryAuthorization(nil)
            guard Self.activationPreparationFailureRequiresManualReview(
                error,
                authorizationIsCurrent: authorizationIsCurrent
            ) else {
                accountManager.publishActivationNotice(
                    "Mac activation authorization expired; no changes were made"
                )
                SwapLog.append(.debug(
                    "ACTIVATION_CREDENTIAL_MUTATION_BLOCKED target=\(targetAccountId.uuidString) source=\(source) reason=authorization_revoked"
                ))
                return .blocked
            }
            if await accountMutationTransaction.owns(lease) {
                await enterActivationManualReview(
                    targetAccountId: targetAccountId,
                    detail: .prepareFailed,
                    authorizeEffect: recoveryAuthorization
                )
            }
            accountManager.publishActivationNotice(
                "Mac activation journal is unavailable; credential changes are paused"
            )
            SwapLog.append(.debug(
                "ACTIVATION_CREDENTIAL_MUTATION_BLOCKED target=\(targetAccountId.uuidString) source=\(source) error=\(error.localizedDescription)"
            ))
            return .blocked
        }
    }

    nonisolated static func activationPreparationFailureRequiresManualReview(
        _ error: Error,
        authorizationIsCurrent: Bool
    ) -> Bool {
        guard authorizationIsCurrent else { return false }
        return (error as? AccountActivationCoordinatorError) != .authorizationRevoked
    }

    private func executeSwap(
        from: CodexAccount,
        to: CodexAccount,
        reason: SwapEvent.SwapReason,
        automaticPermit: AccountActivationRuntimePermit? = nil,
        automaticPolicyLease: AccountAutomaticPolicyLease? = nil
    ) {
        guard !isExiting else { return }
        let isManual: Bool
        switch reason {
        case .manual:
            isManual = true
        default:
            isManual = false
        }
        if !isManual {
            guard let automaticPolicyLease,
                  automaticPolicyEvaluationIsCurrent(automaticPolicyLease),
                  automaticPolicyLease.authority.authorizes() else {
                return
            }
        }
        guard accountManager.activationState != nil else {
            accountManager.publishActivationNotice(
                "Mac runtime confirmation is unavailable; account changes are paused"
            )
            SwapLog.append(.debug(
                "SWAP_BLOCKED target=\(to.email) reason=missing_activation_journal"
            ))
            updatePopoverContent()
            return
        }
        guard swapConvergenceTask == nil,
              pendingSwapTargetAccountId == nil else {
            SwapLog.append(.debug(
                "SWAP_DEFERRED target=\(to.email) reason=commit_or_runtime_convergence_in_flight"
            ))
            return
        }
        Task { @MainActor [weak self] in
            guard let self, !self.isExiting else { return }
            if !isManual {
                guard let automaticPermit,
                      let automaticPolicyLease,
                      automaticPolicyLease.authority.authorizes(),
                      automaticPermit.targetAccountId == from.id,
                      automaticPermit.authorizes(
                          state: self.accountManager.activationState,
                          at: Date()
                      ),
                      self.accountManager.configuredAccount?.id == from.id else {
                    return
                }
            }
            _ = await self.withPreparedActiveCredentialMutation(
                targetAccountId: to.id,
                expectedConfiguredAccountId: from.id,
                source: "swap",
                isManual: isManual,
                policyAuthority: isManual ? nil : automaticPolicyLease?.authority
            ) { [weak self] prepared in
                guard let self else { return false }
                return await self.executeSwapTransaction(
                    from: from,
                    to: to,
                    reason: reason,
                    swapStart: Date(),
                    prepared: prepared
                )
            }
        }
    }

    private func executeSwapTransaction(
        from: CodexAccount,
        to: CodexAccount,
        reason: SwapEvent.SwapReason,
        swapStart: Date,
        prepared: PreparedAccountActivation
    ) async -> Bool {
        SwapLog.append(.swapTriggered(
            from: from.email,
            to: to.email,
            reason: String(describing: reason)
        ))

        switch reason {
        case .manual:
            setManualOverride(to.id)
        default:
            clearManualOverride()
        }

        let mutationRoute: AccountCredentialMutationRoute
        if case .higherPlanAvailable = reason {
            mutationRoute = .planUpgrade
        } else {
            mutationRoute = .swap
        }

        return await commitConfiguredCredentialMutation(
            from: from,
            to: to,
            reason: reason,
            mutationRoute: mutationRoute,
            persistenceContext: "swap",
            authAlreadyConfigured: false,
            swapStart: swapStart,
            prepared: prepared,
            recordsSwap: true
        )
    }

    private func revalidateCredentialMutation(
        route: AccountCredentialMutationRoute,
        from: CodexAccount,
        to: CodexAccount,
        reason: SwapEvent.SwapReason,
        authAlreadyConfigured: Bool,
        prepared: PreparedAccountActivation
    ) async -> AccountCredentialMutationPermit? {
        guard !isExiting,
              pendingSwapTargetAccountId == to.id,
              accountManager.activationState?.phase == .preparing,
              accountManager.activationState?.configuredAccountId == to.id,
              accountManager.activationState?.activationGeneration
                == prepared.activationGeneration,
              accountManager.configuredAccount?.id == prepared.expectedConfiguredAccountId else {
            return nil
        }

        let requiresRuntimeEvidence = AccountCredentialMutationRuntimePolicy
            .requiresSourceRuntimeEvidence(route: route, reason: reason)
        let durableConfiguredTargetMatches: Bool
        switch route {
        case .firstActivation:
            durableConfiguredTargetMatches = await durableAccountStoreHasNoConfiguredAccount()
        case .externalAuthObservation:
            durableConfiguredTargetMatches = await durableAccountStoreMatches(from)
                && authAlreadyConfigured
                && Self.authFileMatches(account: to, atPath: Self.codexAuthPath)
        case .swap, .tokenRefresh, .activeReauthentication, .planUpgrade:
            durableConfiguredTargetMatches = await durableConfiguredFilesMatch(from)
        }

        let runtimePermit: AccountActivationRuntimePermit?
        if requiresRuntimeEvidence {
            let evidenceDecision = await captureFreshLocalRuntimeEvidence(for: from)
            guard case .confirmed(let freshEvidence) = evidenceDecision else {
                if case .denied(
                    let detail,
                    let discoveredRuntimeCount,
                    let acknowledgedRuntimeCount
                ) = evidenceDecision {
                    SwapLog.append(.debug(
                        "ACTIVATION_SOURCE_RUNTIME_AUTHORIZATION_DENIED route=\(route.rawValue) source=\(from.email) detail=\(detail.rawValue) discovered=\(discoveredRuntimeCount) acknowledged=\(acknowledgedRuntimeCount)"
                    ))
                }
                return nil
            }
            runtimePermit = AccountActivationRuntimePermit(
                targetAccountId: to.id,
                activationGeneration: prepared.activationGeneration,
                requiredPhase: .preparing,
                evidence: freshEvidence
            )
        } else {
            runtimePermit = nil
        }

        let now = Date()
        guard let effectPermit = accountMutationTransaction.makeEffectPermit(
            lease: prepared.lease,
            targetAccountId: to.id,
            activationGeneration: prepared.activationGeneration,
            requiredPhase: .preparing,
            runtimePermit: runtimePermit,
            journal: accountActivationCoordinator,
            at: now
        ) else {
            return nil
        }
        let permit = AccountCredentialMutationPermit(
            effectPermit: effectPermit,
            requiresRuntimeEvidence: requiresRuntimeEvidence,
            expectedRuntimeCurrentAccountId: requiresRuntimeEvidence ? from.id : nil
        )
        guard !isExiting,
              durableConfiguredTargetMatches,
              pendingSwapTargetAccountId == to.id,
              accountManager.configuredAccount?.id == prepared.expectedConfiguredAccountId,
              AccountCredentialMutationPolicy.stillAllows(
                  route: route,
                  from: from,
                  to: to,
                  reason: reason,
                  accounts: accountManager.accounts,
                  configuredAccount: accountManager.configuredAccount,
                  now: now
              ),
              permit.authorizes(
                  state: accountManager.activationState,
                  at: now
              ) else {
            return nil
        }
        if route == .swap, reason == .manual {
            SwapLog.append(.debug(
                "ACTIVATION_MANUAL_SWAP_DURABLE_SOURCE_AUTHORIZED source=\(from.email) target=\(to.email)"
            ))
        }
        return permit
    }

    private func activationEffectPermit(
        _ prepared: PreparedAccountActivation,
        targetAccountId: UUID,
        requiredPhase: AccountActivationPhase,
        configuredAccountId: UUID?,
        runtimePermit: AccountActivationRuntimePermit? = nil
    ) async -> AccountActivationEffectPermit? {
        let proof = AccountActivationOperationProof(
            state: accountManager.activationState,
            targetAccountId: targetAccountId,
            activationGeneration: prepared.activationGeneration,
            requiredPhase: requiredPhase,
            expectedSwapGeneration: prepared.swapGeneration,
            currentSwapGeneration: swapGeneration,
            pendingTargetAccountId: pendingSwapTargetAccountId,
            configuredAccountId: accountManager.configuredAccount?.id,
            expectedConfiguredAccountId: configuredAccountId,
            leaseOwned: await accountMutationTransaction.owns(prepared.lease),
            isExiting: isExiting
        )
        guard proof.authorizesEffect else { return nil }
        return accountMutationTransaction.makeEffectPermit(
            lease: prepared.lease,
            targetAccountId: targetAccountId,
            activationGeneration: prepared.activationGeneration,
            requiredPhase: requiredPhase,
            runtimePermit: runtimePermit,
            journal: accountActivationCoordinator
        )
    }

    @discardableResult
    private func commitConfiguredCredentialMutation(
        from: CodexAccount,
        to: CodexAccount,
        reason: SwapEvent.SwapReason,
        mutationRoute: AccountCredentialMutationRoute,
        persistenceContext: String,
        authAlreadyConfigured: Bool,
        swapStart: Date,
        prepared: PreparedAccountActivation,
        recordsSwap: Bool,
        committedDetail: AccountActivationDetail = .runtimeConfirmationPending
    ) async -> Bool {
        let result = await accountMutationTransaction.commitConfiguredCredentials(
            AccountActivationCommitOperations(
                authorizeMutation: { [weak self] in
                    guard let self else { return nil }
                    return await self.revalidateCredentialMutation(
                        route: mutationRoute,
                        from: from,
                        to: to,
                        reason: reason,
                        authAlreadyConfigured: authAlreadyConfigured,
                        prepared: prepared
                    )
                },
                mutateCredentials: { [weak self] permit in
                    guard let self,
                          permit.authorizes(
                              state: self.accountManager.activationState,
                              at: Date()
                          ),
                          self.accountManager.applyConfiguredCredentialMutation(
                              to,
                              permit: permit
                          ) else {
                        return false
                    }
                    CLIStatusChecker.invalidateForAccountSwap()
                    self.accountManager.setConfiguredAccount(to.id)
                    return true
                },
                authorizePreparingEffect: { [weak self] in
                    guard let self else { return nil }
                    return await self.activationEffectPermit(
                        prepared,
                        targetAccountId: to.id,
                        requiredPhase: .preparing,
                        configuredAccountId: to.id
                    )
                },
                persistAccountStore: { [weak self] permit in
                    await self?.persistAuthorizedAccountsSnapshot(
                        context: persistenceContext,
                        permit: permit
                    ) == true
                },
                persistAuth: { [weak self] permit in
                    guard let self else { return false }
                    if authAlreadyConfigured {
                        let matches = permit.isCurrentlyAuthorized()
                            && Self.authFileMatches(
                            account: to,
                            atPath: Self.codexAuthPath
                        )
                        if !matches {
                            self.surfaceActiveAuthCommitFailure(
                                account: to,
                                reason: persistenceContext,
                                detail: "externally configured auth.json changed before verification"
                            )
                        }
                        return matches
                    }
                    return await self.commitActiveAuthFile(
                        for: to,
                        reason: persistenceContext,
                        permit: permit
                    )
                },
                verifyDurableFiles: { [weak self] permit in
                    guard let self, permit.isCurrentlyAuthorized() else { return false }
                    let matches = await self.durableConfiguredFilesMatch(to)
                    return matches && permit.isCurrentlyAuthorized()
                },
                markCommittedDegraded: { [weak self] permit in
                    guard let self else { return false }
                    do {
                        let degraded = try await self.accountActivationCoordinator
                            .markCommittedDegraded(
                                targetAccountId: to.id,
                                expectedActivationGeneration: prepared.activationGeneration,
                                discoveredRuntimeCount: 0,
                                acknowledgedRuntimeCount: 0,
                                detail: committedDetail,
                                authorizeEffect: { state in
                                    permit.authorizes(state: state, at: Date())
                                }
                            )
                        guard degraded.phase == .committedDegraded,
                              degraded.configuredAccountId == to.id,
                              degraded.activationGeneration == prepared.activationGeneration,
                              await self.accountMutationTransaction.owns(prepared.lease),
                              prepared.swapGeneration == self.swapGeneration,
                              self.pendingSwapTargetAccountId == to.id,
                              self.accountManager.configuredAccount?.id == to.id else {
                            return false
                        }
                        self.accountManager.publishActivationState(degraded)
                        return true
                    } catch {
                        return false
                    }
                },
                authorizeConvergence: { [weak self] in
                    guard let self else { return nil }
                    return await self.activationEffectPermit(
                        prepared,
                        targetAccountId: to.id,
                        requiredPhase: .committedDegraded,
                        configuredAccountId: to.id
                    )
                },
                convergeRuntime: { [weak self] permit in
                    guard let self, permit.isCurrentlyAuthorized() else { return false }
                    await self.beginRuntimeConvergence(
                        from: from,
                        to: to,
                        reason: reason,
                        swapStart: swapStart,
                        prepared: prepared,
                        recordsSwap: recordsSwap
                    )
                    return true
                }
            )
        )
        guard case .committed = result else {
            let stage: AccountActivationCommitFailureStage
            if case .failed(let failedStage) = result {
                stage = failedStage
            } else {
                stage = .mutationAuthorization
            }
            await failConfiguredCredentialMutation(
                target: to,
                prepared: prepared,
                stage: stage,
                detail: stage == .journalPersistence
                    ? .committedJournalUpdateFailed
                    : .fileCommitFailed,
                failure: "activation transaction stopped at \(String(describing: stage))"
            )
            return false
        }
        return true
    }

    private func failConfiguredCredentialMutation(
        target: CodexAccount,
        prepared: PreparedAccountActivation,
        stage: AccountActivationCommitFailureStage,
        detail: AccountActivationDetail,
        failure: String
    ) async {
        if stage == .mutationAuthorization,
           await restoreUncommittedPreparation(
               target: target,
               prepared: prepared
           ) {
            if prepared.swapGeneration == swapGeneration,
               pendingSwapTargetAccountId == target.id {
                pendingSwapTargetAccountId = nil
                swapConvergenceTask = nil
            }
            clearManualOverride()
            SwapLog.append(.debug(
                "ACTIVATION_UNCOMMITTED_PREPARATION_RESTORED generation=\(prepared.swapGeneration) target=\(target.email)"
            ))
            SwapLog.append(.swapFailed(error: failure))
            logger.error("Configured credential mutation failed before file mutation: \(failure)")
            return
        }

        if prepared.swapGeneration == swapGeneration,
           pendingSwapTargetAccountId == target.id {
            pendingSwapTargetAccountId = nil
            swapConvergenceTask = nil
        }
        if await accountMutationTransaction.owns(prepared.lease),
           accountManager.activationState?.activationGeneration == prepared.activationGeneration,
           accountManager.activationState?.configuredAccountId == target.id {
            await enterActivationManualReview(
                targetAccountId: target.id,
                detail: detail
            )
        }
        SwapLog.append(.debug(
            "ACTIVATION_COMMIT_BLOCKED generation=\(prepared.swapGeneration) target=\(target.email) detail=\(detail.rawValue)"
        ))
        SwapLog.append(.swapFailed(error: failure))
        logger.error("Configured credential mutation failed: \(failure)")
    }

    private func restoreUncommittedPreparation(
        target: CodexAccount,
        prepared: PreparedAccountActivation
    ) async -> Bool {
        guard let previousState = prepared.previousActivationState,
              let previousTargetAccountId = previousState.configuredAccountId,
              let previousTarget = accountManager.accounts.first(where: {
                  $0.id == previousTargetAccountId
              }),
              accountManager.configuredAccount?.id == prepared.expectedConfiguredAccountId,
              await durableConfiguredFilesMatch(previousTarget),
              await accountMutationTransaction.owns(prepared.lease) else {
            return false
        }

        do {
            let restored = try await accountActivationCoordinator
                .restoreUncommittedPreparation(
                    targetAccountId: target.id,
                    expectedActivationGeneration: prepared.activationGeneration,
                    previousState: previousState,
                    authorizeEffect: { [accountMutationTransaction] state in
                        accountMutationTransaction.ownerAuthorizes(
                            prepared.lease,
                            state: state,
                            targetAccountId: target.id,
                            activationGeneration: prepared.activationGeneration,
                            allowedPhases: [.preparing]
                        )
                    }
                )
            accountManager.publishActivationState(restored)
            let leaseOwned = await accountMutationTransaction.owns(prepared.lease)
            let durableSourceMatches = await durableConfiguredFilesMatch(previousTarget)
            let restorationIsCurrent = leaseOwned
                && prepared.swapGeneration == swapGeneration
                && pendingSwapTargetAccountId == target.id
                && accountManager.configuredAccount?.id == previousTarget.id
                && durableSourceMatches
            if !restorationIsCurrent {
                await enterActivationManualReview(
                    targetAccountId: previousTarget.id,
                    detail: .durableConfigurationChanged
                )
            }
            statusBarController.updateIcon()
            updatePopoverContent()
            return true
        } catch {
            SwapLog.append(.debug(
                "ACTIVATION_UNCOMMITTED_PREPARATION_RESTORE_FAILED generation=\(prepared.swapGeneration) target=\(target.email) error=\(error.localizedDescription)"
            ))
            return false
        }
    }

    private func beginRuntimeConvergence(
        from: CodexAccount,
        to: CodexAccount,
        reason: SwapEvent.SwapReason,
        swapStart: Date,
        prepared: PreparedAccountActivation,
        recordsSwap: Bool
    ) async {
        startPollingForAccount(to.id)
        statusBarController.updateIcon()
        updatePopoverContent()
        CLIStatusChecker.refresh(activeAccountId: to.accountId) { [weak self] in
            self?.updatePopoverContent()
        }

        let convergenceTask = Task.detached(priority: .userInitiated) { [weak self] in
            let shouldStartReload = await self?.activationWorkIsCurrent(
                prepared,
                targetAccountId: to.id
            ) == true
            guard !Task.isCancelled, shouldStartReload else {
                SwapLog.append(.debug(
                    "SWAP_RELOAD_DISCARDED generation=\(prepared.swapGeneration) target=\(to.email) reason=stale_before_reload"
                ))
                await self?.abandonSwapRuntimeConvergence(
                    prepared: prepared,
                    targetAccountId: to.id
                )
                return
            }

            SwapLog.append(.desktopExternalReloadAttempt)
            guard let reloadResult = await self?.accountActivationReloadTransaction.converge(
                account: to,
                authorizeAfterDesktop: { [weak self] in
                    await self?.activationWorkIsCurrent(
                        prepared,
                        targetAccountId: to.id
                    ) == true
                }
            ) else {
                return
            }
            let desktopReload: DesktopReloadResult
            let completion: AccountActivationRuntimeCompletion
            switch reloadResult {
            case .cancelledAfterDesktop:
                SwapLog.append(.debug(
                    "SWAP_RELOAD_DISCARDED generation=\(prepared.swapGeneration) target=\(to.email) reason=stale_before_cli_reload"
                ))
                await self?.abandonSwapRuntimeConvergence(
                    prepared: prepared,
                    targetAccountId: to.id
                )
                return
            case .completed(let completedDesktopReload, let completed):
                desktopReload = completedDesktopReload
                completion = completed
            }

            switch desktopReload {
            case .reloaded(let method, _, _):
                if method == DesktopRuntimeReloadClient.existingAcknowledgementMethod {
                    SwapLog.append(.debug(
                        "DESKTOP_EXTERNAL_RELOAD_REUSED_ACK target=\(to.email)"
                    ))
                } else {
                    SwapLog.append(.desktopExternalReloadSuccess(method: "json-rpc:\(method)"))
                }
            case .noDesktopRuntime:
                SwapLog.append(.debug(
                    "DESKTOP_JSON_RPC_DIAGNOSTIC result=runtime_unavailable"
                ))
            case .unsupported:
                SwapLog.append(.debug(
                    "DESKTOP_JSON_RPC_DIAGNOSTIC result=unsupported"
                ))
            case .failed(let failure, _, _):
                SwapLog.append(.debug(
                    "DESKTOP_JSON_RPC_DIAGNOSTIC result=failed reason=\(failure)"
                ))
            }

            await self?.finishSwapRuntimeConvergence(
                from: from,
                to: to,
                reason: reason,
                swapStart: swapStart,
                prepared: prepared,
                completion: completion,
                recordsSwap: recordsSwap
            )
        }
        swapConvergenceTask = convergenceTask
        await convergenceTask.value
    }

    private func activationWorkIsCurrent(
        _ prepared: PreparedAccountActivation,
        targetAccountId: UUID
    ) async -> Bool {
        AccountActivationOperationProof(
            state: accountManager.activationState,
            targetAccountId: targetAccountId,
            activationGeneration: prepared.activationGeneration,
            requiredPhase: .committedDegraded,
            expectedSwapGeneration: prepared.swapGeneration,
            currentSwapGeneration: swapGeneration,
            pendingTargetAccountId: pendingSwapTargetAccountId,
            configuredAccountId: accountManager.configuredAccount?.id,
            expectedConfiguredAccountId: targetAccountId,
            leaseOwned: await accountMutationTransaction.owns(prepared.lease),
            isExiting: isExiting
        ).authorizesEffect
    }

    private func retryActivationConvergenceIfDue(at date: Date) {
        guard !isExiting,
              let targetAccountId = accountManager.activationState?.automaticRetryTarget(at: date),
              let target = accountManager.accounts.first(where: { $0.id == targetAccountId }),
              accountManager.configuredAccount?.id == targetAccountId else {
            return
        }
        beginSameTargetRuntimeRetry(to: target, source: "automatic")
    }

    private func recoverManualReviewActivationOnLaunch() async {
        guard let targetAccountId = Self.manualReviewLaunchRecoveryTarget(
            state: accountManager.activationState,
            configuredAccountId: accountManager.configuredAccount?.id
        ), let target = accountManager.accounts.first(where: { $0.id == targetAccountId }) else {
            return
        }
        await startSameTargetRuntimeRetry(to: target, source: "launch_recovery")
    }

    private func scheduleRetryExhaustedTopologyRecoveryIfNeeded(
        at date: Date = Date()
    ) {
        guard !isExiting,
              retryExhaustedTopologyCheckTask == nil,
              pendingSwapTargetAccountId == nil,
              swapConvergenceTask == nil,
              accountManager.activationState?.phase == .manualReview,
              accountManager.activationState?.detail == .automaticRetryLimitReached,
              lastRetryExhaustedTopologyCheckAt.map({
                  date.timeIntervalSince($0) >= Self.retryExhaustedTopologyCheckInterval
              }) ?? true else {
            return
        }
        lastRetryExhaustedTopologyCheckAt = date
        retryExhaustedTopologyCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.retryExhaustedTopologyCheckTask = nil }
            let topology = await Task.detached(priority: .utility) {
                SwapEngine.localCLIRuntimeTopology()
            }.value
            guard !Task.isCancelled,
                  !self.isExiting,
                  self.pendingSwapTargetAccountId == nil,
                  self.swapConvergenceTask == nil,
                  let topology,
                  let targetAccountId = Self.retryExhaustedTopologyRecoveryTarget(
                      state: self.accountManager.activationState,
                      configuredAccountId: self.accountManager.configuredAccount?.id,
                      topologyIsFullyManaged: topology.allRuntimesUseManagedRoute,
                      topologyChanged:
                          topology != self.lastAttemptedRetryExhaustedTopology
                  ),
                  let target = self.accountManager.accounts.first(where: {
                      $0.id == targetAccountId
                  }) else {
                return
            }
            self.lastAttemptedRetryExhaustedTopology = topology
            SwapLog.append(.debug(
                "ACTIVATION_TOPOLOGY_RECOVERY_STARTED target=\(target.email) runtimes=\(topology.runtimes.count)"
            ))
            await self.startSameTargetRuntimeRetry(
                to: target,
                source: "runtime_topology_recovery"
            )
        }
    }

    nonisolated static func manualReviewLaunchRecoveryTarget(
        state: AccountActivationState?,
        configuredAccountId: UUID?
    ) -> UUID? {
        guard let state,
              state.phase == .manualReview,
              state.detail?.allowsLaunchSameTargetRecovery == true,
              let targetAccountId = state.configuredAccountId,
              targetAccountId == configuredAccountId else {
            return nil
        }
        return targetAccountId
    }

    nonisolated static func verifiedExternalAuthRecoveryTarget(
        state: AccountActivationState?,
        configuredAccountId: UUID?,
        observedTargetAccountId: UUID
    ) -> UUID? {
        guard let state,
              state.phase == .manualReview,
              state.detail?.allowsVerifiedExternalAuthRecovery == true,
              state.configuredAccountId == observedTargetAccountId,
              configuredAccountId == observedTargetAccountId else {
            return nil
        }
        return observedTargetAccountId
    }

    nonisolated static func retryExhaustedTopologyRecoveryTarget(
        state: AccountActivationState?,
        configuredAccountId: UUID?,
        topologyIsFullyManaged: Bool,
        topologyChanged: Bool
    ) -> UUID? {
        guard topologyIsFullyManaged,
              topologyChanged,
              let state,
              state.phase == .manualReview,
              state.detail == .automaticRetryLimitReached,
              let targetAccountId = state.configuredAccountId,
              targetAccountId == configuredAccountId else {
            return nil
        }
        return targetAccountId
    }

    private func beginSameTargetRuntimeRetry(to target: CodexAccount, source: String) {
        guard !isExiting else { return }
        Task { @MainActor [weak self] in
            await self?.startSameTargetRuntimeRetry(to: target, source: source)
        }
    }

    private func startSameTargetRuntimeRetry(to target: CodexAccount, source: String) async {
        guard !isExiting,
              swapConvergenceTask == nil,
              pendingSwapTargetAccountId == nil,
              accountManager.configuredAccount?.id == target.id,
              accountManager.activationState?.configuredAccountId == target.id else {
            return
        }

        let resetsRetryBudget = source == "manual"
            || source == "launch_recovery"
            || source == "runtime_topology_recovery"
        let recoversExternalAuthBarrier = source == "external_auth_recovered"
        let startsFreshGeneration = resetsRetryBudget || recoversExternalAuthBarrier
        let activationGeneration = startsFreshGeneration
            ? UUID()
            : accountManager.activationState?.activationGeneration ?? UUID()
        let scoped = await accountMutationTransaction.withActivationLease(
            targetAccountId: target.id,
            activationGeneration: activationGeneration
        ) { [weak self] lease in
            guard let self, !self.isExiting else { return false }
            do {
                if startsFreshGeneration {
                    if recoversExternalAuthBarrier {
                        guard await self.durableConfiguredFilesMatch(target) else {
                            self.accountManager.publishActivationNotice(
                                "Stored account and auth file still disagree; activation remains paused"
                            )
                            return false
                        }
                    }
                    if self.accountManager.activationState?.phase == .manualReview,
                       self.accountManager.activationState?.detail
                        == .durableConfigurationChanged {
                        guard await self.durableConfiguredFilesMatch(target) else {
                            self.accountManager.publishActivationNotice(
                                "Stored account and auth file still disagree; activation remains paused"
                            )
                            return false
                        }
                    }
                    let reset: AccountActivationState
                    if recoversExternalAuthBarrier {
                        reset = try await self.accountActivationCoordinator
                            .recoverVerifiedExternalAuth(
                                targetAccountId: target.id,
                                newActivationGeneration: activationGeneration,
                                authorizeEffect: { [accountMutationTransaction] state in
                                    accountMutationTransaction.leaseAuthorizes(
                                        lease,
                                        targetAccountId: target.id,
                                        activationGeneration: activationGeneration
                                    )
                                        && state?.configuredAccountId == target.id
                                        && state?.phase == .manualReview
                                        && state?.detail?
                                            .allowsVerifiedExternalAuthRecovery == true
                                }
                            )
                    } else {
                        reset = try await self.accountActivationCoordinator
                            .resetForManualSameTargetRetry(
                                targetAccountId: target.id,
                                newActivationGeneration: activationGeneration,
                                authorizeEffect: { [accountMutationTransaction] state in
                                    accountMutationTransaction.leaseAuthorizes(
                                        lease,
                                        targetAccountId: target.id,
                                        activationGeneration: activationGeneration
                                    )
                                        && state?.configuredAccountId == target.id
                                        && state.map {
                                            $0.phase == .committedDegraded
                                                || $0.phase == .manualReview
                                        } == true
                                }
                            )
                    }
                    guard reset.phase == .committedDegraded,
                          reset.configuredAccountId == target.id,
                          reset.activationGeneration == activationGeneration,
                          await self.accountMutationTransaction.owns(lease) else {
                        return false
                    }
                    self.accountManager.publishActivationState(reset)
                } else {
                    guard self.accountManager.activationState?.phase == .committedDegraded,
                          self.accountManager.activationState?.activationGeneration
                            == activationGeneration else {
                        return false
                    }
                }
            } catch {
                if await self.accountMutationTransaction.owns(lease) {
                    await self.enterActivationManualReview(
                        targetAccountId: target.id,
                        detail: .runtimeEvidencePersistFailed
                    )
                }
                return false
            }

            guard await self.durableConfiguredFilesMatch(target),
                  !self.isExiting,
                  await self.accountMutationTransaction.owns(lease),
                  self.accountManager.activationState?.phase == .committedDegraded,
                  self.accountManager.activationState?.configuredAccountId == target.id,
                  self.accountManager.activationState?.activationGeneration
                    == activationGeneration,
                  self.accountManager.configuredAccount?.id == target.id else {
                if await self.accountMutationTransaction.owns(lease) {
                    await self.enterActivationManualReview(
                        targetAccountId: target.id,
                        detail: .configuredFilesInconsistent
                    )
                }
                return false
            }

            self.swapGeneration &+= 1
            let generation = self.swapGeneration
            self.pendingSwapTargetAccountId = target.id
            let prepared = PreparedAccountActivation(
                swapGeneration: generation,
                activationGeneration: activationGeneration,
                expectedConfiguredAccountId: target.id,
                previousActivationState: nil,
                lease: lease
            )
            self.accountManager.publishActivationNotice(nil)
            SwapLog.append(.debug(
                "ACTIVATION_RETRY_STARTED target=\(target.email) source=\(source) generation=\(generation)"
            ))
            await self.beginRuntimeConvergence(
                from: target,
                to: target,
                reason: .manual,
                swapStart: Date(),
                prepared: prepared,
                recordsSwap: false
            )
            return true
        }
        guard scoped != nil else {
            accountManager.publishActivationNotice("Another account mutation is already in progress")
            return
        }
    }

    private func abandonSwapRuntimeConvergence(
        prepared: PreparedAccountActivation,
        targetAccountId: UUID
    ) async {
        guard prepared.swapGeneration == swapGeneration,
              pendingSwapTargetAccountId == targetAccountId else {
            return
        }
        pendingSwapTargetAccountId = nil
        swapConvergenceTask = nil
    }

    private func finishSwapRuntimeConvergence(
        from: CodexAccount,
        to: CodexAccount,
        reason: SwapEvent.SwapReason,
        swapStart: Date,
        prepared: PreparedAccountActivation,
        completion: AccountActivationRuntimeCompletion,
        recordsSwap: Bool
    ) async {
        guard !isExiting else {
            await abandonSwapRuntimeConvergence(
                prepared: prepared,
                targetAccountId: to.id
            )
            return
        }
        guard await activationWorkIsCurrent(prepared, targetAccountId: to.id) else {
            SwapLog.append(.debug(
                "SWAP_COMPLETION_DISCARDED generation=\(prepared.swapGeneration) target=\(to.email) current_generation=\(swapGeneration) current_target=\(pendingSwapTargetAccountId?.uuidString ?? "none")"
            ))
            await abandonSwapRuntimeConvergence(
                prepared: prepared,
                targetAccountId: to.id
            )
            return
        }

        var freshRuntimePermit: AccountActivationRuntimePermit?
        if completion.outcome == .runtimeCurrent {
            freshRuntimePermit = await requireFreshLocalRuntimePermit(
                for: to,
                activationGeneration: prepared.activationGeneration,
                requiredPhase: .committedDegraded
            )
            guard freshRuntimePermit != nil,
                  await activationWorkIsCurrent(prepared, targetAccountId: to.id) else {
                if let degraded = accountManager.activationState,
                   degraded.phase == .committedDegraded,
                   degraded.configuredAccountId == to.id {
                    do {
                        guard let failurePermit = await activationEffectPermit(
                            prepared,
                            targetAccountId: to.id,
                            requiredPhase: .committedDegraded,
                            configuredAccountId: to.id
                        ) else {
                            throw AccountActivationCoordinatorError.invalidTransition(
                                "activation owner changed before failure persistence"
                            )
                        }
                        let failed = try await accountActivationCoordinator
                            .recordConvergenceFailure(
                                targetAccountId: to.id,
                                discoveredRuntimeCount: degraded.discoveredRuntimeCount,
                                acknowledgedRuntimeCount: degraded.acknowledgedRuntimeCount,
                                detail: degraded.detail ?? .runtimeAcknowledgementIncomplete,
                                authorizeEffect: { state in
                                    failurePermit.authorizes(state: state, at: Date())
                                }
                            )
                        accountManager.publishActivationState(failed)
                    } catch {
                        await enterActivationManualReview(
                            targetAccountId: to.id,
                            detail: .runtimeEvidencePersistFailed
                        )
                    }
                }
                pendingSwapTargetAccountId = nil
                swapConvergenceTask = nil
                SwapLog.append(.debug(
                    "SWAP_CONFIRMATION_BLOCKED target=\(to.email) reason=fresh_runtime_or_generation_evidence_missing"
                ))
                return
            }
        }

        do {
            let state: AccountActivationState
            switch completion.outcome {
            case .runtimeCurrent:
                guard let freshRuntimePermit else {
                    throw AccountActivationCoordinatorError.invalidTransition(
                        "fresh runtime evidence disappeared before confirmation"
                    )
                }
                let freshEvidence = freshRuntimePermit.evidence
                let confirmationNow = Date()
                let confirmationResult = await accountActivationConfirmationTransaction.confirm(
                    AccountActivationConfirmationOperations(
                        verifyDurableFiles: { [weak self] in
                            await self?.durableConfiguredFilesMatch(to) == true
                        },
                        authorizeConfirmation: { [weak self] in
                            guard let self else { return nil }
                            return await self.activationEffectPermit(
                                prepared,
                                targetAccountId: to.id,
                                requiredPhase: .committedDegraded,
                                configuredAccountId: to.id,
                                runtimePermit: freshRuntimePermit
                            )
                        },
                        reauthorizeConfirmation: { [weak self] confirmationPermit in
                            guard let self,
                                  confirmationPermit.isCurrentlyAuthorized(),
                                  let revalidatedEvidence = await self
                                    .revalidatedRuntimeEvidence(freshEvidence, for: to) else {
                                return nil
                            }
                            let revalidatedRuntimePermit = AccountActivationRuntimePermit(
                                targetAccountId: to.id,
                                activationGeneration: prepared.activationGeneration,
                                requiredPhase: .committedDegraded,
                                evidence: revalidatedEvidence
                            )
                            return await self.activationEffectPermit(
                                prepared,
                                targetAccountId: to.id,
                                requiredPhase: .committedDegraded,
                                configuredAccountId: to.id,
                                runtimePermit: revalidatedRuntimePermit
                            )
                        },
                        persistConfirmation: { [weak self] confirmationPermit in
                            guard let self,
                                  let revalidatedEvidence = confirmationPermit.runtimePermit?.evidence,
                                  revalidatedEvidence.hasConcreteRuntimeBindings else {
                                return nil
                            }
                            return try? await self.accountActivationCoordinator.markConfirmed(
                                targetAccountId: to.id,
                                expectedActivationGeneration: prepared.activationGeneration,
                                discoveredRuntimeCount: revalidatedEvidence.discoveredRuntimeCount,
                                acknowledgedRuntimeCount: revalidatedEvidence.acknowledgedRuntimeCount,
                                evidenceGeneration: revalidatedEvidence.generation,
                                evidenceObservedAt: revalidatedEvidence.observedAt,
                                evidenceExpiresAt: revalidatedEvidence.expiresAt,
                                authorizeEffect: { state in
                                    guard confirmationPermit.authorizes(
                                        state: state,
                                        at: Date()
                                    ), revalidatedEvidence.runtimeBindings.allSatisfy({
                                        SwapEngine.reloadBindingIsCurrent($0)
                                    }) else {
                                        return false
                                    }
                                    return revalidatedEvidence
                                        .matchesRediscoveredRuntimeTopology(
                                            cli: SwapEngine.localRuntimeEvidenceSnapshot(
                                                runtimeKind: .localInteractiveCLI
                                            ),
                                            desktop: SwapEngine.localRuntimeEvidenceSnapshot(
                                                runtimeKind: .externalAppServer
                                            )
                                        )
                                }
                            )
                        }
                    )
                )
                let confirmed: AccountActivationState
                switch confirmationResult {
                case .confirmed(let state):
                    confirmed = state
                case .blocked(.durableReadback):
                    await enterActivationManualReview(
                        targetAccountId: to.id,
                        detail: .durableConfigurationChanged
                    )
                    pendingSwapTargetAccountId = nil
                    swapConvergenceTask = nil
                    return
                case .blocked(.authorization):
                    if freshEvidence.expiresAt <= confirmationNow {
                        do {
                            let degraded = try await accountActivationCoordinator
                                .demoteForRuntimeEvidenceLoss(
                                    targetAccountId: to.id,
                                    expectedActivationGeneration: prepared.activationGeneration,
                                    detail: .runtimeEvidenceExpired,
                                    discoveredRuntimeCount: freshEvidence.discoveredRuntimeCount,
                                    acknowledgedRuntimeCount: freshEvidence.acknowledgedRuntimeCount
                                )
                            accountManager.publishActivationState(degraded)
                        } catch {
                            await enterActivationManualReview(
                                targetAccountId: to.id,
                                detail: .runtimeEvidencePersistFailed
                            )
                        }
                    }
                    pendingSwapTargetAccountId = nil
                    swapConvergenceTask = nil
                    return
                case .blocked(.runtimeRevalidation):
                    pendingSwapTargetAccountId = nil
                    swapConvergenceTask = nil
                    SwapLog.append(.debug(
                        "SWAP_CONFIRMATION_BLOCKED target=\(to.email) reason=runtime_topology_changed_before_publish"
                    ))
                    return
                case .blocked(.journalPersistence):
                    throw AccountActivationCoordinatorError.invalidTransition(
                        "confirmation journal persistence lost authorization"
                    )
                }
                guard confirmed.phase == .confirmed,
                      confirmed.configuredAccountId == to.id,
                      confirmed.activationGeneration == prepared.activationGeneration,
                      await accountMutationTransaction.owns(prepared.lease),
                      prepared.swapGeneration == swapGeneration,
                      pendingSwapTargetAccountId == to.id,
                      accountManager.configuredAccount?.id == to.id else {
                    SwapLog.append(.debug(
                        "SWAP_CONFIRMATION_DISCARDED generation=\(prepared.swapGeneration) target=\(to.email) reason=changed_during_journal_commit"
                    ))
                    await abandonSwapRuntimeConvergence(
                        prepared: prepared,
                        targetAccountId: to.id
                    )
                    return
                }
                state = confirmed
            case .configuredOnly:
                guard let failurePermit = await activationEffectPermit(
                    prepared,
                    targetAccountId: to.id,
                    requiredPhase: .committedDegraded,
                    configuredAccountId: to.id
                ) else {
                    throw AccountActivationCoordinatorError.invalidTransition(
                        "activation owner changed before configured-only persistence"
                    )
                }
                state = try await accountActivationCoordinator.recordConvergenceFailure(
                    targetAccountId: to.id,
                    discoveredRuntimeCount: completion.discoveredRuntimeCount,
                    acknowledgedRuntimeCount: completion.acknowledgedRuntimeCount,
                    detail: .noLocalRuntime,
                    authorizeEffect: { current in
                        failurePermit.authorizes(state: current, at: Date())
                    }
                )
            case .restartRequired:
                guard let failurePermit = await activationEffectPermit(
                    prepared,
                    targetAccountId: to.id,
                    requiredPhase: .committedDegraded,
                    configuredAccountId: to.id
                ) else {
                    throw AccountActivationCoordinatorError.invalidTransition(
                        "activation owner changed before degraded persistence"
                    )
                }
                state = try await accountActivationCoordinator.recordConvergenceFailure(
                    targetAccountId: to.id,
                    discoveredRuntimeCount: completion.discoveredRuntimeCount,
                    acknowledgedRuntimeCount: completion.acknowledgedRuntimeCount,
                    detail: .runtimeAcknowledgementIncomplete,
                    authorizeEffect: { current in
                        failurePermit.authorizes(state: current, at: Date())
                    }
                )
            }
            accountManager.publishActivationState(state)
        } catch {
            pendingSwapTargetAccountId = nil
            swapConvergenceTask = nil
            await enterActivationManualReview(
                targetAccountId: to.id,
                detail: .runtimeEvidencePersistFailed
            )
            SwapLog.append(.debug(
                "SWAP_COMPLETION_PERSIST_FAILED target=\(to.email) error=\(error.localizedDescription)"
            ))
            return
        }

        pendingSwapTargetAccountId = nil
        swapConvergenceTask = nil

        if case .runtimeCurrent = completion.outcome {
            await releaseManualRateLimitResetSwapSuppressionIfNeeded(for: to)
        }

        switch completion.outcome {
        case .runtimeCurrent where recordsSwap:
            let event = SwapEvent(
                fromAccountId: from.id,
                toAccountId: to.id,
                reason: reason,
                timestamp: Date()
            )
            accountManager.recordSwap(event)

            let durationMs = Int(Date().timeIntervalSince(swapStart) * 1000)
            SwapLog.append(.swapCompleted(to: to.email, durationMs: durationMs))
            NotificationManager.notifySwap(from: from, to: to)
        case .runtimeCurrent:
            SwapLog.append(.debug(
                "ACTIVATION_RETRY_CONFIRMED target=\(to.email) generation=\(prepared.swapGeneration)"
            ))
        case .configuredOnly:
            SwapLog.append(.debug(
                "SWAP_CONFIGURED_ONLY target=\(to.email) generation=\(prepared.swapGeneration) runtime_current=false reason=no_local_runtime"
            ))
        case .restartRequired:
            let detail = completion.detail ?? "runtime convergence incomplete"
            SwapLog.append(.debug(
                "SWAP_DIVERGED target=\(to.email) generation=\(prepared.swapGeneration) restart_required=true discovered=\(completion.discoveredRuntimeCount) acknowledged=\(completion.acknowledgedRuntimeCount) detail=\(detail)"
            ))
            SwapLog.append(.swapFailed(error: "runtime convergence incomplete; restart required"))
            logger.warning("Swap configured but runtime convergence failed (\(String(describing: reason))): \(detail)")
        }

        statusBarController.updateIcon()
        updatePopoverContent()
        CLIStatusChecker.refresh(activeAccountId: to.accountId) { [weak self] in
            self?.updatePopoverContent()
        }
    }

    private func forceSwap(to accountId: UUID) {
        guard let active = accountManager.configuredAccount,
              let target = accountManager.accounts.first(where: { $0.id == accountId }) else { return }
        executeSwap(from: active, to: target, reason: .manual)
    }

    private func setManualOverride(_ accountId: UUID) {
        manualOverrideAccountId = accountId
        UserDefaults.standard.set(accountId.uuidString, forKey: Self.manualOverrideAccountIdKey)
    }

    private func clearManualOverride() {
        manualOverrideAccountId = nil
        UserDefaults.standard.removeObject(forKey: Self.manualOverrideAccountIdKey)
    }

    private func reauthenticateAccount(_ accountId: UUID) {
        guard !isExiting else { return }
        guard let original = accountManager.accounts.first(where: { $0.id == accountId }) else { return }

        Task { @MainActor [weak self] in
            guard let self, !self.isExiting else { return }
            do {
                let imported = try await self.oauthManager.performLogin()
                guard !self.isExiting else { return }
                let validation = await self.validateReauthenticatedAccount(imported)
                if case .failure(let validationError) = validation {
                        accountManager.markRuntimeUnusable(
                            for: accountId,
                            reason: "token_expired",
                            until: Date().addingTimeInterval(30 * 24 * 60 * 60)
                        )
                        accountManager.updatePollingError(for: accountId, error: "Re-authentication required")
                        _ = await persistAccountsSnapshot(context: "reauth-validation-failed")
                        statusBarController.updateIcon()
                        updatePopoverContent()
                        SwapLog.append(.debug("ACCOUNT_REAUTH_VALIDATION_FAILED email=\(original.email) error=\(String(describing: validationError))"))
                        NotificationManager.notifyTokenRefreshFailed(account: original)
                        return
                    }

                    if Self.reauthenticationPreservesStableProviderIdentity(
                        original: original,
                        observed: imported
                    ) {
                        let reauthenticatesActiveAccount = accountManager.configuredAccount?.id == accountId
                        var candidate = original
                        candidate.email = imported.email
                        candidate.accessToken = imported.accessToken
                        candidate.refreshToken = imported.refreshToken
                        candidate.idToken = imported.idToken
                        candidate.accountId = imported.accountId
                        candidate.lastRefreshed = imported.lastRefreshed ?? Date()
                        candidate.runtimeUnusableUntil = nil
                        candidate.runtimeUnusableReason = nil
                        if reauthenticatesActiveAccount {
                            let committed = await withPreparedActiveCredentialMutation(
                                targetAccountId: candidate.id,
                                expectedConfiguredAccountId: original.id,
                                source: "reauthentication",
                                isManual: true
                            ) { [weak self] prepared in
                                guard let self else { return false }
                                return await self.commitConfiguredCredentialMutation(
                                    from: original,
                                    to: candidate,
                                    reason: .manual,
                                    mutationRoute: .activeReauthentication,
                                    persistenceContext: "reauth-account",
                                    authAlreadyConfigured: false,
                                    swapStart: Date(),
                                    prepared: prepared,
                                    recordsSwap: false,
                                    committedDetail: .activeCredentialMutation
                                )
                            }
                            guard committed else { return }
                        } else {
                            if case .rejectedConfiguredAccount = accountManager
                                .upsertInactiveAccount(candidate) {
                                return
                            }
                        }
                        accountManager.clearPollingError(for: accountId)
                        if case .success(let quotaResult?) = validation,
                           let refreshedId = accountManager.accounts.first(where: {
                               $0.id == accountId
                           })?.id {
                            accountManager.updateQuota(
                                for: refreshedId,
                                snapshot: quotaResult.snapshot,
                                planType: quotaResult.planType
                            )
                            await clearExternalRateLimitResetHoldIfQuotaRecovered(
                                for: refreshedId,
                                snapshot: quotaResult.snapshot,
                                at: Date()
                            )
                        }
                        if !reauthenticatesActiveAccount {
                            guard await persistAccountsSnapshot(context: "reauth-account") else {
                                return
                            }
                        } else {
                            queueTelemetryPersistence(context: "reauth-account-validation")
                        }
                        startPollingForAccount(accountId)
                        refreshSubscriptionInfoIfNeeded(force: true)
                        statusBarController.updateIcon()
                        updatePopoverContent()
                        SwapLog.append(.debug("ACCOUNT_REAUTH_SUCCESS email=\(original.email)"))
                    } else {
                        var candidate = imported
                        if case .success(let quotaResult?) = validation {
                            candidate.quotaSnapshot = quotaResult.snapshot
                            candidate.planType = quotaResult.planType
                            candidate.lastRefreshed = quotaResult.snapshot.fetchedAt
                        }
                        if let existing = accountManager.accounts.first(where: {
                            $0.accountId == candidate.accountId
                        }) {
                            var canonical = existing
                            canonical.email = candidate.email
                            canonical.accountId = candidate.accountId
                            canonical.accessToken = candidate.accessToken
                            canonical.refreshToken = candidate.refreshToken
                            canonical.idToken = candidate.idToken
                            canonical.lastRefreshed = candidate.lastRefreshed
                            canonical.quotaSnapshot = candidate.quotaSnapshot ?? existing.quotaSnapshot
                            canonical.planType = candidate.planType ?? existing.planType
                            canonical.runtimeUnusableUntil = nil
                            canonical.runtimeUnusableReason = nil
                            if case .rejectedConfiguredAccount = accountManager
                                .upsertInactiveAccount(canonical) {
                                accountManager.publishActivationNotice(
                                    "Re-authentication identity does not match the configured account"
                                )
                                return
                            }
                            candidate = canonical
                        } else if case .rejectedConfiguredAccount = accountManager
                            .upsertInactiveAccount(candidate) {
                            return
                        }
                        if accountManager.configuredAccount?.id != candidate.id,
                           !(await persistAccountsSnapshot(
                               context: "reauth-added-different-account"
                           )) {
                            return
                        }
                        startPollingForAccount(candidate.id)
                        updatePopoverContent()
                        SwapLog.append(.debug("ACCOUNT_REAUTH_DIFFERENT_ACCOUNT expected=\(original.email) got=\(imported.email)"))
                    }
            } catch {
                accountManager.updatePollingError(for: accountId, error: "Re-authentication failed")
                updatePopoverContent()
                SwapLog.append(.debug("ACCOUNT_REAUTH_FAILED email=\(original.email) error=\(error.localizedDescription)"))
            }
        }
    }

    private func validateReauthenticatedAccount(_ account: CodexAccount) async -> Result<QuotaPoller.FetchResult?, PollerError> {
        do {
            return .success(try await quotaPoller.fetchQuota(for: account))
        } catch let error as PollerError {
            if Self.shouldRejectReauthenticationValidation(error) {
                return .failure(error)
            }
            SwapLog.append(.debug("ACCOUNT_REAUTH_VALIDATION_SOFT_ERROR email=\(account.email) error=\(String(describing: error))"))
            return .success(nil)
        } catch {
            SwapLog.append(.debug("ACCOUNT_REAUTH_VALIDATION_SOFT_ERROR email=\(account.email) error=\(error.localizedDescription)"))
            return .success(nil)
        }
    }

    nonisolated static func shouldRejectReauthenticationValidation(_ error: PollerError) -> Bool {
        switch error {
        case .tokenExpired:
            return true
        case .httpError(let code):
            return code == 401 || code == 403
        case .invalidResponse, .rateLimited, .usageUnavailable, .networkError:
            return false
        }
    }

    // MARK: - Popover

    private func updatePopoverContent(forceRefresh: Bool = false) {
        publishRateLimitResetPresentations()
        guard popoverContentInstalled, popover.contentViewController != nil else {
            popover.contentViewController = NSHostingController(
                rootView: PopoverContentView(
                    manager: accountManager,
                    onAddAccount: { [weak self] in self?.addAccount() },
                    onForceSwap: { [weak self] id in self?.forceSwap(to: id) },
                    onReauthenticate: { [weak self] id in self?.reauthenticateAccount(id) },
                    onRedeemReset: { [weak self] id in
                        self?.redeemRateLimitResetManually(for: id)
                    },
                    resetRedemptionAuthorization: { [weak self] id in
                        self?.rateLimitResetCoordinatorAuthorization(for: id)
                            ?? .blocked("Reset coordinator is unavailable")
                    },
                    onOpenSettings: { [weak self] in self?.openSettings() }
                )
            )
            popoverContentInstalled = true
            return
        }

        guard forceRefresh || popover.isShown else { return }
        accountManager.requestUIRefresh()
    }

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        let eventType = NSApp.currentEvent?.type
        let isRightClick = eventType == .rightMouseUp
        handleStatusBarClicked(isRightClick: isRightClick)
    }

    private func handleStatusBarClicked(isRightClick: Bool) {
        if isRightClick {
            showStatusBarMenu()
            return
        }
        togglePopover()
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            updatePopoverContent(forceRefresh: true)
            showPopover(from: button)
            NSApp.activate()
            CLIStatusChecker.refresh(activeAccountId: accountManager.configuredAccount?.accountId) { [weak self] in
                self?.updatePopoverContent(forceRefresh: true)
            }
        }
    }

    private func showPopover(from button: NSStatusBarButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startPopoverDismissalMonitoring()
        clampPopoverToVisibleScreen(relativeTo: button)
    }

    private func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
        stopPopoverDismissalMonitoring()
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.stopPopoverDismissalMonitoring()
        }
    }

    private func startPopoverDismissalMonitoring() {
        stopPopoverDismissalMonitoring()

        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        popoverLocalEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            MainActor.assumeIsolated {
                self?.closePopoverIfNeeded(forLocalEvent: event)
            }
            return event
        }
        popoverGlobalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopoverFromOutsideAppClick()
            }
        }
    }

    private func stopPopoverDismissalMonitoring() {
        if let popoverLocalEventMonitor {
            NSEvent.removeMonitor(popoverLocalEventMonitor)
            self.popoverLocalEventMonitor = nil
        }
        if let popoverGlobalEventMonitor {
            NSEvent.removeMonitor(popoverGlobalEventMonitor)
            self.popoverGlobalEventMonitor = nil
        }
    }

    private func closePopoverFromOutsideAppClick() {
        guard popover.isShown else {
            stopPopoverDismissalMonitoring()
            return
        }
        closePopover()
    }

    private func closePopoverIfNeeded(forLocalEvent event: NSEvent) {
        guard popover.isShown else {
            stopPopoverDismissalMonitoring()
            return
        }
        if let popoverWindow = popover.contentViewController?.view.window,
           event.window === popoverWindow {
            return
        }
        if let statusButtonWindow = statusItem.button?.window,
           event.window === statusButtonWindow {
            return
        }
        closePopover()
    }

    private func clampPopoverToVisibleScreen(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window,
              let popoverWindow = popover.contentViewController?.view.window else {
            return
        }

        let screen = buttonWindow.screen ?? popoverWindow.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let buttonScreenFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var frame = popoverWindow.frame
        let screenPadding: CGFloat = 12
        let minX = visibleFrame.minX + screenPadding
        let maxX = visibleFrame.maxX - screenPadding
        if frame.minX < minX {
            frame.origin.x = minX
        } else if frame.maxX > maxX {
            frame.origin.x = maxX - frame.width
        }

        // NSPopover leaves a small menu-bar gap by default. For a menu-bar
        // utility, make the arrow visually meet the status item instead of
        // floating below it.
        let desiredArrowOverlap: CGFloat = 1
        let verticalGap = buttonScreenFrame.minY - frame.maxY
        if verticalGap > -desiredArrowOverlap {
            frame.origin.y += verticalGap + desiredArrowOverlap
        }

        frame.origin.y = max(frame.origin.y, visibleFrame.minY + screenPadding)
        popoverWindow.setFrame(frame, display: true)
    }

    private func showStatusBarMenu() {
        let menu = NSMenu()

        menu.addItem(menuItem(title: "Restart CodexSwitch", action: #selector(restartApp), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "Quit CodexSwitch", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Clear menu so left-click goes back to popover
        statusItem.menu = nil
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc nonisolated private func restartApp() {
        Task { @MainActor [weak self] in
            self?.restartAppOnMainActor()
        }
    }

    private func restartAppOnMainActor() {
        scheduleRelaunch()
        cleanupBeforeExit()
        NSApp.terminate(nil)
    }

    @objc nonisolated private func quitApp() {
        Task { @MainActor [weak self] in
            self?.quitAppOnMainActor()
        }
    }

    private func quitAppOnMainActor() {
        CodexSwitchKeepAlive.disable()
        cleanupBeforeExit()
        NSApp.terminate(nil)
    }

    private func cleanupBeforeExit() {
        guard !isExiting else { return }
        isExiting = true
        accountMutationTransaction.invalidateCurrentMutationSynchronously()

        popover?.performClose(nil)
        stopPopoverDismissalMonitoring()
        settingsWindow?.close()
        monitorTask?.cancel()
        idleAccountPrimeTask?.cancel()
        idleAccountPrimeTask = nil
        idleAccountPrimePassPending = false
        for task in rateLimitResetRefreshTasks.values {
            task.cancel()
        }
        rateLimitResetRefreshTasks.removeAll()
        rateLimitResetDecisionPending.removeAll()
        Self.requestOwnedMutationTaskCancellation(rateLimitResetRedemptionTask)
        codexAppTerminationTask?.cancel()
        codexAppTerminationTask = nil
        codexAppTerminationTaskIdentifier = nil
        desktopPatchRetryTask?.cancel()
        desktopPatchRetryTask = nil
        linuxDevboxCredentialSyncRetryTask?.cancel()
        linuxDevboxCredentialSyncRetryTask = nil
        Self.requestOwnedMutationTaskCancellation(swapConvergenceTask)
        automaticPolicyGateTask?.cancel()
        automaticPolicyGateTask = nil
        automaticPolicyGateWatchdogTask?.cancel()
        automaticPolicyGateWatchdogTask = nil
        automaticPolicyLeaseState.cancel()
        retryExhaustedTopologyCheckTask?.cancel()
        retryExhaustedTopologyCheckTask = nil
        automaticCodexUpdateTask?.cancel()
        automaticCodexUpdateTask = nil
        globalCLIRepairInFlight = false
        iconUpdateTimer?.invalidate()
        iconUpdateTimer = nil
        configMaintenanceTimer?.invalidate()
        configMaintenanceTimer = nil
        configMaintenanceTask?.cancel()
        configMaintenanceTask = nil
        linuxDevboxMonitorTimer?.invalidate()
        linuxDevboxMonitorTimer = nil
        tokenUsageMetricsTimer?.invalidate()
        tokenUsageMetricsTimer = nil

        if let statusItem {
            statusItem.menu = nil
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        singleInstanceLock.release()
    }

    private func scheduleRelaunch() {
        let appPath = Bundle.main.bundleURL.path
        let script = AppRelaunchPlanner.shellCommand(
            appPath: appPath,
            currentProcessID: ProcessInfo.processInfo.processIdentifier
        )
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
    }

    private func removeAllAccounts() {
        Task { @MainActor [weak self] in
            await self?.removeAllAccountsDurably()
        }
    }

    private func removeAllAccountsDurably() async {
        let emails = accountManager.accounts.map(\.email)
        accountPersistenceRevision &+= 1
        let revision = accountPersistenceRevision
        do {
            try await accountPersistence.deleteAllDurably(revision: revision)
        } catch {
            logger.error("Failed to clear account stores: \(error.localizedDescription)")
            SwapLog.append(.debug(
                "ACCOUNTS_DELETE_ALL_FAILED error=\(error.localizedDescription)"
            ))
            return
        }
        Task {
            await quotaPoller.stopAll()
        }
        accountManager.accounts.removeAll()
        accountManager.swapHistory.removeAll()
        for task in rateLimitResetRefreshTasks.values {
            task.cancel()
        }
        rateLimitResetRefreshTasks.removeAll()
        rateLimitResetDecisionPending.removeAll()
        rateLimitResetRedemptionTask?.cancel()
        rateLimitResetRedemptionTask = nil
        rateLimitResetOperationProviderAccountId = nil
        rateLimitResetSubmissionTracker.clear()
        for email in emails {
            SwapLog.append(.accountRemoved(email: email))
        }
        statusBarController.updateIcon()
        updatePopoverContent()
    }

    private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView(
                accounts: accountManager.accounts,
                onRemoveAllAccounts: { [weak self] in self?.removeAllAccounts() }
            )
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "CodexSwitch Settings"
            window.styleMask = [.titled, .closable]
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func startLinuxDevboxMonitor() {
        linuxDevboxMonitorTimer?.invalidate()
        linuxDevboxMonitorTimer = Timer.scheduledTimer(withTimeInterval: LinuxDevboxMonitor.activeRemoteAccountStatePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkLinuxDevboxReadiness()
            }
        }
        checkLinuxDevboxReadiness(force: true)
    }

    private func startTokenUsageMetricsMonitor() {
        tokenUsageMetricsTimer?.invalidate()
        tokenUsageMetricsTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTokenUsageMetrics()
            }
        }
        refreshTokenUsageMetrics()
    }

    private func refreshTokenUsageMetrics() {
        guard !tokenUsageRefreshInFlight else {
            SwapLog.append(.debug("TOKEN_USAGE_REFRESH_SKIPPED reason=in_flight"))
            return
        }
        let accounts = accountManager.accounts
        guard !accounts.isEmpty else {
            accountManager.tokenSavingsSummary = nil
            updatePopoverContent()
            return
        }
        tokenUsageRefreshInFlight = true
        tokenUsageRefreshSequence += 1
        let refreshSequence = tokenUsageRefreshSequence

        let finish: @MainActor @Sendable (CodexTokenSavingsSummary) -> Void = {
            [weak self] summary in
            self?.finishTokenUsageMetricsRefresh(
                summary,
                refreshSequence: refreshSequence
            )
        }
        Task.detached {
            let localReport = CodexTokenUsageReader.localReport(accounts: accounts, days: 30)
            let settings = LinuxDevboxMonitor.settings()
            let remoteReport: CodexTokenUsageReport?
            if settings.isConfigured {
                if await NetworkBackoffGuard.shared.shouldDeferNonCriticalProbe(operation: "linux_devbox_token_usage") {
                    remoteReport = nil
                } else {
                    switch LinuxDevboxMonitor.fetchUsageReport(settings: settings, days: 30) {
                    case .success(let report):
                        await NetworkBackoffGuard.shared.recordSuccess(operation: "linux_devbox_token_usage")
                        remoteReport = report
                    case .failure(let failure):
                        await NetworkBackoffGuard.shared.recordFailure(failure.message, operation: "linux_devbox_token_usage")
                        SwapLog.append(.debug("TOKEN_USAGE_VPS_REPORT_FAILED message=\(failure.message)"))
                        remoteReport = nil
                    }
                }
            } else {
                remoteReport = nil
            }

            let summary = CodexTokenSavingsSummary(
                subscriptionMonthlyCostUSD: PooledCapacitySummary(accounts: accounts).totalMonthlyCostUSD,
                localReport: localReport,
                remoteReport: remoteReport,
                localTokenHashPrefixes: CodexTelemetryLogParser.tokenHashPrefixes(for: accounts)
            )
            await finish(summary)
        }
    }

    private func finishTokenUsageMetricsRefresh(
        _ summary: CodexTokenSavingsSummary,
        refreshSequence: Int
    ) {
        tokenUsageRefreshInFlight = false
        guard refreshSequence == tokenUsageRefreshSequence else {
            SwapLog.append(.debug("TOKEN_USAGE_REFRESH_STALE ignored_sequence=\(refreshSequence) current_sequence=\(tokenUsageRefreshSequence)"))
            return
        }
        let stabilized = tokenSavingsStore.stabilizedSummary(
            current: accountManager.tokenSavingsSummary,
            candidate: summary
        )
        if stabilized.keptPrevious, let previous = stabilized.previous {
            accountManager.tokenSavingsSummary = stabilized.summary
            SwapLog.append(.debug("TOKEN_USAGE_REFRESH_NON_MONOTONIC_IGNORED previous_api=\(String(format: "%.4f", previous.apiValueUSD)) candidate_api=\(String(format: "%.4f", summary.apiValueUSD)) previous_completions=\(previous.total.completionCount) candidate_completions=\(summary.total.completionCount)"))
            updatePopoverContent()
            return
        }
        accountManager.tokenSavingsSummary = stabilized.summary
        let sources = stabilized.summary.includedReports.map(\.source.rawValue).joined(separator: "+")
        let staleHighWaterReplaced = stabilized.previous != nil
            && stabilized.summary.apiValueUSD + 0.01
                < (stabilized.previous?.apiValueUSD ?? 0)
        SwapLog.append(.debug("TOKEN_USAGE_REFRESH_ACCEPTED sequence=\(refreshSequence) api=\(String(format: "%.4f", stabilized.summary.apiValueUSD)) completions=\(stabilized.summary.total.completionCount) sources=\(sources) remote_included=\(stabilized.summary.includesRemoteUsage) stale_high_water_replaced=\(staleHighWaterReplaced)"))
        updatePopoverContent()
    }

    private func checkLinuxDevboxReadiness(force: Bool = false) {
        let settings = LinuxDevboxMonitor.settings()
        guard settings.isConfigured else {
            lastLinuxDevboxReady = nil
            lastLinuxDevboxFullCheckAt = nil
            invalidateLinuxDevboxReadinessTask()
            lastLinuxDevboxAccountMirrorSucceededAt = nil
            accountManager.invalidateLinuxDevboxRuntimeEvidence()
            linuxDevboxConsecutiveIssueChecks = 0
            accountManager.linuxDevboxStatus = .notConfigured
            updatePopoverContent()
            return
        }
        let supersededReadinessTask: Bool
        if let activeContext = linuxDevboxReadinessTaskContext,
           force || activeContext.settings != settings {
            invalidateLinuxDevboxReadinessTask()
            supersededReadinessTask = true
        } else {
            supersededReadinessTask = false
        }
        if accountManager.linuxDevboxStatus.state == .ready,
           !linuxDevboxAccountMirrorIsFresh() {
            publishLinuxDevboxInvalidation(
                .expired,
                summary: "VPS readiness evidence expired"
            )
            SwapLog.append(.debug("LINUX_DEVBOX_READINESS_EXPIRED"))
            updatePopoverContent()
        }
        let credentialSyncHeld = applyLinuxDevboxCredentialSyncHoldIfPresent(
            context: "readiness",
            settings: settings
        )

        let hasActiveRemoteSession = LinuxDevboxMonitor.isCodexVPSRemoteSessionRunning()
        guard LinuxDevboxMonitor.shouldRunReadinessCheck(
            lastFullCheckAt: lastLinuxDevboxFullCheckAt,
            hasActiveRemoteSession: hasActiveRemoteSession,
            force: force || supersededReadinessTask
        ) else {
            return
        }
        guard !linuxDevboxReadinessCheckInFlight else {
            SwapLog.append(.debug("LINUX_DEVBOX_CHECK_SKIPPED reason=in_flight active_remote=\(hasActiveRemoteSession)"))
            return
        }

        let activeSessionRequiresInvalidation = LinuxDevboxStatus
            .activeSessionRequiresInvalidation(
                hasActiveRemoteSession: hasActiveRemoteSession,
                status: accountManager.linuxDevboxStatus,
                mirrorObservedAt: lastLinuxDevboxAccountMirrorSucceededAt,
                now: Date(),
                maximumAge: LinuxDevboxMonitor.activeRemoteAccountStatePollInterval * 4
            )
        if !credentialSyncHeld,
           activeSessionRequiresInvalidation {
            publishLinuxDevboxInvalidation(
                .activeSessionUnverified,
                summary: "active Codex VPS remote session detected; readiness not verified"
            )
            updatePopoverContent()
        }

        lastLinuxDevboxFullCheckAt = Date()
        if accountManager.linuxDevboxStatus.shouldShowCheckingPlaceholderBeforeRefresh,
           !applyLinuxDevboxCredentialSyncHoldIfPresent(
                context: "readiness-placeholder",
                settings: settings
           ) {
            accountManager.linuxDevboxStatus = .checking
            updatePopoverContent()
        }
        let taskContext = beginLinuxDevboxReadinessTask(settings: settings)
        Task { [weak self] in
            let shouldDefer = await NetworkBackoffGuard.shared
                .shouldDeferNonCriticalProbe(operation: "linux_devbox_readiness")
            guard let self else { return }
            guard self.linuxDevboxReadinessTaskIsCurrent(taskContext) else {
                self.finishLinuxDevboxReadinessTask(taskContext)
                SwapLog.append(.debug(
                    "LINUX_DEVBOX_CHECK_DISCARDED reason=stale_before_probe generation=\(taskContext.generation)"
                ))
                return
            }
            if shouldDefer {
                self.publishLinuxDevboxInvalidation(
                    .deferred,
                    summary: "VPS readiness check deferred by network backoff"
                )
                SwapLog.append(.debug("LINUX_DEVBOX_CHECK_DEFERRED reason=network_backoff"))
                self.updatePopoverContent()
                return
            }
            let result = await Task.detached {
                LinuxDevboxMonitor.check(settings: taskContext.settings)
            }.value
            guard self.linuxDevboxReadinessTaskIsCurrent(taskContext) else {
                self.finishLinuxDevboxReadinessTask(taskContext)
                SwapLog.append(.debug(
                    "LINUX_DEVBOX_CHECK_DISCARDED reason=stale_after_probe generation=\(taskContext.generation)"
                ))
                return
            }
            defer {
                self.finishLinuxDevboxReadinessTask(taskContext)
            }
            switch result {
            case .success(let readiness):
                Task {
                    await NetworkBackoffGuard.shared.recordSuccess(operation: "linux_devbox_readiness")
                }
                let wasReady = self.lastLinuxDevboxReady
                if readiness.ready {
                    let verifiedReadiness = LinuxDevboxStatus(
                        state: .ready,
                        summary: readiness.summary,
                        activeEmail: readiness.activeEmail,
                        activeProviderAccountId: readiness.activeProviderAccountId
                    )
                    let accountStateResult = await Task.detached {
                        LinuxDevboxMonitor.fetchAccountStates(
                            settings: taskContext.settings
                        )
                    }.value
                    guard self.linuxDevboxReadinessTaskIsCurrent(taskContext) else {
                        SwapLog.append(.debug(
                            "LINUX_DEVBOX_CHECK_DISCARDED reason=stale_after_account_mirror generation=\(taskContext.generation)"
                        ))
                        return
                    }
                    switch accountStateResult {
                    case .success(let states):
                        self.lastLinuxDevboxReady = true
                        self.linuxDevboxConsecutiveIssueChecks = 0
                        self.lastLinuxDevboxAccountMirrorSucceededAt = Date()
                        let accountStateActiveEmail = states.first(where: \.isActive)?.email
                        self.accountManager.linuxDevboxStatus = Self
                            .vpsStatusPreservingReadinessIdentity(
                                verifiedReadiness,
                                summary: readiness.summary
                        )
                        self.applyLinuxDevboxAccountStates(
                            states,
                            context: "linux-devbox-status-sync"
                        )
                        SwapLog.append(.debug("LINUX_DEVBOX_REMOTE_ACCOUNT_STATUS_SYNCED remote_active=\(accountStateActiveEmail ?? "none") readiness_active=\(self.accountManager.linuxDevboxStatus.activeEmail ?? "none") local_configured=\(self.accountManager.configuredAccount?.email ?? "none") accounts=\(states.count) reason=headless-readiness"))
                        SwapLog.append(.debug("LINUX_DEVBOX_READY summary=\(readiness.summary)"))
                    case .failure(let failure):
                        self.publishLinuxDevboxInvalidation(
                            failure.isDecodedInvalidObservation ? .decodedInvalid : .failed,
                            summary: failure.message
                        )
                        SwapLog.append(.debug("LINUX_DEVBOX_REMOTE_ACCOUNT_STATUS_SYNC_FAILED message=\(failure.message) reason=headless-readiness"))
                    }
                } else {
                    self.linuxDevboxConsecutiveIssueChecks += 1
                    let issueCount = self.linuxDevboxConsecutiveIssueChecks
                    let suppressNotification = LinuxDevboxStatus
                        .shouldSuppressTransientIssueNotification(
                            wasReady: wasReady,
                            consecutiveIssueChecks: issueCount
                        )
                    self.publishLinuxDevboxInvalidation(
                        .negative,
                        summary: readiness.summary
                    )
                    SwapLog.append(.debug("LINUX_DEVBOX_NOT_READY summary=\(readiness.summary)"))
                    if !suppressNotification,
                       wasReady != false || issueCount == 2 {
                        NotificationManager.notifyLinuxDevboxReadinessIssue(summary: readiness.summary)
                    }
                }
            case .failure(let failure):
                Task {
                    await NetworkBackoffGuard.shared.recordFailure(failure.message, operation: "linux_devbox_readiness")
                }
                let wasReady = self.lastLinuxDevboxReady
                self.linuxDevboxConsecutiveIssueChecks += 1
                let issueCount = self.linuxDevboxConsecutiveIssueChecks
                let suppressNotification = LinuxDevboxStatus
                    .shouldSuppressTransientIssueNotification(
                        wasReady: wasReady,
                        consecutiveIssueChecks: issueCount
                    )
                self.publishLinuxDevboxInvalidation(
                    failure.isDecodedInvalidObservation ? .decodedInvalid : .failed,
                    summary: failure.message
                )
                SwapLog.append(.debug("LINUX_DEVBOX_CHECK_FAILED message=\(failure.message)"))
                if !suppressNotification,
                   wasReady != false || issueCount == 2 {
                    NotificationManager.notifyLinuxDevboxReadinessIssue(summary: failure.message)
                }
            }
            _ = self.applyLinuxDevboxCredentialSyncHoldIfPresent(
                context: "readiness-result",
                settings: taskContext.settings
            )
            self.updatePopoverContent()
        }
    }

    @discardableResult
    private func applyLinuxDevboxCredentialSyncHoldIfPresent(
        context: String,
        settings: LinuxDevboxMonitorSettings
    ) -> Bool {
        guard !linuxDevboxCredentialSyncInFlight else { return false }
        do {
            if let operation = try linuxDevboxCredentialSyncJournal.load() {
                surfaceLinuxDevboxCredentialSyncHold(
                    operation: operation,
                    context: context
                )
                reconcileLinuxDevboxCredentialSyncIfNeeded(
                    operation: operation,
                    settings: settings
                )
                return true
            }
        } catch {
            surfaceLinuxDevboxCredentialSyncHold(
                fingerprint: LinuxDevboxMonitor.credentialSyncFingerprint(
                    accounts: accountManager.accounts
                ),
                reason: "Credential-sync journal is unavailable: \(error.localizedDescription)",
                context: context
            )
            return true
        }
        if let fingerprint = UserDefaults.standard.string(
            forKey: linuxDevboxCredentialSyncUnresolvedFingerprintKey
        ) {
            let reason = UserDefaults.standard.string(
                forKey: linuxDevboxCredentialSyncUnresolvedReasonKey
            ) ?? "Legacy credential-sync hold requires manual reconciliation"
            surfaceLinuxDevboxCredentialSyncHold(
                fingerprint: fingerprint,
                reason: reason,
                context: context
            )
            return true
        }
        return false
    }

    private func linuxDevboxAccountMirrorIsFresh(now: Date = Date()) -> Bool {
        LinuxDevboxStatus.accountMirrorIsFresh(
            observedAt: lastLinuxDevboxAccountMirrorSucceededAt,
            now: now,
            maximumAge: LinuxDevboxMonitor.activeRemoteAccountStatePollInterval * 4
        )
    }

    private func applyLinuxDevboxAccountStates(
        _ states: [LinuxDevboxAccountState],
        context: String
    ) {
        let result = accountManager.applyLinuxDevboxAccountStates(states)
        guard result.stateChanged else { return }
        if let remoteActive = states.first(where: \.isActive)?.email,
           remoteActive.caseInsensitiveCompare(accountManager.configuredAccount?.email ?? "") != .orderedSame {
            SwapLog.append(.debug(
                "LINUX_DEVBOX_REMOTE_ACTIVE_STATUS_ONLY remote=\(remoteActive) local_configured=\(accountManager.configuredAccount?.email ?? "none") reason=codex_app_running"
            ))
        }
        SwapLog.append(.debug("LINUX_DEVBOX_PRESENTATION_UPDATED context=\(context) accounts=\(states.count)"))
        statusBarController.updateIcon()
        updatePopoverContent()
    }
}
