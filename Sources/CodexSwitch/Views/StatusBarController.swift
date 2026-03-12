import AppKit
import SwiftUI

final class StatusBarController: @unchecked Sendable {
    private let statusItem: NSStatusItem
    private let manager: AccountManager

    init(statusItem: NSStatusItem, manager: AccountManager) {
        self.statusItem = statusItem
        self.manager = manager
    }

    /// Update the menu bar icon color based on active account's quota state
    func updateIcon() {
        guard let button = statusItem.button else { return }

        let symbolName: String
        let tintColor: NSColor

        guard let active = manager.activeAccount,
              let snapshot = active.quotaSnapshot else {
            symbolName = "bolt.fill"
            tintColor = .secondaryLabelColor
            applyIcon(button: button, symbolName: symbolName, tintColor: tintColor)
            return
        }

        let remaining = snapshot.fiveHour.remainingPercent
        symbolName = "bolt.fill"

        switch remaining {
        case 50...:
            tintColor = .systemGreen
        case 20..<50:
            tintColor = .systemYellow
        case 5..<20:
            tintColor = .systemOrange
        default:
            tintColor = .systemRed
        }

        applyIcon(button: button, symbolName: symbolName, tintColor: tintColor)
    }

    private func applyIcon(button: NSStatusBarButton, symbolName: String, tintColor: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CodexSwitch") else { return }
        let configured = image.withSymbolConfiguration(config) ?? image
        let size = configured.size

        let tinted = NSImage(size: size, flipped: false) { rect in
            configured.draw(in: rect)
            tintColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        button.image = tinted
    }
}
