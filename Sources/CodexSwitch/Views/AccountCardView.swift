import AppKit
import SwiftUI

struct AccountCardView: View {
    let account: CodexAccount
    var isConfigured: Bool = false
    var poolTargetFreshness: ActiveAccountAuthorityFreshness = .current
    var pollingError: String? = nil
    var rateLimitResetPresentation: RateLimitResetInventoryPresentation? = nil
    var rateLimitResetCoordinatorAuthorization: RateLimitResetCoordinatorAuthorization = .authorized
    var onRedeemReset: (() -> Void)? = nil
    var onRefreshResetInventory: (() -> Void)? = nil
    let onReauthenticate: (() -> Void)?
    let onForceSwap: (() -> Void)?
    @State private var isHovering = false
    @State private var isConfirmingResetRedemption = false

    private static let activeGreen = Color(red: 0.15, green: 0.68, blue: 0.25)
    static let poolTargetLabel = "Pool Target"
    static let switchPoolTargetLabel = "Switch pool target to this account"

    static func poolTargetLabel(
        for freshness: ActiveAccountAuthorityFreshness
    ) -> String {
        switch freshness {
        case .current:
            return poolTargetLabel
        case .stale:
            return poolTargetLabel
        case .unavailable:
            return "Pool Target unavailable"
        }
    }

    private var poolTargetAccent: Color {
        Self.activeGreen
    }
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

    private static let resetExpiryDetailFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
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
        return isConfigured ? poolTargetAccent : .gray.opacity(0.4)
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
        return isConfigured ? Self.poolTargetLabel(for: poolTargetFreshness) : "Idle"
    }

    /// Higher contrast styles for the pool target card.
    private var labelStyle: some ShapeStyle {
        isConfigured ? .primary : .secondary
    }
    private var sublabelStyle: some ShapeStyle {
        isConfigured ? .secondary : .tertiary
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

    private var rateLimitResetLine: (
        text: String,
        color: Color,
        help: String,
        systemImage: String,
        urgency: RateLimitResetExpirationUrgency?
    )? {
        guard account.planPriority > 1, let rateLimitResetPresentation else {
            return nil
        }

        let storedLastKnownCount = account.rateLimitResetBank.map {
            max(0, $0.availableCount)
        }
        let lastCheckedText = account.rateLimitResetBank.map {
            Self.resetInventoryAgeText(fetchedAt: $0.fetchedAt, now: Date())
        }

        let nextExpirationText: String?
        let holdUntilText: String?
        let color: Color
        let help: String
        let systemImage: String
        let urgency: RateLimitResetExpirationUrgency?
        switch rateLimitResetPresentation {
        case .current(_, let nextExpiration):
            nextExpirationText = nextExpiration.map {
                Self.resetExpiryFormatter.string(from: $0)
            }
            holdUntilText = nil
            urgency = nextExpiration.map {
                RateLimitResetExpirationUrgency.resolve(expiration: $0, now: Date())
            }
            color = urgency?.presentationColor ?? .teal
            systemImage = urgency?.systemImage ?? "arrow.counterclockwise.circle.fill"
            if let nextExpiration, let urgency {
                help = "\(urgency.accessibilityDescription). Oldest banked reset expires "
                    + Self.resetExpiryDetailFormatter.string(from: nextExpiration)
            } else {
                help = "Current reset inventory"
            }
        case .error(let message, let lastKnownCount):
            nextExpirationText = nil
            holdUntilText = nil
            color = .secondary
            systemImage = "exclamationmark.circle"
            urgency = nil
            help = "Reset inventory error: \(message). Last-known count: \(max(0, lastKnownCount))"
        case .stale:
            nextExpirationText = nil
            holdUntilText = nil
            color = .secondary
            systemImage = "clock"
            urgency = nil
            help = "Last-known reset inventory is unverified"
        case .expired:
            nextExpirationText = nil
            holdUntilText = nil
            color = .secondary
            systemImage = "clock"
            urgency = nil
            help = "Banked reset inventory has expired and cannot be redeemed"
        case .unknown:
            nextExpirationText = nil
            holdUntilText = nil
            color = .secondary
            systemImage = "questionmark.circle.fill"
            urgency = nil
            help = "Reset inventory has not been verified"
        case .externalHold(let until):
            nextExpirationText = nil
            holdUntilText = Self.resetHoldFormatter.string(from: until)
            color = .orange
            systemImage = "pause.circle.fill"
            urgency = nil
            help = "Reset redemption is temporarily on hold"
        case .redeeming:
            nextExpirationText = nil
            holdUntilText = nil
            color = .blue
            systemImage = "arrow.counterclockwise.circle.fill"
            urgency = nil
            help = "Reset redemption is in progress"
        case .reconciling:
            nextExpirationText = nil
            holdUntilText = nil
            color = .orange
            systemImage = "arrow.triangle.2.circlepath.circle.fill"
            urgency = nil
            help = "Reset inventory is reconciling"
        case .refreshing:
            nextExpirationText = nil
            holdUntilText = nil
            color = .blue
            systemImage = "arrow.clockwise.circle.fill"
            urgency = nil
            help = "Reset inventory is refreshing"
        }

        return (
            Self.rateLimitResetText(
                for: rateLimitResetPresentation,
                nextExpirationText: nextExpirationText,
                holdUntilText: holdUntilText,
                storedLastKnownCount: storedLastKnownCount,
                lastCheckedText: lastCheckedText
            ),
            color,
            help,
            systemImage,
            urgency
        )
    }

    static func rateLimitResetText(
        for presentation: RateLimitResetInventoryPresentation,
        nextExpirationText: String? = nil,
        holdUntilText: String? = nil,
        storedLastKnownCount: Int? = nil,
        lastCheckedText: String? = nil
    ) -> String {
        switch presentation {
        case .redeeming:
            return "Redeeming banked reset"
        case .reconciling:
            return "Reconciling reset inventory"
        case .error(_, let lastKnownCount):
            return lastKnownResetText(
                count: lastKnownCount,
                suffix: "refresh failed"
            )
        case .externalHold:
            return holdUntilText.map { "Reset hold until \($0)" }
                ?? "Reset redemption on hold"
        case .refreshing:
            guard let storedLastKnownCount else { return "Refreshing reset inventory" }
            return lastKnownResetText(
                count: storedLastKnownCount,
                suffix: "refreshing"
            )
        case .stale(let lastKnownCount):
            return lastKnownResetText(
                count: lastKnownCount,
                suffix: lastCheckedText
            )
        case .expired:
            return "No current banked resets"
        case .unknown(let lastKnownCount):
            guard storedLastKnownCount != nil || lastKnownCount > 0 else {
                return "Reset inventory unavailable"
            }
            return lastKnownResetText(
                count: lastKnownCount,
                suffix: "unverified"
            )
        case .current(let availableCount, _):
            var text = resetCountText(availableCount)
            if let nextExpirationText {
                text += " • next expires \(nextExpirationText)"
            }
            return text
        }
    }

    private static func lastKnownResetText(count: Int, suffix: String?) -> String {
        var text = "Last known: \(resetCountText(count))"
        if let suffix, !suffix.isEmpty {
            text += " • \(suffix)"
        }
        return text
    }

    static func resetInventoryAgeText(fetchedAt: Date, now: Date) -> String {
        let age = max(0, now.timeIntervalSince(fetchedAt))
        if age < 60 { return "just now" }
        if age < 3_600 { return "\(Int(age / 60))m ago" }
        if age < 86_400 { return "\(Int(age / 3_600))h ago" }
        return "\(Int(age / 86_400))d ago"
    }

    private static func resetCountText(_ count: Int) -> String {
        let normalizedCount = max(0, count)
        let noun = normalizedCount == 1 ? "reset" : "resets"
        return "\(normalizedCount) banked \(noun)"
    }

    func resetRedemptionActionPresentation(
        at now: Date = Date()
    ) -> RateLimitResetRedemptionActionPresentation {
        RateLimitResetRedemptionActionPresentation.resolve(
            account: account,
            inventory: rateLimitResetPresentation,
            coordinatorAuthorization: rateLimitResetCoordinatorAuthorization,
            now: now
        )
    }

    var resetInventoryRefreshIsAvailable: Bool {
        account.planPriority > 1
            && rateLimitResetPresentation?.offersObservationRefresh == true
            && onRefreshResetInventory != nil
    }

    private var currentRateLimitResetCount: Int? {
        guard let rateLimitResetPresentation,
              case .current(let availableCount, _) = rateLimitResetPresentation else {
            return nil
        }
        return max(0, availableCount)
    }

    @discardableResult
    @MainActor
    func handleResetInventoryRefresh() -> Bool {
        guard resetInventoryRefreshIsAvailable, let onRefreshResetInventory else {
            return false
        }
        onRefreshResetInventory()
        return true
    }

    @discardableResult
    @MainActor
    func handleConfirmedResetRedemption(at now: Date = Date()) -> Bool {
        guard resetRedemptionActionPresentation(at: now).isEnabled,
              let onRedeemReset else {
            return false
        }
        onRedeemReset()
        return true
    }

    var requiresReauthentication: Bool {
        account.requiresReauthentication || Self.needsReauthentication(for: pollingError)
    }

    private var needsReauthentication: Bool {
        requiresReauthentication
    }

    var manualReauthenticationAvailable: Bool {
        onReauthenticate != nil
    }

    var primaryActionAccessibilityHint: String {
        if needsReauthentication {
            return "Reauthenticate this account"
        }
        if isConfigured {
            return "This account is the pool target"
        }
        return Self.switchPoolTargetLabel
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
        guard !isConfigured, let onForceSwap else { return false }
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
                            weight: isConfigured ? .bold : .medium
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


            if isConfigured {
                Label(
                    Self.poolTargetLabel(for: poolTargetFreshness),
                    systemImage: "scope"
                )
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(poolTargetAccent)
                    .lineLimit(1)
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

            if let rateLimitResetLine {
                let redemptionAction = resetRedemptionActionPresentation()
                let redemptionIsConnected = onRedeemReset != nil
                let offersRefresh = rateLimitResetPresentation?.offersObservationRefresh == true
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: rateLimitResetLine.systemImage)
                            .font(.system(size: 9))
                        Text(rateLimitResetLine.text)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                    }
                    .rateLimitResetUrgencyPulse(rateLimitResetLine.urgency)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(rateLimitResetLine.help)

                    Spacer(minLength: 2)

                    if offersRefresh {
                        Button {
                            _ = handleResetInventoryRefresh()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .font(.system(size: 8.5, weight: .semibold))
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .disabled(!resetInventoryRefreshIsAvailable)
                        .help("Refresh reset inventory for \(account.email)")
                    } else if let availableCount = currentRateLimitResetCount,
                              availableCount > 0 {
                        Button {
                            isConfirmingResetRedemption = true
                        } label: {
                            Label("Redeem", systemImage: "arrow.counterclockwise")
                        }
                        .font(.system(size: 8.5, weight: .semibold))
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .disabled(!redemptionAction.isEnabled || !redemptionIsConnected)
                        .help(redemptionIsConnected
                            ? redemptionAction.helpText
                            : "Manual reset redemption is not connected")
                        .accessibilityLabel("Redeem one banked reset for \(account.email)")
                        .accessibilityHint(redemptionIsConnected
                            ? redemptionAction.helpText
                            : "Manual reset redemption is not connected")
                    }
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
                            boostedContrast: isConfigured
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
                                boostedContrast: isConfigured
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
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isConfigured ? poolTargetAccent : Color.primary.opacity(0.1),
                    lineWidth: isConfigured ? 2.5 : 1
                )
        }
        .overlay(alignment: .topLeading) {
            emailHoverOverlay
        }
        .overlay {
            AccountCardHoverTrackingView(email: account.email, isHovering: $isHovering)
                .allowsHitTesting(false)
        }
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
            let resetPresentation = RateLimitResetContextMenuPresentation.resolve(
                account: account,
                inventory: rateLimitResetPresentation,
                coordinatorAuthorization: rateLimitResetCoordinatorAuthorization,
                redemptionHandlerAvailable: onRedeemReset != nil,
                now: Date()
            )

            if manualReauthenticationAvailable {
                Button("Reauthenticate") {
                    onReauthenticate?()
                }
            }
            if !isConfigured {
                Button(Self.switchPoolTargetLabel) {
                    onForceSwap?()
                }
            }
            if rateLimitResetPresentation?.offersObservationRefresh == true {
                Button("Refresh reset inventory") {
                    _ = handleResetInventoryRefresh()
                }
                .disabled(!resetInventoryRefreshIsAvailable)
            }
            if resetPresentation.isEnabled {
                Button(resetPresentation.menuItemTitle) {
                    isConfirmingResetRedemption = true
                }
            } else {
                Button(resetPresentation.menuItemTitle) {}
                    .disabled(true)
                    .help(
                        resetPresentation.unavailableReason
                            ?? "Manual reset redemption is unavailable"
                    )
            }
            Button("Copy email") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.email, forType: .string)
            }
        }
        .confirmationDialog(
            "Redeem one banked reset for \(account.email)?",
            isPresented: $isConfirmingResetRedemption,
            titleVisibility: .visible
        ) {
            Button("Redeem Oldest Reset", role: .destructive) {
                _ = handleConfirmedResetRedemption()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This spends the oldest-expiring available reset for this account. It does not switch accounts.")
        }
    }
}

extension RateLimitResetExpirationUrgency {
    var presentationColor: Color {
        switch self {
        case .normal: return .teal
        case .advisory: return .yellow
        case .urgent: return .orange
        case .critical: return .red
        }
    }

    var systemImage: String {
        switch self {
        case .normal: return "arrow.counterclockwise.circle.fill"
        case .advisory: return "clock.badge.exclamationmark"
        case .urgent: return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .advisory: return "Advisory"
        case .urgent: return "Urgent"
        case .critical: return "Critical"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .normal: return "Reset expiration is more than 7 days away"
        case .advisory: return "Advisory: reset expires within 7 days"
        case .urgent: return "Urgent: reset expires within 72 hours"
        case .critical: return "Critical: reset expires within 24 hours"
        }
    }
}

private struct RateLimitResetUrgencyPulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let urgency: RateLimitResetExpirationUrgency?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let urgency, urgency.pulsePeriod != nil, !reduceMotion {
            TimelineView(.animation(
                minimumInterval: urgency == .critical ? 1.0 / 30.0 : 1.0 / 20.0
            )) { context in
                content.opacity(urgency.pulseOpacity(at: context.date, reduceMotion: false))
            }
        } else {
            content.opacity(1)
        }
    }
}

extension View {
    func rateLimitResetUrgencyPulse(
        _ urgency: RateLimitResetExpirationUrgency?
    ) -> some View {
        modifier(RateLimitResetUrgencyPulseModifier(urgency: urgency))
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
