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
    var isActive: Bool

    var planLabel: String {
        guard let plan = planType else { return "" }
        return plan.replacingOccurrences(of: "_", with: " ").capitalized
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
        self.isActive = isActive
    }
}
