import SwiftUI

struct AccountCardView: View {
    let account: CodexAccount
    var pollingError: String? = nil
    var isPrimed: Bool = false
    var isDeadToken: Bool = false
    let onForceSwap: (() -> Void)?
    var onRelogin: (() -> Void)? = nil
    @State private var isHovered = false

    private static let activeGreen = Color(red: 0.15, green: 0.68, blue: 0.25)

    private var statusDot: Color {
        if account.isActive { return Self.activeGreen }
        guard let snapshot = account.quotaSnapshot else { return .gray }
        // Red = exhausted (weekly or 5h gone)
        if snapshot.weekly.isExhausted || snapshot.fiveHour.isExhausted { return .red }
        // Yellow = available / ready to swap to
        return .yellow
    }

    private var statusDotLabel: String {
        if account.isActive { return "Active" }
        guard let snapshot = account.quotaSnapshot else { return "No data" }
        if snapshot.weekly.isExhausted { return "Weekly exhausted" }
        if snapshot.fiveHour.isExhausted { return "5h exhausted" }
        return "Available"
    }

    /// Higher contrast styles for the active card
    private var labelStyle: some ShapeStyle {
        account.isActive ? .primary : .secondary
    }
    private var sublabelStyle: some ShapeStyle {
        account.isActive ? .secondary : .tertiary
    }

    /// Display the full email — SwiftUI's .truncationMode(.tail) handles overflow.
    /// This preserves the unique local part which is what matters for identification.
    private var displayEmail: String {
        account.email
    }

    /// Subscription renewal date from JWT id_token
    private var renewalLabel: String? {
        guard let plan = account.planType, !plan.isEmpty else { return nil }
        let label = plan.replacingOccurrences(of: "_", with: " ").capitalized
        guard let renewDate = account.subscriptionRenewsAt else { return label }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return "\(label) · renews \(formatter.string(from: renewDate))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayEmail)
                        .font(.system(size: 11, weight: account.isActive ? .bold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let renewal = renewalLabel {
                        Text(renewal)
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

            if let snapshot = account.quotaSnapshot {
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
                if isPrimed {
                    let wkPrimed = snapshot.weekly.remainingPercent >= 99
                    let fhPrimed = snapshot.fiveHour.remainingPercent >= 99
                    if wkPrimed && fhPrimed {
                        Text("5h + weekly timers started")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.green.opacity(0.8))
                    } else if fhPrimed {
                        Text("5h timer started")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.green.opacity(0.8))
                    } else if wkPrimed {
                        Text("Weekly timer started")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.green.opacity(0.8))
                    }
                }
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
        .onHover { hovering in isHovered = hovering }
        .overlay {
            if isDeadToken {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.7))
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "skull.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.red)
                            Text("Session expired")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white)
                            Button(action: { onRelogin?() }) {
                                Label("Re-login", systemImage: "arrow.clockwise")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.orange, in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !account.isActive && !isDeadToken && isHovered {
                Button(action: { onForceSwap?() }) {
                    Text("Switch")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
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
