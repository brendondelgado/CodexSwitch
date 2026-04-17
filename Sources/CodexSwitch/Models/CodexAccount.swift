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

    /// Subscription renewal date parsed from the id_token JWT claims.
    var subscriptionRenewsAt: Date? {
        // Try id_token first, fall back to access_token
        for token in [idToken, accessToken] {
            guard !token.isEmpty else { continue }
            let parts = token.components(separatedBy: ".")
            guard parts.count >= 2 else { continue }
            var base64 = parts[1]
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            guard let data = Data(base64Encoded: base64),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let auth = json["https://api.openai.com/auth"] as? [String: Any],
                  let until = auth["chatgpt_subscription_active_until"] as? String else {
                continue
            }
            // Try multiple date formats
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: until) { return date }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: until) { return date }
        }
        return nil
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
