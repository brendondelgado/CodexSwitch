import Foundation

enum TokenRefresher {
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"

    struct TokenResponse: Decodable {
        let accessToken: String
        let idToken: String?
        let refreshToken: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case idToken = "id_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    /// Refresh an account's access token using its refresh token.
    /// Returns updated account with new tokens.
    static func refresh(_ account: CodexAccount, session: URLSession = .shared) async throws -> CodexAccount {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("client_id", clientId),
            ("refresh_token", account.refreshToken)
        ]
        let body = params
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.1)" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TokenRefreshError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw TokenRefreshError.refreshFailed(
                statusCode: httpResponse.statusCode,
                body: String(responseBody.prefix(500))
            )
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        var updated = account
        updated.accessToken = tokenResponse.accessToken
        if let newIdToken = tokenResponse.idToken {
            updated.idToken = newIdToken
        }
        if let newRefreshToken = tokenResponse.refreshToken {
            updated.refreshToken = newRefreshToken
        }
        updated.lastRefreshed = Date()
        return updated
    }
}

enum TokenRefreshError: Error, Sendable {
    case refreshFailed(statusCode: Int, body: String)
    case invalidResponse
}
