import Foundation

struct CodexAccount: Codable, Identifiable, Sendable {
    let id: UUID
    var email: String
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var accountId: String
    var quotaSnapshot: QuotaSnapshot?
    var lastRefreshed: Date?
    var isActive: Bool

    var displayName: String {
        let local = email.components(separatedBy: "@").first ?? email
        return local.count > 12 ? String(local.prefix(10)) + ".." : local
    }

    init(
        id: UUID = UUID(),
        email: String,
        accessToken: String,
        refreshToken: String,
        idToken: String,
        accountId: String,
        quotaSnapshot: QuotaSnapshot? = nil,
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
        self.lastRefreshed = lastRefreshed
        self.isActive = isActive
    }
}
