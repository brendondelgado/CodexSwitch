import Foundation

enum RateLimitResetInventoryPresentation: Equatable, Sendable {
    case redeeming
    case reconciling
    case error(message: String, lastKnownCount: Int)
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
        error: String? = nil,
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
        if let error {
            return .error(message: error, lastKnownCount: normalizedCount)
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

enum RateLimitResetExpirationUrgency: String, CaseIterable, Equatable, Sendable {
    case normal
    case advisory
    case urgent
    case critical

    static let advisoryInterval: TimeInterval = 7 * 24 * 60 * 60
    static let urgentInterval: TimeInterval = 72 * 60 * 60
    static let criticalInterval: TimeInterval = 24 * 60 * 60

    static func resolve(expiration: Date, now: Date) -> Self {
        let remaining = expiration.timeIntervalSince(now)
        if remaining <= criticalInterval { return .critical }
        if remaining <= urgentInterval { return .urgent }
        if remaining <= advisoryInterval { return .advisory }
        return .normal
    }

    var pulsePeriod: TimeInterval? {
        switch self {
        case .normal, .advisory: return nil
        case .urgent: return 2.4
        case .critical: return 1.2
        }
    }

    var sendsExpirationNotification: Bool {
        self != .normal
    }

    func pulseOpacity(at date: Date, reduceMotion: Bool) -> Double {
        guard !reduceMotion, let pulsePeriod else { return 1 }
        let remainder = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: pulsePeriod)
        let phase = (remainder >= 0 ? remainder : remainder + pulsePeriod) / pulsePeriod
        let triangle = abs((phase * 2) - 1)
        return 0.65 + (0.35 * triangle)
    }
}

struct RateLimitResetRedemptionActionPresentation: Equatable, Sendable {
    let isEnabled: Bool
    let helpText: String

    static func resolve(
        account: CodexAccount,
        inventory: RateLimitResetInventoryPresentation?,
        coordinatorAuthorization: RateLimitResetCoordinatorAuthorization = .authorized,
        now: Date
    ) -> Self {
        let inventoryReason: String?
        let hasCurrentReset: Bool

        switch inventory {
        case .current(let availableCount, _):
            hasCurrentReset = availableCount > 0
            inventoryReason = hasCurrentReset ? nil : "No current banked reset is available"
        case .error(let message, _):
            hasCurrentReset = false
            inventoryReason = "Reset inventory error: \(message)"
        case .redeeming:
            hasCurrentReset = false
            inventoryReason = "A banked reset is already being redeemed"
        case .reconciling:
            hasCurrentReset = false
            inventoryReason = "Reset redemption is awaiting reconciliation"
        case .externalHold:
            hasCurrentReset = false
            inventoryReason = "Reset redemption is temporarily on hold"
        case .refreshing:
            hasCurrentReset = false
            inventoryReason = "Reset inventory is refreshing"
        case .stale:
            hasCurrentReset = false
            inventoryReason = "Reset inventory is stale"
        case nil:
            hasCurrentReset = false
            inventoryReason = "Reset inventory is unavailable"
        }

        let policyAllowsRedemption = RateLimitResetPolicy.canManuallyRedeem(
            for: account,
            bank: account.rateLimitResetBank,
            now: now
        )
        let policyReason = RateLimitResetPolicy.manualRedemptionUnavailableReason(
            for: account,
            bank: account.rateLimitResetBank,
            now: now
        )

        guard coordinatorAuthorization.isAuthorized else {
            return Self(
                isEnabled: false,
                helpText: coordinatorAuthorization.unavailableReason
                    ?? "Manual reset redemption is unavailable"
            )
        }

        guard hasCurrentReset, policyAllowsRedemption else {
            return Self(
                isEnabled: false,
                helpText: inventoryReason
                    ?? policyReason
                    ?? "Manual reset redemption is unavailable"
            )
        }

        return Self(
            isEnabled: true,
            helpText: "Redeem the oldest-expiring banked reset after confirmation"
        )
    }
}

enum RateLimitResetCoordinatorAuthorization: Equatable, Sendable {
    case authorized
    case blocked(String)

    var isAuthorized: Bool {
        self == .authorized
    }

    var unavailableReason: String? {
        guard case .blocked(let reason) = self else { return nil }
        return reason
    }

    static func resolve(
        state: RateLimitResetCoordinatorState,
        now: Date
    ) -> Self {
        guard state.externalHoldStateIsReadable else {
            return .blocked("Reset ownership state is unavailable; refresh and try again")
        }
        guard !state.redemptionIsInProgress else {
            return .blocked("Another reset redemption is already in progress")
        }
        guard state.configuredAccountIsAvailable,
              state.activationAllowsManualRedemption else {
            return .blocked("The active runtime is not ready; wait for account activation to finish")
        }
        guard !state.accountHasUnresolvedAttempt else {
            return .blocked("This account already has a reset awaiting reconciliation")
        }
        guard state.externalHoldUntil.map({ $0 <= now }) ?? true,
              state.localHoldUntil.map({ $0 <= now }) ?? true else {
            return .blocked(
                "Reset redemption is temporarily held while recent inventory changes settle"
            )
        }
        return .authorized
    }
}

struct RateLimitResetCoordinatorState: Equatable, Sendable {
    let externalHoldStateIsReadable: Bool
    let redemptionIsInProgress: Bool
    let configuredAccountIsAvailable: Bool
    let activationAllowsManualRedemption: Bool
    let accountHasUnresolvedAttempt: Bool
    let externalHoldUntil: Date?
    let localHoldUntil: Date?
}

struct RateLimitResetOverviewItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let accountEmail: String
    let availableCount: Int
    let expiration: Date?
    let urgency: RateLimitResetExpirationUrgency?
    let errorMessage: String?

    var isError: Bool {
        errorMessage != nil
    }

    static func make(
        accounts: [CodexAccount],
        presentations: [UUID: RateLimitResetInventoryPresentation],
        now: Date
    ) -> [Self] {
        let candidates = accounts.compactMap { account -> (CodexAccount, Self)? in
            guard let presentation = presentations[account.id] else { return nil }
            switch presentation {
            case .current(let availableCount, let expiration):
                guard availableCount > 0, let expiration, expiration > now else { return nil }
                return (
                    account,
                    Self(
                        id: account.id,
                        accountEmail: account.email,
                        availableCount: availableCount,
                        expiration: expiration,
                        urgency: .resolve(expiration: expiration, now: now),
                        errorMessage: nil
                    )
                )
            case .error(let message, let lastKnownCount):
                return (
                    account,
                    Self(
                        id: account.id,
                        accountEmail: account.email,
                        availableCount: max(0, lastKnownCount),
                        expiration: nil,
                        urgency: nil,
                        errorMessage: message
                    )
                )
            case .redeeming, .reconciling, .externalHold, .refreshing, .stale:
                return nil
            }
        }

        return candidates.sorted { lhs, rhs in
            switch (lhs.1.expiration, rhs.1.expiration) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.0.isOrderedBeforeByStableIdentity(rhs.0)
            }
        }.map(\.1)
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
            case .stale, .error:
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
