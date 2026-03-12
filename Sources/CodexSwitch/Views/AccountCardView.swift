import SwiftUI

struct AccountCardView: View {
    let account: CodexAccount
    let onForceSwap: (() -> Void)?

    private var statusDot: Color {
        if account.isActive { return .green }
        guard let snapshot = account.quotaSnapshot else { return .gray }
        if snapshot.fiveHour.isExhausted { return .red }
        if snapshot.fiveHour.remainingPercent < 20 { return .orange }
        return .gray.opacity(0.4)
    }

    private var statusDotLabel: String {
        if account.isActive { return "Active" }
        guard let snapshot = account.quotaSnapshot else { return "No data" }
        if snapshot.fiveHour.isExhausted { return "Exhausted" }
        if snapshot.fiveHour.remainingPercent < 20 { return "Low quota" }
        return "Idle"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.displayName)
                    .font(.system(size: 11, weight: account.isActive ? .bold : .medium))
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(statusDot)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(statusDotLabel)
            }

            if let snapshot = account.quotaSnapshot {
                DrainBarView(
                    label: "5h",
                    percent: snapshot.fiveHour.remainingPercent,
                    resetsAt: snapshot.fiveHour.resetsAt
                )
                DrainBarView(
                    label: "Wk",
                    percent: snapshot.weekly.remainingPercent,
                    resetsAt: snapshot.weekly.resetsAt
                )
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting for data...")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Polling quota API")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    account.isActive ? Color.green.opacity(0.5) : .clear,
                    lineWidth: 1.5
                )
        )
        .contextMenu {
            if !account.isActive {
                Button("Switch to this account") {
                    onForceSwap?()
                }
            }
            Button("Copy email") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.email, forType: .string)
            }
        }
    }
}
