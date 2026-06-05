import Foundation

struct QuotaSnapshot: Codable, Sendable, Equatable {
    let fiveHour: QuotaWindow
    let weekly: QuotaWindow
    let fetchedAt: Date

    var hasBackendUsagePlaceholder: Bool {
        fiveHour.looksLikeBackendUsagePlaceholder(fetchedAt: fetchedAt)
    }

    func hasExpiredExhaustedWindow(now: Date = Date()) -> Bool {
        fiveHour.needsResetConfirmation(now: now) || weekly.needsResetConfirmation(now: now)
    }

    func hasStaleExpiredExhaustedWindow(now: Date = Date(), staleAfter: TimeInterval = 120) -> Bool {
        fiveHour.needsResetConfirmation(now: now, staleAfter: staleAfter)
            || weekly.needsResetConfirmation(now: now, staleAfter: staleAfter)
    }
}

struct QuotaWindow: Codable, Sendable, Equatable {
    static let autoSwapThresholdPercent = 2.0

    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: Date
    let hardLimitReached: Bool

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowDurationMins
        case resetsAt
        case hardLimitReached
    }

    init(usedPercent: Double, windowDurationMins: Int, resetsAt: Date, hardLimitReached: Bool = false) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
        self.hardLimitReached = hardLimitReached
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        windowDurationMins = try container.decode(Int.self, forKey: .windowDurationMins)
        resetsAt = try container.decode(Date.self, forKey: .resetsAt)
        hardLimitReached = try container.decodeIfPresent(Bool.self, forKey: .hardLimitReached) ?? false
    }

    var remainingPercent: Double { max(0, 100 - usedPercent) }
    var timeUntilReset: TimeInterval { resetsAt.timeIntervalSinceNow }
    var isExhausted: Bool { hardLimitReached || remainingPercent < 1 }
    func needsResetConfirmation(now: Date = Date()) -> Bool {
        isExhausted && resetsAt <= now
    }
    func needsResetConfirmation(now: Date = Date(), staleAfter: TimeInterval) -> Bool {
        isExhausted && resetsAt <= now.addingTimeInterval(-staleAfter)
    }
    var shouldAutoSwapAway: Bool {
        hardLimitReached || remainingPercent < Self.autoSwapThresholdPercent
    }

    func looksLikeBackendUsagePlaceholder(fetchedAt: Date, tolerance: TimeInterval = 10) -> Bool {
        !hardLimitReached
            && usedPercent <= 0.0001
            && abs(resetsAt.timeIntervalSince(fetchedAt)) <= tolerance
    }

    var urgency: QuotaUrgency { QuotaUrgency(remainingPercent: remainingPercent) }
}

/// Urgency levels ordered by increasing severity (Comparable uses declaration order).
enum QuotaUrgency: Sendable, Comparable {
    case relaxed     // >= 50%
    case moderate    // 20–50%
    case elevated    // 10–20%
    case high        // 7–10%
    case imminent    // 1–7% — agents can drain fast, poll every second
    case critical    // < 1% — about to hit the wall

    var pollInterval: TimeInterval {
        switch self {
        case .relaxed:  return 600
        case .moderate: return 300
        case .elevated: return 120
        case .high:     return 60
        case .imminent: return 1
        case .critical: return 1
        }
    }

    init(remainingPercent: Double) {
        switch remainingPercent {
        case 50...: self = .relaxed
        case 20..<50: self = .moderate
        case 10..<20: self = .elevated
        case 7..<10: self = .high
        case 1..<7: self = .imminent
        default: self = .critical
        }
    }
}
