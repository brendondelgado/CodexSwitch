import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let manager: AccountManager

    init(statusItem: NSStatusItem, manager: AccountManager) {
        self.statusItem = statusItem
        self.manager = manager
    }

    /// Determine which reported window is most likely to reach zero first.
    private func urgentWindow(from snapshot: QuotaSnapshot) -> QuotaWindow? {
        guard !snapshot.isDenied else { return nil }
        return snapshot.orderedWindows.min { lhs, rhs in
            estimatedTimeToZero(for: lhs) < estimatedTimeToZero(for: rhs)
        }
    }

    private func estimatedTimeToZero(for window: QuotaWindow) -> TimeInterval {
        if window.isExhausted { return 0 }
        let timeLeft = max(0, window.timeUntilReset)
        let elapsed = max(1, Double(window.durationSeconds) - timeLeft)
        let rate = window.usedPercent / elapsed
        return rate > 0 ? window.effectiveRemainingPercent / rate : .infinity
    }

    static func macRuntimeLabel(_ state: MacCredentialRuntimeState) -> String? {
        switch state {
        case .confirmed:
            return nil
        case .activating:
            return "Mac activation pending"
        case .restartRequired:
            return "Mac runtime restart required"
        case .configuredOnly:
            return "no local Codex runtime"
        case .manualReview:
            return "Mac activation needs review"
        case .unconfirmed:
            return "Mac runtime unconfirmed"
        }
    }

    /// Tooltip scope for the account the ring shows: the Mac-committed
    /// current account, plus the VPS target only when it differs or is stale.
    static func currentScopeLabel(for model: AccountDisplayReadModel) -> String {
        var parts = ["Current: \(model.currentEmail ?? "none")"]
        if let runtime = macRuntimeLabel(model.macRuntime) {
            parts.append(runtime)
        }
        if let note = model.poolTargetNote {
            parts.append(note)
        }
        if !model.unmanagedRuntimes.isEmpty {
            let count = model.unmanagedRuntimes.count
            parts.append(count == 1
                ? "1 unmanaged runtime needs restart"
                : "\(count) unmanaged runtimes need restart")
        }
        return parts.joined(separator: "; ")
    }

    /// Tooltip suffix marking a cached reading older than the freshness contract.
    static func staleQuotaTooltipSuffix(for snapshot: QuotaSnapshot, now: Date) -> String {
        QuotaFreshnessPolicy.staleAgeLabel(fetchedAt: snapshot.fetchedAt, now: now)
            .map { " (stale, \($0))" } ?? ""
    }

    /// Update the menu bar icon — circular ring with percentage
    func updateIcon() {
        guard let button = statusItem.button else { return }

        if manager.accounts.isEmpty {
            button.toolTip = "No accounts"
            applyRingIcon(button: button, percent: 0, color: .secondaryLabelColor, text: "--")
            return
        }

        let now = Date()
        let model = manager.displayReadModel(at: now)
        guard let displayedAccount = manager.accounts.first(where: {
            $0.id == model.currentAccountId
        }) else {
            button.toolTip = model.currentIsAmbiguous
                ? "Mac committed account is ambiguous"
                : "No account committed on this Mac"
            applyRingIcon(button: button, percent: 0, color: .secondaryLabelColor, text: "...")
            return
        }
        let scope = Self.currentScopeLabel(for: model)

        guard let snapshot = displayedAccount.realQuotaSnapshot else {
            button.toolTip = "\(scope): rate limits unavailable"
            applyRingIcon(button: button, percent: 0, color: .secondaryLabelColor, text: "...")
            return
        }

        let staleSuffix = Self.staleQuotaTooltipSuffix(for: snapshot, now: now)
        if snapshot.isDenied {
            let quota = snapshot.limitReached == true ? "quota exhausted" : "quota unavailable"
            button.toolTip = "\(scope): \(quota)\(staleSuffix)"
            applyRingIcon(button: button, percent: 0, color: .systemRed, text: "!")
            return
        }

        guard let window = urgentWindow(from: snapshot) else {
            button.toolTip = "\(scope): quota unknown\(staleSuffix)"
            applyRingIcon(button: button, percent: 0, color: .secondaryLabelColor, text: "--")
            return
        }

        let remaining = window.effectiveRemainingPercent
        let color: NSColor
        switch remaining {
        case _ where !staleSuffix.isEmpty: color = .secondaryLabelColor
        case 50...: color = .systemGreen
        case 20..<50: color = .systemYellow
        case 5..<20: color = .systemOrange
        default: color = .systemRed
        }

        button.toolTip = "\(scope): \(QuotaWindowDisplay.label(for: window)) \(Int(remaining))% remaining\(staleSuffix)"
        applyRingIcon(button: button, percent: remaining, color: color, text: "\(Int(remaining))")
    }

    private func applyRingIcon(button: NSStatusBarButton, percent: Double, color: NSColor, text: String) {
        let size: CGFloat = 18
        let lineWidth: CGFloat = 2.5
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = lineWidth / 2
            let arcRect = rect.insetBy(dx: inset, dy: inset)
            let center = NSPoint(x: arcRect.midX, y: arcRect.midY)
            let radius = arcRect.width / 2

            // Track (background ring)
            let trackPath = NSBezierPath()
            trackPath.appendArc(
                withCenter: center, radius: radius,
                startAngle: 0, endAngle: 360
            )
            trackPath.lineWidth = lineWidth
            NSColor.tertiaryLabelColor.setStroke()
            trackPath.stroke()

            // Filled arc — clockwise from 12 o'clock
            if percent > 0 {
                let fraction = CGFloat(max(0, min(100, percent))) / 100
                let startAngle: CGFloat = 90  // 12 o'clock
                let endAngle = startAngle - (360 * fraction)
                let arcPath = NSBezierPath()
                arcPath.appendArc(
                    withCenter: center, radius: radius,
                    startAngle: startAngle, endAngle: endAngle, clockwise: true
                )
                arcPath.lineWidth = lineWidth
                arcPath.lineCapStyle = .round
                color.setStroke()
                arcPath.stroke()
            }

            // Percentage text
            let fontSize: CGFloat = text.count > 2 ? 7 : 8
            let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let strSize = str.size()
            let strOrigin = NSPoint(
                x: center.x - strSize.width / 2,
                y: center.y - strSize.height / 2
            )
            str.draw(at: strOrigin)

            return true
        }
        image.isTemplate = false
        button.image = image
    }
}
