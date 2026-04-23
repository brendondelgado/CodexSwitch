import Foundation
import Observation

@MainActor @Observable
final class AccountManager {
    struct AuthSyncResult: Equatable {
        let activeAccountId: UUID
        let activeAccountChanged: Bool
        let tokensUpdated: Bool
    }

    enum AccountUpsertAction: Equatable {
        case inserted
        case updated
    }

    struct AccountUpsertResult: Equatable {
        let localId: UUID
        let action: AccountUpsertAction
    }

    var accounts: [CodexAccount] = []
    var swapHistory: [SwapEvent] = []
    var pollingErrors: [UUID: String] = [:]

    static let reauthenticationRequiredPrefix = "Re-authentication required"

    var activeAccount: CodexAccount? {
        accounts.first(where: \.isActive)
    }

    var sortedAccounts: [CodexAccount] {
        accounts.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            // Unusable accounts (weekly exhausted or overall bad score) sort to end
            let aScore = SwapEngine.score(a)
            let bScore = SwapEngine.score(b)
            let aUsable = aScore > 0
            let bUsable = bScore > 0
            if aUsable != bUsable { return aUsable }
            if aScore != bScore { return aScore > bScore }
            let aRemaining = a.quotaSnapshot?.fiveHour.remainingPercent ?? 0
            let bRemaining = b.quotaSnapshot?.fiveHour.remainingPercent ?? 0
            return aRemaining > bRemaining
        }
    }

    func updateQuota(for accountId: UUID, snapshot: QuotaSnapshot, planType: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        accounts[idx].quotaSnapshot = snapshot
        accounts[idx].planType = planType
        accounts[idx].lastRefreshed = snapshot.fetchedAt
        // A healthy quota poll only proves the access token works right now.
        // It must not clear a known-bad refresh token state.
        pollingErrors[accountId] = nil
    }

    func updatePollingError(for accountId: UUID, error: String) {
        pollingErrors[accountId] = error
    }

    func clearPollingError(for accountId: UUID) {
        pollingErrors[accountId] = nil
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        accounts[idx].reauthenticationError = nil
    }

    func markReauthenticationRequired(for accountId: UUID, detail: String? = nil) {
        let message: String
        if let detail, !detail.isEmpty {
            message = "\(Self.reauthenticationRequiredPrefix) — \(detail)"
        } else {
            message = "\(Self.reauthenticationRequiredPrefix) — click Re-authenticate"
        }
        pollingErrors[accountId] = message
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        accounts[idx].reauthenticationError = message
    }

    func requiresReauthentication(for accountId: UUID) -> Bool {
        reauthenticationError(for: accountId) != nil
    }

    func reauthenticationError(for accountId: UUID) -> String? {
        if let persisted = accounts.first(where: { $0.id == accountId })?.reauthenticationError,
           !persisted.isEmpty {
            return persisted
        }
        guard let transient = pollingErrors[accountId],
              transient.localizedCaseInsensitiveContains(Self.reauthenticationRequiredPrefix) else {
            return nil
        }
        return transient
    }

    func setActive(_ accountId: UUID) {
        for i in accounts.indices {
            accounts[i].isActive = (accounts[i].id == accountId)
        }
        // Persist across restarts
        UserDefaults.standard.set(accountId.uuidString, forKey: "activeAccountId")
    }

    /// Restore the last active account after loading from Keychain.
    /// Priority: auth.json (CLI truth) → UserDefaults (persisted) → first account.
    func restoreActiveAccount() async {
        // 1. Check auth.json — this is what Codex CLI actually uses
        if let authFile = await Self.readAuthFile(),
           sync(with: authFile) != nil {
            return
        }

        // 2. Fall back to UserDefaults
        if let stored = UserDefaults.standard.string(forKey: "activeAccountId"),
           let savedId = UUID(uuidString: stored),
           accounts.contains(where: { $0.id == savedId }) {
            setActive(savedId)
            return
        }

        // 3. Last resort: first account
        if let first = accounts.first { setActive(first.id) }
    }

    /// Read the account_id from ~/.codex/auth.json using the shared AuthFile model.
    /// Runs on a detached task to avoid blocking MainActor with file I/O.
    private static func readAuthFile() async -> AuthFile? {
        await Task.detached {
            let path = NSString("~/.codex/auth.json").expandingTildeInPath
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let authFile = try? JSONDecoder().decode(AuthFile.self, from: data) else {
                return nil
            }
            return authFile
        }.value
    }

    /// Sync active account with auth.json if it changed externally.
    /// Call periodically (e.g. every 5s) to detect CLI or manual changes.
    /// Returns details when the active account or its live tokens changed.
    @discardableResult
    func syncWithAuthJson() async -> AuthSyncResult? {
        guard let authFile = await Self.readAuthFile() else { return nil }
        return sync(with: authFile)
    }

    @discardableResult
    func addAccount(_ account: CodexAccount, preferredLocalId: UUID? = nil) -> AccountUpsertResult {
        if let preferredLocalId,
           let idx = accounts.firstIndex(where: { $0.id == preferredLocalId }) {
            merge(account, into: idx)
            clearPollingError(for: preferredLocalId)
            return AccountUpsertResult(localId: preferredLocalId, action: .updated)
        }

        if let idx = accounts.firstIndex(where: { $0.accountId == account.accountId }) {
            let localId = accounts[idx].id
            merge(account, into: idx)
            clearPollingError(for: localId)
            return AccountUpsertResult(localId: localId, action: .updated)
        }

        if let idx = accounts.firstIndex(where: {
            $0.email.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(account.email.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }) {
            let localId = accounts[idx].id
            merge(account, into: idx)
            clearPollingError(for: localId)
            return AccountUpsertResult(localId: localId, action: .updated)
        }

        accounts.append(account)
        clearPollingError(for: account.id)
        return AccountUpsertResult(localId: account.id, action: .inserted)
    }

    func recordSwap(_ event: SwapEvent) {
        swapHistory.append(event)
    }

    @discardableResult
    func sync(with authFile: AuthFile) -> AuthSyncResult? {
        guard let index = accounts.firstIndex(where: { $0.accountId == authFile.tokens.accountId }) else {
            return nil
        }

        let tokensUpdated = mergeAuthTokens(from: authFile, into: index)
        let shouldActivate = activeAccount?.id != accounts[index].id
        if shouldActivate {
            setActive(accounts[index].id)
        }

        guard shouldActivate || tokensUpdated else {
            return nil
        }

        return AuthSyncResult(
            activeAccountId: accounts[index].id,
            activeAccountChanged: shouldActivate,
            tokensUpdated: tokensUpdated
        )
    }

    private func mergeAuthTokens(from authFile: AuthFile, into index: Int) -> Bool {
        var updated = false

        if accounts[index].accessToken != authFile.tokens.accessToken {
            accounts[index].accessToken = authFile.tokens.accessToken
            updated = true
        }
        if accounts[index].refreshToken != authFile.tokens.refreshToken {
            accounts[index].refreshToken = authFile.tokens.refreshToken
            updated = true
        }
        if accounts[index].idToken != authFile.tokens.idToken {
            accounts[index].idToken = authFile.tokens.idToken
            updated = true
        }

        if updated {
            accounts[index].reauthenticationError = nil
            pollingErrors[accounts[index].id] = nil
        }

        if let lastRefresh = Self.parseLastRefresh(authFile.lastRefresh) {
            accounts[index].lastRefreshed = lastRefresh
        } else if updated {
            accounts[index].lastRefreshed = Date()
        }

        return updated
    }

    private static func parseLastRefresh(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) {
            return parsed
        }

        let fallback = ISO8601DateFormatter()
        return fallback.date(from: value)
    }

    private func merge(_ incoming: CodexAccount, into index: Int) {
        accounts[index].email = incoming.email
        accounts[index].accessToken = incoming.accessToken
        accounts[index].refreshToken = incoming.refreshToken
        accounts[index].idToken = incoming.idToken
        accounts[index].accountId = incoming.accountId
        accounts[index].lastRefreshed = incoming.lastRefreshed
    }
}
