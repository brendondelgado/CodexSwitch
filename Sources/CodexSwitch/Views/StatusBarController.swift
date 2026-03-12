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

    /// Determine which limit is more urgent: 5h or weekly.
    /// Uses depletion rate to estimate which hits zero first.
    private func urgentWindow(from snapshot: QuotaSnapshot) -> QuotaWindow {
        let fh = snapshot.fiveHour
        let wk = snapshot.weekly

        // If either is already exhausted, it's the urgent one
        if fh.isExhausted { return fh }
        if wk.isExhausted { return wk }

        let fhTimeLeft = max(0, fh.timeUntilReset)
        let wkTimeLeft = max(0, wk.timeUntilReset)

        // Estimate time until each hits 0% based on current depletion rate
        // rate = usedPercent / (windowDuration - timeUntilReset)
        let fhElapsed = max(1, Double(fh.windowDurationMins * 60) - fhTimeLeft)
        let wkElapsed = max(1, Double(wk.windowDurationMins * 60) - wkTimeLeft)

        let fhRate = fh.usedPercent / fhElapsed  // percent per second
        let wkRate = wk.usedPercent / wkElapsed

        // Time until each would hit 100% used (0% remaining)
        let fhTTZ = fhRate > 0 ? fh.remainingPercent / fhRate : .infinity
        let wkTTZ = wkRate > 0 ? wk.remainingPercent / wkRate : .infinity

        return fhTTZ <= wkTTZ ? fh : wk
    }

    /// Update the menu bar icon — circular ring with percentage
    func updateIcon() {
        guard let button = statusItem.button else { return }

        if manager.accounts.isEmpty {
            applyRingIcon(button: button, percent: 0, color: .secondaryLabelColor, text: "--")
            return
        }

        guard let active = manager.activeAccount,
              let snapshot = active.quotaSnapshot else {
            applyRingIcon(button: button, percent: 0, color: .secondaryLabelColor, text: "...")
            return
        }

        let window = urgentWindow(from: snapshot)
        let remaining = window.remainingPercent
        let color: NSColor
        switch remaining {
        case 50...: color = .systemGreen
        case 20..<50: color = .systemYellow
        case 5..<20: color = .systemOrange
        default: color = .systemRed
        }

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
