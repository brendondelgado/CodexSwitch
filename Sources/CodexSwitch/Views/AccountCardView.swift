import AppKit
import SwiftUI

struct AccountCardView: View {
    let account: CodexAccount
    var pollingError: String? = nil
    let onReauthenticate: (() -> Void)?
    let onForceSwap: (() -> Void)?
    @State private var isHovering = false

    private static let activeGreen = Color(red: 0.15, green: 0.68, blue: 0.25)
    private static let renewalFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let primedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private var statusDot: Color {
        if needsReauthentication { return .red }
        if account.isRuntimeUnusable { return .orange }
        if account.isActive {
            return account.quotaSnapshot?.hasBackendUsagePlaceholder == true ? .orange : Self.activeGreen
        }
        guard let snapshot = account.realQuotaSnapshot else {
            return account.quotaSnapshot?.hasBackendUsagePlaceholder == true ? .orange : .gray
        }
        if snapshot.hasExpiredExhaustedWindow() { return .orange }
        if snapshot.weekly.isExhausted { return .red }    // Weekly gone = completely unusable
        if snapshot.fiveHour.isExhausted { return .red }
        if snapshot.fiveHour.remainingPercent < 20 { return .red }
        if snapshot.weekly.remainingPercent < 20 { return .orange }
        if snapshot.fiveHour.remainingPercent < 50 { return .yellow }
        return .gray.opacity(0.4)
    }

    private var statusDotLabel: String {
        if needsReauthentication { return "Needs re-authentication" }
        if let runtimeStatus = account.runtimeStatusText { return runtimeStatus }
        if account.isActive {
            return account.quotaSnapshot?.hasBackendUsagePlaceholder == true ? "Active, rate limits unavailable" : "Active"
        }
        guard let snapshot = account.realQuotaSnapshot else {
            return account.quotaSnapshot?.hasBackendUsagePlaceholder == true ? "Rate limits unavailable" : "No data"
        }
        if snapshot.hasExpiredExhaustedWindow() { return "Reset needs confirmation" }
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

    private var planLine: String {
        var parts: [String] = []
        if !account.planLabel.isEmpty {
            parts.append(account.planLabel)
        }
        if account.subscriptionWillRenew == true, let renewsAt = account.subscriptionRenewsAt {
            parts.append("renews \(Self.renewalFormatter.string(from: renewsAt))")
        } else if let expiresAt = account.subscriptionExpiresAt {
            parts.append("expires \(Self.renewalFormatter.string(from: expiresAt))")
        } else if account.isFreePlan {
            parts.append("lowest priority")
        }
        return parts.joined(separator: " • ")
    }

    private var fiveHourPrimedLine: String? {
        guard let primedAt = account.fiveHourPrimedAt else { return nil }
        return "5h triggered \(Self.primedFormatter.string(from: primedAt))"
    }

    var requiresReauthentication: Bool {
        account.requiresReauthentication || Self.needsReauthentication(for: pollingError)
    }

    private var needsReauthentication: Bool {
        requiresReauthentication
    }

    static func needsReauthentication(for pollingError: String?) -> Bool {
        guard let pollingError else { return false }
        let lower = pollingError
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return lower.contains("re-auth")
            || lower.contains("re authentication")
            || lower.contains("reauth")
            || lower.contains("token expired")
            || lower.contains("refresh token")
            || lower.contains("refresh failed")
            || lower.contains("authorization")
            || lower.contains("unauthorized")
            || lower.contains("http 401")
            || lower.contains("token invalidated")
            || lower.contains("invalidated")
    }

    @discardableResult
    @MainActor
    func handlePrimaryClick() -> Bool {
        if needsReauthentication {
            guard let onReauthenticate else { return false }
            onReauthenticate()
            return true
        }
        guard !account.isActive, let onForceSwap else { return false }
        onForceSwap()
        return true
    }

    @ViewBuilder
    private var emailHoverOverlay: some View {
        if isHovering {
            Text(account.email)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .padding(4)
                .allowsHitTesting(false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.email)
                        .font(.system(size: 11, weight: account.isActive ? .bold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(account.email)
                    if !planLine.isEmpty {
                        Text(planLine)
                            .font(.system(size: 9))
                            .foregroundStyle(sublabelStyle)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Circle()
                    .fill(statusDot)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(statusDotLabel)
            }

            if let fiveHourPrimedLine {
                HStack(spacing: 4) {
                    Image(systemName: "timer.circle.fill")
                        .font(.system(size: 9))
                    Text(fiveHourPrimedLine)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.blue)
            }

            if needsReauthentication {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Needs login", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                    Button {
                        onReauthenticate?()
                    } label: {
                        Text("Reauthenticate")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            } else if let runtimeStatus = account.runtimeStatusText {
                VStack(alignment: .leading, spacing: 2) {
                    Text(runtimeStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    Text("Excluded from swaps")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            } else if let snapshot = account.realQuotaSnapshot {
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
            } else if account.quotaSnapshot?.hasBackendUsagePlaceholder == true {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rate limits unavailable")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Text("Keeping last real usage")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
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
        .overlay(alignment: .topLeading) {
            emailHoverOverlay
        }
        .overlay {
            AccountCardHoverTrackingView(email: account.email, isHovering: $isHovering)
        }
        .shadow(color: account.isActive ? Self.activeGreen.opacity(0.4) : .clear, radius: 5)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .help(account.email)
        .zIndex(isHovering ? 1 : 0)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            _ = handlePrimaryClick()
        }
        .contextMenu {
            if needsReauthentication {
                Button("Reauthenticate") {
                    onReauthenticate?()
                }
            }
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

private struct AccountCardHoverTrackingView: NSViewRepresentable {
    let email: String
    @Binding var isHovering: Bool

    func makeNSView(context: Context) -> AccountCardHoverTrackingNSView {
        let view = AccountCardHoverTrackingNSView()
        view.email = email
        view.onHoverChanged = { hovering in
            isHovering = hovering
        }
        return view
    }

    func updateNSView(_ nsView: AccountCardHoverTrackingNSView, context: Context) {
        nsView.email = email
        nsView.onHoverChanged = { hovering in
            isHovering = hovering
        }
    }
}

private final class AccountCardHoverTrackingNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var email: String = "" {
        didSet {
            toolTip = email
        }
    }

    private var cardTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let cardTrackingArea {
            removeTrackingArea(cardTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cardTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
