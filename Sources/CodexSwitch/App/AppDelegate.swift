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
    for sig: Int32 in [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP] {
        signal(sig) { sigNum in
            // Only raw POSIX write to stderr — no Foundation, no heap alloc
            var msg = "FATAL SIGNAL: \(sigNum)\n"
            msg.withUTF8 { buf in
                _ = Darwin.write(STDERR_FILENO, buf.baseAddress, buf.count)
            }
            Darwin.signal(sigNum, SIG_DFL)
            Darwin.raise(sigNum)
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
    private let oauthManager = OAuthLoginManager()

    private var monitorTask: Task<Void, Never>?
    private var iconUpdateTimer: Timer?

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

        // Load accounts from Keychain
        loadAccounts()

        // Prune old diagnostic logs (>7 days)
        SwapLog.pruneOldLogs()

        // Start polling + monitoring
        startAllPolling()
        startSwapMonitor()

        // Update icon + status checks periodically
        writeCrashLog("LAUNCH: all services started, \(accountManager.accounts.count) accounts loaded, active=\(accountManager.activeAccount?.email ?? "none")")

        CLIStatusChecker.refresh(activeAccountId: accountManager.activeAccount?.accountId)
        iconUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // If auth.json changed externally, restart polling for new active account
                if let newActiveId = self?.accountManager.syncWithAuthJson() {
                    self?.startPollingForAccount(newActiveId)
                }
                self?.statusBarController.updateIcon()
                self?.updatePopoverContent()
                CLIStatusChecker.refresh(activeAccountId: self?.accountManager.activeAccount?.accountId)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorTask?.cancel()
        iconUpdateTimer?.invalidate()
        let poller = quotaPoller
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await poller.stopAll()
            semaphore.signal()
        }
        semaphore.wait()
    }

    // MARK: - Account Management

    private func loadAccounts() {
        do {
            let accounts = try keychainStore.loadAll()
            for account in accounts {
                accountManager.addAccount(account)
            }
            accountManager.restoreActiveAccount()
        } catch {
            logger.error("Failed to load accounts: \(error.localizedDescription)")
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
                try keychainStore.save(account)
                startPollingForAccount(account.id)
                statusBarController.updateIcon()
                updatePopoverContent()

                // Show popover to confirm the account was added
                if let button = statusItem.button {
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
                        self?.accountManager.updateQuota(for: id, snapshot: snapshot, planType: planType)
                        self?.statusBarController.updateIcon()
                        // Immediate swap check if active account is approaching exhaustion
                        if self?.accountManager.activeAccount?.id == id,
                           (snapshot.fiveHour.remainingPercent < Self.preemptiveSwapPercent
                            || snapshot.weekly.remainingPercent < Self.preemptiveSwapPercent) {
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
            NotificationManager.notifyTokenRefreshFailed(account: account)
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

    /// Pre-emptive swap threshold — swap BEFORE hitting 0% so the user's
    /// next message goes through on the fresh account without interruption.
    /// 1% maximizes usage per account while still swapping before the wall.
    private static let preemptiveSwapPercent: Double = 1

    private func checkAndSwapIfNeeded() {
        guard let active = accountManager.activeAccount,
              let snapshot = active.quotaSnapshot else { return }

        let needsSwap = snapshot.fiveHour.remainingPercent < Self.preemptiveSwapPercent
            || snapshot.weekly.remainingPercent < Self.preemptiveSwapPercent

        guard needsSwap else { return }

        guard let best = SwapEngine.selectOptimalAccount(from: accountManager.accounts) else {
            NotificationManager.notifyAllExhausted()
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

            // 2. SIGHUP + desktop injection — run off main thread
            let shouldSighup = reason == .quotaExhausted
            Task.detached {
                if shouldSighup {
                    SwapEngine.signalCodexReload()
                } else {
                    SwapLog.append(.sighupSkipped(reason: "manual swap — session continuity"))
                }
                let injected = await DesktopAppConnector.tryInjectTokens(for: to)
                if injected {
                    SwapLog.append(.desktopAppInjected(port: 0))
                }
            }

            accountManager.setActive(to.id)
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
