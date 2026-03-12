import Foundation
import Observation

@MainActor @Observable
final class AccountManager {
    var accounts: [CodexAccount] = []
    var swapHistory: [SwapEvent] = []
    var pollingErrors: [UUID: String] = [:]

    var activeAccount: CodexAccount? {
        accounts.first(where: \.isActive)
    }

    var sortedAccounts: [CodexAccount] {
        accounts.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            // Unusable accounts (weekly exhausted or overall bad score) sort to end
            let aUsable = SwapEngine.score(a) > 0
            let bUsable = SwapEngine.score(b) > 0
            if aUsable != bUsable { return aUsable }
            let aRemaining = a.quotaSnapshot?.fiveHour.remainingPercent ?? 0
            let bRemaining = b.quotaSnapshot?.fiveHour.remainingPercent ?? 0
            return aRemaining > bRemaining
        }
    }

    func updateQuota(for accountId: UUID, snapshot: QuotaSnapshot, planType: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        accounts[idx].quotaSnapshot = snapshot
        accounts[idx].planType = planType
        pollingErrors[accountId] = nil // Clear error on success
    }

    func updatePollingError(for accountId: UUID, error: String) {
        pollingErrors[accountId] = error
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
    func restoreActiveAccount() {
        // 1. Check auth.json — this is what Codex CLI actually uses
        if let authAccountId = Self.readAuthJsonAccountId(),
           let match = accounts.first(where: { $0.accountId == authAccountId }) {
            setActive(match.id)
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
    /// Marked nonisolated to avoid blocking MainActor with file I/O.
    private nonisolated static func readAuthJsonAccountId() -> String? {
        let path = NSString("~/.codex/auth.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let authFile = try? JSONDecoder().decode(AuthFile.self, from: data) else {
            return nil
        }
        return authFile.tokens.accountId
    }

    /// Sync active account with auth.json if it changed externally.
    /// Call periodically (e.g. every 5s) to detect CLI or manual changes.
    /// Returns the UUID of the newly active account if it changed, nil otherwise.
    @discardableResult
    func syncWithAuthJson() -> UUID? {
        guard let authAccountId = Self.readAuthJsonAccountId() else { return nil }
        // Already in sync
        if activeAccount?.accountId == authAccountId { return nil }
        // Find matching account and switch
        if let match = accounts.first(where: { $0.accountId == authAccountId }) {
            setActive(match.id)
            return match.id
        }
        return nil
    }

    func addAccount(_ account: CodexAccount) {
        // Prevent duplicate by accountId (OpenAI account UUID)
        if let idx = accounts.firstIndex(where: { $0.accountId == account.accountId }) {
            accounts[idx].accessToken = account.accessToken
            accounts[idx].refreshToken = account.refreshToken
            accounts[idx].idToken = account.idToken
            accounts[idx].lastRefreshed = account.lastRefreshed
        } else {
            accounts.append(account)
        }
    }

    func recordSwap(_ event: SwapEvent) {
        swapHistory.append(event)
    }
}
