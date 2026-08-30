import Foundation

enum RateLimitResetInventoryPresentation: Equatable, Sendable {
    case redeeming
    case reconciling
    case error(message: String, lastKnownCount: Int)
    case externalHold(until: Date)
    case refreshing
    case stale(lastKnownCount: Int)
    case expired(lastKnownCount: Int)
    case unknown(lastKnownCount: Int)
    case current(availableCount: Int, nextExpiration: Date?)

    var offersObservationRefresh: Bool {
        switch self {
        case .error, .stale, .expired, .unknown:
            return true
        case .redeeming, .reconciling, .externalHold, .refreshing, .current:
            return false
        }
    }

    static func resolve(
        availableCount: Int,
        nextExpiration: Date?,
        inventoryIsFresh: Bool,
        inventoryExists: Bool = true,
        inventoryHasExpiredAvailableCredit: Bool = false,
        inventoryIsStructurallyValid: Bool = true,
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
        guard inventoryExists else {
            return .unknown(lastKnownCount: normalizedCount)
        }
        if inventoryHasExpiredAvailableCredit {
            return .expired(lastKnownCount: normalizedCount)
        }
        guard inventoryIsStructurallyValid else {
            return .unknown(lastKnownCount: normalizedCount)
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

enum RateLimitResetInventoryFreshness: Equatable, Sendable {
    case current
    case stale
    case expired
    case refreshFailed
    case unknown
    case pending

    var authorizesCount: Bool {
        self == .current
    }
}

struct VerifiedRateLimitResetCount: Equatable, Sendable {
    let availableCount: Int
    let fetchedAt: Date
}

struct RateLimitResetInventoryObservation: Equatable, Sendable {
    static let presentationMaximumAge: TimeInterval = 60

    let freshness: RateLimitResetInventoryFreshness
    let verifiedCount: VerifiedRateLimitResetCount?
    let lastKnownCount: Int
    let fetchedAt: Date?
    let nextExpiration: Date?
    let failureMessage: String?

    static func resolve(
        presentation: RateLimitResetInventoryPresentation?,
        bank: RateLimitResetBank?,
        now: Date
    ) -> Self {
        let normalizedBankCount = max(0, bank?.availableCount ?? 0)

        guard let presentation else {
            return Self(
                freshness: .unknown,
                verifiedCount: nil,
                lastKnownCount: normalizedBankCount,
                fetchedAt: bank?.fetchedAt,
                nextExpiration: nil,
                failureMessage: nil
            )
        }

        switch presentation {
        case .current(let availableCount, let nextExpiration):
            let normalizedCount = max(0, availableCount)
            guard let bank,
                  bank.availableCount == normalizedCount,
                  bank.isFresh(at: now, maxAge: presentationMaximumAge),
                  bank.structurallyValidAvailableCredits(at: now) != nil,
                  normalizedCount == 0 || nextExpiration == bank.nextExpiration(at: now) else {
                return nonCurrentObservation(
                    for: bank,
                    lastKnownCount: normalizedCount,
                    now: now
                )
            }
            return Self(
                freshness: .current,
                verifiedCount: VerifiedRateLimitResetCount(
                    availableCount: normalizedCount,
                    fetchedAt: bank.fetchedAt
                ),
                lastKnownCount: normalizedCount,
                fetchedAt: bank.fetchedAt,
                nextExpiration: normalizedCount > 0 ? nextExpiration : nil,
                failureMessage: nil
            )
        case .error(let message, let lastKnownCount):
            return Self(
                freshness: message.hasPrefix("Reset inventory")
                    ? .refreshFailed
                    : .pending,
                verifiedCount: nil,
                lastKnownCount: max(0, lastKnownCount),
                fetchedAt: bank?.fetchedAt,
                nextExpiration: nil,
                failureMessage: message
            )
        case .stale(let lastKnownCount):
            return nonCurrentObservation(
                for: bank,
                lastKnownCount: max(0, lastKnownCount),
                now: now
            )
        case .expired(let lastKnownCount):
            return Self(
                freshness: .expired,
                verifiedCount: nil,
                lastKnownCount: max(0, lastKnownCount),
                fetchedAt: bank?.fetchedAt,
                nextExpiration: nil,
                failureMessage: nil
            )
        case .unknown(let lastKnownCount):
            return Self(
                freshness: .unknown,
                verifiedCount: nil,
                lastKnownCount: max(0, lastKnownCount),
                fetchedAt: bank?.fetchedAt,
                nextExpiration: nil,
                failureMessage: nil
            )
        case .redeeming, .reconciling, .externalHold, .refreshing:
            return Self(
                freshness: .pending,
                verifiedCount: nil,
                lastKnownCount: normalizedBankCount,
                fetchedAt: bank?.fetchedAt,
                nextExpiration: nil,
                failureMessage: nil
            )
        }
    }

    private static func nonCurrentObservation(
        for bank: RateLimitResetBank?,
        lastKnownCount: Int,
        now: Date
    ) -> Self {
        guard let bank else {
            return Self(
                freshness: .unknown,
                verifiedCount: nil,
                lastKnownCount: max(0, lastKnownCount),
                fetchedAt: nil,
                nextExpiration: nil,
                failureMessage: nil
            )
        }

        let hasNaturallyExpiredCredit = bank.credits.contains { credit in
            credit.isAvailable
                && credit.expiresAt.map { $0 <= now } == true
        }
        let bankIsTimestampFresh = bank.isFresh(
            at: now,
            maxAge: presentationMaximumAge
        )
        let freshness: RateLimitResetInventoryFreshness
        if hasNaturallyExpiredCredit {
            freshness = .expired
        } else if bankIsTimestampFresh {
            freshness = .unknown
        } else {
            freshness = .stale
        }
        return Self(
            freshness: freshness,
            verifiedCount: nil,
            lastKnownCount: max(0, lastKnownCount),
            fetchedAt: bank.fetchedAt,
            nextExpiration: nil,
            failureMessage: nil
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
            inventoryReason = "Reset inventory is unverified because refresh failed; refresh it before redeeming: \(message)"
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
            inventoryReason = "Reset inventory is last-known and unverified; refresh it before redeeming"
        case .expired:
            hasCurrentReset = false
            inventoryReason = "Banked reset inventory has expired; refresh it before redeeming"
        case .unknown:
            hasCurrentReset = false
            inventoryReason = "Reset inventory has not been verified; refresh it before redeeming"
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
            let staleCurrentInventoryReason = hasCurrentReset
                && policyReason == "No fresh banked reset is available"
                ? "Reset inventory is last-known and unverified; refresh it before redeeming"
                : nil
            return Self(
                isEnabled: false,
                helpText: inventoryReason
                    ?? staleCurrentInventoryReason
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

/// The account-card context menu uses the same guarded manual-redemption contract
/// as the button flow. Building this value never submits or redeems a reset.
struct RateLimitResetContextMenuPresentation: Equatable, Sendable {
    let title: String
    let isEnabled: Bool
    let unavailableReason: String?

    var menuItemTitle: String {
        guard let unavailableReason else { return title }
        return "\(title) - \(unavailableReason)"
    }

    static func resolve(
        account: CodexAccount,
        inventory: RateLimitResetInventoryPresentation?,
        coordinatorAuthorization: RateLimitResetCoordinatorAuthorization = .authorized,
        redemptionHandlerAvailable: Bool = true,
        now: Date
    ) -> Self {
        let action = RateLimitResetRedemptionActionPresentation.resolve(
            account: account,
            inventory: inventory,
            coordinatorAuthorization: coordinatorAuthorization,
            now: now
        )
        guard redemptionHandlerAvailable else {
            return Self(
                title: "Redeem banked reset for \(account.email)",
                isEnabled: false,
                unavailableReason: "Reset redemption is unavailable in this view"
            )
        }

        return Self(
            title: "Redeem banked reset for \(account.email)",
            isEnabled: action.isEnabled,
            unavailableReason: action.isEnabled ? nil : action.helpText
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
    let expiration: Date
    let urgency: RateLimitResetExpirationUrgency

    static func make(
        accounts: [CodexAccount],
        presentations: [UUID: RateLimitResetInventoryPresentation],
        now: Date
    ) -> [Self] {
        let candidates = accounts.compactMap { account -> (CodexAccount, Self)? in
            guard account.planPriority > 1 else { return nil }
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
                        urgency: .resolve(expiration: expiration, now: now)
                    )
                )
            case .error, .redeeming, .reconciling, .externalHold, .refreshing,
                 .stale, .expired, .unknown:
                return nil
            }
        }

        return candidates.sorted { lhs, rhs in
            guard lhs.1.expiration == rhs.1.expiration else {
                return lhs.1.expiration < rhs.1.expiration
            }
            return lhs.0.isOrderedBeforeByStableIdentity(rhs.0)
        }.map(\.1)
    }
}

struct PooledRateLimitResetPresentation: Equatable, Sendable {
    let currentAvailableCount: Int
    let nextCurrentExpiration: Date?
    let pendingAccountCount: Int
    let staleAccountCount: Int
    let expiredAccountCount: Int
    let refreshFailedAccountCount: Int
    let unknownAccountCount: Int
    let currentCountFetchedAt: Date?

    init(
        currentAvailableCount: Int,
        nextCurrentExpiration: Date?,
        pendingAccountCount: Int,
        staleAccountCount: Int,
        expiredAccountCount: Int = 0,
        refreshFailedAccountCount: Int = 0,
        unknownAccountCount: Int = 0,
        currentCountFetchedAt: Date? = nil
    ) {
        self.currentAvailableCount = max(0, currentAvailableCount)
        self.nextCurrentExpiration = nextCurrentExpiration
        self.pendingAccountCount = max(0, pendingAccountCount)
        self.staleAccountCount = max(0, staleAccountCount)
        self.expiredAccountCount = max(0, expiredAccountCount)
        self.refreshFailedAccountCount = max(0, refreshFailedAccountCount)
        self.unknownAccountCount = max(0, unknownAccountCount)
        self.currentCountFetchedAt = currentCountFetchedAt
    }

    var hasIncompleteInventory: Bool {
        pendingAccountCount > 0
            || staleAccountCount > 0
            || expiredAccountCount > 0
            || refreshFailedAccountCount > 0
            || unknownAccountCount > 0
    }

    static func summarize(
        accounts: [CodexAccount],
        presentations: [UUID: RateLimitResetInventoryPresentation],
        now: Date
    ) -> Self {
        summarize(accounts.filter { $0.planPriority > 1 }.map { account in
            RateLimitResetInventoryObservation.resolve(
                presentation: presentations[account.id],
                bank: account.rateLimitResetBank,
                now: now
            )
        })
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
            case .expired, .unknown:
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

    private static func summarize(
        _ observations: [RateLimitResetInventoryObservation]
    ) -> Self {
        var currentAvailableCount = 0
        var currentExpirations: [Date] = []
        var currentFetchedDates: [Date] = []
        var pendingAccountCount = 0
        var staleAccountCount = 0
        var expiredAccountCount = 0
        var refreshFailedAccountCount = 0
        var unknownAccountCount = 0

        for observation in observations {
            switch observation.freshness {
            case .current:
                guard let verifiedCount = observation.verifiedCount else {
                    unknownAccountCount += 1
                    continue
                }
                currentAvailableCount += verifiedCount.availableCount
                currentFetchedDates.append(verifiedCount.fetchedAt)
                if verifiedCount.availableCount > 0,
                   let nextExpiration = observation.nextExpiration {
                    currentExpirations.append(nextExpiration)
                }
            case .stale:
                staleAccountCount += 1
            case .expired:
                expiredAccountCount += 1
            case .refreshFailed:
                refreshFailedAccountCount += 1
            case .unknown:
                unknownAccountCount += 1
            case .pending:
                pendingAccountCount += 1
            }
        }

        return Self(
            currentAvailableCount: currentAvailableCount,
            nextCurrentExpiration: currentExpirations.min(),
            pendingAccountCount: pendingAccountCount,
            staleAccountCount: staleAccountCount,
            expiredAccountCount: expiredAccountCount,
            refreshFailedAccountCount: refreshFailedAccountCount,
            unknownAccountCount: unknownAccountCount,
            currentCountFetchedAt: currentFetchedDates.min()
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
