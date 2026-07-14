import Foundation

struct CodexAccount: Codable, Identifiable, Sendable {
    let id: UUID
    var email: String
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var accountId: String
    var quotaSnapshot: QuotaSnapshot?
    var planType: String?
    var lastRefreshed: Date?
    var subscriptionRenewsAt: Date?
    var subscriptionExpiresAt: Date?
    var subscriptionWillRenew: Bool?
    var hasActiveSubscription: Bool?
    var fiveHourPrimedAt: Date?
    var rateLimitResetBank: RateLimitResetBank?
    var runtimeUnusableUntil: Date?
    var runtimeUnusableReason: String?
    var isActive: Bool

    var realQuotaSnapshot: QuotaSnapshot? {
        realQuotaSnapshot(at: Date())
    }

    func realQuotaSnapshot(at now: Date) -> QuotaSnapshot? {
        guard !hasHardRuntimeBlock(at: now),
              let quotaSnapshot,
              !quotaSnapshot.hasBackendUsagePlaceholder else {
            return nil
        }
        return quotaSnapshot
    }

    var hasRealQuotaData: Bool {
        guard let snapshot = realQuotaSnapshot else { return false }
        return snapshot.isDenied || !snapshot.policyWindows.isEmpty
    }

    var hasCompleteRuntimeCredentials: Bool {
        Self.hasContent(accessToken)
            && Self.hasContent(refreshToken)
            && Self.hasContent(idToken)
            && normalizedProviderAccountId != nil
    }

    var isImmediatelyUsableReplacement: Bool {
        isImmediatelyUsableReplacement(at: Date())
    }

    func isImmediatelyUsableReplacement(at now: Date) -> Bool {
        guard hasCompleteRuntimeCredentials,
              !isRuntimeUnusable(at: now) else {
            return false
        }
        return isQuotaImmediatelyUsable(at: now)
    }

    var isQuotaImmediatelyUsable: Bool {
        isQuotaImmediatelyUsable(at: Date())
    }

    func isQuotaImmediatelyUsable(at now: Date) -> Bool {
        guard let snapshot = realQuotaSnapshot(at: now),
              snapshot.isFresh(at: now),
              !snapshot.hasExpiredExhaustedWindow(now: now) else {
            return false
        }
        return snapshot.isImmediatelyUsable
    }

    var needsQuotaRelief: Bool {
        needsQuotaRelief(at: Date())
    }

    func needsQuotaRelief(at now: Date) -> Bool {
        guard let snapshot = realQuotaSnapshot(at: now) else { return false }
        guard snapshot.isFresh(at: now) else { return false }
        return snapshot.isDenied
            || snapshot.policyWindows.isEmpty
            || snapshot.needsSwap
            || snapshot.hasExpiredExhaustedWindow(now: now)
    }

    func blockedQuotaRecoveryAt(now: Date = Date()) -> Date? {
        guard let snapshot = realQuotaSnapshot(at: now),
              snapshot.isFresh(at: now),
              snapshot.needsSwap else { return nil }
        let resetDates = snapshot.blockingWindows
            .map(\.resetsAt)
            .filter { $0 > now }
        return resetDates.max()
    }

    var isRuntimeUnusable: Bool {
        isRuntimeUnusable(at: Date())
    }

    func isRuntimeUnusable(at now: Date) -> Bool {
        guard let runtimeUnusableUntil else { return false }
        return runtimeUnusableUntil > now
    }

    var isQuotaRuntimeLimited: Bool {
        isQuotaRuntimeLimited(at: Date())
    }

    func isQuotaRuntimeLimited(at now: Date) -> Bool {
        guard isRuntimeUnusable(at: now),
              let reason = runtimeUnusableReason?.normalizedRuntimeReason else {
            return false
        }
        return reason.contains("usage_limit")
            || reason.contains("insufficient_quota")
    }

    var hasHardRuntimeBlock: Bool {
        hasHardRuntimeBlock(at: Date())
    }

    func hasHardRuntimeBlock(at now: Date) -> Bool {
        isRuntimeUnusable(at: now) && !isQuotaRuntimeLimited(at: now)
    }

    var requiresReauthentication: Bool {
        requiresReauthentication(at: Date())
    }

    func requiresReauthentication(at now: Date) -> Bool {
        guard isRuntimeUnusable(at: now),
              let reason = runtimeUnusableReason?.normalizedRuntimeReason else {
            return false
        }
        return reason.contains("token_expired")
            || reason.contains("token_invalidated")
            || reason.contains("refresh_token_reused")
            || reason.contains("reauth")
            || reason.contains("unauthorized")
            || reason.contains("authentication")
    }

    var runtimeStatusText: String? {
        guard isRuntimeUnusable else { return nil }
        if requiresReauthentication { return "Re-authentication required" }
        if isQuotaRuntimeLimited, quotaSnapshot != nil { return nil }
        if let reason = runtimeUnusableReason, !reason.isEmpty {
            return reason
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
        return "Temporarily unavailable"
    }

    var planLabel: String {
        guard let plan = planType else { return "" }
        return plan.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var normalizedPlanType: String {
        guard let planType else { return "unknown" }
        let normalized = planType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return normalized.isEmpty ? "unknown" : normalized
    }

    var planPriority: Int {
        let normalized = normalizedPlanType
        if isPlan(normalized, named: "pro_lite") || normalized == "prolite" {
            return 3
        }
        if isPlan(normalized, named: "pro") {
            return 4
        }
        if ["plus", "team", "business", "enterprise", "edu"].contains(where: { isPlan(normalized, named: $0) }) {
            return 2
        }
        if ["free", "free_workspace", "guest"].contains(where: { isPlan(normalized, named: $0) }) {
            return 1
        }
        return hasActiveSubscription == true ? 2 : 1
    }

    var isFreePlan: Bool {
        planPriority <= 1
    }

    var normalizedProviderAccountId: String? {
        Self.stableIdentityComponent(accountId)
    }

    func isOrderedBeforeByStableIdentity(_ other: CodexAccount) -> Bool {
        switch (normalizedProviderAccountId, other.normalizedProviderAccountId) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        let leftEmail = Self.stableIdentityComponent(email) ?? ""
        let rightEmail = Self.stableIdentityComponent(other.email) ?? ""
        if leftEmail != rightEmail {
            return leftEmail < rightEmail
        }
        return id.uuidString < other.id.uuidString
    }

    private func isPlan(_ normalized: String, named plan: String) -> Bool {
        normalized == plan
            || normalized.hasPrefix("\(plan)_")
            || normalized.hasSuffix("_\(plan)")
            || normalized.contains("_\(plan)_")
    }

    private static func hasContent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func stableIdentityComponent(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.precomposedStringWithCanonicalMapping.lowercased()
    }

    init(
        id: UUID = UUID(),
        email: String,
        accessToken: String,
        refreshToken: String,
        idToken: String,
        accountId: String,
        quotaSnapshot: QuotaSnapshot? = nil,
        planType: String? = nil,
        lastRefreshed: Date? = nil,
        subscriptionRenewsAt: Date? = nil,
        subscriptionExpiresAt: Date? = nil,
        subscriptionWillRenew: Bool? = nil,
        hasActiveSubscription: Bool? = nil,
        fiveHourPrimedAt: Date? = nil,
        rateLimitResetBank: RateLimitResetBank? = nil,
        runtimeUnusableUntil: Date? = nil,
        runtimeUnusableReason: String? = nil,
        isActive: Bool = false
    ) {
        self.id = id
        self.email = email
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.quotaSnapshot = quotaSnapshot
        self.planType = planType
        self.lastRefreshed = lastRefreshed
        self.subscriptionRenewsAt = subscriptionRenewsAt
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.subscriptionWillRenew = subscriptionWillRenew
        self.hasActiveSubscription = hasActiveSubscription
        self.fiveHourPrimedAt = fiveHourPrimedAt
        self.rateLimitResetBank = rateLimitResetBank
        self.runtimeUnusableUntil = runtimeUnusableUntil
        self.runtimeUnusableReason = runtimeUnusableReason
        self.isActive = isActive
    }
}

private extension String {
    var normalizedRuntimeReason: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
