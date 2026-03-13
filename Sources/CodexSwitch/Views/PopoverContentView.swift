import SwiftUI

struct PopoverContentView: View {
    @Bindable var manager: AccountManager
    var onAddAccount: () -> Void
    var onForceSwap: (UUID) -> Void
    var onOpenSettings: () -> Void

    private static let relativeFormatter = RelativeDateTimeFormatter()

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    private static func quotaColor(for percent: Double) -> Color {
        switch percent {
        case 50...: return .green
        case 20..<50: return .yellow
        case 5..<20: return .orange
        default: return .red
        }
    }

    /// Find the non-active account whose weekly resets soonest (for "Next Available" fallback)
    private static func nextWeeklyResetAccount(from accounts: [CodexAccount]) -> (account: CodexAccount, formattedTime: String)? {
        let candidates = accounts
            .filter { !$0.isActive && $0.quotaSnapshot != nil }
            .compactMap { account -> (CodexAccount, TimeInterval)? in
                guard let resetTime = account.quotaSnapshot?.weekly.resetsAt else { return nil }
                let seconds = resetTime.timeIntervalSinceNow
                guard seconds > 0 else { return nil }
                return (account, seconds)
            }
            .sorted { $0.1 < $1.1 }

        guard let best = candidates.first else { return nil }
        let secs = best.1
        let hours = Int(secs) / 3600
        let mins = (Int(secs) % 3600) / 60
        let formatted = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        return (best.0, formatted)
    }

    private var connectionStatus: (icon: String, label: String, color: Color) {
        if manager.accounts.isEmpty {
            return ("bolt.slash.fill", "No accounts — tap + to add one", .secondary)
        }
        let hasQuotaData = manager.accounts.contains { $0.quotaSnapshot != nil }
        let hasErrors = manager.accounts.contains { manager.pollingErrors[$0.id] != nil }
        if hasErrors && !hasQuotaData {
            let firstError = manager.accounts.compactMap { manager.pollingErrors[$0.id] }.first ?? "Unknown error"
            return ("exclamationmark.triangle.fill", firstError, .red)
        }
        if !hasQuotaData {
            return ("bolt.badge.clock.fill", "Connecting — waiting for quota data...", .orange)
        }
        let connectedCount = manager.accounts.filter { $0.quotaSnapshot != nil }.count
        if hasErrors {
            return ("exclamationmark.triangle.fill", "\(connectedCount)/\(manager.accounts.count) connected — some errors", .orange)
        }
        return ("bolt.fill", "\(connectedCount)/\(manager.accounts.count) accounts connected", .green)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CodexSwitch")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let active = manager.activeAccount {
                    Text(active.email)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button(action: onOpenSettings) {
                    Image(systemName: "gear")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Connection status banner
            let status = connectionStatus
            HStack(spacing: 6) {
                Image(systemName: status.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(status.color)
                Text(status.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.08))

            Divider()

            if manager.accounts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No accounts imported")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Sign in with your ChatGPT account to get started")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Button(action: onAddAccount) {
                        Label("Add Account", systemImage: "plus.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.vertical, 30)
                .padding(.horizontal, 20)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(manager.sortedAccounts) { account in
                        AccountCardView(
                            account: account,
                            pollingError: manager.pollingErrors[account.id]
                        ) {
                            onForceSwap(account.id)
                        }
                    }
                }
                .padding(10)
            }

            // Pooled usage meter — aggregate capacity vs Pro
            if manager.accounts.count > 1 {
                Divider()
                PooledUsageMeterView(accounts: manager.accounts)
            }

            // Current account + CLI status + Next up
            if let active = manager.activeAccount {
                Divider()

                // Current account
                HStack(spacing: 6) {
                    Image(systemName: "person.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Current Account")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(active.email)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Spacer()
                    if let snapshot = active.quotaSnapshot {
                        let fhPct = snapshot.fiveHour.remainingPercent
                        let wkPct = snapshot.weekly.remainingPercent
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(Int(fhPct))% 5h")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Self.quotaColor(for: fhPct))
                            Text("\(Int(wkPct))% wk")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(Self.quotaColor(for: wkPct))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)

                // CLI connection status (read from cache, never block main thread)
                let cliStatus = CLIStatusChecker.cachedCLIStatus
                HStack(spacing: 4) {
                    Image(systemName: cliStatus.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(cliStatus.isHealthy ? .green : .orange)
                    Text(cliStatus.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(cliStatus.isHealthy ? .green : .orange)
                }
                .padding(.horizontal, 12)
                .padding(.leading, 17)
                .padding(.bottom, 1)

                // Desktop app connection status (read from cache)
                let desktopStatus = CLIStatusChecker.cachedDesktopStatus
                HStack(spacing: 4) {
                    Image(systemName: desktopStatus.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(desktopStatus.isHealthy ? .green : .secondary)
                    Text(desktopStatus.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(desktopStatus.isHealthy ? .green : .secondary)
                }
                .padding(.horizontal, 12)
                .padding(.leading, 17)
                .padding(.bottom, 2)
            }

            // Next swap preview
            if let nextUp = SwapEngine.selectOptimalAccount(from: manager.accounts) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Next Up")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 0) {
                            Text(nextUp.email)
                                .font(.system(size: 10, weight: .semibold))
                            if let snapshot = nextUp.quotaSnapshot {
                                let pct = snapshot.fiveHour.remainingPercent
                                Spacer()
                                Text("\(Int(pct))%")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Self.quotaColor(for: pct))
                            }
                        }
                        // Swap reasoning inline
                        Text(SwapEngine.explainSelection(candidate: nextUp, allAccounts: manager.accounts))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 6)
            } else if let nextReset = Self.nextWeeklyResetAccount(from: manager.accounts) {
                // All accounts weekly-exhausted — show which resets first
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Next Available")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 0) {
                            Text(nextReset.account.email)
                                .font(.system(size: 10, weight: .semibold))
                            Spacer()
                            Text(nextReset.formattedTime)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                        Text("Weekly resets — will have \(Int(nextReset.account.quotaSnapshot?.fiveHour.remainingPercent ?? 0))% 5h ready")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 6)
            }

            // Swap statistics
            if !manager.swapHistory.isEmpty || manager.accounts.count > 1 {
                Divider()
                SwapStatsView(accountCount: manager.accounts.count)
            }

            Divider()

            HStack {
                if let lastSwap = manager.swapHistory.last {
                    Text("Last swap: \(Self.relativeFormatter.localizedString(for: lastSwap.timestamp, relativeTo: Date()))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No swaps yet")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button(action: onAddAccount) {
                    Label("Add Account", systemImage: "plus.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 540)
    }
}
