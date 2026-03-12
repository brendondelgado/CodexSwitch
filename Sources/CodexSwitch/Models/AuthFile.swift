import Foundation

/// Mirrors the structure of ~/.codex/auth.json
struct AuthFile: Codable, Sendable {
    let authMode: String
    let openaiApiKey: String?
    let tokens: AuthTokens
    let lastRefresh: String

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openaiApiKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }
}

struct AuthTokens: Codable, Sendable {
    let idToken: String
    let accessToken: String
    let refreshToken: String
    let accountId: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountId = "account_id"
    }
}
