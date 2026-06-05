import Foundation
import os

private let subscriptionLogger = Logger(subsystem: "com.codexswitch", category: "SubscriptionInfo")

struct SubscriptionInfo: Sendable {
    let planType: String?
    let renewsAt: Date?
    let expiresAt: Date?
    let willRenew: Bool?
    let hasActiveSubscription: Bool?
}

actor SubscriptionInfoFetcher {
    private static let accountCheckURL = URL(string: "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(for account: CodexAccount) async throws -> SubscriptionInfo {
        var request = URLRequest(url: Self.accountCheckURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PollerError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw PollerError.httpError(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(AccountCheckResponse.self, from: data)
        let entry = decoded.accounts[account.accountId] ?? decoded.accounts["default"]
        guard let entry else {
            subscriptionLogger.warning("No subscription entry for \(account.email, privacy: .private)")
            return SubscriptionInfo(
                planType: account.planType,
                renewsAt: nil,
                expiresAt: nil,
                willRenew: nil,
                hasActiveSubscription: nil
            )
        }

        return SubscriptionInfo(
            planType: entry.account?.planType,
            renewsAt: Self.parseDate(entry.entitlement?.renewsAt),
            expiresAt: Self.parseDate(entry.entitlement?.expiresAt),
            willRenew: entry.lastActiveSubscription?.willRenew,
            hasActiveSubscription: entry.entitlement?.hasActiveSubscription
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

private struct AccountCheckResponse: Decodable {
    let accounts: [String: AccountCheckEntry]
}

private struct AccountCheckEntry: Decodable {
    let account: AccountCheckAccount?
    let entitlement: AccountCheckEntitlement?
    let lastActiveSubscription: LastActiveSubscription?

    enum CodingKeys: String, CodingKey {
        case account
        case entitlement
        case lastActiveSubscription = "last_active_subscription"
    }
}

private struct AccountCheckAccount: Decodable {
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
    }
}

private struct AccountCheckEntitlement: Decodable {
    let hasActiveSubscription: Bool?
    let renewsAt: String?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case hasActiveSubscription = "has_active_subscription"
        case renewsAt = "renews_at"
        case expiresAt = "expires_at"
    }
}

private struct LastActiveSubscription: Decodable {
    let willRenew: Bool?

    enum CodingKeys: String, CodingKey {
        case willRenew = "will_renew"
    }
}
