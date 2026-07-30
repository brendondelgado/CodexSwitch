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

struct AppDelegateDesktopPatchRetryLifecycle: Equatable, Sendable {
    private(set) var activeIdentifier: UUID?

    var isActive: Bool {
        activeIdentifier != nil
    }

    mutating func begin(identifier: UUID) -> Bool {
        guard activeIdentifier == nil else { return false }
        activeIdentifier = identifier
        return true
    }

    @discardableResult
    mutating func finish(identifier: UUID) -> Bool {
        guard activeIdentifier == identifier else { return false }
        activeIdentifier = nil
        return true
    }

    mutating func cancel() {
        activeIdentifier = nil
    }
}

enum AppDelegateDesktopUpdateActivationObservation: Equatable, Sendable {
    case updateInProgress
    case runningReady
    case runningUnready
    case stopped
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

struct RateLimitResetSubmissionObservation: Equatable, Sendable {
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

@MainActor
private final class ConfiguredCredentialPublicationBuffer {
    var persistedAccounts: [CodexAccount]?
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

private enum ExternalHandoffAdoptionResult: Sendable {
    case notAdopted
    case adopted(CodexAccount)
}

private enum ExternalHandoffResolution: Sendable {
    case unavailable
    case deferred
    case adopted(CodexAccount)
}

private enum ExternalHandoffAdoptionError: Error {
    case revalidationFailed
    case transientRevalidation
}

enum ExternalHandoffFollowUp: Equatable {
    case adopt
    case retryRuntime
    case none
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
    private var instanceRole: CodexSwitchInstanceRole = .unresolved

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
    private var rateLimitResetInventoryFailureStates: [UUID: RateLimitResetFailureState] = [:]
    private var rateLimitResetManualErrors: [UUID: String] = [:] {
        didSet { publishRateLimitResetPresentations() }
    }
    private var rateLimitResetUnresolvedProviderAccountIds: Set<String> = [] {
        didSet { publishRateLimitResetPresentations() }
    }
    private var remoteRateLimitResetUnknownProviderAccountIds: Set<String> = [] {
        didSet { publishRateLimitResetPresentations() }
    }
    private var remoteRateLimitResetRefreshStartedAt: [String: Date] = [:] {
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
    private var poolAuthorityClientState = PoolAuthorityClientState()
    private var poolAuthorityStatusCheckInFlight = false
    private var poolAuthorityRequestInFlight = false
    private var poolAuthorityOperationAuthority: PoolAuthorityOperationAuthority?
    private var poolAuthorityStatusGeneration: UInt64 = 0
    private var remoteAuthorityTransportSettings: LinuxDevboxMonitorSettings?
    private var remoteAuthorityTransportWriteGeneration: UInt64 = 0
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
    private var desktopPatchRetryLifecycle = AppDelegateDesktopPatchRetryLifecycle()
    private var desktopUpdateActivationProbeTask: Task<Void, Never>?
    private var desktopUpdateActivationProbeTaskIdentifier: UUID?
    private var lastDesktopUpdateActivationResumeAt: Date?
    private var handledDesktopUpdateTransactionIdentifiers: Set<UInt64> = []
    private var swapGeneration: UInt64 = 0
    private var pendingSwapTargetAccountId: UUID?
    private var swapConvergenceTask: Task<Void, Never>?
    private var automaticPolicyGateTask: Task<Void, Never>?
    private var automaticPolicyGateWatchdogTask: Task<Void, Never>?
    private var automaticPolicyLeaseState = AccountAutomaticPolicyLeaseState()
    private var quotaPollingReconciliationTask: Task<Void, Never>?
    private var isExiting = false
    private var terminationFlushTask: Task<Void, Never>?
    private var terminationFlushCompleted = false
    private var accountPersistenceRevision: UInt64 = 0
    private var externalHandoffAdoptionInFlight = false
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        instanceRole = .resolve(lockAcquired: singleInstanceLock.acquire())
        guard instanceRole.mayStartServices else {
            NSApp.terminate(nil)
            return
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceRole.mayStartServices else {
            NSApp.terminate(nil)
            return
        }
        installCrashHandlers()
        writeCrashLog("LAUNCH: applicationDidFinishLaunching started")

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
                    self?.reconcileQuotaPollingIfNeeded()
                    CLIStatusChecker.refresh(activeAccountId: self?.accountManager.configuredAccount?.accountId) { [weak self] in
                        self?.updatePopoverContent()
                    }
                    self?.scheduleDesktopPatchCheckIfNeeded()
                    self?.resumePendingDesktopUpdateActivationIfNeeded()
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
            if let state = accountManager.activationState {
                switch await adoptVerifiedExternalHandoffIfPresent(
                    expectedState: state,
                    expectedObservedProviderAccountId: imported.accountId,
                    requiresDifferentJournalTarget: true
                ) {
                case .adopted(let adopted):
                    await startSameTargetRuntimeRetry(
                        to: adopted,
                        source: "external_handoff"
                    )
                    return
                case .deferred:
                    return
                case .unavailable:
                    break
                }
            }
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
            switch Self.externalHandoffFollowUp(
                state: accountManager.activationState,
                configuredAccountId: configured?.id,
                observedTargetAccountId: target.id
            ) {
            case .adopt:
                guard let state = accountManager.activationState else { return }
                switch await adoptVerifiedExternalHandoffIfPresent(
                    expectedState: state,
                    expectedObservedProviderAccountId: target.accountId,
                    requiresDifferentJournalTarget: true
                ) {
                case .adopted(let adopted):
                    await startSameTargetRuntimeRetry(
                        to: adopted,
                        source: "external_handoff"
                    )
                    return
                case .deferred:
                    return
                case .unavailable:
                    break
                }
            case .retryRuntime:
                guard await durableAccountStoreMatches(target) else { return }
                await startSameTargetRuntimeRetry(
                    to: target,
                    source: "external_handoff_deferred_revalidation"
                )
                return
            case .none:
                break
            }
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

        if let state = accountManager.activationState {
            switch await adoptVerifiedExternalHandoffIfPresent(
                expectedState: state,
                expectedObservedProviderAccountId: target.accountId,
                requiresDifferentJournalTarget: false
            ) {
            case .adopted(let adopted):
                await startSameTargetRuntimeRetry(
                    to: adopted,
                    source: "external_handoff"
                )
                return
            case .deferred:
                return
            case .unavailable:
                break
            }
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
            requestKind: .automatic
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
            if transaction.kind == .stagedUpdate {
                CodexDesktopUpdateActivationIntent.clear()
            }
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
        let identifier = UUID()
        guard desktopPatchRetryLifecycle.begin(identifier: identifier) else {
            SwapLog.append(
                .debug(
                    "DESKTOP_PATCH_RETRY_COALESCED reason=\(reason) "
                        + "active=\(desktopPatchRetryLifecycle.activeIdentifier?.uuidString ?? "unknown")"
                )
            )
            return
        }
        let activationAccount = relaunchAfterCompletion
            ? accountManager.configuredAccount
            : nil
        let publishActivationResult: @MainActor @Sendable (
            Bool,
            String
        ) -> Void = { [weak self] success, message in
            self?.desktopUpdateCoordinator.desktopActivationFinished(
                success: success,
                message: message
            )
        }
        let finishRetryBurst: @MainActor @Sendable (UUID) -> Void = {
            [weak self] identifier in
            self?.finishDesktopPatchRetryBurst(identifier: identifier)
        }
        let performRetryBurst: @Sendable () async -> Void = {
            let retryDelays = DesktopPatchManager.postQuitPatchRetryDelaysSeconds
            for (index, delaySeconds) in retryDelays.enumerated() {
                let nanoseconds = UInt64(delaySeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }

                if let operation = await CodexDesktopAppUpdater.currentOperation(),
                   operation == .recovering
                    || operation == .installingStagedUpdate
                    || operation == .restoringStock {
                    SwapLog.append(
                        .debug(
                            "DESKTOP_PATCH_RETRY_DEFERRED reason=\(reason) "
                                + "updater_operation=\(operation.rawValue)"
                        )
                    )
                    continue
                }
                let outcome = DesktopPatchManager.checkAndPatchIfPossible(
                    ignoreCooldown: true,
                    ignorePermissionDeniedBackoff: true
                )
                guard !Task.isCancelled else { return }
                SwapLog.append(
                    .debug(
                        "DESKTOP_PATCH_RETRY reason=\(reason) delay_seconds=\(Int(delaySeconds)) outcome=\(outcome.logValue)"
                    )
                )
                let verifiedInstall = relaunchAfterCompletion
                    ? Self.desktopUpdateActivationReadyInstall()
                    : nil
                let activationReady = verifiedInstall != nil
                switch Self.desktopPatchRetryDisposition(
                    after: outcome,
                    hasRemainingAttempts: index + 1 < retryDelays.count,
                    relaunchAfterCompletion: relaunchAfterCompletion,
                    activationReady: activationReady
                ) {
                case .retry:
                    continue
                case .stop:
                    if relaunchAfterCompletion, !activationReady {
                        SwapLog.append(
                            .debug(
                                "DESKTOP_UPDATE_ACTIVATION_DEFERRED reason=\(reason) "
                                    + "outcome=\(outcome.logValue)"
                            )
                        )
                        await publishActivationResult(
                            false,
                            "Update installed, but hot-swap repair failed "
                                + "(\(outcome.logValue))."
                        )
                    }
                    return
                case .relaunch:
                    guard !Task.isCancelled, let verifiedInstall else { return }
                    if Self.relaunchDesktopAppAfterUpdate(
                        verifiedInstall: verifiedInstall,
                        isCancelled: { Task.isCancelled }
                    ) {
                        if let activationAccount,
                           await Self.confirmDesktopUpdateHotSwap(
                               verifiedInstall: verifiedInstall,
                               account: activationAccount
                           ) {
                            CodexDesktopUpdateActivationIntent.clear()
                            await publishActivationResult(
                                true,
                                "ChatGPT is updated and hot swapping is ready."
                            )
                            return
                        }
                        SwapLog.append(
                            .debug(
                                "DESKTOP_UPDATE_ACTIVATION_PENDING "
                                    + "waiting_for=acknowledged_auth_reload"
                            )
                        )
                    }
                    guard index + 1 < retryDelays.count else {
                        await publishActivationResult(
                            false,
                            "ChatGPT updated, but live hot-swap confirmation failed."
                        )
                        return
                    }
                }
            }
            if relaunchAfterCompletion {
                await publishActivationResult(
                    false,
                    "ChatGPT updated, but activation is still pending."
                )
            }
        }
        desktopPatchRetryTask = Task.detached {
            await performRetryBurst()
            await finishRetryBurst(identifier)
        }
    }

    private func finishDesktopPatchRetryBurst(identifier: UUID) {
        guard desktopPatchRetryLifecycle.finish(identifier: identifier) else { return }
        desktopPatchRetryTask = nil
    }

    nonisolated static func desktopPatchRetryDisposition(
        after outcome: DesktopPatchAttemptOutcome,
        hasRemainingAttempts: Bool,
        relaunchAfterCompletion: Bool,
        activationReady: Bool
    ) -> AppDelegateDesktopPatchRetryDisposition {
        if relaunchAfterCompletion, activationReady {
            return .relaunch
        }
        switch outcome {
        case .completed, .notNeeded:
            guard relaunchAfterCompletion else { return .stop }
            return hasRemainingAttempts ? .retry : .stop
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

    nonisolated static func desktopUpdateActivationReadyInstall(
        target: CodexDesktopUpdateActivationTarget? =
            CodexDesktopUpdateActivationIntent.pendingTarget()
    )
        -> CodexDesktopAppInstall?
    {
        guard let target,
              let install = CodexDesktopAppLocator.locate(),
              install.appPath == target.appPath,
              install.shortVersion == target.shortVersion,
              install.bundleVersion == target.bundleVersion,
              CodexDesktopAppLocator.patchMarkerPresent(install: install),
              CodexDesktopAppLocator.bundleIsValid(appPath: install.appPath) else {
            return nil
        }
        guard DesktopPatchManager.currentStatus(maxAge: 0).desktopIntegrationInstalled else {
            return nil
        }
        return install
    }

    nonisolated static func desktopUpdateActivationReady() -> Bool {
        desktopUpdateActivationReadyInstall() != nil
    }

    nonisolated static func desktopUpdateActivationObservation(
        account: CodexAccount?
    ) async
        -> AppDelegateDesktopUpdateActivationObservation
    {
        if let operation = await CodexDesktopAppUpdater.currentOperation(),
           operation == .recovering
            || operation == .installingStagedUpdate
            || operation == .restoringStock {
            return .updateInProgress
        }
        guard DesktopPatchManager.isCodexDesktopRuntimeRunning() else {
            return .stopped
        }
        guard let install = desktopUpdateActivationReadyInstall(),
              desktopHostIsRunning(at: install.appPath) else {
            return .runningUnready
        }
        guard let account,
              await confirmDesktopUpdateHotSwap(
                  verifiedInstall: install,
                  account: account
              ) else {
            return .runningUnready
        }
        return .runningReady
    }

    nonisolated static func desktopReloadConfirmsActivation(
        _ result: DesktopReloadResult
    ) -> Bool {
        guard case .reloaded(
            _,
            let discoveredRuntimeCount,
            let acknowledgedRuntimeCount,
            _
        ) = result else {
            return false
        }
        return discoveredRuntimeCount > 0
            && acknowledgedRuntimeCount == discoveredRuntimeCount
    }

    nonisolated private static func confirmDesktopUpdateHotSwap(
        verifiedInstall: CodexDesktopAppInstall,
        account: CodexAccount
    ) async -> Bool {
        let reloadResult = await DesktopRuntimeReloadClient().reloadAuth(
            account: account,
            reuseExistingAcknowledgement: false,
            includeAcknowledgedRuntimeBindings: true
        )
        guard desktopReloadConfirmsActivation(reloadResult),
              DesktopUpdateRuntimeBindingVerifier.acknowledgesInstalledHost(
                  result: reloadResult,
                  appPath: verifiedInstall.appPath,
                  hostProcesses: desktopHostProcesses(
                      at: verifiedInstall.appPath
                  )
              ) else {
            SwapLog.append(
                .debug(
                    "DESKTOP_UPDATE_AUTH_RELOAD_UNCONFIRMED "
                        + "result=\(String(describing: reloadResult))"
                )
            )
            return false
        }
        guard desktopUpdateActivationReadyInstall() == verifiedInstall,
              desktopHostIsRunning(at: verifiedInstall.appPath),
              DesktopPatchManager.runtimeHotSwapState() == .ready else {
            SwapLog.append(
                .debug(
                    "DESKTOP_UPDATE_AUTH_RELOAD_STALE path=\(verifiedInstall.appPath)"
                )
            )
            return false
        }
        SwapLog.append(
            .debug(
                "DESKTOP_UPDATE_AUTH_RELOAD_CONFIRMED path=\(verifiedInstall.appPath)"
            )
        )
        return true
    }

    nonisolated private static func desktopHostIsRunning(at appPath: String) -> Bool {
        !desktopHostProcesses(at: appPath).isEmpty
    }

    nonisolated private static func desktopHostProcesses(
        at appPath: String
    ) -> [DesktopUpdateHostProcess] {
        return DesktopPatchManager.desktopHostBundleIdentifiers.flatMap { bundleIdentifier in
            NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).compactMap { application in
                guard !application.isTerminated,
                      application.bundleURL?.path == appPath,
                      application.executableURL != nil,
                      let processIdentity = SwapEngine.signalProcessIdentity(
                          pid: application.processIdentifier
                      ) else {
                    return nil
                }
                return DesktopUpdateHostProcess(
                    processIdentity: processIdentity
                )
            }
        }
    }

    nonisolated private static func relaunchDesktopAppAfterUpdate(
        verifiedInstall: CodexDesktopAppInstall,
        isCancelled: () -> Bool
    ) -> Bool {
        guard !isCancelled() else { return false }
        guard desktopUpdateActivationReadyInstall() == verifiedInstall else { return false }
        let appPath = verifiedInstall.appPath
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
        guard !result.timedOut, result.terminationStatus == 0 else { return false }

        let deadline = Date().addingTimeInterval(10)
        var continuouslyRunningSince: Date?
        while Date() < deadline {
            if isCancelled() { return false }
            let running = desktopHostIsRunning(at: appPath)
            if running {
                let now = Date()
                continuouslyRunningSince = continuouslyRunningSince ?? now
                if let continuouslyRunningSince,
                   now.timeIntervalSince(continuouslyRunningSince) >= 2 {
                    guard desktopUpdateActivationReadyInstall() == verifiedInstall else {
                        SwapLog.append(
                            .debug(
                                "DESKTOP_UPDATE_RELAUNCH_IDENTITY_CHANGED path=\(appPath)"
                            )
                        )
                        return false
                    }
                    SwapLog.append(.debug("DESKTOP_UPDATE_RELAUNCH_CONFIRMED path=\(appPath)"))
                    return true
                }
            } else {
                continuouslyRunningSince = nil
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        SwapLog.append(.debug("DESKTOP_UPDATE_RELAUNCH_UNCONFIRMED path=\(appPath)"))
        return false
    }

    private func resumePendingDesktopUpdateActivationIfNeeded(force: Bool = false) {
        guard CodexDesktopUpdateActivationIntent.isPending() else { return }
        guard desktopUpdateActivationProbeTask == nil else { return }
        guard CodexDesktopUpdateActivationIntent.pendingTarget() != nil else {
            CodexDesktopUpdateActivationIntent.clear()
            desktopUpdateCoordinator.desktopActivationFinished(
                success: false,
                message: "Desktop update activation target was missing; update not confirmed."
            )
            SwapLog.append(
                .debug("DESKTOP_UPDATE_ACTIVATION_REJECTED reason=missing_target")
            )
            return
        }
        let now = Date()
        if !force,
           let lastDesktopUpdateActivationResumeAt,
           now.timeIntervalSince(lastDesktopUpdateActivationResumeAt) < 60 {
            return
        }
        lastDesktopUpdateActivationResumeAt = now
        let activationAccount = accountManager.configuredAccount
        let identifier = UUID()
        desktopUpdateActivationProbeTaskIdentifier = identifier
        let finish: @MainActor @Sendable (
            AppDelegateDesktopUpdateActivationObservation,
            UUID
        ) -> Void = { [weak self] observation, identifier in
            self?.finishPendingDesktopUpdateActivationProbe(
                observation,
                identifier: identifier
            )
        }
        desktopUpdateActivationProbeTask = Task.detached(priority: .utility) {
            let observation = await Self.desktopUpdateActivationObservation(
                account: activationAccount
            )
            guard !Task.isCancelled else { return }
            await finish(observation, identifier)
        }
    }

    private func finishPendingDesktopUpdateActivationProbe(
        _ observation: AppDelegateDesktopUpdateActivationObservation,
        identifier: UUID
    ) {
        guard desktopUpdateActivationProbeTaskIdentifier == identifier else { return }
        desktopUpdateActivationProbeTask = nil
        desktopUpdateActivationProbeTaskIdentifier = nil
        guard !isExiting, CodexDesktopUpdateActivationIntent.isPending() else { return }

        switch observation {
        case .updateInProgress:
            SwapLog.append(
                .debug("DESKTOP_UPDATE_ACTIVATION_PENDING waiting_for=updater_operation")
            )
        case .runningReady:
            CodexDesktopUpdateActivationIntent.clear()
            desktopUpdateCoordinator.desktopActivationFinished(
                success: true,
                message: "ChatGPT is updated and hot swapping is ready."
            )
            SwapLog.append(.debug("DESKTOP_UPDATE_ACTIVATION_CONFIRMED existing_runtime=true"))
        case .runningUnready:
            desktopUpdateCoordinator.desktopActivationDeferred(
                "ChatGPT updated; waiting for live hot-swap confirmation."
            )
            SwapLog.append(
                .debug(
                    "DESKTOP_UPDATE_ACTIVATION_PENDING "
                        + "waiting_for=acknowledged_auth_reload"
                )
            )
        case .stopped:
            scheduleDesktopPatchRetryBurst(
                reason: "desktop_update_activation_resume",
                relaunchAfterCompletion: true
            )
        }
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
        guard instanceRole.requiresTerminationPersistence else {
            return .terminateNow
        }
        if terminationFlushCompleted { return .terminateNow }
        guard terminationFlushTask == nil else { return .terminateLater }

        let persistence = accountPersistence
        let accounts = accountManager.accounts
        accountPersistenceRevision &+= 1
        let revision = accountPersistenceRevision
        terminationFlushTask = Task { @MainActor [weak self, weak sender] in
            do {
                _ = try await persistence.persistTelemetrySnapshot(
                    accounts,
                    revision: revision
                )
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
        guard instanceRole == .primary else { return }
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
        guard Self.isManagedDesktopApplication(
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath
        ) else {
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
            self.installPreparedDesktopUpdate(
                fallbackPatchReason: "codex_app_terminated"
            )
        }
    }

    nonisolated static func isManagedDesktopApplication(
        bundleIdentifier: String?,
        bundlePath: String?
    ) -> Bool {
        if let bundleIdentifier,
           DesktopPatchManager.desktopHostBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        guard let bundlePath else { return false }
        return CodexDesktopAppLocator.defaultAppPaths.contains(bundlePath)
    }

    private func requestDesktopUpdateInstallationFromSettings() {
        var runningHostsByPID: [pid_t: NSRunningApplication] = [:]
        let managedBundlePaths = Set(CodexDesktopAppLocator.defaultAppPaths)
        for bundleIdentifier in DesktopPatchManager.desktopHostBundleIdentifiers {
            for application in NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ) where !application.isTerminated
                && application.bundleURL.map({ managedBundlePaths.contains($0.path) }) == true {
                runningHostsByPID[application.processIdentifier] = application
            }
        }

        let runningHosts = Array(runningHostsByPID.values)
        desktopUpdateCoordinator.manualInstallRequested(
            waitingForDesktopQuit: !runningHosts.isEmpty
        )
        guard !runningHosts.isEmpty else {
            SwapLog.append(.debug("DESKTOP_UPDATE_MANUAL_INSTALL host=not_running"))
            installPreparedDesktopUpdate(
                fallbackPatchReason: "settings_manual_desktop_update"
            )
            return
        }

        for application in runningHosts {
            let accepted = application.terminate()
            SwapLog.append(
                .debug(
                    "DESKTOP_UPDATE_MANUAL_QUIT_REQUEST "
                        + "pid=\(application.processIdentifier) accepted=\(accepted)"
                )
            )
        }
    }

    private func retryDesktopPatchFromSettings(
        completion: @escaping @MainActor @Sendable (
            DesktopPatchAttemptOutcome
        ) -> Void
    ) {
        DesktopPatchManager.prepareForAppManagementPermissionRetry()
        Task.detached(priority: .userInitiated) {
            let outcome = DesktopPatchManager.checkAndPatchIfPossible(
                ignoreCooldown: true,
                ignorePermissionDeniedBackoff: true
            )
            await completion(outcome)
        }
    }

    private func installPreparedDesktopUpdate(fallbackPatchReason: String) {
        desktopUpdateCoordinator.desktopAppDidTerminate {
            [weak self] installedUpdate, transaction in
            guard let self else { return }
            if let transaction {
                self.handleDesktopUpdateTransactionCompletion(transaction)
            } else {
                let activationPending = CodexDesktopUpdateActivationIntent.isPending()
                self.scheduleDesktopPatchRetryBurst(
                    reason: installedUpdate
                        ? "desktop_update_installed"
                        : fallbackPatchReason,
                    relaunchAfterCompletion: activationPending
                )
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
            switch await adoptVerifiedExternalHandoffIfPresent(
                expectedState: stored,
                expectedObservedProviderAccountId: nil,
                requiresDifferentJournalTarget: true
            ) {
            case .adopted:
                return
            case .deferred:
                accountManager.publishActivationState(stored)
                return
            case .unavailable:
                break
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
        let recovery = Self.journalFreeBootstrapRecovery(
            accounts: accountManager.accounts,
            observedProviderAccountId: observedAccount?.accountId
        )
        if recovery == .ambiguous {
            await enterActivationManualReview(
                targetAccountId: nil,
                detail: .configuredFilesInconsistent
            )
            return
        }
        guard case .recovered(let targetAccountId) = recovery,
              var target = accountManager.accounts.first(where: {
                  $0.id == targetAccountId
              }) else {
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

        _ = await withPreparedActiveCredentialMutation(
            targetAccountId: target.id,
            expectedConfiguredAccountId: previousConfigured?.id,
            source: "launch-activation-bootstrap",
            requestKind: .automatic
        ) { [weak self] prepared in
            guard let self else { return false }
            return await self.commitConfiguredCredentialMutation(
                from: previousConfigured ?? target,
                to: target,
                reason: .manual,
                mutationRoute: Self.journalFreeBootstrapMutationRoute(
                    previousConfiguredAccountId: previousConfigured?.id
                ),
                persistenceContext: "launch-activation-bootstrap",
                authAlreadyConfigured: true,
                swapStart: Date(),
                prepared: prepared,
                recordsSwap: false,
                committedDetail: .launchRuntimeEvidenceExpired
            )
        }
    }

    nonisolated static func journalFreeBootstrapRecovery(
        accounts: [CodexAccount],
        observedProviderAccountId: String?
    ) -> ConfiguredAccountRecovery {
        AccountActivationRecoveryCoordinator.configuredAccountRecovery(
            accounts: accounts,
            observedProviderAccountId: observedProviderAccountId
        )
    }

    nonisolated static func journalFreeBootstrapMutationRoute(
        previousConfiguredAccountId: UUID?
    ) -> AccountCredentialMutationRoute {
        previousConfiguredAccountId == nil ? .firstActivation : .externalAuthObservation
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

    nonisolated static func reauthenticatedAccountCandidate(
        original: CodexAccount,
        observed: CodexAccount
    ) -> CodexAccount? {
        guard reauthenticationPreservesStableProviderIdentity(
            original: original,
            observed: observed
        ), observed.hasCompleteRuntimeCredentials else {
            return nil
        }

        var candidate = original
        candidate.email = observed.email
        candidate.accessToken = observed.accessToken
        candidate.refreshToken = observed.refreshToken
        candidate.idToken = observed.idToken
        candidate.accountId = observed.accountId
        candidate.lastRefreshed = observed.lastRefreshed ?? Date()
        candidate.runtimeUnusableUntil = nil
        candidate.runtimeUnusableReason = nil
        return candidate
    }

    nonisolated static func inactiveReauthenticationSnapshot(
        accounts: [CodexAccount],
        original: CodexAccount,
        candidate: CodexAccount
    ) -> [CodexAccount]? {
        guard !original.isActive,
              candidate.id == original.id,
              candidate.accountId == original.accountId,
              candidate.hasCompleteRuntimeCredentials,
              let index = accounts.firstIndex(where: { $0.id == original.id }),
              !accounts[index].isActive,
              credentialsMatch(accounts[index], original),
              !accounts.contains(where: {
                  $0.id != original.id && $0.accountId == candidate.accountId
              }) else {
            return nil
        }

        var replacement = accounts[index]
        replacement.email = candidate.email
        replacement.accessToken = candidate.accessToken
        replacement.refreshToken = candidate.refreshToken
        replacement.idToken = candidate.idToken
        replacement.accountId = candidate.accountId
        replacement.lastRefreshed = candidate.lastRefreshed
        replacement.runtimeUnusableUntil = nil
        replacement.runtimeUnusableReason = nil

        var snapshot = accounts
        snapshot[index] = replacement
        return snapshot
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

    private func adoptVerifiedExternalHandoffIfPresent(
        expectedState: AccountActivationState,
        expectedObservedProviderAccountId: String?,
        requiresDifferentJournalTarget: Bool
    ) async -> ExternalHandoffResolution {
        guard !isExiting,
              !externalHandoffAdoptionInFlight,
              pendingSwapTargetAccountId == nil,
              swapConvergenceTask == nil,
              expectedState.phase == .confirmed
                || expectedState.phase == .committedDegraded else {
            return .unavailable
        }

        externalHandoffAdoptionInFlight = true
        defer { externalHandoffAdoptionInFlight = false }

        accountPersistenceRevision &+= 1
        let revision = accountPersistenceRevision
        let initialTarget: CodexAccount
        do {
            let accounts = try await accountPersistence.adoptExternalSnapshot(
                revision: revision
            )
            let observation = await Task.detached(priority: .utility) {
                AccountImporter.observeCurrentAccount()
            }.value
            switch observation {
            case .valid(let observed):
                guard let target = Self.verifiedExternalHandoffTarget(
                    accounts: accounts,
                    authObservation: observation
                ) else {
                    return expectedObservedProviderAccountId.map({
                        $0 == observed.accountId
                    }) == true ? .deferred : .unavailable
                }
                guard expectedObservedProviderAccountId.map({
                    $0 == target.accountId
                }) ?? true,
                !requiresDifferentJournalTarget
                    || expectedState.configuredAccountId != target.id else {
                    return .unavailable
                }
                initialTarget = target
            case .invalid(let reason) where reason.isRetryableObservationFailure:
                SwapLog.append(.debug(
                    "ACTIVATION_EXTERNAL_HANDOFF_DEFERRED reason=\(reason.rawValue)"
                ))
                return .deferred
            case .unreadable(let reason):
                SwapLog.append(.debug(
                    "ACTIVATION_EXTERNAL_HANDOFF_DEFERRED reason=\(reason.rawValue)"
                ))
                return .deferred
            case .absent, .invalid:
                return .unavailable
            }
        } catch {
            SwapLog.append(.debug(
                "ACTIVATION_EXTERNAL_HANDOFF_READ_FAILED error=\(error.localizedDescription)"
            ))
            return .deferred
        }

        switch RustActivationJournal.handoffDisposition(for: initialTarget) {
        case .ready:
            break
        case .deferred(let reason), .blocked(let reason):
            accountManager.publishActivationNotice(reason)
            SwapLog.append(.debug(
                "ACTIVATION_EXTERNAL_HANDOFF_DEFERRED target=\(initialTarget.id.uuidString) reason=\(reason)"
            ))
            return .deferred
        }

        let activationGeneration = UUID()
        let scoped = await accountMutationTransaction.withActivationLease(
            targetAccountId: initialTarget.id,
            activationGeneration: activationGeneration
        ) { [weak self] lease in
            guard let self, !self.isExiting else {
                return ExternalHandoffAdoptionResult.notAdopted
            }
            var adoptedState: AccountActivationState?
            do {
                let revalidatedAccounts = try await self.accountPersistence
                    .adoptExternalSnapshot(revision: revision)
                let revalidatedObservation = await Task.detached(priority: .utility) {
                    AccountImporter.observeCurrentAccount()
                }.value
                guard let revalidatedTarget = Self.verifiedExternalHandoffTarget(
                    accounts: revalidatedAccounts,
                    authObservation: revalidatedObservation
                ),
                    revalidatedTarget.id == initialTarget.id,
                    expectedObservedProviderAccountId.map({
                        $0 == revalidatedTarget.accountId
                    }) ?? true,
                    !requiresDifferentJournalTarget
                        || expectedState.configuredAccountId != revalidatedTarget.id,
                    await self.accountMutationTransaction.owns(lease) else {
                    return .notAdopted
                }
                guard case .ready = RustActivationJournal.handoffDisposition(
                    for: revalidatedTarget
                ) else {
                    return .notAdopted
                }

                let adopted = try await self.accountActivationCoordinator
                    .adoptVerifiedExternalHandoff(
                        targetAccountId: revalidatedTarget.id,
                        expectedState: expectedState,
                        newActivationGeneration: activationGeneration,
                        authorizeEffect: { [accountMutationTransaction] state in
                            accountMutationTransaction.leaseAuthorizes(
                                lease,
                                targetAccountId: revalidatedTarget.id,
                                activationGeneration: activationGeneration
                            ) && state == expectedState
                        }
                    )
                adoptedState = adopted

                let synchronizedAccounts: [CodexAccount]
                do {
                    synchronizedAccounts = try await self.accountPersistence
                        .adoptExternalSnapshot(revision: revision)
                } catch {
                    if Self.externalHandoffFinalStoreErrorIsTransient(error) {
                        throw ExternalHandoffAdoptionError.transientRevalidation
                    }
                    throw ExternalHandoffAdoptionError.revalidationFailed
                }
                let synchronizedObservation = await Task.detached(priority: .utility) {
                    AccountImporter.observeCurrentAccount()
                }.value
                if Self.externalHandoffFinalObservationIsTransient(
                    synchronizedObservation
                ) {
                    throw ExternalHandoffAdoptionError.transientRevalidation
                }
                guard let synchronizedTarget = Self.verifiedExternalHandoffTarget(
                    accounts: synchronizedAccounts,
                    authObservation: synchronizedObservation
                ),
                synchronizedTarget.id == revalidatedTarget.id,
                expectedObservedProviderAccountId.map({
                    $0 == synchronizedTarget.accountId
                }) ?? true,
                await self.accountMutationTransaction.owns(lease),
                try await self.accountActivationCoordinator.load() == adopted,
                self.accountManager.adoptVerifiedExternalHandoff(
                    synchronizedAccounts,
                    targetAccountId: synchronizedTarget.id
                ) else {
                    throw ExternalHandoffAdoptionError.revalidationFailed
                }

                self.accountManager.publishActivationState(adopted)
                self.swapGeneration &+= 1
                CLIStatusChecker.invalidateForAccountSwap()
                SwapLog.append(.debug(
                    "ACTIVATION_EXTERNAL_HANDOFF_ADOPTED target=\(synchronizedTarget.id.uuidString) previous_target=\(expectedState.configuredAccountId?.uuidString ?? "none")"
                ))
                return .adopted(synchronizedTarget)
            } catch {
                if let adoptionError = error as? ExternalHandoffAdoptionError,
                   case .transientRevalidation = adoptionError,
                   let adoptedState {
                    self.accountManager.publishActivationState(adoptedState)
                    SwapLog.append(.debug(
                        "ACTIVATION_EXTERNAL_HANDOFF_DEFERRED target=\(initialTarget.id.uuidString) reason=transient_final_revalidation"
                    ))
                    return .notAdopted
                }
                if let adoptedState {
                    do {
                        let failed = try await self.accountActivationCoordinator
                            .failVerifiedExternalHandoff(
                                targetAccountId: initialTarget.id,
                                expectedActivationGeneration: activationGeneration,
                                authorizeEffect: { [accountMutationTransaction] state in
                                    accountMutationTransaction.leaseAuthorizes(
                                        lease,
                                        targetAccountId: initialTarget.id,
                                        activationGeneration: activationGeneration
                                    ) && state == adoptedState
                                }
                            )
                        self.accountManager.publishActivationState(failed)
                    } catch {
                        do {
                            self.accountManager.publishActivationState(
                                try await self.accountActivationCoordinator.load()
                            )
                        } catch {
                            self.accountManager.publishActivationNotice(
                                "Activation journal changed during external handoff"
                            )
                        }
                    }
                }
                SwapLog.append(.debug(
                    "ACTIVATION_EXTERNAL_HANDOFF_REJECTED target=\(initialTarget.id.uuidString) error=\(error.localizedDescription)"
                ))
                return .notAdopted
            }
        }

        guard let scoped else {
            accountManager.publishActivationNotice(
                "Another account mutation is already in progress"
            )
            return .deferred
        }
        if case .adopted(let target) = scoped {
            statusBarController?.updateIcon()
            updatePopoverContent()
            return .adopted(target)
        }
        return .deferred
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
                            reuseExistingAcknowledgement:
                                !AccountActivationRuntimeEvidencePreflight
                                    .requiresFreshAcknowledgements,
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
                                reuseExistingAcknowledgement:
                                    !AccountActivationRuntimeEvidencePreflight
                                        .requiresFreshAcknowledgements,
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
                        desktop: SwapEngine.localDesktopRuntimeEvidenceSnapshot(),
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
    private func persistAccountsSnapshot(
        context: String,
        expectedCredentialAuthority: [CodexAccount],
        log: Bool = true
    ) async -> Bool {
        guard !externalHandoffAdoptionInFlight else {
            SwapLog.append(.debug(
                "ACCOUNTS_PERSIST_BLOCKED context=\(context) reason=external_handoff_adoption"
            ))
            return false
        }
        let accounts = accountManager.accounts
        accountPersistenceRevision &+= 1
        let revision = accountPersistenceRevision
        let outcome: AppDelegateAccountsPersistenceOutcome
        do {
            switch try await accountPersistence.persistDurably(
                accounts,
                ifCredentialAuthorityMatches: expectedCredentialAuthority,
                revision: revision
            ) {
            case .persisted:
                outcome = .persisted
            case .discardedCredentialDrift:
                outcome = .failed(
                    "credential authority changed before account persistence"
                )
                externalAuthReconciliationPending = true
                SwapLog.append(.debug(
                    "ACCOUNTS_PERSIST_DISCARDED context=\(context) reason=credential_or_selection_changed"
                ))
            }
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

    private func persistAuthorizedAccountsSnapshot(
        _ accounts: [CodexAccount],
        context: String,
        expectedCredentialAuthority: [CodexAccount],
        permit: AccountActivationEffectPermit
    ) async -> [CodexAccount]? {
        guard !externalHandoffAdoptionInFlight else {
            SwapLog.append(.debug(
                "ACCOUNTS_PERSIST_BLOCKED context=\(context) reason=external_handoff_adoption"
            ))
            return nil
        }
        accountPersistenceRevision &+= 1
        let revision = accountPersistenceRevision
        do {
            let persisted: [CodexAccount]
            switch try await accountPersistence.persistDurably(
                accounts,
                ifCredentialAuthorityMatches: expectedCredentialAuthority,
                revision: revision,
                authorizeEffect: { permit.isCurrentlyAuthorized() }
            ) {
            case .persisted(let committed):
                persisted = committed
            case .discardedCredentialDrift:
                externalAuthReconciliationPending = true
                SwapLog.append(.debug(
                    "ACCOUNTS_PERSIST_DISCARDED context=\(context) reason=credential_or_selection_changed"
                ))
                return nil
            }
            SwapLog.append(.debug(
                "ACCOUNTS_PERSISTED context=\(context) configured=\(persisted.first(where: \.isActive)?.email ?? "none")"
            ))
            return persisted
        } catch {
            logger.warning(
                "Failed to persist authorized accounts snapshot (\(context)): \(error.localizedDescription)"
            )
            SwapLog.append(.debug(
                "ACCOUNTS_PERSIST_FAILED context=\(context) error=\(error.localizedDescription)"
            ))
            return nil
        }
    }

    @discardableResult
    private func persistTelemetrySnapshot(context: String) async -> Bool {
        guard !externalHandoffAdoptionInFlight else { return false }
        let accounts = accountManager.accounts
        accountPersistenceRevision &+= 1
        let revision = accountPersistenceRevision
        do {
            let persisted = try await accountPersistence.persistTelemetrySnapshot(
                accounts,
                revision: revision
            )
            if !persisted {
                externalAuthReconciliationPending = true
                SwapLog.append(.debug(
                    "ACCOUNTS_TELEMETRY_DISCARDED context=\(context) reason=credential_or_selection_changed"
                ))
            }
            return persisted
        } catch {
            SwapLog.append(.debug(
                "ACCOUNTS_PERSIST_FAILED context=\(context) error=\(error.localizedDescription)"
            ))
            return false
        }
    }

    private func queueTelemetryPersistence(context _: String) {
        guard !externalHandoffAdoptionInFlight else { return }
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
        if context != "authority-reconciliation",
           UserDefaults.standard.string(forKey: linuxDevboxLastCredentialSyncFingerprintKey) == fingerprint {
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
        let authorityObservation = accountManager.poolAuthorityObservation
        let journal = linuxDevboxCredentialSyncJournal
        let deferSync: @MainActor @Sendable () -> Void = { [weak self] in
            self?.deferLinuxDevboxCredentialSync(
                fingerprint: fingerprint,
                context: context
            )
        }
        let finishSync: @MainActor @Sendable (
            Result<String, LinuxDevboxMonitorFailure>,
            String
        ) -> Void = { [weak self] result, completedFingerprint in
            self?.finishLinuxDevboxCredentialSync(
                result: result,
                fingerprint: completedFingerprint,
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
                await finishSync(.failure(failure), fingerprint)
                return
            }

            let synchronizedAccounts: [CodexAccount]
            let credentialSyncProviderAccountId = Self
                .linuxDevboxCredentialSyncProviderAccountId(
                    authorityObservation: authorityObservation,
                    observedRemoteProviderAccountId: baseline.activeProviderAccountId,
                    now: now
                )
            switch LinuxDevboxMonitor.credentialSyncAccountsPreservingRemoteActive(
                accounts: accounts,
                remoteActiveProviderAccountId: credentialSyncProviderAccountId
            ) {
            case .success(let value):
                synchronizedAccounts = value
            case .failure(let failure):
                await finishSync(.failure(failure), fingerprint)
                return
            }
            let synchronizedFingerprint = LinuxDevboxMonitor.credentialSyncFingerprint(
                accounts: synchronizedAccounts
            )
            if LinuxDevboxMonitor.credentialStateEvidenceMatches(
                accounts: synchronizedAccounts,
                observed: baseline
            ) {
                await finishSync(
                    .success("credentials already converged"),
                    synchronizedFingerprint
                )
                return
            }

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
                await finishSync(.failure(failure), synchronizedFingerprint)
                return
            }

            do {
                try journal.begin(operation)
            } catch {
                await finishSync(
                    .failure(LinuxDevboxMonitorFailure(
                        message: "Credential-sync journal could not be committed; no remote mutation was attempted: \(error.localizedDescription)",
                        credentialSyncDisposition: .rejected
                    )),
                    synchronizedFingerprint
                )
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

            await finishSync(result, synchronizedFingerprint)
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
             "authority-reconciliation",
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

    nonisolated static func linuxDevboxCredentialSyncProviderAccountId(
        authorityObservation: PoolAuthorityObservation?,
        observedRemoteProviderAccountId: String,
        now: Date
    ) -> String {
        guard let authorityObservation,
              authorityObservation.phase == .stable,
              authorityObservation.isFresh(at: now),
              authorityObservation.desiredProviderAccountId
                == observedRemoteProviderAccountId else {
            return observedRemoteProviderAccountId
        }
        return authorityObservation.desiredProviderAccountId
    }

    nonisolated static func linuxDevboxCredentialSyncThrottleInterval(for context: String) -> TimeInterval {
        switch context {
        case "quota-primed",
             "quota-update",
             "reset-consumed",
             "subscription-info",
             "authority-reconciliation":
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
                        requestKind: .manual
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
                    guard await persistAccountsSnapshot(
                        context: "add-account",
                        expectedCredentialAuthority: previousAccounts
                    ) else {
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

    private func reconcileQuotaPollingIfNeeded() {
        guard !isExiting, quotaPollingReconciliationTask == nil else { return }
        let expectedAccountIds = Set(accountManager.accounts.lazy
            .filter { !$0.hasHardRuntimeBlock }
            .map(\.id))
        let knownAccountIds = Set(accountManager.accounts.map(\.id))
        let poller = quotaPoller

        quotaPollingReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.quotaPollingReconciliationTask = nil }
            let pollingAccountIds = await poller.pollingAccountIds()
            guard !Task.isCancelled, !self.isExiting else { return }

            for accountId in pollingAccountIds.subtracting(expectedAccountIds) {
                await poller.stopPolling(for: accountId)
            }
            for accountId in expectedAccountIds.subtracting(pollingAccountIds) {
                guard knownAccountIds.contains(accountId) else { continue }
                SwapLog.append(.debug(
                    "POLL_SELF_HEAL_RESTART account=\(accountId.uuidString)"
                ))
                self.startPollingForAccount(accountId)
            }
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
                           account.isRuntimeImmediatelyUsable(at: Date()),
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
        let credentialAuthorityBeforeRefresh = accountManager.accounts
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
                requestKind: .automatic
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
            guard await persistAccountsSnapshot(
                context: "token-refresh",
                expectedCredentialAuthority: credentialAuthorityBeforeRefresh
            ) else { return }
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
            _ = await persistTelemetrySnapshot(context: "token-refresh-failed")
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
            let hasExpiredAvailableCredit = bank?.credits.contains { credit in
                credit.isAvailable && credit.expiresAt.map { $0 <= now } == true
            } ?? false
            let presentation = RateLimitResetInventoryPresentation.resolve(
                availableCount: bank?.availableCount ?? 0,
                nextExpiration: bank?.nextExpiration(at: now),
                inventoryIsFresh: Self.rateLimitResetBankIsFresh(
                    bank,
                    at: now,
                    requiresDecisionEvidence: true
                ),
                inventoryExists: bank != nil,
                inventoryHasExpiredAvailableCredit: hasExpiredAvailableCredit,
                inventoryIsStructurallyValid: bank.map {
                    $0.structurallyValidAvailableCredits(at: now) != nil
                } ?? false,
                isRedeeming: providerAccountId.map {
                    rateLimitResetOperationProviderAccountId == $0
                } ?? false,
                isReconciling: providerAccountId.map {
                    rateLimitResetUnresolvedProviderAccountIds.contains($0)
                        || remoteRateLimitResetUnknownProviderAccountIds.contains($0)
                } ?? false,
                error: rateLimitResetManualErrors[account.id],
                externalHoldUntil: externalRateLimitResetRedemptionBlockedUntil[account.id],
                isRefreshing: rateLimitResetRefreshTasks[account.id] != nil
                    || (providerAccountId.map {
                        remoteRateLimitResetRefreshStartedAt[$0] != nil
                    } ?? false),
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
        let settings = LinuxDevboxMonitor.settings()
        let remoteOwned = settings.usesVPSResetAuthority
        guard !remoteOwned || settings.hasRemoteAuthorityEndpoint else {
            return .blocked(
                "VPS reset authority endpoint is unavailable; local fallback is disabled"
            )
        }
        guard remoteOwned || Self.rateLimitResetJournalAllowsAutomaticRouting(
            isReadable: rateLimitResetJournalStateIsReadable
        ) else {
            return .blocked("Reset journal is unavailable; redemption is paused")
        }
        guard let account = accountManager.accounts.first(where: { $0.id == accountId }) else {
            return .blocked("This account is no longer available")
        }
        let configuredAccount = accountManager.configuredAccount
        let activationState = accountManager.activationState
        let remoteCoordinatorReady = accountManager.poolAuthorityObservation.map {
            $0.isFresh(at: now)
        } ?? false
        let providerAccountId = account.normalizedProviderAccountId ?? ""
        return .resolve(
            state: RateLimitResetCoordinatorState(
                externalHoldStateIsReadable: remoteOwned
                    || externalRateLimitResetHoldStateIsReadable,
                redemptionIsInProgress: rateLimitResetRedemptionTask != nil
                    || rateLimitResetOperationProviderAccountId != nil,
                configuredAccountIsAvailable: remoteOwned
                    ? remoteCoordinatorReady
                    : configuredAccount != nil,
                activationAllowsManualRedemption: remoteOwned
                    ? remoteCoordinatorReady
                    : configuredAccount.map { configured in
                        activationState?.configuredAccountId == configured.id
                            && activationState.map {
                                Self.rateLimitResetActivationStateAllows($0, reason: .manual)
                            } == true
                    } ?? false,
                accountHasUnresolvedAttempt: remoteOwned
                    ? remoteRateLimitResetUnknownProviderAccountIds.contains(providerAccountId)
                    : rateLimitResetUnresolvedProviderAccountIds.contains(providerAccountId),
                externalHoldUntil: remoteOwned
                    ? nil
                    : externalRateLimitResetRedemptionBlockedUntil[accountId],
                localHoldUntil: remoteOwned
                    ? nil
                    : rateLimitResetRedemptionBlockedUntil[accountId]
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
            if LinuxDevboxMonitor.settings().usesVPSResetAuthority {
                checkLinuxDevboxReadiness(force: true)
            } else {
                scheduleRateLimitResetRefresh(for: accountId, force: true)
            }
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
                if LinuxDevboxMonitor.settings().usesVPSResetAuthority {
                    checkLinuxDevboxReadiness(force: true)
                } else {
                    scheduleRateLimitResetRefresh(for: accountId, force: true)
                }
            }
            return
        }

        recordManualRateLimitResetError(nil, for: accountId, reason: .manual)
        let settings = LinuxDevboxMonitor.settings()
        if settings.usesVPSResetAuthority {
            guard settings.hasRemoteAuthorityEndpoint else {
                recordManualRateLimitResetError(
                    "VPS reset authority endpoint is unavailable; local fallback is disabled",
                    for: accountId,
                    reason: .manual
                )
                return
            }
            startRemoteRateLimitResetRedemption(
                account: account,
                settings: settings
            )
            return
        }
        startRateLimitResetRedemption(
            account: account,
            bank: bank,
            reason: .manual
        )
    }

    private func startRemoteRateLimitResetRedemption(
        account: CodexAccount,
        settings: LinuxDevboxMonitorSettings
    ) {
        guard !isExiting,
              let providerAccountId = account.normalizedProviderAccountId else {
            recordManualRateLimitResetError(
                "A stable provider account ID is required",
                for: account.id,
                reason: .manual
            )
            return
        }
        guard rateLimitResetRedemptionTask == nil else {
            recordManualRateLimitResetError(
                "Another reset redemption is already in progress",
                for: account.id,
                reason: .manual
            )
            return
        }

        rateLimitResetOperationProviderAccountId = providerAccountId
        remoteRateLimitResetRefreshStartedAt[providerAccountId] = Date()
        recordManualRateLimitResetError(nil, for: account.id, reason: .manual)
        SwapLog.append(.debug(
            "RESET_REMOTE_REDEMPTION_STARTED account=\(account.email) owner=vps_authority"
        ))
        rateLimitResetRedemptionTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                LinuxDevboxMonitor.redeemReset(
                    settings: settings,
                    providerAccountId: providerAccountId
                )
            }.value
            guard let self else { return }
            self.rateLimitResetOperationProviderAccountId = nil
            self.rateLimitResetRedemptionTask = nil

            switch result {
            case .success(let response):
                self.remoteRateLimitResetUnknownProviderAccountIds.remove(providerAccountId)
                self.recordManualRateLimitResetError(nil, for: account.id, reason: .manual)
                self.accountManager.publishActivationNotice(
                    response.submittedReset
                        ? "VPS redeemed one banked reset for \(account.email); refreshing inventory"
                        : "VPS found no reset to redeem for \(account.email); refreshing inventory"
                )
                SwapLog.append(.debug(
                    "RESET_REMOTE_REDEMPTION_COMPLETED account=\(account.email) submitted=\(response.submittedReset) remaining=\(response.bankedResetsRemaining) owner=vps_authority"
                ))
            case .failure(let failure):
                if failure.disposition == .outcomeUnknown {
                    self.remoteRateLimitResetUnknownProviderAccountIds.insert(providerAccountId)
                } else {
                    self.remoteRateLimitResetRefreshStartedAt[providerAccountId] = nil
                }
                self.recordManualRateLimitResetError(
                    failure.message,
                    for: account.id,
                    reason: .manual
                )
                SwapLog.append(.debug(
                    "RESET_REMOTE_REDEMPTION_FAILED account=\(account.email) disposition=\(String(describing: failure.disposition)) owner=vps_authority"
                ))
            }
            self.checkPoolAuthorityStatus()
            self.checkLinuxDevboxReadiness(force: true)
            self.updatePopoverContent()
        }
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
        let settings = LinuxDevboxMonitor.settings()
        return Self.automaticRateLimitResetRedemptionIsEnabled(
            preferenceEnabled: RateLimitResetSettings.automaticRedemptionEnabled(
                in: .standard
            ),
            externalHoldStateIsReadable: externalRateLimitResetHoldStateIsReadable,
            authorityMode: settings.effectiveResetAuthorityMode
        )
    }

    nonisolated static func automaticRateLimitResetRedemptionIsEnabled(
        preferenceEnabled: Bool,
        externalHoldStateIsReadable: Bool,
        authorityMode: AutomaticRateLimitResetOwner
    ) -> Bool {
        preferenceEnabled
            && externalHoldStateIsReadable
            && automaticRateLimitResetOwner(authorityMode: authorityMode) == .macStandalone
    }

    nonisolated static func automaticRateLimitResetOwner(
        authorityMode: AutomaticRateLimitResetOwner
    ) -> AutomaticRateLimitResetOwner {
        authorityMode
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
    ) async -> RateLimitResetSubmissionObservation {
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
        return RateLimitResetSubmissionObservation(
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
        guard let currentAccount = accountManager.accounts.first(where: { $0.id == accountId }) else {
            rateLimitResetDecisionPending.remove(accountId)
            return
        }
        if rateLimitResetInventoryRefreshIsBlocked(
            for: currentAccount,
            at: now,
            bypassTimedBackoff: force
        ) {
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
        let account = currentAccount

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
                self.rateLimitResetInventoryFailureStates[accountId] = nil
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
                self.recordRateLimitResetInventoryFailure(
                    error,
                    for: account,
                    context: "inventory-refresh"
                )
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

    private func rateLimitResetInventoryRefreshIsBlocked(
        for account: CodexAccount,
        at now: Date,
        bypassTimedBackoff: Bool = false
    ) -> Bool {
        let credentialFingerprint = SwapEngine.completeTokenFingerprint(for: account)
        if let state = rateLimitResetInventoryFailureStates[account.id] {
            if state.decision.waitsForCredentialChange {
                if state.credentialFingerprint == credentialFingerprint {
                    return true
                }
            } else if !bypassTimedBackoff,
                      state.blocksRetry(
                          currentCredentialFingerprint: credentialFingerprint,
                          now: now
                      ) {
                return true
            }
            rateLimitResetInventoryFailureStates[account.id] = nil
            rateLimitResetInventoryRetryAfter[account.id] = nil
        }
        guard !bypassTimedBackoff else { return false }
        return rateLimitResetInventoryRetryAfter[account.id].map { $0 > now } ?? false
    }

    private func recordRateLimitResetInventoryFailure(
        _ error: Error,
        for account: CodexAccount,
        context: String
    ) {
        let serviceError = Self.rateLimitResetServiceError(for: error)
        let liveAccount = accountManager.accounts.first(where: { $0.id == account.id })
            ?? account
        let credentialFingerprint = SwapEngine.completeTokenFingerprint(for: liveAccount)
        let state = RateLimitResetFailurePolicy.updatedState(
            for: serviceError,
            credentialFingerprint: credentialFingerprint,
            previous: rateLimitResetInventoryFailureStates[account.id],
            now: Date()
        )
        rateLimitResetInventoryFailureStates[account.id] = state
        rateLimitResetInventoryRetryAfter[account.id] = state.decision.waitsForCredentialChange
            ? .distantFuture
            : state.decision.retryAt
        rateLimitResetManualErrors[account.id] = serviceError.localizedDescription
        SwapLog.append(.debug(
            "RESET_INVENTORY_FAILED account=\(account.email) context=\(context) classification=\(state.decision.classification.rawValue) failures=\(state.consecutiveFailureCount) waits_for_credentials=\(state.decision.waitsForCredentialChange)"
        ))
    }

    nonisolated static func rateLimitResetServiceError(
        for error: Error
    ) -> RateLimitResetServiceError {
        if let serviceError = error as? RateLimitResetServiceError {
            return serviceError
        }
        if let pollerError = error as? PollerError {
            switch pollerError {
            case .tokenExpired:
                return .httpError(401)
            case .httpError(let statusCode):
                return .httpError(statusCode)
            case .rateLimited:
                return .httpError(429)
            case .invalidResponse, .usageUnavailable, .networkError:
                break
            }
        }
        return .transport(error.localizedDescription)
    }

    private func reconcileRateLimitResetAttempt(
        account: CodexAccount,
        bank: RateLimitResetBank,
        observation suppliedObservation: RateLimitResetSubmissionObservation? = nil,
        source: String
    ) async -> Bool {
        let accountId = account.id
        guard let providerAccountId = account.normalizedProviderAccountId else { return false }
        let quotaAccount = accountManager.accounts.first(where: { $0.id == accountId }) ?? account
        let observation: RateLimitResetSubmissionObservation
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
                guard await persistTelemetrySnapshot(context: "reset-reconciled") else {
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
                rateLimitResetInventoryFailureStates[accountId] = nil
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
        if reason != .manual {
            let settings = LinuxDevboxMonitor.settings()
            guard Self.automaticRateLimitResetOwner(
                authorityMode: settings.effectiveResetAuthorityMode
            ) == .macStandalone else {
                accountManager.publishActivationNotice(
                    "VPS pool authority owns automatic banked resets; awaiting authority update"
                )
                SwapLog.append(.debug(
                    "RESET_AUTOMATIC_REDEMPTION_BLOCKED owner=vps_authority account=\(account.email) reason=\(reason.rawValue)"
                ))
                checkPoolAuthorityStatus()
                updatePopoverContent()
                return
            }
        }
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
                    recordRateLimitResetInventoryFailure(
                        error,
                        for: account,
                        context: "reconciliation-inventory-\(attemptId.uuidString)"
                    )
                }
            case .noCredit, .nothingToReset:
                rateLimitResetUnresolvedProviderAccountIds.remove(providerAccountId)
                rateLimitResetInventoryFailureStates[accountId] = nil
                rateLimitResetInventoryRetryAfter[accountId] = nil
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
                recordRateLimitResetInventoryFailure(
                    error,
                    for: account,
                    context: "redemption-reconciliation"
                )
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
            recordRateLimitResetInventoryFailure(
                error,
                for: account,
                context: "redemption-pre-submission"
            )
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
        guard Self.localRateLimitResetSubmissionIsAuthorized(
                  authorityMode: LinuxDevboxMonitor.settings().effectiveResetAuthorityMode
              ),
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
            recordRateLimitResetInventoryFailure(
                error,
                for: account,
                context: "redemption-revalidation"
            )
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
            recordRateLimitResetInventoryFailure(
                error,
                for: account,
                context: "submission-authorization"
            )
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
            recordRateLimitResetInventoryFailure(
                error,
                for: account,
                context: "submission-journal-authorization"
            )
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
              Self.localRateLimitResetSubmissionIsAuthorized(
                  authorityMode: LinuxDevboxMonitor.settings().effectiveResetAuthorityMode
              ),
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

    nonisolated static func localRateLimitResetSubmissionIsAuthorized(
        authorityMode: AutomaticRateLimitResetOwner
    ) -> Bool {
        authorityMode == .macStandalone
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
            await self.restoreExternalRateLimitResetHolds(at: now)
            guard self.automaticPolicyEvaluationIsCurrent(lease),
                  self.accountManager.configuredAccount?.id == configured.id else {
                return
            }
            self.performRoutineAutomaticPolicyHousekeeping(
                trigger: trigger,
                active: configured,
                now: now
            )
            let mutationDemand = self.automaticPolicyMutationDemand(
                trigger: trigger,
                active: configured,
                now: now
            )
            let trustedUsageIsHealthy = Self.trustedUsageIsHealthy(
                trigger: trigger,
                active: configured,
                now: now
            )
            let permit = await AccountAutomaticPolicyMutationGate
                .requestRuntimeAuthorizationIfNeeded(
                trigger: trigger,
                configuredAccountId: configured.id,
                trustedUsageIsHealthy: trustedUsageIsHealthy,
                demand: mutationDemand,
                request: {
                    await self.requireFreshLocalRuntimePermit(
                        for: configured,
                        activationGeneration: activationGeneration,
                        requiredPhase: .confirmed,
                        policyAuthority: lease.authority
                    )
                }
            )
            guard let permit else {
                self.reportExhaustedPoolWithoutRuntimeRenewalIfNeeded(
                    trigger: trigger,
                    active: configured,
                    demand: mutationDemand,
                    now: now
                )
                return
            }
            guard self.automaticPolicyEvaluationIsCurrent(lease),
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

    private func performRoutineAutomaticPolicyHousekeeping(
        trigger: AccountAutomaticPolicyTrigger,
        active: CodexAccount,
        now: Date
    ) {
        guard case .routine = trigger else { return }
        let decision = AccountAutomaticPolicyRoutineHousekeepingDecision.evaluate(
            activeAccountId: active.id,
            activeNeedsRelief: active.needsQuotaRelief(at: now),
            manualOverrideAccountId: manualOverrideAccountId,
            recoveryUntil: rateLimitResetRecoveryUntil[active.id],
            now: now
        )
        if decision.clearExpiredRecovery {
            rateLimitResetRecoveryUntil[active.id] = nil
        }
        if decision.clearManualOverride {
            clearManualOverride()
        }
        if decision.markPoolRecovered {
            exhaustedPoolAlertGate.markRecovered()
        }
    }

    private func automaticPolicyMutationDemand(
        trigger: AccountAutomaticPolicyTrigger,
        active: CodexAccount,
        now: Date
    ) -> AccountAutomaticPolicyMutationDemand {
        switch trigger {
        case .usageUnavailable(let accountId):
            guard active.id == accountId else { return .none }
            return AccountAutomaticPolicyMutationDemand(
                hasResetRedemption: false,
                needsResetInventoryRefresh: false,
                hasPlanUpgrade: SwapEngine.selectPlanUpgradeCandidate(
                    active: active,
                    from: accountManager.accounts,
                    now: now
                ) != nil,
                hasAccountSwap: SwapEngine.selectAutoSwapCandidate(
                    from: accountManager.accounts,
                    now: now
                ) != nil
            )
        case .tokenInvalidated(let accountId):
            guard active.id == accountId else { return .none }
            return AccountAutomaticPolicyMutationDemand(
                hasResetRedemption: false,
                needsResetInventoryRefresh: false,
                hasPlanUpgrade: false,
                hasAccountSwap: SwapEngine.selectAutoSwapCandidate(
                    from: accountManager.accounts,
                    now: now
                ) != nil
            )
        case .routine:
            guard rateLimitResetOperationProviderAccountId == nil,
                  rateLimitResetDecisionPending.isEmpty else {
                return .none
            }

            let activeNeedsRelief = active.needsQuotaRelief(at: now)
            let manualOverrideActive = SwapEngine.shouldHonorManualOverride(
                activeAccountId: active.id,
                manualOverrideAccountId: manualOverrideAccountId,
                activeNeedsRelief: activeNeedsRelief
            )
            var hasResetRedemption = false
            var needsResetInventoryRefresh = false
            if automaticRateLimitResetRedemptionEnabled {
                hasResetRedemption = RateLimitResetPolicy.selectRedemptionCandidate(
                    from: accountManager.accounts,
                    excluding: automaticRateLimitResetExcludedAccountIds(at: now),
                    now: now
                ) != nil

                let activeRedemptionBlocked = Self.rateLimitResetRedemptionIsBlocked(
                    until: rateLimitResetRedemptionBlockedUntil[active.id],
                    at: now
                ) || Self.rateLimitResetRedemptionIsBlocked(
                    until: externalRateLimitResetRedemptionBlockedUntil[active.id],
                    at: now
                )
                let activeInventoryBlocked = rateLimitResetInventoryRefreshIsBlocked(
                    for: active,
                    at: now
                )
                needsResetInventoryRefresh = activeNeedsRelief
                    && !activeRedemptionBlocked
                    && !activeInventoryBlocked
                    && !Self.rateLimitResetBankIsFresh(
                        active.rateLimitResetBank,
                        at: now,
                        requiresDecisionEvidence: true
                    )
            }

            let resetSwapExclusions = activeManualRateLimitResetSwapExclusions(at: now)
            let hasPlanUpgrade = !manualOverrideActive
                && SwapEngine.selectPlanUpgradeCandidate(
                    active: active,
                    from: accountManager.accounts,
                    excluding: resetSwapExclusions,
                    now: now
                ) != nil
            let hasAccountSwap = active.realQuotaSnapshot != nil
                && activeNeedsRelief
                && SwapEngine.selectAutoSwapCandidate(
                    from: accountManager.accounts,
                    now: now
                ) != nil
            return AccountAutomaticPolicyMutationDemand(
                hasResetRedemption: hasResetRedemption,
                needsResetInventoryRefresh: needsResetInventoryRefresh,
                hasPlanUpgrade: hasPlanUpgrade,
                hasAccountSwap: hasAccountSwap
            )
        }
    }

    nonisolated private static func trustedUsageIsHealthy(
        trigger: AccountAutomaticPolicyTrigger,
        active: CodexAccount,
        now: Date
    ) -> Bool {
        guard case .usageUnavailable(let accountId) = trigger,
              active.id == accountId,
              let snapshot = active.realQuotaSnapshot else {
            return false
        }
        return active.isRuntimeImmediatelyUsable(at: now)
            && snapshot.isImmediatelyUsable
    }

    private func reportExhaustedPoolWithoutRuntimeRenewalIfNeeded(
        trigger: AccountAutomaticPolicyTrigger,
        active: CodexAccount,
        demand: AccountAutomaticPolicyMutationDemand,
        now: Date
    ) {
        guard case .routine = trigger,
              !demand.hasActionableMutation,
              rateLimitResetOperationProviderAccountId == nil,
              rateLimitResetDecisionPending.isEmpty,
              active.realQuotaSnapshot != nil,
              active.needsQuotaRelief(at: now),
              SwapEngine.selectAutoSwapCandidate(
                  from: accountManager.accounts,
                  now: now
              ) == nil else {
            return
        }
        if exhaustedPoolAlertGate.shouldNotifyNoCandidate() {
            NotificationManager.notifyAllExhausted(
                nextReset: SwapEngine.earliestUsableReset(
                    from: accountManager.accounts,
                    now: now
                )
            )
            SwapLog.append(.debug(
                "AUTO_SWAP_NO_READY_CANDIDATE active=\(active.email) notified=true runtime_renewal=false"
            ))
        } else {
            SwapLog.append(.debug(
                "AUTO_SWAP_NO_READY_CANDIDATE active=\(active.email) notified=false runtime_renewal=false"
            ))
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
        guard let active = accountManager.configuredAccount else { return }
        switch trigger {
        case .routine:
            break
        case .usageUnavailable(let accountId):
            guard active.id == accountId else { return }
            if let snapshot = active.realQuotaSnapshot,
               active.isRuntimeImmediatelyUsable(at: now),
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
        guard rateLimitResetOperationProviderAccountId == nil,
              rateLimitResetDecisionPending.isEmpty else {
            return
        }

        let activeSnapshot = active.realQuotaSnapshot
        let activeNeedsRelief = active.needsQuotaRelief(at: now)

        let manualOverrideActive = SwapEngine.shouldHonorManualOverride(
            activeAccountId: active.id,
            manualOverrideAccountId: manualOverrideAccountId,
            activeNeedsRelief: activeNeedsRelief
        )

        if automaticRateLimitResetRedemptionEnabled {
            let excludedAccountIds = automaticRateLimitResetExcludedAccountIds(at: now)

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
            let activeInventoryBlocked = rateLimitResetInventoryRefreshIsBlocked(
                for: active,
                at: now
            )
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

    private func automaticRateLimitResetExcludedAccountIds(
        at now: Date
    ) -> Set<UUID> {
        Set(accountManager.accounts.compactMap { account -> UUID? in
            let redemptionBlocked = Self.rateLimitResetRedemptionIsBlocked(
                until: rateLimitResetRedemptionBlockedUntil[account.id],
                at: now
            )
            let externalRedemptionBlocked = Self.rateLimitResetRedemptionIsBlocked(
                until: externalRateLimitResetRedemptionBlockedUntil[account.id],
                at: now
            )
            let inventoryBlocked = rateLimitResetInventoryRefreshIsBlocked(
                for: account,
                at: now
            )
            let recovering = rateLimitResetRecoveryUntil[account.id]
                .map { $0 > now } ?? false
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
        requestKind: AccountActivationRequestKind,
        verifiedExternalAuthConflictRecovery: Bool = false,
        policyAuthority: AccountAutomaticPolicyAuthority? = nil,
        operationAuthority: PoolAuthorityOperationAuthority? = nil,
        operation: @escaping @MainActor @Sendable (PreparedAccountActivation) async -> Bool
    ) async -> Bool {
        guard !isExiting,
              policyAuthority?.authorizes() ?? true,
              operationAuthority?.authorizes() ?? true else {
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
                  policyAuthority?.authorizes() ?? true,
                  operationAuthority?.authorizes() ?? true else {
                return ScopedAccountActivationResult.blocked
            }
            switch await self.prepareActiveCredentialMutation(
                targetAccountId: targetAccountId,
                expectedConfiguredAccountId: expectedConfiguredAccountId,
                source: source,
                requestKind: requestKind,
                verifiedExternalAuthConflictRecovery: verifiedExternalAuthConflictRecovery,
                activationGeneration: activationGeneration,
                lease: lease,
                policyAuthority: policyAuthority,
                operationAuthority: operationAuthority
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
            if requestKind.permitsOperatorRecovery,
               let target = accountManager.accounts.first(where: { $0.id == targetAccountId }) {
                return await startSameTargetRuntimeRetry(
                    to: target,
                    source: requestKind == .poolAuthority ? "pool-authority" : "manual",
                    operationAuthority: operationAuthority
                )
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
        requestKind: AccountActivationRequestKind,
        verifiedExternalAuthConflictRecovery: Bool,
        activationGeneration: UUID,
        lease: AccountMutationLease,
        policyAuthority: AccountAutomaticPolicyAuthority? = nil,
        operationAuthority: PoolAuthorityOperationAuthority? = nil
    ) async -> AccountActivationPreparationResult {
        guard !isExiting,
              policyAuthority?.authorizes() ?? true,
              operationAuthority?.authorizes() ?? true,
              accountManager.configuredAccount?.id == expectedConfiguredAccountId,
              await accountMutationTransaction.owns(lease) else {
            accountManager.publishActivationNotice(
                "Configured account changed before activation could begin"
            )
            return .blocked
        }

        do {
            let authorizeEffect: AccountActivationCoordinator.StateEffectAuthorization = {
                [accountMutationTransaction] _ in
                    (policyAuthority?.authorizes() ?? true)
                        && (operationAuthority?.authorizes() ?? true)
                        && accountMutationTransaction.leaseAuthorizes(
                            lease,
                            targetAccountId: targetAccountId,
                            activationGeneration: activationGeneration
                        )
            }
            let decision: AccountActivationCredentialMutationDecision
            if verifiedExternalAuthConflictRecovery,
               let expectedConfiguredAccountId {
                decision = try await accountActivationCoordinator
                    .beginVerifiedExternalAuthConflictRecovery(
                        targetAccountId: targetAccountId,
                        durableSourceAccountId: expectedConfiguredAccountId,
                        requestedActivationGeneration: activationGeneration,
                        authorizeEffect: authorizeEffect
                    )
            } else {
                decision = try await accountActivationCoordinator
                    .beginAuthorizedCredentialMutation(
                        targetAccountId: targetAccountId,
                        kind: requestKind,
                        requestedActivationGeneration: activationGeneration,
                        authorizeEffect: authorizeEffect
                    )
            }
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
                    && (operationAuthority?.authorizes() ?? true)
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
        let linuxSettings = LinuxDevboxMonitor.settings()
        if Self.swapRequiresRemoteAuthority(linuxSettings) {
            executeRemoteFirstSwap(
                from: from,
                to: to,
                reason: reason,
                settings: linuxSettings,
                automaticPermit: automaticPermit,
                automaticPolicyLease: automaticPolicyLease
            )
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
                requestKind: isManual ? .manual : .automatic,
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

    private func executeRemoteFirstSwap(
        from: CodexAccount,
        to: CodexAccount,
        reason: SwapEvent.SwapReason,
        settings: LinuxDevboxMonitorSettings,
        automaticPermit: AccountActivationRuntimePermit?,
        automaticPolicyLease: AccountAutomaticPolicyLease?
    ) {
        guard !poolAuthorityRequestInFlight else {
            accountManager.publishActivationNotice(
                "VPS pool authority is already processing an account request"
            )
            return
        }
        guard let targetProviderAccountId = to.normalizedProviderAccountId else {
            accountManager.publishActivationNotice(
                "Target account has no stable provider identity"
            )
            return
        }
        if reason != .manual {
            guard let automaticPermit,
                  let automaticPolicyLease,
                  automaticPolicyEvaluationIsCurrent(automaticPolicyLease),
                  automaticPolicyLease.authority.authorizes(),
                  automaticPermit.targetAccountId == from.id,
                  automaticPermit.authorizes(
                      state: accountManager.activationState,
                      at: Date()
                  ),
                  accountManager.configuredAccount?.id == from.id else {
                return
            }
        }

        poolAuthorityRequestInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.poolAuthorityRequestInFlight = false }

            let baselineResult = await Task.detached(priority: .utility) {
                LinuxDevboxMonitor.fetchPoolAuthorityStatus(settings: settings)
            }.value
            let knownProviderAccountIds = self.accountManager.accounts.compactMap(
                \.normalizedProviderAccountId
            )
            let baseline = try? baselineResult.get()
            let remoteFirstDecision = self.poolAuthorityClientState.remoteFirstDecision(
                observation: baseline,
                targetProviderAccountId: targetProviderAccountId,
                knownProviderAccountIds: knownProviderAccountIds,
                now: Date()
            )

            let acceptedObservation: PoolAuthorityObservation
            switch remoteFirstDecision {
            case .adoptExisting(let baseline):
                acceptedObservation = baseline
            case .requestRequired(let baseline):
                let request: PoolAuthorityRequest
                do {
                    request = try PoolAuthorityRequest(
                        selector: targetProviderAccountId,
                        requestId: UUID().uuidString.lowercased(),
                        expectedEpoch: baseline.epoch,
                        reason: reason.rawValue
                    )
                } catch {
                    self.failClosedPoolAuthoritySwap(
                        "VPS pool authority request is invalid; Mac credentials were not changed"
                    )
                    return
                }
                let requestResult = await Task.detached(priority: .utility) {
                    LinuxDevboxMonitor.requestPoolTarget(
                        settings: settings,
                        request: request,
                        requiresEpochAdvance: true
                    )
                }.value
                guard case .success(let resolution) = requestResult else {
                    self.failClosedPoolAuthoritySwap(
                        "VPS pool authority did not confirm the requested account; Mac credentials were not changed"
                    )
                    return
                }
                acceptedObservation = resolution.observation
            case .failClosed(let detail):
                self.failClosedPoolAuthoritySwap(
                    "VPS pool authority is unavailable or contradictory (\(detail)); Mac credentials were not changed"
                )
                return
            }

            if reason != .manual {
                guard let automaticPermit,
                      let automaticPolicyLease,
                      self.automaticPolicyEvaluationIsCurrent(automaticPolicyLease),
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
            self.handlePoolAuthorityObservation(
                acceptedObservation,
                permitsConverging: true,
                automaticPolicyLease: reason == .manual ? nil : automaticPolicyLease
            )
        }
    }

    nonisolated static func swapRequiresRemoteAuthority(
        _ settings: LinuxDevboxMonitorSettings
    ) -> Bool {
        settings.hasRemoteAuthorityEndpoint
    }

    private func failClosedPoolAuthoritySwap(_ message: String) {
        accountManager.publishActivationNotice(message)
        SwapLog.append(.debug("POOL_AUTHORITY_SWAP_BLOCKED message=\(message)"))
        updatePopoverContent()
    }

    private func handlePoolAuthorityObservation(
        _ observation: PoolAuthorityObservation,
        permitsConverging: Bool,
        automaticPolicyLease: AccountAutomaticPolicyLease? = nil
    ) {
        let now = Date()
        let configuredAccount = accountManager.configuredAccount
        let operationWitness = poolAuthorityOperationAuthority
        let runtimeRemainsConfirmedForObservation =
            configuredAccount?.normalizedProviderAccountId
                == observation.desiredProviderAccountId
            && configuredAccount.map {
                let activationState = accountManager.activationState
                return activationState?.phase == .confirmed
                    && activationState?.configuredAccountId == $0.id
                    && activationState?.runtimeCurrentAccountId == $0.id
            } == true
        let runtimeConvergedForObservation =
            runtimeRemainsConfirmedForObservation
            && configuredAccount.map {
                accountManager.activationState?.runtimeIsCurrent(
                    for: $0.id,
                    at: now
                ) == true
            } == true
            && operationWitness?.epoch == observation.epoch
            && operationWitness?.providerAccountId
                == observation.desiredProviderAccountId
            && operationWitness?.authorizes() == true
        let knownProviderAccountIds = accountManager.accounts.compactMap(
            \.normalizedProviderAccountId
        )
        let decision = LinuxDevboxMonitor.poolAuthorityAdoptionDecision(
            state: &poolAuthorityClientState,
            observation: observation,
            localProviderAccountId: configuredAccount?
                .normalizedProviderAccountId,
            runtimeConvergedForObservation: runtimeConvergedForObservation,
            runtimeRemainsConfirmedForObservation:
                runtimeRemainsConfirmedForObservation,
            knownProviderAccountIds: knownProviderAccountIds,
            permitsConverging: permitsConverging,
            now: now
        )
        if case .rejected = decision {
            // Invalid observations never become presentation authority.
        } else {
            accountManager.publishPoolAuthorityObservation(observation)
        }
        guard case .adopt = decision,
              let target = accountManager.accounts.first(where: {
                  $0.normalizedProviderAccountId
                      == observation.desiredProviderAccountId
              }) else {
            if case .rejected(let reason) = decision {
                SwapLog.append(.debug(
                    "POOL_AUTHORITY_OBSERVATION_REJECTED epoch=\(observation.epoch) reason=\(reason)"
                ))
            }
            return
        }

        if let current = poolAuthorityOperationAuthority,
           observation.epoch > current.epoch {
            current.revoke()
        }
        let operationAuthority = PoolAuthorityOperationAuthority(
            epoch: observation.epoch,
            providerAccountId: observation.desiredProviderAccountId,
            expiresAt: observation.observedAt.addingTimeInterval(
                PoolAuthorityObservation.maximumFreshnessAge
            )
        )
        poolAuthorityOperationAuthority = operationAuthority

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            guard operationAuthority.authorizes() else {
                self.poolAuthorityClientState.finishAdoption(
                    epoch: observation.epoch,
                    succeeded: false,
                    at: Date()
                )
                return
            }
            let recoversExternalAuthConflict =
                self.accountManager.activationState?.phase == .manualReview
                && self.accountManager.activationState?.detail == .externalAuthConflict
            let adoptionTarget: CodexAccount
            if recoversExternalAuthConflict {
                guard let observedTarget = await self
                    .externalAuthConflictAuthorityTarget(
                        storedTarget: target,
                        observation: observation,
                        operationAuthority: operationAuthority
                    ) else {
                    self.poolAuthorityClientState.finishAdoption(
                        epoch: observation.epoch,
                        succeeded: false,
                        at: Date()
                    )
                    SwapLog.append(.debug(
                        "POOL_AUTHORITY_EXTERNAL_AUTH_RECOVERY_BLOCKED reason=observed_target_generation"
                    ))
                    return
                }
                adoptionTarget = observedTarget
            } else {
                adoptionTarget = target
            }
            let from: CodexAccount
            if let configured = self.accountManager.configuredAccount {
                from = configured
            } else if recoversExternalAuthConflict,
                      let durableSource = await self
                        .restoreDurableExternalAuthConflictSource(
                            target: adoptionTarget,
                            operationAuthority: operationAuthority
                        ) {
                from = durableSource
            } else {
                self.poolAuthorityClientState.finishAdoption(
                    epoch: observation.epoch,
                    succeeded: false,
                    at: Date()
                )
                SwapLog.append(.debug(
                    "POOL_AUTHORITY_ADOPTION_BLOCKED reason=configured_source_unavailable"
                ))
                return
            }
            if recoversExternalAuthConflict {
                let recoveryDecision = await self
                    .poolAuthorityExternalAuthConflictRecoveryDecision(
                        observation: observation,
                        from: from,
                        to: adoptionTarget,
                        operationAuthority: operationAuthority
                    )
                guard recoveryDecision == .recover else {
                    self.poolAuthorityClientState.finishAdoption(
                        epoch: observation.epoch,
                        succeeded: false,
                        at: Date()
                    )
                    SwapLog.append(.debug(
                        "POOL_AUTHORITY_EXTERNAL_AUTH_RECOVERY_BLOCKED reason=\(String(describing: recoveryDecision))"
                    ))
                    return
                }
            }
            let succeeded = await self.withPreparedActiveCredentialMutation(
                targetAccountId: adoptionTarget.id,
                expectedConfiguredAccountId: from.id,
                source: "pool-authority",
                requestKind: .poolAuthority,
                verifiedExternalAuthConflictRecovery: recoversExternalAuthConflict,
                policyAuthority: automaticPolicyLease?.authority,
                operationAuthority: operationAuthority
            ) { [weak self] prepared in
                guard let self, operationAuthority.authorizes() else {
                    return false
                }
                return await self.executeSwapTransaction(
                    from: from,
                    to: adoptionTarget,
                    reason: .poolAuthority,
                    swapStart: Date(),
                    prepared: prepared,
                    verifiedExternalAuthConflictRecovery: recoversExternalAuthConflict,
                    operationAuthority: operationAuthority
                )
            }
            self.poolAuthorityClientState.finishAdoption(
                epoch: observation.epoch,
                succeeded: succeeded,
                at: Date()
            )
        }
    }

    private func externalAuthConflictAuthorityTarget(
        storedTarget: CodexAccount,
        observation: PoolAuthorityObservation,
        operationAuthority: PoolAuthorityOperationAuthority
    ) async -> CodexAccount? {
        guard operationAuthority.authorizes() else { return nil }
        let authObservation = await Task.detached(priority: .userInitiated) {
            AccountImporter.observeCurrentAccount(from: Self.codexAuthPath)
        }.value
        guard operationAuthority.authorizes(),
              case .valid(let observedAuth) = authObservation else {
            return nil
        }
        return ExternalAuthConflictRecoveryPolicy.authorityTarget(
            storedTarget: storedTarget,
            observedAuth: observedAuth,
            authorityProviderAccountId: observation.desiredProviderAccountId,
            now: Date()
        )
    }

    private func restoreDurableExternalAuthConflictSource(
        target: CodexAccount,
        operationAuthority: PoolAuthorityOperationAuthority
    ) async -> CodexAccount? {
        guard operationAuthority.authorizes(),
              accountManager.activationState?.phase == .manualReview,
              accountManager.activationState?.detail == .externalAuthConflict,
              accountManager.configuredAccount == nil else {
            return nil
        }

        do {
            let durableAccounts = try await accountPersistence.loadAll()
            guard operationAuthority.authorizes(),
                  let source = ExternalAuthConflictRecoveryPolicy.durableSource(
                      durableAccounts: durableAccounts,
                      inMemoryAccounts: accountManager.accounts,
                      targetAccountId: target.id
                  ) else {
                return nil
            }
            accountManager.setConfiguredAccount(source.id)
            guard operationAuthority.authorizes(),
                  accountManager.configuredAccount?.id == source.id,
                  Self.accountStoreMatches(
                      account: source,
                      accounts: durableAccounts
                  ) else {
                return nil
            }
            SwapLog.append(.debug(
                "POOL_AUTHORITY_DURABLE_SOURCE_RESTORED source=\(source.id.uuidString) target=\(target.id.uuidString)"
            ))
            return accountManager.configuredAccount
        } catch {
            SwapLog.append(.debug(
                "POOL_AUTHORITY_DURABLE_SOURCE_READ_FAILED error=\(error.localizedDescription)"
            ))
            return nil
        }
    }

    private func poolAuthorityExternalAuthConflictRecoveryDecision(
        observation: PoolAuthorityObservation,
        from source: CodexAccount,
        to target: CodexAccount,
        operationAuthority: PoolAuthorityOperationAuthority
    ) async -> ExternalAuthConflictRecoveryDecision {
        let matchingProviderAccountCount = accountManager.accounts.filter {
            $0.normalizedProviderAccountId == observation.desiredProviderAccountId
        }.count
        let durableStoreMatchesSource = await durableAccountStoreMatches(source)
        let authMatchesTarget = Self.authFileMatches(
            account: target,
            atPath: Self.codexAuthPath
        )
        let rustHandoffDisposition = RustActivationJournal.handoffDisposition(
            for: target
        )
        return ExternalAuthConflictRecoveryPolicy.decision(
            ExternalAuthConflictRecoveryEvidence(
                activationState: accountManager.activationState,
                sourceAccountId: source.id,
                targetAccountId: target.id,
                authorityProviderAccountId: observation.desiredProviderAccountId,
                targetProviderAccountId: target.normalizedProviderAccountId,
                matchingProviderAccountCount: matchingProviderAccountCount,
                authorityIsFresh: observation.isFresh(at: Date()),
                authorityOperationIsAuthorized: operationAuthority.authorizes()
                    && operationAuthority.epoch == observation.epoch
                    && operationAuthority.providerAccountId
                        == observation.desiredProviderAccountId,
                durableStoreMatchesSource: durableStoreMatchesSource,
                authMatchesTarget: authMatchesTarget,
                rustHandoffDisposition: rustHandoffDisposition
            )
        )
    }

    private func executeSwapTransaction(
        from: CodexAccount,
        to: CodexAccount,
        reason: SwapEvent.SwapReason,
        swapStart: Date,
        prepared: PreparedAccountActivation,
        verifiedExternalAuthConflictRecovery: Bool = false,
        operationAuthority: PoolAuthorityOperationAuthority? = nil
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
        if verifiedExternalAuthConflictRecovery {
            mutationRoute = .externalAuthObservation
        } else if case .higherPlanAvailable = reason {
            mutationRoute = .planUpgrade
        } else {
            mutationRoute = .swap
        }

        return await commitConfiguredCredentialMutation(
            from: from,
            to: to,
            reason: reason,
            mutationRoute: mutationRoute,
            persistenceContext: verifiedExternalAuthConflictRecovery
                ? "pool-authority-external-auth-recovery"
                : "swap",
            authAlreadyConfigured: verifiedExternalAuthConflictRecovery,
            swapStart: swapStart,
            prepared: prepared,
            recordsSwap: true,
            committedDetail: verifiedExternalAuthConflictRecovery
                ? .externalAuthObserved
                : .runtimeConfirmationPending,
            operationAuthority: operationAuthority
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
            durableConfiguredTargetMatches =
                await durableAccountStoreHasNoConfiguredAccount()
                && (!authAlreadyConfigured
                    || Self.authFileMatches(
                        account: to,
                        atPath: Self.codexAuthPath
                    ))
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
        committedDetail: AccountActivationDetail = .runtimeConfirmationPending,
        operationAuthority: PoolAuthorityOperationAuthority? = nil
    ) async -> Bool {
        let publicationBuffer = ConfiguredCredentialPublicationBuffer()
        let expectedCredentialAuthority = accountManager.accounts
        let result = await accountMutationTransaction.commitConfiguredCredentials(
            AccountActivationCommitOperations(
                authorizeMutation: { [weak self] in
                    guard let self,
                          operationAuthority?.authorizes() ?? true else { return nil }
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
                          operationAuthority?.authorizes() ?? true,
                          permit.authorizes(
                              state: self.accountManager.activationState,
                              at: Date()
                          ),
                          AccountManager.configuredCredentialSnapshot(
                              from: self.accountManager.accounts,
                              applying: to
                          ) != nil
                    else {
                        return false
                    }
                    return true
                },
                authorizePreparingEffect: { [weak self] in
                    guard let self,
                          operationAuthority?.authorizes() ?? true else { return nil }
                    let configuredAccountId =
                        self.accountManager.configuredAccount?.id
                    guard configuredAccountId
                            == prepared.expectedConfiguredAccountId
                            || configuredAccountId == to.id else {
                        return nil
                    }
                    return await self.activationEffectPermit(
                        prepared,
                        targetAccountId: to.id,
                        requiredPhase: .preparing,
                        configuredAccountId: configuredAccountId
                    )
                },
                persistAccountStore: { [weak self] permit in
                    guard let self,
                          operationAuthority?.authorizes() ?? true else { return false }
                    guard let configuredCredentialSnapshot =
                            AccountManager.configuredCredentialSnapshot(
                                from: expectedCredentialAuthority,
                                applying: to
                            ),
                          let persisted =
                            await self.persistAuthorizedAccountsSnapshot(
                                configuredCredentialSnapshot,
                                context: persistenceContext,
                                expectedCredentialAuthority: expectedCredentialAuthority,
                                permit: permit
                            ) else {
                        return false
                    }
                    publicationBuffer.persistedAccounts = persisted
                    return true
                },
                persistAuth: { [weak self] permit in
                    guard let self,
                          operationAuthority?.authorizes() ?? true else { return false }
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
                    guard let self,
                          operationAuthority?.authorizes() ?? true,
                          permit.isCurrentlyAuthorized() else { return false }
                    let matches = await self.durableConfiguredFilesMatch(to)
                    return matches && permit.isCurrentlyAuthorized()
                },
                publishConfiguredCredentials: { [weak self] permit in
                    guard let self,
                          operationAuthority?.authorizes() ?? true,
                          permit.isCurrentlyAuthorized(),
                          let persistedCredentialSnapshot = publicationBuffer.persistedAccounts,
                          self.accountManager.adoptVerifiedCommittedCredentialHandoff(
                              persistedCredentialSnapshot,
                              expectedCredentialAuthority: expectedCredentialAuthority,
                              targetAccountId: to.id
                          ) else {
                        return false
                    }
                    CLIStatusChecker.invalidateForAccountSwap()
                    self.accountManager.clearPollingError(for: to.id)
                    self.scheduleLinuxDevboxCredentialSyncIfNeeded(
                        context: persistenceContext
                    )
                    return true
                },
                markCommittedDegraded: { [weak self] permit in
                    guard let self,
                          operationAuthority?.authorizes() ?? true else { return false }
                    do {
                        let degraded = try await self.accountActivationCoordinator
                            .markCommittedDegraded(
                                targetAccountId: to.id,
                                expectedActivationGeneration: prepared.activationGeneration,
                                discoveredRuntimeCount: 0,
                                acknowledgedRuntimeCount: 0,
                                detail: committedDetail,
                                authorizeEffect: { state in
                                    (operationAuthority?.authorizes() ?? true)
                                        && permit.authorizes(state: state, at: Date())
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
                    guard let self,
                          operationAuthority?.authorizes() ?? true else { return nil }
                    return await self.activationEffectPermit(
                        prepared,
                        targetAccountId: to.id,
                        requiredPhase: .committedDegraded,
                        configuredAccountId: to.id
                    )
                },
                convergeRuntime: { [weak self] permit in
                    guard let self,
                          operationAuthority?.authorizes() ?? true,
                          permit.isCurrentlyAuthorized() else { return false }
                    await self.beginRuntimeConvergence(
                        from: from,
                        to: to,
                        reason: reason,
                        swapStart: swapStart,
                        prepared: prepared,
                        recordsSwap: recordsSwap,
                        operationAuthority: operationAuthority
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
        recordsSwap: Bool,
        operationAuthority: PoolAuthorityOperationAuthority? = nil
    ) async {
        guard operationAuthority?.authorizes() ?? true else {
            await abandonSwapRuntimeConvergence(
                prepared: prepared,
                targetAccountId: to.id
            )
            return
        }
        startPollingForAccount(to.id)
        statusBarController.updateIcon()
        updatePopoverContent()
        CLIStatusChecker.refresh(activeAccountId: to.accountId) { [weak self] in
            self?.updatePopoverContent()
        }

        // Runtime convergence must inherit the cross-process lease task-local.
        let convergenceTask = Task(priority: .userInitiated) { [weak self] in
            let shouldStartReload = await self?.activationWorkIsCurrent(
                prepared,
                targetAccountId: to.id,
                operationAuthority: operationAuthority
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
                        targetAccountId: to.id,
                        operationAuthority: operationAuthority
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
            case .reloaded(let method, _, _, _):
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
                recordsSwap: recordsSwap,
                operationAuthority: operationAuthority
            )
        }
        swapConvergenceTask = convergenceTask
        await convergenceTask.value
    }

    private func activationWorkIsCurrent(
        _ prepared: PreparedAccountActivation,
        targetAccountId: UUID,
        operationAuthority: PoolAuthorityOperationAuthority? = nil
    ) async -> Bool {
        guard operationAuthority?.authorizes() ?? true else {
            return false
        }
        return AccountActivationOperationProof(
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

    nonisolated static func externalHandoffFollowUp(
        state: AccountActivationState?,
        configuredAccountId: UUID?,
        observedTargetAccountId: UUID
    ) -> ExternalHandoffFollowUp {
        guard let state else { return .none }
        if state.configuredAccountId != observedTargetAccountId {
            return .adopt
        }
        if state.phase == .committedDegraded,
           state.detail == .externalAuthObserved,
           configuredAccountId == observedTargetAccountId {
            return .retryRuntime
        }
        return .none
    }

    nonisolated static func externalHandoffFinalObservationIsTransient(
        _ observation: AccountAuthObservation
    ) -> Bool {
        switch observation {
        case .invalid(let reason):
            return reason.isRetryableObservationFailure
        case .unreadable:
            return true
        case .valid, .absent:
            return false
        }
    }

    nonisolated static func externalHandoffFinalStoreErrorIsTransient(
        _ error: Error
    ) -> Bool {
        if error as? AccountPersistenceCoordinatorError == .authorizationLost {
            return true
        }
        guard let keychainError = error as? KeychainError else { return false }
        switch keychainError {
        case .lockTimedOut, .staleGeneration, .runtimeActivationLeaseUnavailable:
            return true
        case .lockFailed(_, _, let code), .fileOperationFailed(_, _, let code):
            return code == EINTR
                || code == EAGAIN
                || code == EBUSY
                || code == ESTALE
        case .saveFailed, .loadFailed, .deleteFailed,
             .duplicateAccountId, .duplicateLocalId, .missingAccountId,
             .missingLocalId, .invalidLegacyCredentialResult,
             .invalidActiveAccountCount, .unsafePath, .readbackMismatch:
            return false
        }
    }

    nonisolated static func verifiedExternalHandoffTarget(
        accounts: [CodexAccount],
        authObservation: AccountAuthObservation
    ) -> CodexAccount? {
        guard case .valid(let observed) = authObservation,
              let target = accounts.first(where: \.isActive),
              accountStoreMatches(account: target, accounts: accounts),
              credentialsMatch(target, observed) else {
            return nil
        }
        return target
    }

    private func beginSameTargetRuntimeRetry(to target: CodexAccount, source: String) {
        guard !isExiting else { return }
        Task { @MainActor [weak self] in
            await self?.startSameTargetRuntimeRetry(to: target, source: source)
        }
    }

    @discardableResult
    private func startSameTargetRuntimeRetry(
        to target: CodexAccount,
        source: String,
        operationAuthority: PoolAuthorityOperationAuthority? = nil
    ) async -> Bool {
        guard !isExiting,
              operationAuthority?.authorizes() ?? true,
              swapConvergenceTask == nil,
              pendingSwapTargetAccountId == nil,
              accountManager.configuredAccount?.id == target.id,
              accountManager.activationState?.configuredAccountId == target.id else {
            return false
        }

        let resetsRetryBudget = source == "manual"
            || source == "pool-authority"
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
            guard let self,
                  !self.isExiting,
                  operationAuthority?.authorizes() ?? true else {
                return false
            }
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
                                        && (operationAuthority?.authorizes() ?? true)
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
                                        && (operationAuthority?.authorizes() ?? true)
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
                  operationAuthority?.authorizes() ?? true,
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
                reason: source == "pool-authority" ? .poolAuthority : .manual,
                swapStart: Date(),
                prepared: prepared,
                recordsSwap: false,
                operationAuthority: operationAuthority
            )
            return self.accountManager.activationState?.runtimeIsCurrent(
                for: target.id,
                at: Date()
            ) == true
        }
        guard scoped != nil else {
            accountManager.publishActivationNotice("Another account mutation is already in progress")
            return false
        }
        return scoped == true
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

    private enum RuntimeRevalidationFailurePersistence: String {
        case recorded
        case recordedNotPublished = "recorded_not_published"
        case authorizationLost = "authorization_lost"
        case stateChanged = "state_changed"
        case failed
    }

    private func persistRuntimeRevalidationFailure(
        target: CodexAccount,
        prepared: PreparedAccountActivation,
        operationAuthority: PoolAuthorityOperationAuthority?
    ) async -> RuntimeRevalidationFailurePersistence {
        guard let degraded = accountManager.activationState,
              degraded.phase == .committedDegraded,
              degraded.configuredAccountId == target.id,
              degraded.activationGeneration == prepared.activationGeneration else {
            return .stateChanged
        }
        guard operationAuthority?.authorizes() ?? true,
              let failurePermit = await activationEffectPermit(
                prepared,
                targetAccountId: target.id,
                requiredPhase: .committedDegraded,
                configuredAccountId: target.id
              ),
              operationAuthority?.authorizes() ?? true else {
            return .authorizationLost
        }

        do {
            let failed = try await accountActivationCoordinator
                .recordRuntimeRevalidationFailure(
                    targetAccountId: target.id,
                    expectedActivationGeneration: prepared.activationGeneration,
                    authorizeEffect: { state in
                        (operationAuthority?.authorizes() ?? true)
                            && failurePermit.authorizes(
                                state: state,
                                at: Date()
                            )
                    }
                )
            guard operationAuthority?.authorizes() ?? true,
                  await activationWorkIsCurrent(
                    prepared,
                    targetAccountId: target.id,
                    operationAuthority: operationAuthority
                  ) else {
                return .recordedNotPublished
            }
            accountManager.publishActivationState(failed)
            return .recorded
        } catch {
            let authorityIsCurrent = operationAuthority?.authorizes() ?? true
            let activationIsCurrent: Bool
            if authorityIsCurrent {
                activationIsCurrent = await activationWorkIsCurrent(
                    prepared,
                    targetAccountId: target.id,
                    operationAuthority: operationAuthority
                )
            } else {
                activationIsCurrent = false
            }

            let failure: RuntimeRevalidationFailurePersistence
            switch error as? AccountActivationCoordinatorError {
            case .authorizationRevoked?:
                failure = .authorizationLost
            case .invalidTransition?:
                failure = .stateChanged
            default:
                failure = authorityIsCurrent ? .failed : .authorizationLost
                if activationIsCurrent {
                    await enterActivationManualReview(
                        targetAccountId: target.id,
                        detail: .runtimeEvidencePersistFailed
                    )
                }
            }
            SwapLog.append(.debug(
                "SWAP_CONFIRMATION_FAILURE_PERSIST_FAILED target=\(target.email) outcome=\(failure.rawValue) error=\(error.localizedDescription)"
            ))
            return failure
        }
    }

    private func finishSwapRuntimeConvergence(
        from: CodexAccount,
        to: CodexAccount,
        reason: SwapEvent.SwapReason,
        swapStart: Date,
        prepared: PreparedAccountActivation,
        completion: AccountActivationRuntimeCompletion,
        recordsSwap: Bool,
        operationAuthority: PoolAuthorityOperationAuthority? = nil
    ) async {
        guard !isExiting else {
            await abandonSwapRuntimeConvergence(
                prepared: prepared,
                targetAccountId: to.id
            )
            return
        }
        guard await activationWorkIsCurrent(
            prepared,
            targetAccountId: to.id,
            operationAuthority: operationAuthority
        ) else {
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
                  await activationWorkIsCurrent(
                      prepared,
                      targetAccountId: to.id,
                      operationAuthority: operationAuthority
                  ) else {
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
                                runtimeBlockers: degraded.convergenceBlockers,
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
                            guard operationAuthority?.authorizes() ?? true else {
                                return false
                            }
                            return await self?.durableConfiguredFilesMatch(to) == true
                        },
                        authorizeConfirmation: { [weak self] in
                            guard let self,
                                  operationAuthority?.authorizes() ?? true else {
                                return nil
                            }
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
                                  operationAuthority?.authorizes() ?? true,
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
                                  operationAuthority?.authorizes() ?? true,
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
                                    ),
                                    operationAuthority?.authorizes() ?? true,
                                    revalidatedEvidence.runtimeBindings.allSatisfy({
                                        SwapEngine.reloadBindingIsCurrent($0)
                                    }) else {
                                        return false
                                    }
                                    return revalidatedEvidence
                                        .matchesRediscoveredRuntimeTopology(
                                            cli: SwapEngine.localRuntimeEvidenceSnapshot(
                                                runtimeKind: .localInteractiveCLI
                                            ),
                                            desktop: SwapEngine
                                                .localDesktopRuntimeEvidenceSnapshot()
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
                    let failurePersistence =
                        await persistRuntimeRevalidationFailure(
                            target: to,
                            prepared: prepared,
                            operationAuthority: operationAuthority
                        )
                    pendingSwapTargetAccountId = nil
                    swapConvergenceTask = nil
                    SwapLog.append(.debug(
                        "SWAP_CONFIRMATION_BLOCKED target=\(to.email) reason=runtime_topology_changed_before_publish failure_persistence=\(failurePersistence.rawValue)"
                    ))
                    return
                case .blocked(.journalPersistence):
                    throw AccountActivationCoordinatorError.invalidTransition(
                        "confirmation journal persistence lost authorization"
                    )
                }
                guard confirmed.phase == .confirmed,
                      operationAuthority?.authorizes() ?? true,
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
                guard operationAuthority?.authorizes() ?? true,
                      let failurePermit = await activationEffectPermit(
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
                    runtimeBlockers: completion.blockers,
                    authorizeEffect: { current in
                        (operationAuthority?.authorizes() ?? true)
                            && failurePermit.authorizes(state: current, at: Date())
                    }
                )
            case .restartRequired:
                guard operationAuthority?.authorizes() ?? true,
                      let failurePermit = await activationEffectPermit(
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
                    runtimeBlockers: completion.blockers,
                    authorizeEffect: { current in
                        (operationAuthority?.authorizes() ?? true)
                            && failurePermit.authorizes(state: current, at: Date())
                    }
                )
            }
            guard operationAuthority?.authorizes() ?? true else {
                await abandonSwapRuntimeConvergence(
                    prepared: prepared,
                    targetAccountId: to.id
                )
                return
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
        let credentialAuthorityBeforeLogin = accountManager.accounts

        Task { @MainActor [weak self] in
            guard let self, !self.isExiting else { return }
            do {
                let imported = try await self.oauthManager.performLogin()
                guard !self.isExiting else { return }
                guard Self.reauthenticationPreservesStableProviderIdentity(
                    original: original,
                    observed: imported
                ) else {
                    accountManager.publishActivationNotice(
                        "Re-authentication identity does not match the selected account"
                    )
                    updatePopoverContent()
                    SwapLog.append(.debug(
                        "ACCOUNT_REAUTH_IDENTITY_MISMATCH target=\(original.id.uuidString)"
                    ))
                    return
                }
                guard let candidate = Self.reauthenticatedAccountCandidate(
                    original: original,
                    observed: imported
                ) else {
                    accountManager.publishActivationNotice(
                        "Re-authentication did not return complete credentials"
                    )
                    updatePopoverContent()
                    SwapLog.append(.debug(
                        "ACCOUNT_REAUTH_INCOMPLETE_CREDENTIALS target=\(original.id.uuidString)"
                    ))
                    return
                }

                let validation = await self.validateReauthenticatedAccount(candidate)
                if case .failure(let validationError) = validation {
                    accountManager.markRuntimeUnusable(
                        for: accountId,
                        reason: "token_expired",
                        until: Date().addingTimeInterval(30 * 24 * 60 * 60)
                    )
                    accountManager.updatePollingError(
                        for: accountId,
                        error: "Re-authentication required"
                    )
                    _ = await persistTelemetrySnapshot(
                        context: "reauth-validation-failed"
                    )
                    statusBarController.updateIcon()
                    updatePopoverContent()
                    SwapLog.append(.debug(
                        "ACCOUNT_REAUTH_VALIDATION_FAILED email=\(original.email) error=\(String(describing: validationError))"
                    ))
                    NotificationManager.notifyTokenRefreshFailed(account: original)
                    return
                }

                let reauthenticatesActiveAccount = accountManager.configuredAccount?.id == accountId
                if reauthenticatesActiveAccount {
                    let committed = await withPreparedActiveCredentialMutation(
                        targetAccountId: candidate.id,
                        expectedConfiguredAccountId: original.id,
                        source: "reauthentication",
                        requestKind: .manual
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
                    guard await persistInactiveReauthentication(
                        original: original,
                        candidate: candidate,
                        expectedCredentialAuthority: credentialAuthorityBeforeLogin
                    ) else {
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
                queueTelemetryPersistence(context: "reauth-account-validation")
                startPollingForAccount(accountId)
                refreshSubscriptionInfoIfNeeded(force: true)
                statusBarController.updateIcon()
                updatePopoverContent()
                SwapLog.append(.debug("ACCOUNT_REAUTH_SUCCESS email=\(original.email)"))
            } catch {
                accountManager.updatePollingError(for: accountId, error: "Re-authentication failed")
                updatePopoverContent()
                SwapLog.append(.debug("ACCOUNT_REAUTH_FAILED email=\(original.email) error=\(error.localizedDescription)"))
            }
        }
    }

    private func persistInactiveReauthentication(
        original: CodexAccount,
        candidate: CodexAccount,
        expectedCredentialAuthority: [CodexAccount]
    ) async -> Bool {
        guard !externalHandoffAdoptionInFlight,
              let snapshot = Self.inactiveReauthenticationSnapshot(
                  accounts: accountManager.accounts,
                  original: original,
                  candidate: candidate
              ) else {
            SwapLog.append(.debug(
                "ACCOUNT_REAUTH_COMMIT_BLOCKED target=\(original.id.uuidString) reason=credential_authority_changed"
            ))
            return false
        }

        accountPersistenceRevision &+= 1
        let revision = accountPersistenceRevision
        do {
            let outcome = try await accountPersistence.persistDurably(
                snapshot,
                ifCredentialAuthorityMatches: expectedCredentialAuthority,
                revision: revision
            )
            guard case .persisted(let persisted) = outcome,
                  let committed = persisted.first(where: { $0.id == original.id }),
                  let current = accountManager.accounts.first(where: {
                      $0.id == original.id
                  }),
                  !current.isActive,
                  Self.credentialsMatch(current, original) else {
                externalAuthReconciliationPending = true
                SwapLog.append(.debug(
                    "ACCOUNT_REAUTH_COMMIT_BLOCKED target=\(original.id.uuidString) reason=credential_authority_drift"
                ))
                return false
            }

            var applied = current
            applied.email = committed.email
            applied.accessToken = committed.accessToken
            applied.refreshToken = committed.refreshToken
            applied.idToken = committed.idToken
            applied.accountId = committed.accountId
            applied.lastRefreshed = committed.lastRefreshed
            applied.runtimeUnusableUntil = nil
            applied.runtimeUnusableReason = nil
            guard case .updated = accountManager.upsertInactiveAccount(applied) else {
                externalAuthReconciliationPending = true
                SwapLog.append(.debug(
                    "ACCOUNT_REAUTH_COMMIT_BLOCKED target=\(original.id.uuidString) reason=in_memory_adoption_failed"
                ))
                return false
            }

            SwapLog.append(.debug(
                "ACCOUNTS_PERSISTED context=reauth-account configured=\(accountManager.configuredAccount?.email ?? "none")"
            ))
            scheduleLinuxDevboxCredentialSyncIfNeeded(context: "reauth-account")
            return true
        } catch {
            SwapLog.append(.debug(
                "ACCOUNTS_PERSIST_FAILED context=reauth-account error=\(error.localizedDescription)"
            ))
            return false
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
        desktopPatchRetryLifecycle.cancel()
        desktopUpdateActivationProbeTask?.cancel()
        desktopUpdateActivationProbeTask = nil
        desktopUpdateActivationProbeTaskIdentifier = nil
        linuxDevboxCredentialSyncRetryTask?.cancel()
        linuxDevboxCredentialSyncRetryTask = nil
        Self.requestOwnedMutationTaskCancellation(swapConvergenceTask)
        automaticPolicyGateTask?.cancel()
        automaticPolicyGateTask = nil
        automaticPolicyGateWatchdogTask?.cancel()
        automaticPolicyGateWatchdogTask = nil
        automaticPolicyLeaseState.cancel()
        quotaPollingReconciliationTask?.cancel()
        quotaPollingReconciliationTask = nil
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
        let expectedCredentialAuthority = accountManager.accounts
        guard let accountId = accountManager.configuredAccount?.id
                ?? expectedCredentialAuthority.first?.id else {
            return
        }
        let emails = expectedCredentialAuthority.map(\.email)
        let deletionOutcome: AccountTelemetryPersistenceOutcome?
        do {
            deletionOutcome = try await accountMutationTransaction
                .withAccountStoreDeletionLease(
                    accountId: accountId,
                    mutationGeneration: UUID()
                ) { [self] _ in
                    accountPersistenceRevision &+= 1
                    return try await accountPersistence.deleteAllDurably(
                        ifCredentialAuthorityMatches: expectedCredentialAuthority,
                        revision: accountPersistenceRevision
                    )
                }
        } catch {
            logger.error("Failed to clear account stores: \(error.localizedDescription)")
            SwapLog.append(.debug(
                "ACCOUNTS_DELETE_ALL_FAILED error=\(error.localizedDescription)"
            ))
            return
        }
        guard let deletionOutcome else {
            SwapLog.append(.debug(
                "ACCOUNTS_DELETE_ALL_BLOCKED reason=account_mutation_in_progress"
            ))
            return
        }
        guard case .persisted = deletionOutcome else {
            externalAuthReconciliationPending = true
            SwapLog.append(.debug(
                "ACCOUNTS_DELETE_ALL_DISCARDED reason=credential_or_selection_changed"
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
                onRemoveAllAccounts: { [weak self] in self?.removeAllAccounts() },
                desktopUpdateCoordinator: desktopUpdateCoordinator,
                onInstallDesktopUpdate: { [weak self] in
                    self?.requestDesktopUpdateInstallationFromSettings()
                },
                onRetryDesktopPatch: { [weak self] completion in
                    self?.retryDesktopPatchFromSettings(completion: completion)
                }
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
                self?.checkPoolAuthorityStatus()
                self?.checkLinuxDevboxReadiness()
            }
        }
        checkPoolAuthorityStatus()
        checkLinuxDevboxReadiness(force: true)
    }

    private func checkPoolAuthorityStatus() {
        let settings = LinuxDevboxMonitor.settings()
        publishRemoteAuthorityTransportConfigIfNeeded(settings)
        accountManager.publishRemoteAuthorityEndpointConfigured(
            settings.hasRemoteAuthorityEndpoint
        )
        guard Self.swapRequiresRemoteAuthority(settings) else {
            poolAuthorityStatusGeneration &+= 1
            poolAuthorityStatusCheckInFlight = false
            poolAuthorityClientState.reset()
            accountManager.clearPoolAuthorityObservation()
            poolAuthorityOperationAuthority?.revoke()
            poolAuthorityOperationAuthority = nil
            return
        }
        guard !poolAuthorityStatusCheckInFlight,
              !poolAuthorityRequestInFlight else {
            return
        }

        poolAuthorityStatusCheckInFlight = true
        poolAuthorityStatusGeneration &+= 1
        let generation = poolAuthorityStatusGeneration
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                LinuxDevboxMonitor.fetchPoolAuthorityStatus(settings: settings)
            }.value
            guard let self else {
                return
            }
            self.poolAuthorityStatusCheckInFlight = false
            guard generation == self.poolAuthorityStatusGeneration,
                  settings == LinuxDevboxMonitor.settings() else {
                return
            }
            guard case .success(let observation) = result else {
                return
            }
            if let operation = self.poolAuthorityOperationAuthority,
               observation.epoch > operation.epoch {
                operation.revoke()
            }
            self.handlePoolAuthorityObservation(
                observation,
                permitsConverging: false
            )
            if self.accountManager.configuredAccount?.normalizedProviderAccountId
                == observation.desiredProviderAccountId {
                self.scheduleLinuxDevboxCredentialSyncIfNeeded(
                    context: "authority-reconciliation"
                )
            }
        }
    }

    private func publishRemoteAuthorityTransportConfigIfNeeded(
        _ settings: LinuxDevboxMonitorSettings
    ) {
        guard remoteAuthorityTransportSettings != settings else {
            return
        }
        remoteAuthorityTransportSettings = settings
        remoteAuthorityTransportWriteGeneration &+= 1
        let generation = remoteAuthorityTransportWriteGeneration
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result {
                    try RemoteAuthorityTransportConfigStore().write(
                        settings: settings
                    )
                }
            }.value
            guard let self,
                  generation == self.remoteAuthorityTransportWriteGeneration else {
                return
            }
            if case .failure(let error) = result {
                self.remoteAuthorityTransportSettings = nil
                SwapLog.append(.debug(
                    "REMOTE_AUTHORITY_CONFIG_WRITE_FAILED error=\(error.localizedDescription)"
                ))
            }
        }
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
            NotificationManager.resolveLinuxDevboxReadinessIssue()
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
                        NotificationManager.resolveLinuxDevboxReadinessIssue()
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
                    if taskContext.settings.readinessNotificationsEnabled,
                       !suppressNotification {
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
                if taskContext.settings.readinessNotificationsEnabled,
                   !suppressNotification {
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
        var resetReconciliationChanged = false
        for state in states {
            guard let providerAccountId = state.providerAccountId,
                  let account = accountManager.accounts.first(where: {
                      RateLimitResetProviderAccountIdentity.matches(
                          $0.accountId,
                          providerAccountId
                      )
                  }),
                  let bank = state.rateLimitResetBank else {
                continue
            }
            guard let normalizedProviderAccountId = account.normalizedProviderAccountId,
                  let refreshStartedAt = remoteRateLimitResetRefreshStartedAt[
                      normalizedProviderAccountId
                  ],
                  bank.fetchedAt >= refreshStartedAt else {
                continue
            }
            remoteRateLimitResetRefreshStartedAt[normalizedProviderAccountId] = nil
            if !remoteRateLimitResetUnknownProviderAccountIds.contains(
                normalizedProviderAccountId
            ) {
                rateLimitResetManualErrors[account.id] = nil
            }
            resetReconciliationChanged = true
        }
        guard result.stateChanged || resetReconciliationChanged else { return }
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
