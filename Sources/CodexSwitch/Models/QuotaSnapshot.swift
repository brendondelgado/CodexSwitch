import Foundation

struct QuotaSnapshot: Codable, Sendable {
    let fiveHour: QuotaWindow
    let weekly: QuotaWindow
    let fetchedAt: Date
}

struct QuotaWindow: Codable, Sendable {
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: Date

    var remainingPercent: Double { max(0, 100 - usedPercent) }
    var timeUntilReset: TimeInterval { resetsAt.timeIntervalSinceNow }
    var isExhausted: Bool { usedPercent >= 100 }

    var urgency: QuotaUrgency { QuotaUrgency(remainingPercent: remainingPercent) }
}

enum QuotaUrgency: Sendable, Comparable {
    case relaxed
    case moderate
    case elevated
    case high
    case critical

    var pollInterval: TimeInterval {
        switch self {
        case .relaxed:  return 600
        case .moderate: return 300
        case .elevated: return 120
        case .high:     return 60
        case .critical: return 10
        }
    }

    init(remainingPercent: Double) {
        switch remainingPercent {
        case 50...: self = .relaxed
        case 20..<50: self = .moderate
        case 10..<20: self = .elevated
        case 5..<10: self = .high
        default: self = .critical
        }
    }
}
