import SwiftUI

struct PopoverContentView: View {
    @Bindable var manager: AccountManager
    var onImportAccount: () -> Void
    var onForceSwap: (UUID) -> Void
    var onOpenSettings: () -> Void

    private static let relativeFormatter = RelativeDateTimeFormatter()

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    private func swapReason(for candidate: CodexAccount) -> String {
        let score = SwapEngine.score(candidate)
        guard let snapshot = candidate.quotaSnapshot else {
            return "Score: \(String(format: "%.0f", score))"
        }
        let fiveHr = snapshot.fiveHour
        var parts: [String] = []
        parts.append("\(Int(fiveHr.remainingPercent))% 5h quota")
        if fiveHr.isExhausted && fiveHr.timeUntilReset < 1800 {
            let mins = Int(fiveHr.timeUntilReset / 60)
            parts.append("resets in \(mins)m")
        }
        parts.append("score \(String(format: "%.0f", score))")
        return parts.joined(separator: " · ")
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

            Divider()

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(manager.sortedAccounts) { account in
                    AccountCardView(account: account) {
                        onForceSwap(account.id)
                    }
                }
            }
            .padding(10)

            // Next swap preview
            if let nextUp = SwapEngine.selectOptimalAccount(from: manager.accounts) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Next up: **\(nextUp.email)**")
                            .font(.system(size: 10))
                        Text(swapReason(for: nextUp))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let snapshot = nextUp.quotaSnapshot {
                        Text("\(Int(snapshot.fiveHour.remainingPercent))%")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
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

                Button(action: onImportAccount) {
                    Label("Import Account", systemImage: "plus.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 500)
    }
}
