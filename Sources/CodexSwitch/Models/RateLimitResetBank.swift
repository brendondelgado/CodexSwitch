import Foundation

struct RateLimitResetCredit: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let resetType: String?
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?
    let redeemedAt: Date?
    let title: String?
    let description: String?

    var isAvailable: Bool {
        status.caseInsensitiveCompare("available") == .orderedSame && redeemedAt == nil
    }

    func isAvailable(at date: Date) -> Bool {
        guard isAvailable else { return false }
        return expiresAt.map { $0 > date } ?? true
    }

    var normalizedRedemptionIdentifier: String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizedForRedemption() -> RateLimitResetCredit? {
        guard let normalizedRedemptionIdentifier else { return nil }
        return RateLimitResetCredit(
            id: normalizedRedemptionIdentifier,
            resetType: resetType,
            status: status,
            grantedAt: grantedAt,
            expiresAt: expiresAt,
            redeemedAt: redeemedAt,
            title: title,
            description: description
        )
    }
}

struct RateLimitResetBank: Codable, Sendable, Equatable {
    let availableCount: Int
    let totalEarnedCount: Int
    let credits: [RateLimitResetCredit]
    let fetchedAt: Date

    func availableCredits(at date: Date = Date()) -> [RateLimitResetCredit] {
        guard availableCount > 0 else { return [] }

        var identifiers = Set<String>()
        var normalizedCredits: [RateLimitResetCredit] = []
        for credit in credits where credit.isAvailable(at: date) {
            guard let normalized = credit.normalizedForRedemption(),
                  identifiers.insert(normalized.id).inserted else {
                return []
            }
            normalizedCredits.append(normalized)
        }

        return normalizedCredits.sorted {
            switch ($0.expiresAt, $1.expiresAt) {
            case let (lhs?, rhs?):
                return lhs == rhs ? $0.id < $1.id : lhs < rhs
            case (nil, nil): return $0.id < $1.id
            case (nil, _): return false
            case (_, nil): return true
            }
        }
    }

    func oldestExpiringCredit(at date: Date = Date()) -> RateLimitResetCredit? {
        availableCredits(at: date).first
    }

    func nextExpiration(at date: Date = Date()) -> Date? {
        oldestExpiringCredit(at: date)?.expiresAt
    }

    func hasAvailableReset(at date: Date = Date()) -> Bool {
        return oldestExpiringCredit(at: date) != nil
    }

    func isFresh(at date: Date = Date(), maxAge: TimeInterval = 60) -> Bool {
        date.timeIntervalSince(fetchedAt) >= 0 && date.timeIntervalSince(fetchedAt) < maxAge
    }
}

enum RateLimitResetRedemptionReason: String, Sendable, Equatable {
    case weeklyPressure = "weekly_pressure"
    case poolExhausted = "pool_exhausted"
    case expiringSoon = "expiring_soon"
    case runtimeLimitNoAlternative = "runtime_limit_no_alternative"
    case preserveFasterTier = "preserve_faster_tier"
}

struct RateLimitResetRedemptionCandidate: Equatable, Sendable {
    let accountId: UUID
    let bank: RateLimitResetBank
    let reason: RateLimitResetRedemptionReason
}

enum RateLimitResetPolicy {
    static let expiringSoonInterval: TimeInterval = 24 * 60 * 60
    static let naturalResetProtectionInterval: TimeInterval = 24 * 60 * 60

    static func selectRedemptionCandidate(
        from accounts: [CodexAccount],
        excluding excludedAccountIds: Set<UUID> = [],
        now: Date = Date()
    ) -> RateLimitResetRedemptionCandidate? {
        accounts.compactMap { account -> (CodexAccount, RateLimitResetRedemptionCandidate)? in
            guard !excludedAccountIds.contains(account.id),
                  let bank = account.rateLimitResetBank,
                  bank.isFresh(at: now),
                  let reason = redemptionReason(
                    for: account,
                    allAccounts: accounts,
                    bank: bank,
                    runtimeUsageLimit: account.isQuotaRuntimeLimited(at: now),
                    now: now
                  ) else {
                return nil
            }
            return (
                account,
                RateLimitResetRedemptionCandidate(
                    accountId: account.id,
                    bank: bank,
                    reason: reason
                )
            )
        }.sorted { lhs, rhs in
            if lhs.0.planPriority != rhs.0.planPriority {
                return lhs.0.planPriority > rhs.0.planPriority
            }
            return lhs.0.isOrderedBeforeByStableIdentity(rhs.0)
        }.first?.1
    }

    static func redemptionReason(
        for account: CodexAccount,
        allAccounts: [CodexAccount],
        bank: RateLimitResetBank,
        runtimeUsageLimit: Bool = false,
        now: Date = Date()
    ) -> RateLimitResetRedemptionReason? {
        guard bank.isFresh(at: now),
              bank.hasAvailableReset(at: now),
              let snapshot = account.realQuotaSnapshot(at: now),
              snapshot.isFresh(at: now),
              !snapshot.hasExpiredExhaustedWindow(now: now),
              !snapshot.blockingWindows.contains(where: { $0.resetsAt <= now }) else {
            return nil
        }

        // Active capacity is not a switch destination, but it must still
        // protect another account's reset from unnecessary redemption.
        let readyAlternatives = allAccounts.filter {
            $0.id != account.id && $0.isImmediatelyUsableReplacement(at: now)
        }
        let hasReadyAlternative = !readyAlternatives.isEmpty
        let hasSameOrHigherTierAlternative = readyAlternatives.contains {
            $0.planPriority >= account.planPriority
        }
        if hasSameOrHigherTierAlternative {
            return nil
        }

        if hasReadyAlternative,
           let resetAt = account.blockedQuotaRecoveryAt(now: now),
           resetAt <= now.addingTimeInterval(naturalResetProtectionInterval) {
            return nil
        }

        if snapshot.blockingWindows.contains(where: \.isExhausted),
           let expiration = bank.nextExpiration(at: now),
           expiration.timeIntervalSince(now) <= expiringSoonInterval {
            return .expiringSoon
        }

        if hasReadyAlternative,
           runtimeUsageLimit
                || snapshot.needsSwap {
            return .preserveFasterTier
        }

        if runtimeUsageLimit && !hasReadyAlternative {
            return .runtimeLimitNoAlternative
        }

        guard !snapshot.policyWindows.isEmpty else { return nil }

        if let weekly = snapshot.weekly,
           (weekly.shouldAutoSwapAway || (snapshot.isDenied && snapshot.fiveHour == nil)),
           !hasReadyAlternative {
            return .weeklyPressure
        }

        if snapshot.needsSwap,
           !hasReadyAlternative {
            return .poolExhausted
        }

        return nil
    }
}
