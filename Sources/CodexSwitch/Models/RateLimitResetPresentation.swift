import Foundation

enum RateLimitResetInventoryPresentation: Equatable, Sendable {
    case redeeming
    case reconciling
    case externalHold(until: Date)
    case refreshing
    case stale(lastKnownCount: Int)
    case current(availableCount: Int, nextExpiration: Date?)

    static func resolve(
        availableCount: Int,
        nextExpiration: Date?,
        inventoryIsFresh: Bool,
        isRedeeming: Bool = false,
        isReconciling: Bool = false,
        externalHoldUntil: Date? = nil,
        isRefreshing: Bool = false,
        now: Date = Date()
    ) -> Self {
        let normalizedCount = max(0, availableCount)
        if isRedeeming {
            return .redeeming
        }
        if isReconciling {
            return .reconciling
        }
        if let externalHoldUntil, externalHoldUntil > now {
            return .externalHold(until: externalHoldUntil)
        }
        if isRefreshing {
            return .refreshing
        }
        guard inventoryIsFresh else {
            return .stale(lastKnownCount: normalizedCount)
        }
        return .current(
            availableCount: normalizedCount,
            nextExpiration: normalizedCount > 0 ? nextExpiration : nil
        )
    }
}

struct PooledRateLimitResetPresentation: Equatable, Sendable {
    let currentAvailableCount: Int
    let nextCurrentExpiration: Date?
    let pendingAccountCount: Int
    let staleAccountCount: Int

    var hasIncompleteInventory: Bool {
        pendingAccountCount > 0 || staleAccountCount > 0
    }

    static func summarize(
        _ presentations: [RateLimitResetInventoryPresentation]
    ) -> Self {
        var currentAvailableCount = 0
        var currentExpirations: [Date] = []
        var pendingAccountCount = 0
        var staleAccountCount = 0

        for presentation in presentations {
            switch presentation {
            case .current(let availableCount, let nextExpiration):
                currentAvailableCount += max(0, availableCount)
                if availableCount > 0, let nextExpiration {
                    currentExpirations.append(nextExpiration)
                }
            case .stale:
                staleAccountCount += 1
            case .redeeming, .reconciling, .externalHold, .refreshing:
                pendingAccountCount += 1
            }
        }

        return Self(
            currentAvailableCount: currentAvailableCount,
            nextCurrentExpiration: currentExpirations.min(),
            pendingAccountCount: pendingAccountCount,
            staleAccountCount: staleAccountCount
        )
    }
}

extension RateLimitResetSettings {
    static func automaticRedemptionEnabled(
        in userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard userDefaults.object(forKey: automaticRedemptionDefaultsKey) != nil else {
            return true
        }
        return userDefaults.bool(forKey: automaticRedemptionDefaultsKey)
    }
}
