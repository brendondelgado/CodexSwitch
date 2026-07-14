import Foundation
import UserNotifications

enum NotificationManager {
    private static let tokenRefreshNotificationCooldown: TimeInterval = 12 * 3600
    private static let tokenRefreshNotificationPrefix = "tokenRefreshFailedNotificationAt."

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

        content.body = swapNotificationBody(from: from, to: to)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "swap-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func swapNotificationBody(
        from: CodexAccount,
        to: CodexAccount,
        now: Date = Date()
    ) -> String {
        var lines: [String] = []

        if let snapshot = to.realQuotaSnapshot {
            let windowStatus = snapshot.orderedPolicyWindows.map {
                "\(windowLabel($0.kind)): \(Int($0.effectiveRemainingPercent))% remaining"
            }
            lines.append(contentsOf: windowStatus)

            if snapshot.isDenied {
                lines.append("Quota access is currently denied.")
            } else if let resetAt = snapshot.mostUrgentWindow?.resetsAt {
                let resetMinutes = max(0, Int(resetAt.timeIntervalSince(now) / 60))
                lines.append("Next quota reset in \(resetMinutes)m.")
            } else {
                lines.append("Quota windows are unavailable.")
            }
        } else {
            lines.append("Quota windows are unavailable.")
        }

        if from.needsQuotaRelief {
            lines.append("Previous account (\(from.email)) is unavailable.")
            lines.append("CLI sessions refreshed; new conversations use \(to.email).")
        }

        return lines.joined(separator: "\n")
    }

    private static func windowLabel(_ kind: QuotaWindowKind) -> String {
        switch kind {
        case .fiveHour: return "5hr"
        case .weekly: return "Weekly"
        case .unknown: return "Quota"
        }
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
        guard shouldNotifyTokenRefreshFailed(account: account) else { return }

        let content = UNMutableNotificationContent()
        content.title = "CodexSwitch: Token Refresh Failed"
        content.body = "Account \(account.email) needs re-authentication. Use the Re-authenticate button on its account card in CodexSwitch."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "refresh-fail-\(account.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func shouldNotifyTokenRefreshFailed(
        account: CodexAccount,
        now: Date = Date(),
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        let key = tokenRefreshNotificationPrefix + account.id.uuidString
        let last = userDefaults.double(forKey: key)
        if last > 0,
           now.timeIntervalSince(Date(timeIntervalSince1970: last)) < tokenRefreshNotificationCooldown {
            return false
        }
        userDefaults.set(now.timeIntervalSince1970, forKey: key)
        return true
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
