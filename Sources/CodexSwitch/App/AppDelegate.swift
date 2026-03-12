import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "AppDelegate")

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

    private var monitorTask: Task<Void, Never>?
    private var iconUpdateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationManager.requestPermission()

        // Status bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusBarController = StatusBarController(statusItem: statusItem, manager: accountManager)

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
        statusBarController.updateIcon()

        // Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 500, height: 420)
        popover.behavior = .transient
        updatePopoverContent()

        // Load accounts from Keychain
        loadAccounts()

        // Start polling + monitoring
        startAllPolling()
        startSwapMonitor()

        // Update icon periodically
        iconUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.statusBarController.updateIcon()
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
            if accountManager.activeAccount == nil, let first = accountManager.accounts.first {
                accountManager.setActive(first.id)
            }
        } catch {
            logger.error("Failed to load accounts: \(error.localizedDescription)")
        }
    }

    private func importCurrentAccount() {
        do {
            var account = try AccountImporter.importCurrentAccount()
            if accountManager.accounts.isEmpty {
                account.isActive = true
            }
            accountManager.addAccount(account)
            try keychainStore.save(account)
            startPollingForAccount(account.id)
            updatePopoverContent()
        } catch {
            logger.error("Import failed: \(error.localizedDescription)")
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
                onUpdate: { [weak self] id, snapshot in
                    Task { @MainActor in
                        self?.accountManager.updateQuota(for: id, snapshot: snapshot)
                        self?.statusBarController.updateIcon()
                    }
                },
                onError: { [weak self] id, error in
                    if case .tokenExpired = error {
                        Task { @MainActor in
                            await self?.refreshToken(for: id)
                        }
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
            startPollingForAccount(accountId)
        } catch {
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

    private func checkAndSwapIfNeeded() {
        guard let active = accountManager.activeAccount,
              let snapshot = active.quotaSnapshot,
              snapshot.fiveHour.isExhausted else { return }

        guard let best = SwapEngine.selectOptimalAccount(from: accountManager.accounts) else {
            NotificationManager.notifyAllExhausted()
            return
        }

        executeSwap(from: active, to: best, reason: .quotaExhausted)
    }

    private func executeSwap(from: CodexAccount, to: CodexAccount, reason: SwapEvent.SwapReason) {
        do {
            try SwapEngine.writeAuthFile(for: to)
            accountManager.setActive(to.id)

            let event = SwapEvent(
                fromAccountId: from.id,
                toAccountId: to.id,
                reason: reason,
                timestamp: Date()
            )
            accountManager.recordSwap(event)

            NotificationManager.notifySwap(from: from, to: to)
            statusBarController.updateIcon()
            updatePopoverContent()
        } catch {
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
                onImportAccount: { [weak self] in self?.importCurrentAccount() },
                onForceSwap: { [weak self] id in self?.forceSwap(to: id) },
                onOpenSettings: { [weak self] in self?.openSettings() }
            )
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            updatePopoverContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
        }
    }

    private func openSettings() {
        if settingsWindow == nil {
            let hostingController = NSHostingController(rootView: SettingsView())
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
