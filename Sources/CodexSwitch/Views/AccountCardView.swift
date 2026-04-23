import SwiftUI

struct AccountCardView: View {
    let account: CodexAccount
    var pollingError: String? = nil
    let onForceSwap: (() -> Void)?
    let onReauthenticate: (() -> Void)?

    private static let activeGreen = Color(red: 0.15, green: 0.68, blue: 0.25)

    var requiresReauthentication: Bool {
        guard let pollingError else { return false }
        return pollingError.localizedCaseInsensitiveContains(AccountManager.reauthenticationRequiredPrefix)
    }

    private var statusDot: Color {
        if requiresReauthentication { return .red }
        if account.isActive { return Self.activeGreen }
        guard let snapshot = account.quotaSnapshot else { return .gray }
        if snapshot.weekly.isExhausted { return .red }    // Weekly gone = completely unusable
        if snapshot.fiveHour.isExhausted { return .red }
        if snapshot.fiveHour.remainingPercent < 20 { return .red }
        if snapshot.weekly.remainingPercent < 20 { return .orange }
        if snapshot.fiveHour.remainingPercent < 50 { return .yellow }
        return .gray.opacity(0.4)
    }

    private var statusDotLabel: String {
        if requiresReauthentication { return "Needs re-authentication" }
        if account.isActive { return "Active" }
        guard let snapshot = account.quotaSnapshot else { return "No data" }
        if snapshot.weekly.isExhausted { return "Weekly exhausted" }
        if snapshot.fiveHour.isExhausted { return "5h exhausted" }
        if snapshot.fiveHour.remainingPercent < 20 { return "Low quota" }
        return "Idle"
    }

    /// Higher contrast styles for the active card
    private var labelStyle: some ShapeStyle {
        account.isActive ? .primary : .secondary
    }
    private var sublabelStyle: some ShapeStyle {
        account.isActive ? .secondary : .tertiary
    }

    @discardableResult
    @MainActor
    func handlePrimaryClick() -> Bool {
        if requiresReauthentication, let onReauthenticate {
            onReauthenticate()
            return true
        }
        guard !account.isActive, let onForceSwap else { return false }
        onForceSwap()
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.email)
                        .font(.system(size: 11, weight: account.isActive ? .bold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !account.planLabel.isEmpty {
                        Text(account.planLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(sublabelStyle)
                    }
                }
                Spacer()
                Circle()
                    .fill(statusDot)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(statusDotLabel)
            }

            if requiresReauthentication, let error = pollingError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red)
                        .lineLimit(3)
                    if let onReauthenticate {
                        Button("Re-authenticate") {
                            onReauthenticate()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.red)
                    }
                }
            } else if let snapshot = account.quotaSnapshot {
                DrainBarView(
                    label: "5h",
                    percent: snapshot.fiveHour.remainingPercent,
                    resetsAt: snapshot.fiveHour.resetsAt,
                    boostedContrast: account.isActive
                )
                DrainBarView(
                    label: "Wk",
                    percent: snapshot.weekly.remainingPercent,
                    resetsAt: snapshot.weekly.resetsAt,
                    boostedContrast: account.isActive
                )
            } else if let error = pollingError {
                VStack(alignment: .leading, spacing: 2) {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Text("Will retry in 60s")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connecting...")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Fetching quota data")
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
                    account.isActive ? Self.activeGreen : .clear,
                    lineWidth: 2.5
                )
        )
        .shadow(color: account.isActive ? Self.activeGreen.opacity(0.4) : .clear, radius: 5)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            _ = handlePrimaryClick()
        }
        .contextMenu {
            if requiresReauthentication {
                Button("Re-authenticate this account") {
                    onReauthenticate?()
                }
            } else if !account.isActive {
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
