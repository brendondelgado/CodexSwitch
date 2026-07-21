import Foundation
import UserNotifications

private final class RateLimitResetNotificationDefaultsReference: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

final class RateLimitResetNotificationDedupeCoordinator: @unchecked Sendable {
    typealias Enqueue = @Sendable (
        UNNotificationRequest,
        @escaping @Sendable (Error?) -> Void
    ) -> Void

    private let lock = NSLock()
    private let defaultsKey: String
    private let maximumPersistedKeys: Int
    private var inFlightKeys = Set<String>()

    init(defaultsKey: String, maximumPersistedKeys: Int) {
        self.defaultsKey = defaultsKey
        self.maximumPersistedKeys = maximumPersistedKeys
    }

    @discardableResult
    func enqueue(
        request: UNNotificationRequest,
        dedupeKey: String,
        userDefaults: UserDefaults,
        using enqueue: @escaping Enqueue
    ) -> Bool {
        lock.lock()
        let persistedKeys = Set(userDefaults.stringArray(forKey: defaultsKey) ?? [])
        guard !persistedKeys.contains(dedupeKey),
              !inFlightKeys.contains(dedupeKey) else {
            lock.unlock()
            return false
        }
        inFlightKeys.insert(dedupeKey)
        lock.unlock()

        let defaultsReference = RateLimitResetNotificationDefaultsReference(userDefaults)
        enqueue(request) { [weak self] error in
            self?.complete(
                dedupeKey: dedupeKey,
                error: error,
                userDefaults: defaultsReference.value
            )
        }
        return true
    }

    private func complete(
        dedupeKey: String,
        error: Error?,
        userDefaults: UserDefaults
    ) {
        lock.lock()
        defer { lock.unlock() }
        inFlightKeys.remove(dedupeKey)
        guard error == nil else { return }

        var orderedKeys: [String] = []
        var knownKeys = Set<String>()
        for key in userDefaults.stringArray(forKey: defaultsKey) ?? []
            where knownKeys.insert(key).inserted {
            orderedKeys.append(key)
        }
        guard knownKeys.insert(dedupeKey).inserted else { return }
        orderedKeys.append(dedupeKey)
        if orderedKeys.count > maximumPersistedKeys {
            orderedKeys.removeFirst(orderedKeys.count - maximumPersistedKeys)
        }
        userDefaults.set(orderedKeys, forKey: defaultsKey)
    }
}

enum NotificationManager {
    private static let tokenRefreshNotificationCooldown: TimeInterval = 12 * 3600
    private static let tokenRefreshNotificationPrefix = "tokenRefreshFailedNotificationAt."
    private static let resetExpirationNotificationDedupeDefaultsKey =
        "resetExpirationNotificationDedupeKeys.v1"
    private static let maximumResetExpirationNotificationDedupeKeys = 256
    private static let resetExpirationNotificationCoordinator =
        RateLimitResetNotificationDedupeCoordinator(
            defaultsKey: resetExpirationNotificationDedupeDefaultsKey,
            maximumPersistedKeys: maximumResetExpirationNotificationDedupeKeys
        )

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

    static func resetExpirationNotificationDedupeKey(
        stableProviderAccountId: String,
        expiration: Date,
        urgency: RateLimitResetExpirationUrgency
    ) -> String? {
        guard urgency.sendsExpirationNotification else { return nil }
        let normalizedAccountId = stableProviderAccountId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
        guard !normalizedAccountId.isEmpty else { return nil }

        let accountComponent = Data(normalizedAccountId.utf8).base64EncodedString()
        let expirationComponent = String(
            expiration.timeIntervalSince1970.bitPattern,
            radix: 16
        )
        return [
            "reset-expiration",
            accountComponent,
            expirationComponent,
            urgency.rawValue,
        ].joined(separator: ".")
    }

    static func shouldNotifyResetExpiration(
        stableProviderAccountId: String,
        expiration: Date,
        urgency: RateLimitResetExpirationUrgency,
        alreadyNotifiedKeys: Set<String>
    ) -> Bool {
        guard let key = resetExpirationNotificationDedupeKey(
            stableProviderAccountId: stableProviderAccountId,
            expiration: expiration,
            urgency: urgency
        ) else {
            return false
        }
        return !alreadyNotifiedKeys.contains(key)
    }

    static func notifyResetExpiration(
        account: CodexAccount,
        expiration: Date,
        now: Date = Date(),
        userDefaults: UserDefaults = .standard
    ) {
        guard isEnabled,
              Bundle.main.bundleIdentifier != nil,
              expiration > now,
              let stableProviderAccountId = account.normalizedProviderAccountId else {
            return
        }
        let urgency = RateLimitResetExpirationUrgency.resolve(
            expiration: expiration,
            now: now
        )
        guard let identifier = resetExpirationNotificationDedupeKey(
            stableProviderAccountId: stableProviderAccountId,
            expiration: expiration,
            urgency: urgency
        ) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "CodexSwitch: \(urgencyNotificationTitle(urgency))"
        content.body = "\(account.email) has a banked reset expiring "
            + expiration.formatted(date: .abbreviated, time: .shortened)
            + ". Review that account before the credit expires."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        enqueueResetExpirationNotification(
            request: request,
            dedupeKey: identifier,
            userDefaults: userDefaults
        ) { request, completion in
            UNUserNotificationCenter.current().add(
                request,
                withCompletionHandler: completion
            )
        }
    }

    @discardableResult
    static func enqueueResetExpirationNotification(
        request: UNNotificationRequest,
        dedupeKey: String,
        userDefaults: UserDefaults,
        coordinator: RateLimitResetNotificationDedupeCoordinator? = nil,
        enqueue: @escaping RateLimitResetNotificationDedupeCoordinator.Enqueue
    ) -> Bool {
        (coordinator ?? resetExpirationNotificationCoordinator).enqueue(
            request: request,
            dedupeKey: dedupeKey,
            userDefaults: userDefaults,
            using: enqueue
        )
    }

    private static func urgencyNotificationTitle(
        _ urgency: RateLimitResetExpirationUrgency
    ) -> String {
        switch urgency {
        case .normal: return "Banked Reset Inventory"
        case .advisory: return "Banked Reset Expires Within 7 Days"
        case .urgent: return "Banked Reset Expires Within 72 Hours"
        case .critical: return "Banked Reset Expires Within 24 Hours"
        }
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
