import AppKit
import SwiftUI
import os
import Darwin

private let logger = Logger(subsystem: "com.codexswitch", category: "AppDelegate")

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
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Set in applicationDidFinishLaunching before any other access
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var statusBarController: StatusBarController!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    let accountManager = AccountManager()
    let versionChecker = CodexVersionChecker()
    private let keychainStore = KeychainStore()
    private let quotaPoller = QuotaPoller()
    private let weeklyPrimer = WeeklyPrimer()
    private let oauthManager = OAuthLoginManager()
    private var forkCheckCounter = 0
    private var primerCheckCounter = 0
    private var clickOutsideMonitor: Any?
    private var launchTime = Date()

    private var monitorTask: Task<Void, Never>?
    private var iconUpdateTimer: Timer?
    private var hasNotifiedAllExhausted = false
    private var lastLoggedPollSummary: String = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        installCrashHandlers()
        writeCrashLog("LAUNCH: applicationDidFinishLaunching started")

        NSApp.setActivationPolicy(.accessory)
        NotificationManager.requestPermission()

        // Status bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusBarController = StatusBarController(statusItem: statusItem, manager: accountManager)

        if let button = statusItem.button {
            button.action = #selector(statusBarClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusBarController.updateIcon()

        // Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 480, height: 520)
        popover.behavior = .transient
        updatePopoverContent()

        // Show onboarding on first launch
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        }

        // Load accounts from Keychain (async for file I/O), then start services
        Task { @MainActor in
            await loadAccounts()

            // Refresh onboarding account count after loading from Keychain
            updateOnboardingContent()

            // Prune old diagnostic logs (>7 days)
            SwapLog.pruneOldLogs()

            // Restore primed account indicators from persisted state
            if let saved = UserDefaults.standard.stringArray(forKey: "primedAccountIds") {
                for str in saved {
                    if let uuid = UUID(uuidString: str) {
                        accountManager.primedAccountIds.insert(uuid)
                    }
                }
            }

            // Start polling + monitoring
            startAllPolling()
            startSwapMonitor()

            // Ensure CLI is in sync — write auth.json + SIGHUP on every launch
            // so the CLI picks up the current account even after a CodexSwitch restart
            if let active = accountManager.activeAccount {
                try? SwapEngine.writeAuthFile(for: active)
                Task.detached { SwapEngine.signalCodexReload() }
            }

            // Update icon + status checks periodically
            writeCrashLog("LAUNCH: all services started, \(accountManager.accounts.count) accounts loaded, active=\(accountManager.activeAccount?.email ?? "none")")
            SwapLog.append(.appLaunched(
                accountCount: accountManager.accounts.count,
                activeEmail: accountManager.activeAccount?.email
            ))

            CLIStatusChecker.refresh(activeAccountId: accountManager.activeAccount?.accountId)
            versionChecker.autoRebuildIfNeeded() // Initial fork check on launch

            // Prime idle accounts' weekly timers after initial quota data arrives
            let primerAccounts = accountManager.accounts
            let primerManager = accountManager
            let primer = weeklyPrimer
            Task {
                // Wait 30s for initial quota polls to complete before priming
                try? await Task.sleep(for: .seconds(30))
                await primer.primeIfNeeded(
                    accounts: primerAccounts,
                    accountProvider: { @Sendable id in
                        await MainActor.run {
                            primerManager.accounts.first { $0.id == id }
                        }
                    },
                    onPrimed: { @Sendable id in
                        Task { @MainActor in primerManager.primedAccountIds.insert(id) }
                    }
                )
            }
            iconUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    // If auth.json changed externally, restart polling for new active account
                    let oldActiveEmail = self?.accountManager.activeAccount?.email
                    if let newActiveId = await self?.accountManager.syncWithAuthJson() {
                        let newEmail = self?.accountManager.accounts.first(where: { $0.id == newActiveId })?.email ?? "?"
                        SwapLog.append(.activeAccountChanged(from: oldActiveEmail, to: newEmail, source: "syncWithAuthJson"))
                        self?.startPollingForAccount(newActiveId)
                    }
                    self?.statusBarController.updateIcon()
                    // Only rebuild the popover content when it's closed — rebuilding
                    // while open causes the popover to resize and jump offscreen.
                    if self?.popover.isShown != true {
                        self?.updatePopoverContent()
                    }
                    CLIStatusChecker.refresh(activeAccountId: self?.accountManager.activeAccount?.accountId)

                    // Backup swap check — runs every 5s from the icon timer
                    // in case the swap monitor task died
                    self?.checkAndSwapIfNeeded()
                    self?.ensureActiveAccountPolling()

                    // Check fork status every 60s (every 12th tick)
                    if let self {
                        self.forkCheckCounter += 1
                        if self.forkCheckCounter >= 12 {
                            self.forkCheckCounter = 0
                            self.versionChecker.autoRebuildIfNeeded()
                            Self.healBundledBinaryIfNeeded()
                        }

                        // Prime idle accounts' weekly timers every 5min (every 60th tick)
                        self.primerCheckCounter += 1
                        if self.primerCheckCounter >= 60 {
                            self.primerCheckCounter = 0
                            let accounts = self.accountManager.accounts
                            let manager = self.accountManager
                            Task {
                                await self.weeklyPrimer.primeIfNeeded(
                                    accounts: accounts,
                                    accountProvider: { @Sendable id in
                                        await MainActor.run {
                                            manager.accounts.first { $0.id == id }
                                        }
                                    },
                                    onPrimed: { @Sendable id in
                                        Task { @MainActor in manager.primedAccountIds.insert(id) }
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let uptime = Int(Date().timeIntervalSince(launchTime))
        SwapLog.append(.appShutdown(uptimeSeconds: uptime))
        monitorTask?.cancel()
        iconUpdateTimer?.invalidate()
        // Use Task.detached to avoid MainActor deadlock — the main thread
        // is about to exit, so we just fire and let the process tear down.
        let poller = quotaPoller
        Task.detached { await poller.stopAll() }
    }

    // MARK: - Account Management

    private func loadAccounts() async {
        do {
            let accounts = try keychainStore.loadAll()
            for account in accounts {
                accountManager.addAccount(account)
            }
            await accountManager.restoreActiveAccount()
        } catch {
            logger.error("Failed to load accounts: \(error.localizedDescription)")
        }
    }

    private func addAccount() {
        Task {
            SwapLog.append(.oauthFlowStarted)
            do {
                var account = try await oauthManager.performLogin()
                SwapLog.append(.oauthFlowCompleted(email: account.email))
                if accountManager.accounts.isEmpty {
                    account.isActive = true
                }
                accountManager.addAccount(account)
                try keychainStore.save(account)
                startPollingForAccount(account.id)
                statusBarController.updateIcon()
                updatePopoverContent()
                updateOnboardingContent()

                // Show popover to confirm the account was added (only if not onboarding)
                if onboardingWindow == nil, let button = statusItem.button {
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                    NSApp.activate()
                }

                SwapLog.append(.accountAdded(email: account.email))
                logger.info("Account added: \(account.email)")
            } catch {
                SwapLog.append(.oauthFlowFailed(error: error.localizedDescription))
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

    private func stopPollingForAccount(_ accountId: UUID, reason: String) {
        let email = accountManager.accounts.first(where: { $0.id == accountId })?.email ?? "?"
        SwapLog.append(.pollerStopped(email: email, reason: reason))
        Task { await quotaPoller.stopPolling(for: accountId) }
    }

    private func startPollingForAccount(_ accountId: UUID) {
        let email = accountManager.accounts.first(where: { $0.id == accountId })?.email ?? "?"
        let isActive = accountManager.activeAccount?.id == accountId
        SwapLog.append(.pollerStarted(email: email, intervalSeconds: isActive ? 5 : 300))
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
                        self?.accountManager.updateQuota(for: id, snapshot: snapshot, planType: planType)
                        self?.statusBarController.updateIcon()

                        // Log active account polls on value change (not every 5s)
                        if self?.accountManager.activeAccount?.id == id {
                            let fh = String(format: "%.1f", snapshot.fiveHour.remainingPercent)
                            let wk = String(format: "%.1f", snapshot.weekly.remainingPercent)
                            let summary = "\(fh)|\(wk)|\(snapshot.fiveHour.isExhausted)"
                            if summary != self?.lastLoggedPollSummary {
                                self?.lastLoggedPollSummary = summary
                                let email = self?.accountManager.accounts.first(where: { $0.id == id })?.email ?? "?"
                                SwapLog.append(.debug("ACTIVE_POLL \(email) 5h=\(fh)% wk=\(wk)% exhausted=\(snapshot.fiveHour.isExhausted)"))
                            }
                        }

                        // Immediate swap check if active account is exhausted
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
                        case .httpError(let code):
                            errorMsg = "API error (HTTP \(code))"
                        case .invalidResponse:
                            errorMsg = "Invalid response"
                        case .networkError(let msg):
                            errorMsg = "Network error: \(msg)"
                        }
                        SwapLog.append(.pollError(accountEmail: email, error: errorMsg))
                        logger.error("Polling error for \(id): \(errorMsg)")
                        self?.accountManager.updatePollingError(for: id, error: errorMsg)
                    }
                }
            )
        }
    }

    private func refreshToken(for accountId: UUID) async {
        guard let account = accountManager.accounts.first(where: { $0.id == accountId }) else { return }
        do {
            let updated = try await TokenRefresher.refresh(account)
            accountManager.addAccount(updated)
            do {
                try keychainStore.save(updated)
            } catch {
                logger.warning("Failed to persist refreshed token for \(accountId): \(error.localizedDescription)")
            }
            // Same-account refresh — SIGHUP is safe here since the conversation
            // thread is still valid (same account, just new tokens)
            if account.isActive {
                try? SwapEngine.writeAuthFile(for: updated)
                Task.detached { SwapEngine.signalCodexReload() }
            }
            SwapLog.append(.tokenRefreshed(email: account.email))
            startPollingForAccount(accountId)
        } catch {
            SwapLog.append(.tokenRefreshFailed(email: account.email, error: error.localizedDescription))

            // Mark this account as having a dead token — excludes it from swap
            // candidates and stops polling. Only notify once per account.
            if !accountManager.deadTokenAccountIds.contains(account.id) {
                accountManager.deadTokenAccountIds.insert(account.id)
                NotificationManager.notifyTokenRefreshFailed(account: account)
            }

            // Stop polling this account — the refresh token is dead,
            // retrying every 60s just wastes cycles and spams notifications.
            stopPollingForAccount(account.id, reason: "token_dead")

            // If the ACTIVE account's token is dead, swap away immediately.
            if account.isActive {
                logger.error("Active account \(account.email) token dead — emergency swap")
                SwapLog.append(.debug("EMERGENCY_SWAP: active account token dead, swapping away"))
                let candidates = accountManager.accounts.filter {
                    !accountManager.deadTokenAccountIds.contains($0.id)
                }
                if let best = SwapEngine.selectOptimalAccount(from: candidates),
                   best.quotaSnapshot != nil {
                    executeSwap(from: account, to: best, reason: .quotaExhausted)
                }
            }
        }
    }

    // MARK: - Swap Monitor

    private func startSwapMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    break // Task was cancelled
                }
                guard let self else { break }
                await MainActor.run {
                    self.checkAndSwapIfNeeded()
                    self.ensureActiveAccountPolling()
                }
            }
            // If we get here, the monitor died — restart it
            if !Task.isCancelled {
                await MainActor.run {
                    SwapLog.append(.debug("SWAP_MONITOR_DIED — restarting"))
                    self?.startSwapMonitor()
                }
            }
        }
    }

    // MARK: - Binary Watchdog

    /// Self-healing watchdog: if the Codex app-server binary in the app bundle
    /// is too old (Sparkle overwrote it, etc.), replace it from our cached copy.
    /// Runs every 60s from the icon update timer.
    private nonisolated static let cachedBinaryPath = NSString("~/.codexswitch/cache/codex-latest").expandingTildeInPath
    private nonisolated static let bundledBinaryPaths = [
        "/Applications/Codex.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/bin/codex",
    ]
    private nonisolated static let minRequiredVersion = "0.117.0"

    private nonisolated static func healBundledBinaryIfNeeded() {
        Task.detached {
            let fm = FileManager.default
            guard fm.fileExists(atPath: cachedBinaryPath) else { return }

            for dest in bundledBinaryPaths {
                guard fm.fileExists(atPath: dest) else { continue }
                let version = CodexVersionChecker._getBinaryVersion(dest)
                guard !version.isEmpty else { continue }
                if version.compare(minRequiredVersion, options: .numeric) == .orderedAscending {
                    // Binary is too old — replace from cache
                    do {
                        try? fm.removeItem(atPath: dest)
                        try fm.copyItem(atPath: cachedBinaryPath, toPath: dest)
                        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
                        let newVersion = CodexVersionChecker._getBinaryVersion(dest)
                        SwapLog.append(.debug("BINARY_HEALED \(dest) \(version) → \(newVersion)"))
                    } catch {
                        SwapLog.append(.debug("BINARY_HEAL_FAILED \(dest) error=\(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    /// Safety net: if the active account hasn't had a quota update in over 30s,
    /// the poller likely died silently. Restart it.
    private func ensureActiveAccountPolling() {
        guard let active = accountManager.activeAccount else { return }
        let staleCutoff: TimeInterval = 15  // active account should poll every 5s

        if let snapshot = active.quotaSnapshot {
            let age = Date().timeIntervalSince(snapshot.fetchedAt)
            if age > staleCutoff {
                logger.warning("Active account \(active.email, privacy: .private) quota data is \(String(format: "%.0f", age))s stale — restarting poller")
                SwapLog.append(.debug("POLLER_RESTART: \(active.email) stale \(Int(age))s"))
                startPollingForAccount(active.id)
            }
        } else {
            // No quota data at all — poller never completed a fetch
            logger.warning("Active account \(active.email, privacy: .private) has no quota data — starting poller")
            SwapLog.append(.debug("POLLER_START: \(active.email) no quota data"))
            startPollingForAccount(active.id)
        }
    }

    private func checkAndSwapIfNeeded() {
        // Grace period: don't swap within 15s of launch — stale quota data
        // from the previous session may falsely show exhaustion before the
        // poller fetches fresh data.
        let sincelaunch = Date().timeIntervalSince(launchTime)
        guard sincelaunch > 15 else {
            SwapLog.append(.swapDecisionSkipped(reason: "grace_period(\(Int(15 - sincelaunch))s remaining)"))
            return
        }

        guard let active = accountManager.activeAccount else {
            SwapLog.append(.swapDecisionSkipped(reason: "no_active_account"))
            return
        }
        guard let snapshot = active.quotaSnapshot else {
            SwapLog.append(.swapDecisionSkipped(reason: "no_snapshot"))
            return
        }

        let fhLow = snapshot.fiveHour.isExhausted
        let wkLow = snapshot.weekly.isExhausted

        // Not exhausted = happy path. Don't log — fires every 5s.
        guard fhLow || wkLow else { return }

        guard let best = SwapEngine.selectOptimalAccount(from: accountManager.accounts),
              let bestSnapshot = best.quotaSnapshot else {
            if !hasNotifiedAllExhausted {
                SwapLog.append(.swapDecisionSkipped(reason: "all_exhausted"))
                NotificationManager.notifyAllExhausted()
                hasNotifiedAllExhausted = true
            }
            return
        }

        // A candidate is available — reset the exhaustion flag
        hasNotifiedAllExhausted = false

        // Only swap if the candidate can actually serve requests right now
        // (has usable 5h AND weekly). This prevents all ping-pong scenarios:
        // - Both accounts 5h-exhausted → neither can serve, don't swap
        // - Active has 5h but low weekly, candidate has no 5h → stay put
        let candidateReady = !bestSnapshot.fiveHour.isExhausted
            && !bestSnapshot.weekly.isExhausted
        guard candidateReady else {
            SwapLog.append(.swapDecisionSkipped(reason: "candidate_not_ready(\(best.email))"))
            return
        }

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
            SwapLog.append(.authFileWritten(accountId: to.accountId))

            // 2. Hot-swap both CLI and desktop app:
            // - CLI (TUI/exec): SIGHUP → fork handler reloads auth.json instantly
            // - Desktop app-server: the fork binary's file watcher polls auth.json
            //   mtime every 2s, detects the change, reloads auth, and notifies
            //   the Electron frontend. No restart or SIGHUP needed.
            Task.detached {
                SwapEngine.signalCodexReload()
            }

            // 3. Always promote immediately
            accountManager.setActive(to.id)
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

    /// Re-login an account with a dead token via OAuth.
    /// Triggers the same OAuth flow as addAccount but updates the existing account in place.
    private func reloginAccount(_ accountId: UUID) {
        guard let existing = accountManager.accounts.first(where: { $0.id == accountId }) else { return }
        Task {
            SwapLog.append(.oauthFlowStarted)
            do {
                let freshAccount = try await oauthManager.performLogin()
                SwapLog.append(.oauthFlowCompleted(email: freshAccount.email))
                // Verify the user logged in with the same OpenAI account
                guard freshAccount.accountId == existing.accountId else {
                    logger.warning("Re-login account mismatch: expected \(existing.accountId), got \(freshAccount.accountId)")
                    // Still add it — it's a valid account, just not the one they intended
                    accountManager.addAccount(freshAccount)
                    try keychainStore.save(freshAccount)
                    startPollingForAccount(freshAccount.id)
                    updatePopoverContent()
                    return
                }
                // Update existing account with fresh tokens (clears dead token flag)
                accountManager.addAccount(freshAccount)
                try keychainStore.save(CodexAccount(
                    id: existing.id,
                    email: freshAccount.email,
                    accessToken: freshAccount.accessToken,
                    refreshToken: freshAccount.refreshToken,
                    idToken: freshAccount.idToken,
                    accountId: freshAccount.accountId,
                    quotaSnapshot: existing.quotaSnapshot,
                    planType: existing.planType,
                    isActive: existing.isActive
                ))
                startPollingForAccount(existing.id)
                if existing.isActive {
                    try? SwapEngine.writeAuthFile(for: accountManager.accounts.first(where: { $0.id == existing.id })!)
                    Task.detached { SwapEngine.signalCodexReload() }
                }
                SwapLog.append(.tokenRefreshed(email: existing.email))
                logger.info("Re-login succeeded for \(existing.email)")
                updatePopoverContent()
            } catch {
                SwapLog.append(.oauthFlowFailed(error: error.localizedDescription))
                logger.error("Re-login failed for \(existing.email): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Popover

    private func updatePopoverContent() {
        // Don't replace the content view while the popover is visible — it causes
        // the popover to resize and jump offscreen. The SwiftUI views observe
        // accountManager via @Observable so they update reactively already.
        guard !popover.isShown else { return }
        popover.contentViewController = NSHostingController(
            rootView: PopoverContentView(
                manager: accountManager,
                versionChecker: versionChecker,
                onAddAccount: { [weak self] in self?.addAccount() },
                onForceSwap: { [weak self] id in self?.forceSwap(to: id) },
                onRelogin: { [weak self] id in self?.reloginAccount(id) },
                onOpenSettings: { [weak self] in self?.openSettings() }
            )
        )
    }

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showStatusBarMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            updatePopoverContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()

            // Global click monitor — closes popover when clicking anywhere outside
            clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePopover()
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    private func showStatusBarMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Restart CodexSwitch", action: #selector(restartApp), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit CodexSwitch", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Clear menu so left-click goes back to popover
        statusItem.menu = nil
    }

    @objc private func restartApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
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

    // MARK: - Onboarding

    private func showOnboarding() {
        let onboardingView = OnboardingView(
            onAddAccount: { [weak self] in self?.addAccount() },
            onComplete: { [weak self] in self?.completeOnboarding() },
            accountCount: accountManager.accounts.count
        )
        let hostingController = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to CodexSwitch"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        onboardingWindow?.close()
        onboardingWindow = nil

        // Show the popover so the user sees the menu bar UI
        if let button = statusItem.button {
            updatePopoverContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
        }
    }

    /// Rebuild the onboarding window content to reflect current account count.
    /// Called after addAccount and loadAccounts to keep the checkmarks in sync.
    private func updateOnboardingContent() {
        guard onboardingWindow != nil else { return }
        let onboardingView = OnboardingView(
            onAddAccount: { [weak self] in self?.addAccount() },
            onComplete: { [weak self] in self?.completeOnboarding() },
            accountCount: accountManager.accounts.count
        )
        onboardingWindow?.contentViewController = NSHostingController(rootView: onboardingView)
    }
}
