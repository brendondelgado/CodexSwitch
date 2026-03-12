import Foundation

enum SwapEngine {
    private static let codexAuthPath = NSString("~/.codex/auth.json").expandingTildeInPath

    /// Score an account for swap eligibility. Higher = better candidate.
    static func score(_ account: CodexAccount) -> Double {
        guard let snapshot = account.quotaSnapshot else { return -1 }
        let fiveHr = snapshot.fiveHour
        let weekly = snapshot.weekly

        // Exclude exhausted on both windows
        if fiveHr.isExhausted && weekly.isExhausted { return -1 }

        // Primary: 5-hour remaining (0-100)
        var s = fiveHr.remainingPercent

        // Tiebreaker: weekly remaining (scaled to 0-10)
        s += weekly.remainingPercent * 0.1

        // Bonus: if 5-hour resets within 30 minutes, add bonus proportional to proximity
        if fiveHr.isExhausted && fiveHr.timeUntilReset < 1800 {
            let proximityBonus = (1800 - fiveHr.timeUntilReset) / 1800 * 15
            s += proximityBonus
        }

        return s
    }

    /// Select the best account to swap to from candidates (excluding currently active)
    static func selectOptimalAccount(from accounts: [CodexAccount]) -> CodexAccount? {
        accounts
            .filter { !$0.isActive }
            .filter { score($0) > 0 }
            .max { score($0) < score($1) }
    }

    /// Generate auth.json data for a given account
    static func generateAuthFileData(for account: CodexAccount) throws -> Data {
        let authFile = AuthFile(
            authMode: "chatgpt",
            openaiApiKey: nil,
            tokens: AuthTokens(
                idToken: account.idToken,
                accessToken: account.accessToken,
                refreshToken: account.refreshToken,
                accountId: account.accountId
            ),
            lastRefresh: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(authFile)
    }

    /// Atomically write auth.json for the given account
    static func writeAuthFile(for account: CodexAccount, path: String? = nil) throws {
        let targetPath = path ?? codexAuthPath
        let tmpPath = targetPath + ".tmp"
        let data = try generateAuthFileData(for: account)

        try data.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)

        // Atomic rename
        let fm = FileManager.default
        if fm.fileExists(atPath: targetPath) {
            try fm.removeItem(atPath: targetPath)
        }
        try fm.moveItem(atPath: tmpPath, toPath: targetPath)

        // Restore permissions (600)
        try fm.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: targetPath
        )
    }
}
