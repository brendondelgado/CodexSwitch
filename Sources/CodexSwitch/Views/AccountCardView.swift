import AppKit
import SwiftUI

struct AccountCardHostOwnershipLabels: Equatable, Sendable {
    let macConfigured: String
    let macRuntime: String
    let vpsRuntime: String
}

struct AccountCardView: View {
    let account: CodexAccount
    var isConfigured: Bool = false
    var isRuntimeCurrent: Bool = false
    var vpsRuntimePresentation: VPSRuntimeAccountPresentation = .disconnected
    var pollingError: String? = nil
    var rateLimitResetPresentation: RateLimitResetInventoryPresentation? = nil
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

    private static let resetExpiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let resetHoldFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private var statusDot: Color {
        if needsReauthentication { return .red }
        if account.hasHardRuntimeBlock { return .orange }
        if isConfigured && account.quotaSnapshot?.hasBackendUsagePlaceholder == true { return .orange }
        guard let snapshot = account.realQuotaSnapshot else {
            return account.quotaSnapshot?.hasBackendUsagePlaceholder == true ? .orange : .gray
        }
        if snapshot.isDenied { return .red }
        if snapshot.windows.isEmpty { return .gray }
        if snapshot.hasExpiredExhaustedWindow() { return .orange }
        if snapshot.windows.contains(where: \.isExhausted) { return .red }
        if let fiveHour = snapshot.fiveHour, fiveHour.effectiveRemainingPercent < 20 { return .red }
        if let weekly = snapshot.weekly, weekly.effectiveRemainingPercent < 20 { return .orange }
        if snapshot.windows.contains(where: { $0.effectiveRemainingPercent < 20 }) { return .orange }
        if snapshot.windows.contains(where: { $0.effectiveRemainingPercent < 50 }) { return .yellow }
        if isRuntimeCurrent { return Self.activeGreen }
        return isConfigured ? .orange : .gray.opacity(0.4)
    }

    private var statusDotLabel: String {
        if needsReauthentication { return "Needs re-authentication" }
        if let runtimeStatus = account.runtimeStatusText { return runtimeStatus }
        if isConfigured && account.quotaSnapshot?.hasBackendUsagePlaceholder == true {
            return "Configured, rate limits unavailable"
        }
        guard let snapshot = account.realQuotaSnapshot else {
            return account.quotaSnapshot?.hasBackendUsagePlaceholder == true ? "Rate limits unavailable" : "No data"
        }
        if snapshot.isDenied {
            return snapshot.limitReached == true ? "Quota exhausted" : "Quota unavailable"
        }
        if snapshot.windows.isEmpty { return "Quota unknown" }
        if snapshot.hasExpiredExhaustedWindow() { return "Reset needs confirmation" }
        if let exhausted = snapshot.orderedWindows.first(where: \.isExhausted) {
            return "\(QuotaWindowDisplay.label(for: exhausted)) exhausted"
        }
        if snapshot.windows.contains(where: { $0.effectiveRemainingPercent < 20 }) { return "Low quota" }
        if isRuntimeCurrent { return "Mac Runtime Current" }
        return isConfigured ? "Mac Configured" : "Idle"
    }

    static func vpsRuntimeLabel(_ presentation: VPSRuntimeAccountPresentation) -> String {
        switch presentation {
        case .current: return "VPS Runtime Current"
        case .notCurrent: return "VPS Not Current"
        case .unknown: return "VPS Runtime Unknown"
        case .disconnected: return "VPS Disconnected"
        }
    }

    static func hostOwnershipLabels(
        isConfigured: Bool,
        isRuntimeCurrent: Bool,
        vpsRuntimePresentation: VPSRuntimeAccountPresentation
    ) -> AccountCardHostOwnershipLabels {
        AccountCardHostOwnershipLabels(
            macConfigured: isConfigured ? "Mac Configured" : "Mac Not Configured",
            macRuntime: isRuntimeCurrent
                ? "Mac Runtime Current"
                : "Mac Runtime Not Current",
            vpsRuntime: vpsRuntimeLabel(vpsRuntimePresentation)
        )
    }

    private var vpsRuntimeColor: Color {
        switch vpsRuntimePresentation {
        case .current: return .blue
        case .notCurrent, .unknown: return .secondary
        case .disconnected: return .orange
        }
    }

    /// Higher contrast styles for the active card
    private var labelStyle: some ShapeStyle {
        isRuntimeCurrent || isConfigured ? .primary : .secondary
    }
    private var sublabelStyle: some ShapeStyle {
        isRuntimeCurrent || isConfigured ? .secondary : .tertiary
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
        guard account.realQuotaSnapshot?.fiveHour != nil,
              let primedAt = account.fiveHourPrimedAt else {
            return nil
        }
        return "5h triggered \(Self.primedFormatter.string(from: primedAt))"
    }

    private var rateLimitResetLine: (text: String, color: Color, help: String)? {
        guard let rateLimitResetPresentation else {
            return nil
        }

        let nextExpirationText: String?
        let holdUntilText: String?
        let color: Color
        let help: String
        switch rateLimitResetPresentation {
        case .current(_, let nextExpiration):
            nextExpirationText = nextExpiration.map {
                Self.resetExpiryFormatter.string(from: $0)
            }
            holdUntilText = nil
            color = .teal
            help = "Current reset inventory"
        case .stale:
            nextExpirationText = nil
            holdUntilText = nil
            color = .orange
            help = "Last-known reset inventory"
        case .externalHold(let until):
            nextExpirationText = nil
            holdUntilText = Self.resetHoldFormatter.string(from: until)
            color = .orange
            help = "Reset redemption is temporarily on hold"
        case .redeeming:
            nextExpirationText = nil
            holdUntilText = nil
            color = .blue
            help = "Reset redemption is in progress"
        case .reconciling:
            nextExpirationText = nil
            holdUntilText = nil
            color = .orange
            help = "Reset inventory is reconciling"
        case .refreshing:
            nextExpirationText = nil
            holdUntilText = nil
            color = .blue
            help = "Reset inventory is refreshing"
        }

        return (
            Self.rateLimitResetText(
                for: rateLimitResetPresentation,
                nextExpirationText: nextExpirationText,
                holdUntilText: holdUntilText
            ),
            color,
            help
        )
    }

    static func rateLimitResetText(
        for presentation: RateLimitResetInventoryPresentation,
        nextExpirationText: String? = nil,
        holdUntilText: String? = nil
    ) -> String {
        switch presentation {
        case .redeeming:
            return "Redeeming banked reset"
        case .reconciling:
            return "Reconciling reset inventory"
        case .externalHold:
            return holdUntilText.map { "Reset hold until \($0)" }
                ?? "Reset redemption on hold"
        case .refreshing:
            return "Refreshing reset inventory"
        case .stale(let lastKnownCount):
            return "Last-known: \(resetCountText(lastKnownCount))"
        case .current(let availableCount, _):
            var text = resetCountText(availableCount)
            if let nextExpirationText {
                text += " • next expires \(nextExpirationText)"
            }
            return text
        }
    }

    private static func resetCountText(_ count: Int) -> String {
        let normalizedCount = max(0, count)
        let noun = normalizedCount == 1 ? "reset" : "resets"
        return "\(normalizedCount) banked \(noun)"
    }

    var requiresReauthentication: Bool {
        account.requiresReauthentication || Self.needsReauthentication(for: pollingError)
    }

    private var needsReauthentication: Bool {
        requiresReauthentication
    }

    var primaryActionAccessibilityHint: String {
        if needsReauthentication {
            return "Reauthenticate this account"
        }
        if isRuntimeCurrent {
            return "Mac runtime is already using this account"
        }
        if isConfigured {
            return "Retry Mac runtime activation"
        }
        return "Switch Mac to this account"
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
        guard !isRuntimeCurrent, let onForceSwap else { return false }
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
                        .font(.system(
                            size: 11,
                            weight: isRuntimeCurrent ? .bold : (isConfigured ? .semibold : .medium)
                        ))
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


            VStack(alignment: .leading, spacing: 2) {
                let ownership = Self.hostOwnershipLabels(
                    isConfigured: isConfigured,
                    isRuntimeCurrent: isRuntimeCurrent,
                    vpsRuntimePresentation: vpsRuntimePresentation
                )
                Label(
                    ownership.macConfigured,
                    systemImage: "laptopcomputer"
                )
                .foregroundStyle(isConfigured ? .orange : .secondary)

                Label(
                    ownership.macRuntime,
                    systemImage: "dot.radiowaves.left.and.right"
                )
                .foregroundStyle(isRuntimeCurrent ? Self.activeGreen : .secondary)

                Label(
                    ownership.vpsRuntime,
                    systemImage: "server.rack"
                )
                .foregroundStyle(vpsRuntimeColor)
            }
            .font(.system(size: 8.5, weight: .medium))
            .lineLimit(1)

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

            if let rateLimitResetLine {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 9))
                    Text(rateLimitResetLine.text)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(rateLimitResetLine.color)
                .help(rateLimitResetLine.help)
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
                switch QuotaSnapshotPresentation(snapshot: snapshot) {
                case .windows(let rows):
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        DrainBarView(
                            label: row.label,
                            percent: row.percent,
                            resetsAt: row.resetsAt,
                            boostedContrast: isRuntimeCurrent
                        )
                    }
                case .denied(let message, let rows):
                    VStack(alignment: .leading, spacing: 4) {
                        Label(message, systemImage: snapshot.limitReached == true ? "gauge.with.dots.needle.0percent" : "exclamationmark.circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            DrainBarView(
                                label: row.label,
                                percent: snapshot.limitReached == true ? 0 : row.percent,
                                resetsAt: row.resetsAt,
                                boostedContrast: isRuntimeCurrent
                            )
                        }
                    }
                case .unknown(let message):
                    Label(message, systemImage: "questionmark.circle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
                    isRuntimeCurrent ? Self.activeGreen : (isConfigured ? .orange : .clear),
                    lineWidth: isRuntimeCurrent ? 2.5 : 1.5
                )
        )
        .overlay(alignment: .topLeading) {
            emailHoverOverlay
        }
        .overlay {
            AccountCardHoverTrackingView(email: account.email, isHovering: $isHovering)
                .allowsHitTesting(false)
        }
        .shadow(
            color: isRuntimeCurrent ? Self.activeGreen.opacity(0.4) : .clear,
            radius: 5
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .help(account.email)
        .zIndex(isHovering ? 1 : 0)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            _ = handlePrimaryClick()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(account.email)
        .accessibilityHint(primaryActionAccessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            _ = handlePrimaryClick()
        }
        .contextMenu {
            if needsReauthentication {
                Button("Reauthenticate") {
                    onReauthenticate?()
                }
            }
            if !isRuntimeCurrent {
                Button(isConfigured ? "Retry Mac runtime activation" : "Switch Mac to this account") {
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
