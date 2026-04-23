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

    let accountManager = AccountManager()
    private let keychainStore = KeychainStore()
    private let quotaPoller = QuotaPoller()
    private let weeklyPrimer = WeeklyPrimer()
    private let oauthManager = OAuthLoginManager()
    private let codexAutoPatchMonitor = CodexAutoPatchMonitor()

    private var monitorTask: Task<Void, Never>?
    private var iconUpdateTimer: Timer?
    private var lastAutoSwapAt: Date?
    private let autoSwapCooldown: TimeInterval = 30

    private func persistAccounts() {
        do {
            try keychainStore.replaceAll(accountManager.accounts)
        } catch {
            logger.warning("Failed to persist account state: \(error.localizedDescription)")
        }
    }

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
        popover.contentSize = NSSize(width: 540, height: 480)
        popover.behavior = .transient
        updatePopoverContent()

        // Load accounts from Keychain (async for file I/O), then start services
        Task { @MainActor in
            await loadAccounts()

            // Prune old diagnostic logs (>7 days)
            SwapLog.pruneOldLogs()

            // Start polling + monitoring
            startAllPolling()
            startSwapMonitor()

            // Ensure CLI is in sync on launch, but don't SIGHUP existing sessions.
            // Launch-time auth alignment should never disrupt an active terminal run.
            if let active = accountManager.activeAccount {
                try? SwapEngine.writeAuthFile(for: active)
            }

            codexAutoPatchMonitor.start()

            // Update icon + status checks periodically
            writeCrashLog("LAUNCH: all services started, \(accountManager.accounts.count) accounts loaded, active=\(accountManager.activeAccount?.email ?? "none")")

            CLIStatusChecker.refresh(activeAccountId: accountManager.activeAccount?.accountId)
            iconUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    // If auth.json changed externally, restart polling for new active account
                    if let syncResult = await self?.accountManager.syncWithAuthJson() {
                        self?.persistAccounts()
                        if syncResult.activeAccountChanged {
                            self?.startPollingForAccount(syncResult.activeAccountId)
                            self?.checkAndSwapIfNeeded()
                        }
                    }
                    self?.statusBarController.updateIcon()
                    self?.updatePopoverContent()
                    CLIStatusChecker.refresh(activeAccountId: self?.accountManager.activeAccount?.accountId)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorTask?.cancel()
        iconUpdateTimer?.invalidate()
        codexAutoPatchMonitor.stop()
        Task { [quotaPoller] in
            await quotaPoller.stopAll()
        }
    }

    // MARK: - Account Management

    private func loadAccounts() async {
        do {
            let accounts = try keychainStore.loadAll()
            accountManager.accounts = accounts
            await accountManager.restoreActiveAccount()
            persistAccounts()
        } catch {
            logger.error("Failed to load accounts: \(error.localizedDescription)")
        }
    }

    private func addAccount(replacingLocalId: UUID? = nil) {
        Task {
            do {
                var account = try await oauthManager.performLogin()
                let hadNoAccounts = accountManager.accounts.isEmpty
                if hadNoAccounts {
                    account.isActive = true
                }

                let preferredLocalId: UUID?
                if let replacingLocalId,
                   let existing = accountManager.accounts.first(where: { $0.id == replacingLocalId }),
                   existing.accountId == account.accountId
                    || existing.email.caseInsensitiveCompare(account.email) == .orderedSame {
                    preferredLocalId = replacingLocalId
                } else {
                    preferredLocalId = nil
                }

                let upsert = accountManager.addAccount(account, preferredLocalId: preferredLocalId)
                persistAccounts()

                guard let storedAccount = accountManager.accounts.first(where: { $0.id == upsert.localId }) else {
                    return
                }

                if hadNoAccounts {
                    accountManager.setActive(storedAccount.id)
                    persistAccounts()
                }

                startPollingForAccount(storedAccount.id)

                if storedAccount.isActive {
                    try? SwapEngine.writeAuthFile(for: storedAccount)
                    Task.detached {
                        _ = await DesktopAppConnector.tryInjectTokens(for: storedAccount)
                    }
                }

                statusBarController.updateIcon()
                updatePopoverContent()

                // Show popover to confirm the account was added
                if let button = statusItem.button {
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                    NSApp.activate()
                }

                switch upsert.action {
                case .inserted:
                    SwapLog.append(.accountAdded(email: storedAccount.email))
                    logger.info("Account added: \(storedAccount.email)")
                case .updated:
                    SwapLog.append(.debug("ACCOUNT_REAUTHED email=\(storedAccount.email)"))
                    logger.info("Account tokens updated: \(storedAccount.email)")
                }
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
                        self?.accountManager.updateQuota(for: id, snapshot: snapshot, planType: planType)
                        self?.persistAccounts()
                        self?.statusBarController.updateIcon()
                        self?.checkAndSwapIfNeeded()
                        self?.primeIdleAccountsIfNeeded()
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
            let upsert = accountManager.addAccount(updated, preferredLocalId: accountId)
            persistAccounts()
            // Preserve current CLI sessions. Future launches pick up the fresh auth file.
            if let storedAccount = accountManager.accounts.first(where: { $0.id == upsert.localId }),
               storedAccount.isActive {
                try? SwapEngine.writeAuthFile(for: storedAccount)
            }
            SwapLog.append(.tokenRefreshed(email: account.email))
            startPollingForAccount(upsert.localId)
        } catch {
            SwapLog.append(.tokenRefreshFailed(email: account.email, error: error.localizedDescription))
            accountManager.markReauthenticationRequired(
                for: accountId,
                detail: "refresh token rejected — click Re-authenticate"
            )
            persistAccounts()
            NotificationManager.notifyTokenRefreshFailed(account: account)
            statusBarController.updateIcon()
            updatePopoverContent()
        }
    }

    private func primeIdleAccountsIfNeeded() {
        let accounts = accountManager.accounts
        guard accounts.contains(where: { account in
            guard !account.isActive, let snapshot = account.quotaSnapshot else { return false }
            return snapshot.fiveHour.remainingPercent >= 99.5 || snapshot.weekly.remainingPercent >= 99.5
        }) else {
            return
        }

        let manager = accountManager
        let pollRestart: @Sendable (UUID) -> Void = { [weak self] id in
            Task { @MainActor in
                self?.startPollingForAccount(id)
            }
        }

        Task.detached { [weeklyPrimer] in
            await weeklyPrimer.primeIfNeeded(
                accounts: accounts,
                accountProvider: { @Sendable id in
                    await MainActor.run {
                        manager.accounts.first { $0.id == id }
                    }
                },
                onPrimed: pollRestart
            )
        }
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
        if let lastAutoSwapAt,
           Date().timeIntervalSince(lastAutoSwapAt) < autoSwapCooldown {
            return
        }

        guard let active = accountManager.activeAccount,
              let activeSnapshot = active.quotaSnapshot else { return }

        let activeNeedsRelief = activeSnapshot.fiveHour.isExhausted
            || activeSnapshot.weekly.isExhausted

        guard let best = SwapEngine.selectOptimalAccount(from: accountManager.accounts) else {
            if activeNeedsRelief {
                NotificationManager.notifyAllExhausted()
            }
            return
        }
        guard SwapEngine.shouldSwap(from: active, to: best) else { return }

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

            // 2. Hot-reload eligible live CLI sessions and update the desktop app.
            // SwapEngine gates SIGHUP on verified patched installs and filters out
            // Codex.app bundled/background processes, so this is safe for manual clicks.
            Task.detached {
                SwapEngine.signalCodexReload()
                let injected = await DesktopAppConnector.tryInjectTokens(for: to)
                if injected {
                    SwapLog.append(.desktopAppInjected(port: 0))
                }
            }

            accountManager.setActive(to.id)
            if reason == .quotaExhausted {
                lastAutoSwapAt = Date()
            }
            persistAccounts()
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

    // MARK: - Popover

    private func updatePopoverContent() {
        popover.contentViewController = NSHostingController(
            rootView: PopoverContentView(
                manager: accountManager,
                onAddAccount: { [weak self] in self?.addAccount() },
                onForceSwap: { [weak self] id in self?.forceSwap(to: id) },
                onReauthenticate: { [weak self] id in self?.addAccount(replacingLocalId: id) },
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
            popover.performClose(nil)
        } else {
            updatePopoverContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
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
}
