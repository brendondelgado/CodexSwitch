import Foundation

struct ExhaustedPoolAlertGate: Sendable {
    private let cooldown: TimeInterval
    private var lastAlertAt: Date?
    private var exhaustedStateActive = false

    init(cooldown: TimeInterval = 30 * 60) {
        self.cooldown = cooldown
    }

    mutating func shouldNotifyNoCandidate(now: Date = Date()) -> Bool {
        if !exhaustedStateActive {
            exhaustedStateActive = true
            lastAlertAt = now
            return true
        }

        guard let lastAlertAt else {
            self.lastAlertAt = now
            return true
        }

        guard now.timeIntervalSince(lastAlertAt) >= cooldown else {
            return false
        }
        self.lastAlertAt = now
        return true
    }

    mutating func markRecovered() {
        exhaustedStateActive = false
    }
}
