import Foundation

enum AccountImporter {
    static let defaultAuthPath = NSString("~/.codex/auth.json").expandingTildeInPath

    static func importCurrentAccount(from path: String? = nil) throws -> CodexAccount {
        let filePath = path ?? defaultAuthPath
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        return try accountFromAuthJSON(data)
    }

    static func accountFromAuthJSON(_ data: Data) throws -> CodexAccount {
        let authFile = try JSONDecoder().decode(AuthFile.self, from: data)
        let email = extractEmail(from: authFile.tokens.idToken) ?? "unknown-\(authFile.tokens.accountId.prefix(8))@imported"

        return CodexAccount(
            email: email,
            accessToken: authFile.tokens.accessToken,
            refreshToken: authFile.tokens.refreshToken,
            idToken: authFile.tokens.idToken,
            accountId: authFile.tokens.accountId,
            lastRefreshed: ISO8601DateFormatter().date(from: authFile.lastRefresh)
        )
    }

    /// Extract email from JWT id_token payload (base64-decoded, no verification)
    private static func extractEmail(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
        // Pad to multiple of 4
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else {
            return nil
        }
        return email
    }
}
