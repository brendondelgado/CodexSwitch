import Foundation
import UserNotifications

enum NotificationManager {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func notifySwap(from: CodexAccount, to: CodexAccount) {
        let content = UNMutableNotificationContent()
        content.title = "CodexSwitch: Account Swapped"
        content.subtitle = "Now using \(to.email)"

        var body = ""
        if let snapshot = to.quotaSnapshot {
            let fiveHr = Int(snapshot.fiveHour.remainingPercent)
            let weekly = Int(snapshot.weekly.remainingPercent)
            let resetMins = Int(snapshot.fiveHour.timeUntilReset / 60)
            body = "5hr: \(fiveHr)% remaining | Weekly: \(weekly)% | Resets in \(resetMins)m"
        }
        if let fromSnapshot = from.quotaSnapshot, fromSnapshot.fiveHour.isExhausted {
            body += "\nPrevious account (\(from.displayName)) exhausted."
        }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "swap-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func notifyAllExhausted() {
        let content = UNMutableNotificationContent()
        content.title = "CodexSwitch: All Accounts Exhausted"
        content.body = "No accounts have remaining quota. Waiting for earliest reset."
        content.sound = .defaultCritical

        let request = UNNotificationRequest(
            identifier: "exhausted-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func notifyTokenRefreshFailed(account: CodexAccount) {
        let content = UNMutableNotificationContent()
        content.title = "CodexSwitch: Token Refresh Failed"
        content.body = "Account \(account.email) needs re-authentication. Import again from Codex CLI."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "refresh-fail-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
