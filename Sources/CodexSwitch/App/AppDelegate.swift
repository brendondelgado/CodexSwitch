import AppKit
import SwiftUI
import os
import Darwin

private let logger = Logger(subsystem: "com.codexswitch", category: "AppDelegate")
private let linuxDevboxLastCredentialSyncFingerprintKey = "linuxDevboxLastCredentialSyncFingerprint"

@MainActor
private enum LinuxDevboxPersistThrottle {
    static var lastPersistAt: Date?
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
    // Set in applicationDidFinishLaunching before any other access
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var statusBarController: StatusBarController!
    private var settingsWindow: NSWindow?
    private var popoverContentInstalled = false
    private var popoverLocalEventMonitor: Any?
    private var popoverGlobalEventMonitor: Any?

    let accountManager = AccountManager()
    private let keychainStore = KeychainStore()
    private let quotaPoller = QuotaPoller()
    private let tokenSavingsStore = CodexTokenSavingsStore()
    private let weeklyPrimer = WeeklyPrimer()
    private let subscriptionInfoFetcher = SubscriptionInfoFetcher()
    private let oauthManager = OAuthLoginManager()
    private let singleInstanceLock = SingleInstanceLock()

    private var monitorTask: Task<Void, Never>?
    private var iconUpdateTimer: Timer?
    private var linuxDevboxMonitorTimer: Timer?
    private var tokenUsageMetricsTimer: Timer?
    private var tokenUsageRefreshSequence = 0
    private var tokenUsageRefreshInFlight = false
    private var lastLinuxDevboxReady: Bool?
    private var lastLinuxDevboxFullCheckAt: Date?
    private var lastLinuxDevboxAccountMirrorSucceededAt: Date?
    private var linuxDevboxReadinessCheckInFlight = false
    private var linuxDevboxConsecutiveIssueChecks = 0
    private var lastSubscriptionRefresh: Date?
    private var lastCLIRepairCheck: Date?
    private var lastComputerUsePermissionRepair: Date?
    private var lastDesktopPatchCheck: Date?
    private var lastCodexBrowserSessionRepairCheck: Date?
    private var lastLinuxDevboxAccountPersistAt: Date?
    private var lastLinuxDevboxAccountRefreshByKey: [String: Date] = [:]
    private var pendingLinuxDevboxActiveEmail: String?
    private var pendingLinuxDevboxActiveUntil: Date?
    private var linuxDevboxActivePushInFlight = false
    private var linuxDevboxCredentialSyncInFlight = false
    private var pendingLinuxDevboxCredentialSyncFingerprint: String?
    private var lastLinuxDevboxCredentialSyncAttemptAt: Date?
    private var exhaustedPoolAlertGate = ExhaustedPoolAlertGate()
    private var codexAppTerminationObserver: NSObjectProtocol?
    private var desktopPatchRetryTask: Task<Void, Never>?
    private var isExiting = false

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
        CodexSwitchKeepAlive.installIfNeeded()
        Task.detached { CodexConfigRepair.repairDefaultConfigIfNeeded() }
        scheduleComputerUsePermissionRepairIfNeeded(force: true)
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
            Task { @MainActor [weak self] in
                self?.handleCodexAppDidTerminate(
                    bundleIdentifier: bundleIdentifier,
                    bundlePath: bundlePath
                )
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
        Task { @MainActor in
            await loadAccounts()

            // Prune old diagnostic logs (>7 days)
            SwapLog.pruneOldLogs()

            // Start polling + monitoring
            startAllPolling()
            primeIdleAccountsIfNeeded()
            refreshSubscriptionInfoIfNeeded(force: true)
            startSwapMonitor()
            startLinuxDevboxMonitor()
            startTokenUsageMetricsMonitor()
            scheduleDesktopPatchCheckIfNeeded(force: true)

            // Ensure auth.json is in sync on launch without touching live sessions.
            // Readiness/status polling must never use SIGHUP as a probe; real
            // swaps and token refreshes are the only paths that reload clients.
            if let active = accountManager.activeAccount {
                try? SwapEngine.writeAuthFile(for: active)
                syncHermesLocal(account: active, reason: "launch-active-sync")
            }

            // Update icon + status checks periodically
            writeCrashLog("LAUNCH: all services started, \(accountManager.accounts.count) accounts loaded, active=\(accountManager.activeAccount?.email ?? "none")")

            CLIStatusChecker.refresh(activeAccountId: accountManager.activeAccount?.accountId)
            iconUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    // If auth.json changed externally, restart polling for new active account
                    if let refreshedId = self?.importCurrentAuthAccountIfKnown() {
                        self?.persistAccountsSnapshot(context: "auth-json-token-import")
                        self?.startPollingForAccount(refreshedId)
                    }
                    if let newActiveId = await self?.accountManager.syncWithAuthJson() {
                        self?.persistAccountsSnapshot(context: "auth-json-sync")
                        self?.startPollingForAccount(newActiveId)
                    }
                    self?.ensureStatusItemHealthy()
                    self?.statusBarController.updateIcon()
                    self?.updatePopoverContent()
                    self?.refreshSubscriptionInfoIfNeeded()
                    self?.scheduleComputerUsePermissionRepairIfNeeded()
                    self?.scheduleGlobalCLIRepairIfNeeded()
                    self?.scheduleCodexBrowserSessionRepairIfNeeded()
                    CLIStatusChecker.refresh(activeAccountId: self?.accountManager.activeAccount?.accountId) { [weak self] in
                        self?.updatePopoverContent()
                    }
                    Task.detached {
                        CodexConfigRepair.repairDefaultConfigIfNeeded(removeStaleCopies: false)
                    }
                    self?.scheduleDesktopPatchCheckIfNeeded()
                }
            }
        }
    }

    private func importCurrentAuthAccountIfKnown() -> UUID? {
        guard let imported = try? AccountImporter.importCurrentAccount() else { return nil }
        return accountManager.refreshStoredTokens(from: imported)
    }


    private func scheduleGlobalCLIRepairIfNeeded(force: Bool = false) {
        let now = Date()
        if !force, let lastCLIRepairCheck, now.timeIntervalSince(lastCLIRepairCheck) < 5 * 60 {
            return
        }
        lastCLIRepairCheck = now
        Task.detached {
            let result = CodexVersionChecker.repairBrokenGlobalCLIIfNeeded(force: force)
            if result.attempted {
                SwapLog.append(.debug("GLOBAL_CODEX_CLI_REPAIR success=\(result.success) message=\(result.message)"))
            }
        }
    }

    private func scheduleDesktopPatchCheckIfNeeded(force: Bool = false) {
        let now = Date()
        if !force, let lastDesktopPatchCheck, now.timeIntervalSince(lastDesktopPatchCheck) < 15 * 60 {
            return
        }
        lastDesktopPatchCheck = now
        Task.detached {
            DesktopPatchManager.checkAndPatchIfPossible(
                ignoreCooldown: force,
                ignorePermissionDeniedBackoff: force
            )
        }
    }

    private func scheduleDesktopPatchRetryBurst(reason: String) {
        desktopPatchRetryTask?.cancel()
        desktopPatchRetryTask = Task.detached {
            for delaySeconds in DesktopPatchManager.postQuitPatchRetryDelaysSeconds {
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
                if outcome.shouldStopPostQuitRetry {
                    return
                }
            }
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

    private func scheduleComputerUsePermissionRepairIfNeeded(force: Bool = false) {
        let now = Date()
        if !force,
           let lastComputerUsePermissionRepair,
           now.timeIntervalSince(lastComputerUsePermissionRepair) < 10 * 60 {
            return
        }
        lastComputerUsePermissionRepair = now
        Task.detached {
            let result = ComputerUsePermissionRepair.repairGenericAppleEventsIfNeeded()
            if result.attempted || !result.success {
                SwapLog.append(.debug("COMPUTER_USE_PERMISSION_REPAIR success=\(result.success) changed=\(result.changed) message=\(result.message)"))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let codexAppTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(codexAppTerminationObserver)
            self.codexAppTerminationObserver = nil
        }
        cleanupBeforeExit()
        let poller = quotaPoller
        Task {
            await poller.stopAll()
        }
    }

    private func handleCodexAppDidTerminate(bundleIdentifier: String?, bundlePath: String?) {
        guard bundleIdentifier == "com.openai.codex"
            || bundlePath == "/Applications/Codex.app" else {
            return
        }

        Task.detached {
            try? await Task.sleep(for: .milliseconds(750))
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
            await MainActor.run {
                self.scheduleDesktopPatchRetryBurst(reason: "codex_app_terminated")
            }
        }
    }

    // MARK: - Account Management

    private func loadAccounts() async {
        do {
            let accounts = try keychainStore.loadAll()
            for account in accounts {
                accountManager.addAccount(account)
            }
            await accountManager.restoreActiveAccount()
            let primedDates = await weeklyPrimer.persistedFiveHourPrimedAt()
            for (id, date) in primedDates {
                accountManager.markFiveHourPrimed(for: id, at: date)
            }
            persistAccountsSnapshot(context: "load-restore")
        } catch {
            logger.error("Failed to load accounts: \(error.localizedDescription)")
        }
    }

    private func persistAccountsSnapshot(context: String, log: Bool = true) {
        if context == "linux-devbox-interactive-sync" {
            let now = Date()
            let lastPersistAt = LinuxDevboxPersistThrottle.lastPersistAt ?? lastLinuxDevboxAccountPersistAt
            if let lastPersistAt,
               now.timeIntervalSince(lastPersistAt) < 60 {
                return
            }
            LinuxDevboxPersistThrottle.lastPersistAt = now
            lastLinuxDevboxAccountPersistAt = now
        }
        do {
            try keychainStore.saveAll(accountManager.accounts)
            if log {
                SwapLog.append(.debug("ACCOUNTS_PERSISTED context=\(context) active=\(accountManager.activeAccount?.email ?? "none")"))
            }
            scheduleLinuxDevboxCredentialSyncIfNeeded(context: context)
        } catch {
            logger.warning("Failed to persist accounts snapshot (\(context)): \(error.localizedDescription)")
            SwapLog.append(.debug("ACCOUNTS_PERSIST_FAILED context=\(context) error=\(error.localizedDescription)"))
        }
    }

    private func scheduleLinuxDevboxCredentialSyncIfNeeded(context: String) {
        guard Self.shouldSyncLinuxDevboxCredentials(for: context) else { return }
        let settings = LinuxDevboxMonitor.settings()
        guard settings.isConfigured else { return }
        let accounts = accountManager.accounts
        guard !accounts.isEmpty else { return }

        let fingerprint = LinuxDevboxMonitor.credentialSyncFingerprint(accounts: accounts)
        if UserDefaults.standard.string(forKey: linuxDevboxLastCredentialSyncFingerprintKey) == fingerprint {
            return
        }
        if linuxDevboxCredentialSyncInFlight {
            pendingLinuxDevboxCredentialSyncFingerprint = fingerprint
            SwapLog.append(.debug("LINUX_DEVBOX_CREDENTIAL_SYNC_QUEUED context=\(context)"))
            return
        }
        let now = Date()
        if !Self.shouldBypassLinuxDevboxCredentialSyncThrottle(for: context),
           let lastLinuxDevboxCredentialSyncAttemptAt,
           now.timeIntervalSince(lastLinuxDevboxCredentialSyncAttemptAt) < 10 * 60 {
            pendingLinuxDevboxCredentialSyncFingerprint = fingerprint
            SwapLog.append(.debug("LINUX_DEVBOX_CREDENTIAL_SYNC_THROTTLED context=\(context)"))
            return
        }

        linuxDevboxCredentialSyncInFlight = true
        lastLinuxDevboxCredentialSyncAttemptAt = now
        pendingLinuxDevboxCredentialSyncFingerprint = nil
        Task.detached { [weak self] in
            if await NetworkBackoffGuard.shared.shouldDeferNonCriticalProbe(operation: "linux_devbox_credential_sync") {
                await MainActor.run {
                    guard let self else { return }
                    self.linuxDevboxCredentialSyncInFlight = false
                    self.pendingLinuxDevboxCredentialSyncFingerprint = fingerprint
                    SwapLog.append(.debug("LINUX_DEVBOX_CREDENTIAL_SYNC_DEFERRED context=\(context)"))
                }
                return
            }

            let result = LinuxDevboxMonitor.syncCredentials(settings: settings, accounts: accounts)
            await MainActor.run {
                guard let self else { return }
                self.linuxDevboxCredentialSyncInFlight = false
                let queuedFingerprint = self.pendingLinuxDevboxCredentialSyncFingerprint
                switch result {
                case .success(let output):
                    UserDefaults.standard.set(fingerprint, forKey: linuxDevboxLastCredentialSyncFingerprintKey)
                    self.pendingLinuxDevboxCredentialSyncFingerprint = nil
                    Task {
                        await NetworkBackoffGuard.shared.recordSuccess(operation: "linux_devbox_credential_sync")
                    }
                    SwapLog.append(.debug("LINUX_DEVBOX_CREDENTIAL_SYNCED context=\(context) accounts=\(accounts.count) output=\(output)"))
                    self.checkLinuxDevboxReadiness(force: true)
                case .failure(let failure):
                    self.pendingLinuxDevboxCredentialSyncFingerprint = fingerprint
                    Task {
                        await NetworkBackoffGuard.shared.recordFailure(failure.message, operation: "linux_devbox_credential_sync")
                    }
                    SwapLog.append(.debug("LINUX_DEVBOX_CREDENTIAL_SYNC_FAILED context=\(context) error=\(failure.message)"))
                }

                if case .success = result,
                   queuedFingerprint != nil,
                   queuedFingerprint != UserDefaults.standard.string(forKey: linuxDevboxLastCredentialSyncFingerprintKey) {
                    self.pendingLinuxDevboxCredentialSyncFingerprint = queuedFingerprint
                    self.scheduleLinuxDevboxCredentialSyncIfNeeded(context: "queued-after-\(context)")
                }
            }
        }
    }

    nonisolated static func shouldSyncLinuxDevboxCredentials(for context: String) -> Bool {
        switch context {
        case "add-account",
             "auth-json-token-import",
             "auth-json-sync",
             "load-restore",
             "reauth-account",
             "reauth-added-different-account",
             "swap",
             "token-refresh":
            return true
        default:
            let prefix = "queued-after-"
            if context.hasPrefix(prefix) {
                let originalContext = String(context.dropFirst(prefix.count))
                return shouldSyncLinuxDevboxCredentials(for: originalContext)
            }
            return false
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
            let prefix = "queued-after-"
            if context.hasPrefix(prefix) {
                let originalContext = String(context.dropFirst(prefix.count))
                return shouldBypassLinuxDevboxCredentialSyncThrottle(for: originalContext)
            }
            return false
        }
    }

    private func syncHermesLocal(account: CodexAccount, reason: String) {
        Task.detached {
            do {
                let result = try HermesTarget.applyLocal(account: account, restartGateway: false)
                SwapLog.append(.debug(
                    "HERMES_LOCAL_SYNC_SUCCESS reason=\(reason) account=\(account.email) tokenHash=\(result.tokenHashPrefix) tuiRunning=\(result.tuiRunning)"
                ))
                if let hint = result.restartHint {
                    SwapLog.append(.debug("HERMES_LOCAL_SYNC_HINT reason=\(reason) message=\(hint)"))
                }
            } catch {
                SwapLog.append(.debug(
                    "HERMES_LOCAL_SYNC_SKIPPED reason=\(reason) account=\(account.email) error=\(error.localizedDescription)"
                ))
            }
        }
    }

    private func addAccount() {
        Task {
            do {
                var account = try await oauthManager.performLogin()
                if accountManager.accounts.isEmpty {
                    account.isActive = true
                }
                accountManager.addAccount(account)
                persistAccountsSnapshot(context: "add-account")
                startPollingForAccount(account.id)
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
        let manager = accountManager
        Task {
            await quotaPoller.startPolling(
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
                        self?.persistAccountsSnapshot(context: "quota-update", log: false)
                        self?.statusBarController.updateIcon()
                        self?.updatePopoverContent()
                        self?.primeIdleAccountsIfNeeded()
                        if let email,
                           self?.shouldPushLinuxDevboxPlanRefresh(previousPlan: previousPlan, newPlan: planType) == true {
                            self?.pushLinuxDevboxAccountRefresh(email: email, reason: "plan_changed:\(previousPlan ?? "unknown")->\(planType)")
                        }
                        // Immediate swap check if active account is approaching exhaustion
                        if self?.accountManager.activeAccount?.id == id,
                           (snapshot.fiveHour.isExhausted || snapshot.weekly.isExhausted) {
                            self?.checkAndSwapIfNeeded()
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
                           !snapshot.hasExpiredExhaustedWindow(),
                           !snapshot.fiveHour.shouldAutoSwapAway,
                           !snapshot.weekly.shouldAutoSwapAway {
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
        guard let active = accountManager.activeAccount, active.id == accountId else { return }
        if let snapshot = active.realQuotaSnapshot,
           !snapshot.hasExpiredExhaustedWindow(),
           !snapshot.fiveHour.shouldAutoSwapAway,
           !snapshot.weekly.shouldAutoSwapAway {
            SwapLog.append(.debug("AUTO_SWAP_USAGE_UNAVAILABLE_SKIPPED active=\(active.email) reason=trusted_healthy_snapshot"))
            return
        }

        if let upgrade = SwapEngine.selectPlanUpgradeCandidate(active: active, from: accountManager.accounts) {
            SwapLog.append(.debug("AUTO_SWAP_USAGE_UNAVAILABLE active=\(active.email) target=\(upgrade.email) reason=higher_plan_available"))
            executeSwap(from: active, to: upgrade, reason: .usageUnavailable)
            return
        }

        guard let best = SwapEngine.selectAutoSwapCandidate(from: accountManager.accounts) else {
            SwapLog.append(.debug("AUTO_SWAP_USAGE_UNAVAILABLE_NO_READY_CANDIDATE active=\(active.email)"))
            return
        }
        SwapLog.append(.debug("AUTO_SWAP_USAGE_UNAVAILABLE active=\(active.email) target=\(best.email) reason=best_real_candidate"))
        executeSwap(from: active, to: best, reason: .usageUnavailable)
    }

    private func refreshToken(for accountId: UUID) async {
        guard let account = accountManager.accounts.first(where: { $0.id == accountId }) else { return }
        do {
            let updated = try await TokenRefresher.refresh(account)
            accountManager.addAccount(updated)
            persistAccountsSnapshot(context: "token-refresh")
            refreshSubscriptionInfoIfNeeded(force: true)
            // Same-account refresh — SIGHUP is safe here since the conversation
            // thread is still valid (same account, just new tokens)
            if account.isActive {
                try? SwapEngine.writeAuthFile(for: updated)
                syncHermesLocal(account: updated, reason: "token-refresh")
                Task.detached { SwapEngine.signalCodexReload() }
            }
            SwapLog.append(.tokenRefreshed(email: account.email))
            startPollingForAccount(accountId)
        } catch {
            SwapLog.append(.tokenRefreshFailed(email: account.email, error: error.localizedDescription))
            accountManager.markRuntimeUnusable(
                for: accountId,
                reason: "token_expired",
                until: Date().addingTimeInterval(30 * 24 * 60 * 60)
            )
            accountManager.updatePollingError(for: accountId, error: "Re-authentication required")
            persistAccountsSnapshot(context: "token-refresh-failed")
            updatePopoverContent()
            NotificationManager.notifyTokenRefreshFailed(account: account)
            if account.isActive,
               let best = SwapEngine.selectAutoSwapCandidate(from: accountManager.accounts) {
                SwapLog.append(.debug("AUTO_SWAP_ACTIVE_TOKEN_INVALIDATED from=\(account.email) to=\(best.email)"))
                executeSwap(from: account, to: best, reason: .tokenInvalidated)
            }
        }
    }

    private func primeIdleAccountsIfNeeded() {
        let accounts = accountManager.accounts
        guard !accounts.isEmpty else { return }

        let manager = accountManager
        let primer = weeklyPrimer
        Task { [weak self] in
            let primeResults = await primer.primeIfNeeded(
                accounts: accounts,
                accountProvider: { @Sendable id in
                    await MainActor.run {
                        manager.accounts.first { $0.id == id }
                    }
                }
            )

            guard !primeResults.isEmpty else { return }
            await MainActor.run {
                for result in primeResults {
                    if result.fiveHourPrimed {
                        self?.accountManager.markFiveHourPrimed(for: result.accountId)
                    } else if result.fiveHourUnconfirmed {
                        self?.accountManager.clearFiveHourPrimed(
                            for: result.accountId,
                            reason: "primer_unconfirmed"
                        )
                    }
                    self?.persistAccountsSnapshot(context: "quota-primed", log: false)
                    self?.startPollingForAccount(result.accountId)
                }
            }
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
                        self?.persistAccountsSnapshot(context: "subscription-info", log: false)
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

    private func checkAndSwapIfNeeded() {
        guard let active = accountManager.activeAccount else { return }

        let hasActiveRemoteSession = LinuxDevboxMonitor.isCodexVPSRemoteSessionRunning()
        let accountMirrorHealthy = linuxDevboxAccountMirrorIsFresh()
        let localDesktopRuntimeRunning = DesktopPatchManager.isCodexDesktopRuntimeRunning()
        guard LinuxDevboxMonitor.shouldRunMacAutoSwap(
            hasActiveRemoteSession: hasActiveRemoteSession,
            accountMirrorHealthy: accountMirrorHealthy,
            localDesktopRuntimeRunning: localDesktopRuntimeRunning
        ) else {
            SwapLog.append(.debug("AUTO_SWAP_SKIPPED reason=vps_remote_session_owns_rotation active=\(active.email) mirror=fresh"))
            return
        }
        if hasActiveRemoteSession && accountMirrorHealthy && localDesktopRuntimeRunning {
            SwapLog.append(.debug("AUTO_SWAP_REMOTE_SESSION_DESKTOP_OVERRIDE active=\(active.email) reason=local_codex_app_running"))
        } else if hasActiveRemoteSession {
            SwapLog.append(.debug("AUTO_SWAP_REMOTE_SESSION_FALLBACK active=\(active.email) mirror=fresh_false"))
        }

        if let upgrade = SwapEngine.selectPlanUpgradeCandidate(active: active, from: accountManager.accounts) {
            exhaustedPoolAlertGate.markRecovered()
            SwapLog.append(.debug(
                "AUTO_SWAP_PLAN_UPGRADE active=\(active.email) active_plan=\(active.normalizedPlanType) target=\(upgrade.email) target_plan=\(upgrade.normalizedPlanType)"
            ))
            executeSwap(from: active, to: upgrade, reason: .higherPlanAvailable)
            return
        }

        guard let snapshot = active.realQuotaSnapshot else { return }

        let fhLow = snapshot.fiveHour.shouldAutoSwapAway
        let wkLow = snapshot.weekly.shouldAutoSwapAway

        guard fhLow || wkLow else {
            exhaustedPoolAlertGate.markRecovered()
            return
        }

        SwapLog.append(.debug(
            "AUTO_SWAP_CHECK active=\(active.email) five_hour=\(Int(snapshot.fiveHour.remainingPercent)) weekly=\(Int(snapshot.weekly.remainingPercent))"
        ))

        guard let best = SwapEngine.selectAutoSwapCandidate(from: accountManager.accounts) else {
            if exhaustedPoolAlertGate.shouldNotifyNoCandidate() {
                NotificationManager.notifyAllExhausted(
                    nextReset: SwapEngine.earliestUsableReset(from: accountManager.accounts)
                )
                SwapLog.append(.debug("AUTO_SWAP_NO_READY_CANDIDATE active=\(active.email) notified=true"))
            } else {
                SwapLog.append(.debug("AUTO_SWAP_NO_READY_CANDIDATE active=\(active.email) notified=false"))
            }
            return
        }

        exhaustedPoolAlertGate.markRecovered()
        executeSwap(from: active, to: best, reason: .quotaExhausted)
    }

    private func executeSwap(from: CodexAccount, to: CodexAccount, reason: SwapEvent.SwapReason) {
        let swapStart = Date()
        SwapLog.append(.swapTriggered(
            from: from.email,
            to: to.email,
            reason: String(describing: reason)
        ))

        do {
            // 1. Write auth.json for CLI sessions
            try SwapEngine.writeAuthFile(for: to)
            syncHermesLocal(account: to, reason: "swap")
            pushLinuxDevboxActiveAccount(email: to.email, reason: "swap")
            SwapLog.append(.authFileWritten(accountId: to.accountId))

            // 2. SIGHUP + desktop reload — run off main thread.
            // Manual clicks should switch the live CLI too; otherwise the UI
            // and auth.json change while the running session keeps old tokens.
            Task.detached {
                SwapEngine.signalCodexReload()
                SwapLog.append(.desktopExternalReloadAttempt)
                let desktopReload = await DesktopRuntimeReloadClient().reloadAuth(account: to)
                switch desktopReload {
                case .reloaded(let method):
                    SwapLog.append(.desktopExternalReloadSuccess(method: method))
                case .noDesktopRuntime:
                    if SwapEngine.signalDesktopAppServerReload() {
                        SwapLog.append(.desktopExternalReloadSuccess(method: "sighup-app-server"))
                    } else {
                        SwapLog.append(.desktopExternalReloadSkipped(reason: "no_desktop_runtime"))
                    }
                case .unsupported:
                    SwapLog.append(.desktopExternalReloadSkipped(reason: "unsupported"))
                case .failed(let reason):
                    SwapLog.append(.desktopExternalReloadFailed(reason: reason))
                }
            }

            accountManager.setActive(to.id)
            persistAccountsSnapshot(context: "swap")
            // Restart polling for new active account — clears old sleep, fetches immediately
            startPollingForAccount(to.id)

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
            statusBarController.updateIcon()
            updatePopoverContent()
        } catch {
            SwapLog.append(.swapFailed(error: error.localizedDescription))
            logger.error("Swap failed (\(String(describing: reason))): \(error.localizedDescription)")
        }
    }

    private func forceSwap(to accountId: UUID) {
        guard let active = accountManager.activeAccount,
              let target = accountManager.accounts.first(where: { $0.id == accountId }) else { return }
        executeSwap(from: active, to: target, reason: .manual)
    }

    private func reauthenticateAccount(_ accountId: UUID) {
        guard let original = accountManager.accounts.first(where: { $0.id == accountId }) else { return }

        Task {
            do {
                let imported = try await oauthManager.performLogin()
                let validation = await validateReauthenticatedAccount(imported)
                await MainActor.run {
                    if case .failure(let validationError) = validation {
                        accountManager.markRuntimeUnusable(
                            for: accountId,
                            reason: "token_expired",
                            until: Date().addingTimeInterval(30 * 24 * 60 * 60)
                        )
                        accountManager.updatePollingError(for: accountId, error: "Re-authentication required")
                        persistAccountsSnapshot(context: "reauth-validation-failed")
                        statusBarController.updateIcon()
                        updatePopoverContent()
                        SwapLog.append(.debug("ACCOUNT_REAUTH_VALIDATION_FAILED email=\(original.email) error=\(String(describing: validationError))"))
                        NotificationManager.notifyTokenRefreshFailed(account: original)
                        return
                    }

                    if imported.accountId == original.accountId
                        || imported.email.caseInsensitiveCompare(original.email) == .orderedSame {
                        let refreshedId = accountManager.refreshStoredTokens(from: imported)
                        accountManager.clearPollingError(for: accountId)
                        if case .success(let quotaResult?) = validation,
                           let refreshedId {
                            accountManager.updateQuota(
                                for: refreshedId,
                                snapshot: quotaResult.snapshot,
                                planType: quotaResult.planType
                            )
                        }
                        persistAccountsSnapshot(context: "reauth-account")
                        startPollingForAccount(accountId)
                        refreshSubscriptionInfoIfNeeded(force: true)
                        if accountManager.activeAccount?.id == accountId,
                           let active = accountManager.activeAccount {
                            try? SwapEngine.writeAuthFile(for: active)
                            syncHermesLocal(account: active, reason: "reauth-account")
                            Task.detached { SwapEngine.signalCodexReload() }
                        }
                        statusBarController.updateIcon()
                        updatePopoverContent()
                        SwapLog.append(.debug("ACCOUNT_REAUTH_SUCCESS email=\(original.email)"))
                    } else {
                        if case .success(let quotaResult?) = validation {
                            var validated = imported
                            validated.quotaSnapshot = quotaResult.snapshot
                            validated.planType = quotaResult.planType
                            validated.lastRefreshed = quotaResult.snapshot.fetchedAt
                            accountManager.addAccount(validated)
                        } else {
                            accountManager.addAccount(imported)
                        }
                        persistAccountsSnapshot(context: "reauth-added-different-account")
                        startPollingForAccount(imported.id)
                        updatePopoverContent()
                        SwapLog.append(.debug("ACCOUNT_REAUTH_DIFFERENT_ACCOUNT expected=\(original.email) got=\(imported.email)"))
                    }
                }
            } catch {
                await MainActor.run {
                    accountManager.updatePollingError(for: accountId, error: "Re-authentication failed")
                    updatePopoverContent()
                    SwapLog.append(.debug("ACCOUNT_REAUTH_FAILED email=\(original.email) error=\(error.localizedDescription)"))
                }
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
        guard popoverContentInstalled, popover.contentViewController != nil else {
            popover.contentViewController = NSHostingController(
                rootView: PopoverContentView(
                    manager: accountManager,
                    onAddAccount: { [weak self] in self?.addAccount() },
                    onForceSwap: { [weak self] id in self?.forceSwap(to: id) },
                    onReauthenticate: { [weak self] id in self?.reauthenticateAccount(id) },
                    onOpenSettings: { [weak self] in self?.openSettings() }
                )
            )
            popoverContentInstalled = true
            return
        }

        guard forceRefresh || popover.isShown else { return }
        accountManager.requestUIRefresh()
    }

    @objc nonisolated private func statusBarClicked(_ sender: NSStatusBarButton) {
        Task { @MainActor [weak self] in
            let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            self?.handleStatusBarClicked(isRightClick: isRightClick)
        }
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
            CLIStatusChecker.refresh(activeAccountId: accountManager.activeAccount?.accountId) { [weak self] in
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

        popover?.performClose(nil)
        stopPopoverDismissalMonitoring()
        settingsWindow?.close()
        monitorTask?.cancel()
        desktopPatchRetryTask?.cancel()
        desktopPatchRetryTask = nil
        iconUpdateTimer?.invalidate()
        iconUpdateTimer = nil
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
        let emails = accountManager.accounts.map(\.email)
        Task {
            await quotaPoller.stopAll()
        }
        accountManager.accounts.removeAll()
        accountManager.swapHistory.removeAll()
        for email in emails {
            SwapLog.append(.accountRemoved(email: email))
        }
        do {
            try keychainStore.deleteAll()
        } catch {
            logger.error("Failed to clear Keychain: \(error.localizedDescription)")
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

        Task.detached { [weak self] in
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

            await MainActor.run {
                guard let self else { return }
                self.tokenUsageRefreshInFlight = false
                guard refreshSequence == self.tokenUsageRefreshSequence else {
                    SwapLog.append(.debug("TOKEN_USAGE_REFRESH_STALE ignored_sequence=\(refreshSequence) current_sequence=\(self.tokenUsageRefreshSequence)"))
                    return
                }
                let stabilized = self.tokenSavingsStore.stabilizedSummary(
                    current: self.accountManager.tokenSavingsSummary,
                    candidate: summary
                )
                if stabilized.keptPrevious, let previous = stabilized.previous {
                    self.accountManager.tokenSavingsSummary = stabilized.summary
                    SwapLog.append(.debug("TOKEN_USAGE_REFRESH_NON_MONOTONIC_IGNORED previous_api=\(String(format: "%.4f", previous.apiValueUSD)) candidate_api=\(String(format: "%.4f", summary.apiValueUSD)) previous_completions=\(previous.total.completionCount) candidate_completions=\(summary.total.completionCount)"))
                    self.updatePopoverContent()
                    return
                }
                self.accountManager.tokenSavingsSummary = stabilized.summary
                let sources = stabilized.summary.includedReports.map(\.source.rawValue).joined(separator: "+")
                let staleHighWaterReplaced = stabilized.previous != nil && stabilized.summary.apiValueUSD + 0.01 < (stabilized.previous?.apiValueUSD ?? 0)
                SwapLog.append(.debug("TOKEN_USAGE_REFRESH_ACCEPTED sequence=\(refreshSequence) api=\(String(format: "%.4f", stabilized.summary.apiValueUSD)) completions=\(stabilized.summary.total.completionCount) sources=\(sources) remote_included=\(stabilized.summary.includesRemoteUsage) stale_high_water_replaced=\(staleHighWaterReplaced)"))
                self.updatePopoverContent()
            }
        }
    }

    private func checkLinuxDevboxReadiness(force: Bool = false) {
        let settings = LinuxDevboxMonitor.settings()
        guard settings.isConfigured else {
            lastLinuxDevboxReady = nil
            lastLinuxDevboxFullCheckAt = nil
            linuxDevboxReadinessCheckInFlight = false
            lastLinuxDevboxAccountMirrorSucceededAt = nil
            linuxDevboxConsecutiveIssueChecks = 0
            accountManager.linuxDevboxStatus = .notConfigured
            updatePopoverContent()
            return
        }

        let hasActiveRemoteSession = LinuxDevboxMonitor.isCodexVPSRemoteSessionRunning()
        guard LinuxDevboxMonitor.shouldRunReadinessCheck(
            lastFullCheckAt: lastLinuxDevboxFullCheckAt,
            hasActiveRemoteSession: hasActiveRemoteSession,
            force: force
        ) else {
            return
        }
        guard !linuxDevboxReadinessCheckInFlight else {
            SwapLog.append(.debug("LINUX_DEVBOX_CHECK_SKIPPED reason=in_flight active_remote=\(hasActiveRemoteSession)"))
            return
        }
        linuxDevboxReadinessCheckInFlight = true

        if LinuxDevboxMonitor.activeAccountSyncMode(hasActiveRemoteSession: hasActiveRemoteSession) == .mirrorVPS {
            Task { [weak self] in
                let result = await Task.detached {
                    LinuxDevboxMonitor.fetchAccountStates(settings: settings)
                }.value
                guard let self else { return }
                self.linuxDevboxReadinessCheckInFlight = false
                self.lastLinuxDevboxReady = true
                self.linuxDevboxConsecutiveIssueChecks = 0
                switch result {
                case .success(let states):
                    self.lastLinuxDevboxAccountMirrorSucceededAt = Date()
                    let activeEmail = states.first(where: \.isActive)?.email ?? self.accountManager.linuxDevboxStatus.activeEmail
                    if let pendingEmail = self.pendingLinuxDevboxActiveEmail,
                       self.pendingLinuxDevboxActiveUntil.map({ $0 > Date() }) == true {
                        if activeEmail?.caseInsensitiveCompare(pendingEmail) != .orderedSame {
                            self.accountManager.linuxDevboxStatus = LinuxDevboxStatus(
                                state: .notReady,
                                summary: "VPS active account is \(activeEmail ?? "unknown"); pushing pending Mac swap to \(pendingEmail)",
                                activeEmail: activeEmail
                            )
                            SwapLog.append(.debug("LINUX_DEVBOX_ACTIVE_DIVERGED remote=\(activeEmail ?? "none") expected=\(pendingEmail)"))
                            self.pushLinuxDevboxActiveAccount(email: pendingEmail, reason: "pending-active-mismatch")
                            self.updatePopoverContent()
                            return
                        }
                        self.pendingLinuxDevboxActiveEmail = nil
                        self.pendingLinuxDevboxActiveUntil = nil
                        SwapLog.append(.debug("LINUX_DEVBOX_ACTIVE_CONFIRMED active=\(pendingEmail)"))
                    }
                    let mirrorRemoteActiveToLocal = !DesktopPatchManager.isCodexDesktopRuntimeRunning()
                    self.accountManager.linuxDevboxStatus = LinuxDevboxStatus(
                        state: .ready,
                        summary: mirrorRemoteActiveToLocal
                            ? "active Codex VPS remote session detected; account state mirrored"
                            : "active Codex VPS remote session detected; remote account status mirrored",
                        activeEmail: activeEmail
                    )
                    self.applyLinuxDevboxAccountStates(
                        states,
                        context: "linux-devbox-interactive-sync",
                        mirrorRemoteActiveToLocal: mirrorRemoteActiveToLocal
                    )
                    if mirrorRemoteActiveToLocal {
                        SwapLog.append(.debug("LINUX_DEVBOX_REMOTE_ACCOUNT_SYNCED active=\(activeEmail ?? "none") accounts=\(states.count)"))
                    } else {
                        SwapLog.append(.debug("LINUX_DEVBOX_REMOTE_ACCOUNT_STATUS_SYNCED remote_active=\(activeEmail ?? "none") local_active=\(self.accountManager.activeAccount?.email ?? "none") accounts=\(states.count)"))
                    }
                case .failure(let failure):
                    self.lastLinuxDevboxAccountMirrorSucceededAt = nil
                    self.accountManager.linuxDevboxStatus = LinuxDevboxStatus(
                        state: .ready,
                        summary: "active Codex VPS remote session detected; account mirror failed: \(failure.message)",
                        activeEmail: self.accountManager.linuxDevboxStatus.activeEmail
                    )
                    SwapLog.append(.debug("LINUX_DEVBOX_REMOTE_ACCOUNT_SYNC_FAILED message=\(failure.message)"))
                }
                self.updatePopoverContent()
            }
            return
        }

        lastLinuxDevboxFullCheckAt = Date()
        if accountManager.linuxDevboxStatus.shouldShowCheckingPlaceholderBeforeRefresh {
            accountManager.linuxDevboxStatus = .checking
            updatePopoverContent()
        }
        Task { [weak self] in
            if await NetworkBackoffGuard.shared.shouldDeferNonCriticalProbe(operation: "linux_devbox_readiness") {
                self?.linuxDevboxReadinessCheckInFlight = false
                return
            }
            let result = await Task.detached {
                LinuxDevboxMonitor.check(settings: settings)
            }.value
            guard let self else { return }
            defer {
                self.linuxDevboxReadinessCheckInFlight = false
            }
            switch result {
            case .success(let readiness):
                Task {
                    await NetworkBackoffGuard.shared.recordSuccess(operation: "linux_devbox_readiness")
                }
                let wasReady = self.lastLinuxDevboxReady
                self.lastLinuxDevboxReady = readiness.ready
                if readiness.ready {
                    self.linuxDevboxConsecutiveIssueChecks = 0
                } else {
                    self.linuxDevboxConsecutiveIssueChecks += 1
                    if LinuxDevboxStatus.shouldSuppressTransientIssue(
                        wasReady: wasReady,
                        consecutiveIssueChecks: self.linuxDevboxConsecutiveIssueChecks
                    ) {
                        SwapLog.append(.debug("LINUX_DEVBOX_TRANSIENT_NOT_READY summary=\(readiness.summary)"))
                        self.updatePopoverContent()
                        return
                    }
                }
                self.accountManager.linuxDevboxStatus = LinuxDevboxStatus(
                    state: readiness.ready ? .ready : .notReady,
                    summary: readiness.summary,
                    activeEmail: readiness.activeEmail
                )
                if readiness.ready {
                    SwapLog.append(.debug("LINUX_DEVBOX_READY summary=\(readiness.summary)"))
                } else if wasReady != false {
                    SwapLog.append(.debug("LINUX_DEVBOX_NOT_READY summary=\(readiness.summary)"))
                    NotificationManager.notifyLinuxDevboxReadinessIssue(summary: readiness.summary)
                }
            case .failure(let failure):
                Task {
                    await NetworkBackoffGuard.shared.recordFailure(failure.message, operation: "linux_devbox_readiness")
                }
                let wasReady = self.lastLinuxDevboxReady
                self.lastLinuxDevboxReady = false
                self.linuxDevboxConsecutiveIssueChecks += 1
                if LinuxDevboxStatus.shouldSuppressTransientIssue(
                    wasReady: wasReady,
                    consecutiveIssueChecks: self.linuxDevboxConsecutiveIssueChecks
                ) {
                    SwapLog.append(.debug("LINUX_DEVBOX_TRANSIENT_CHECK_FAILED message=\(failure.message)"))
                    self.updatePopoverContent()
                    return
                }
                self.accountManager.linuxDevboxStatus = LinuxDevboxStatus(
                    state: .failed,
                    summary: failure.message,
                    activeEmail: nil
                )
                if wasReady != false {
                    SwapLog.append(.debug("LINUX_DEVBOX_CHECK_FAILED message=\(failure.message)"))
                    NotificationManager.notifyLinuxDevboxReadinessIssue(summary: failure.message)
                }
            }
            self.updatePopoverContent()
        }
    }

    private func linuxDevboxAccountMirrorIsFresh(now: Date = Date()) -> Bool {
        guard let lastLinuxDevboxAccountMirrorSucceededAt else { return false }
        return now.timeIntervalSince(lastLinuxDevboxAccountMirrorSucceededAt)
            <= LinuxDevboxMonitor.activeRemoteAccountStatePollInterval * 4
    }

    private func applyLinuxDevboxAccountStates(
        _ states: [LinuxDevboxAccountState],
        context: String,
        mirrorRemoteActiveToLocal: Bool = true
    ) {
        guard !states.isEmpty else { return }
        let result = accountManager.applyLinuxDevboxAccountStatesWithResult(
            states,
            mirrorRemoteActive: mirrorRemoteActiveToLocal
        )
        guard result.stateChanged else { return }
        if !mirrorRemoteActiveToLocal,
           let remoteActive = states.first(where: \.isActive)?.email,
           remoteActive.caseInsensitiveCompare(accountManager.activeAccount?.email ?? "") != .orderedSame {
            SwapLog.append(.debug(
                "LINUX_DEVBOX_REMOTE_ACTIVE_STATUS_ONLY remote=\(remoteActive) local=\(accountManager.activeAccount?.email ?? "none") reason=codex_app_running"
            ))
        }
        let now = Date()
        let shouldPersist = result.activeChangedId != nil
            || lastLinuxDevboxAccountPersistAt == nil
            || now.timeIntervalSince(lastLinuxDevboxAccountPersistAt!) >= 60
        if shouldPersist {
            persistAccountsSnapshot(context: context)
        }
        if let changedId = result.activeChangedId, let active = accountManager.activeAccount {
            activateLinuxDevboxAccount(changedId: changedId, active: active, reason: context)
        } else {
            statusBarController.updateIcon()
            updatePopoverContent()
        }
    }

    private func activateLinuxDevboxAccount(changedId: UUID, active: CodexAccount, reason: String) {
        try? SwapEngine.writeAuthFile(for: active)
        syncHermesLocal(account: active, reason: reason)
        startPollingForAccount(changedId)
        Task.detached { SwapEngine.signalCodexReload() }
        SwapLog.append(.debug("LINUX_DEVBOX_ACTIVE_SYNC active=\(active.email) reason=\(reason)"))
        statusBarController.updateIcon()
        updatePopoverContent()
        CLIStatusChecker.refresh(activeAccountId: accountManager.activeAccount?.accountId) { [weak self] in
            self?.updatePopoverContent()
        }
    }

    private func pushLinuxDevboxActiveAccount(email: String, reason: String) {
        let settings = LinuxDevboxMonitor.settings()
        guard settings.isConfigured else { return }

        pendingLinuxDevboxActiveEmail = email
        pendingLinuxDevboxActiveUntil = Date().addingTimeInterval(120)
        guard !linuxDevboxActivePushInFlight else {
            SwapLog.append(.debug("LINUX_DEVBOX_ACTIVE_PUSH_SKIPPED reason=in_flight expected=\(email)"))
            return
        }
        linuxDevboxActivePushInFlight = true

        Task { [weak self] in
            let result = await Task.detached {
                LinuxDevboxMonitor.swapAccount(settings: settings, selector: email)
            }.value
            guard let self else { return }
            self.linuxDevboxActivePushInFlight = false
            switch result {
            case .success(let output):
                SwapLog.append(.debug("LINUX_DEVBOX_ACTIVE_PUSHED active=\(email) reason=\(reason) output=\(output)"))
                self.checkLinuxDevboxReadiness(force: true)
            case .failure(let failure):
                self.accountManager.linuxDevboxStatus = LinuxDevboxStatus(
                    state: .failed,
                    summary: "VPS active account push failed: \(failure.message)",
                    activeEmail: self.accountManager.linuxDevboxStatus.activeEmail
                )
                SwapLog.append(.debug("LINUX_DEVBOX_ACTIVE_PUSH_FAILED active=\(email) reason=\(reason) error=\(failure.message)"))
                NotificationManager.notifyLinuxDevboxReadinessIssue(summary: failure.message)
                self.updatePopoverContent()
            }
        }
    }
}
