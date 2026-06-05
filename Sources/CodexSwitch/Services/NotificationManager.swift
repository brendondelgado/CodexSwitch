import Foundation
import UserNotifications

enum NotificationManager {
    private static var isEnabled: Bool {
        // @AppStorage defaults to true in SettingsView; UserDefaults.bool returns false when unset
        UserDefaults.standard.object(forKey: "notificationsEnabled") == nil
            || UserDefaults.standard.bool(forKey: "notificationsEnabled")
    }

    static func requestPermission() {
        // UNUserNotificationCenter crashes if no app bundle exists (e.g. running raw binary)
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func notifySwap(from: CodexAccount, to: CodexAccount) {
        guard isEnabled, Bundle.main.bundleIdentifier != nil else { return }
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
        if let fromSnapshot = from.quotaSnapshot,
           (fromSnapshot.fiveHour.isExhausted || fromSnapshot.weekly.isExhausted) {
            body += "\nPrevious account (\(from.email)) exhausted."
            body += "\nCLI sessions refreshed — new conversations use \(to.email)."
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

    static func notifyAllExhausted(nextReset: Date? = nil) {
        guard isEnabled, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "CodexSwitch: All Accounts Exhausted"
        if let nextReset {
            let minutes = max(0, Int(nextReset.timeIntervalSinceNow / 60))
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            let resetText = hours > 0 ? "\(hours)h \(remainingMinutes)m" : "\(remainingMinutes)m"
            content.body = "No accounts have remaining quota. Waiting for earliest reset in \(resetText)."
        } else {
            content.body = "No accounts have remaining quota. Waiting for earliest reset."
        }
        content.sound = .defaultCritical

        let request = UNNotificationRequest(
            identifier: "codexswitch-pool-exhausted",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func notifyTokenRefreshFailed(account: CodexAccount) {
        guard isEnabled, Bundle.main.bundleIdentifier != nil else { return }
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

    static func notifyLinuxDevboxReadinessIssue(summary: String) {
        guard isEnabled, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "CodexSwitch: Linux Devbox Not Ready"
        content.body = summary
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "linux-devbox-readiness-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
