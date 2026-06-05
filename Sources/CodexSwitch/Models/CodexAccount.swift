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
    var runtimeUnusableUntil: Date?
    var runtimeUnusableReason: String?
    var isActive: Bool

    var realQuotaSnapshot: QuotaSnapshot? {
        guard !isRuntimeUnusable,
              let quotaSnapshot,
              !quotaSnapshot.hasBackendUsagePlaceholder else {
            return nil
        }
        return quotaSnapshot
    }

    var hasRealQuotaData: Bool {
        realQuotaSnapshot != nil
    }

    var isRuntimeUnusable: Bool {
        guard let runtimeUnusableUntil else { return false }
        return runtimeUnusableUntil > Date()
    }

    var requiresReauthentication: Bool {
        guard isRuntimeUnusable,
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

    private func isPlan(_ normalized: String, named plan: String) -> Bool {
        normalized == plan
            || normalized.hasPrefix("\(plan)_")
            || normalized.hasSuffix("_\(plan)")
            || normalized.contains("_\(plan)_")
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
