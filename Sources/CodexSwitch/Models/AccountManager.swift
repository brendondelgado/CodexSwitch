import Foundation
import Observation

@MainActor @Observable
final class AccountManager {
    private static let activeAccountDefaultsKey = "activeAccountId"

    private let userDefaults: UserDefaults
    private let authAccountIdProvider: @Sendable () async -> String?
    private let authFileWriter: (CodexAccount) throws -> Void

    var accounts: [CodexAccount] = []
    var swapHistory: [SwapEvent] = []
    var pollingErrors: [UUID: String] = [:]
    var primedAccountIds: Set<UUID> = []
    var deadTokenAccountIds: Set<UUID> = []

    var activeAccount: CodexAccount? {
        accounts.first(where: \.isActive)
    }

    /// Sorted as swap queue: active first, then usable accounts ordered by swap
    /// priority (lowest weekly first — drain constrained accounts), then exhausted
    /// accounts ordered by soonest weekly reset.
    var sortedAccounts: [CodexAccount] {
        accounts.sorted { a, b in
            // Active always first
            if a.isActive != b.isActive { return a.isActive }

            let aScore = SwapEngine.score(a)
            let bScore = SwapEngine.score(b)
            let aUsable = aScore > 0
            let bUsable = bScore > 0

            // Usable accounts before exhausted
            if aUsable != bUsable { return aUsable }

            if aUsable && bUsable {
                // Both usable: higher swap score first (matches swap engine priority)
                return aScore > bScore
            }

            // Both exhausted: sort by soonest weekly reset (next to recover)
            let aReset = a.quotaSnapshot?.weekly.timeUntilReset ?? .greatestFiniteMagnitude
            let bReset = b.quotaSnapshot?.weekly.timeUntilReset ?? .greatestFiniteMagnitude
            return aReset < bReset
        }
    }

    init(
        userDefaults: UserDefaults = .standard,
        authAccountIdProvider: @escaping @Sendable () async -> String? = { await AccountManager.readAuthJsonAccountId() },
        authFileWriter: @escaping (CodexAccount) throws -> Void = { try SwapEngine.writeAuthFile(for: $0) }
    ) {
        self.userDefaults = userDefaults
        self.authAccountIdProvider = authAccountIdProvider
        self.authFileWriter = authFileWriter
    }

    func updateQuota(for accountId: UUID, snapshot: QuotaSnapshot, planType: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        accounts[idx].quotaSnapshot = snapshot
        accounts[idx].planType = planType
        accounts[idx].lastRefreshed = snapshot.fetchedAt
        pollingErrors[accountId] = nil // Clear error on success
    }

    func updatePollingError(for accountId: UUID, error: String) {
        pollingErrors[accountId] = error
    }

    func setActive(_ accountId: UUID, logSource: String? = nil) {
        let oldEmail = activeAccount?.email
        for i in accounts.indices {
            accounts[i].isActive = (accounts[i].id == accountId)
        }
        if let source = logSource {
            let newEmail = activeAccount?.email ?? "?"
            SwapLog.append(.activeAccountChanged(from: oldEmail, to: newEmail, source: source))
        }
        // Persist across restarts
        userDefaults.set(accountId.uuidString, forKey: Self.activeAccountDefaultsKey)
    }

    /// Restore the last active account after loading from Keychain.
    /// Prefer stored active account (UserDefaults) since it reflects what CodexSwitch
    /// was actually using. auth.json may be stale from a swap chain that happened
    /// before the app was killed. After restoring, re-write auth.json to match.
    func restoreActiveAccount() async {
        // Primary: stored active account from UserDefaults (what we were actually using)
        if let storedId = storedActiveAccountId(),
           accounts.contains(where: { $0.id == storedId }) {
            setActive(storedId, logSource: "restore_from_defaults")
            // Re-sync auth.json to match our active account
            if let active = activeAccount {
                try? authFileWriter(active)
            }
            return
        }

        // Fallback: match auth.json to a known account
        if let authMatch = await authMatchFromProvider() {
            setActive(authMatch.id, logSource: "restore_from_auth_json")
            return
        }

        // Fallback: last stored active account
        if let storedId = storedActiveAccountId(),
           accounts.contains(where: { $0.id == storedId }) {
            setActive(storedId, logSource: "restore_from_stored")
            return
        }

        // Last resort: first account
        if let first = accounts.first {
            setActive(first.id, logSource: "restore_fallback_first")
        }
    }

    /// Read the account_id from ~/.codex/auth.json using the shared AuthFile model.
    /// Runs on a detached task to avoid blocking MainActor with file I/O.
    private static func readAuthJsonAccountId() async -> String? {
        await Task.detached {
            let path = NSString("~/.codex/auth.json").expandingTildeInPath
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let authFile = try? JSONDecoder().decode(AuthFile.self, from: data) else {
                return nil
            }
            return authFile.tokens.accountId
        }.value
    }

    /// Sync active account with auth.json if it changed externally.
    /// Returns the UUID of the newly active account if changed, nil otherwise.
    @discardableResult
    func syncWithAuthJson() async -> UUID? {
        guard let match = await authMatchFromProvider() else { return nil }
        guard activeAccount?.id != match.id else { return nil }
        guard accounts.contains(where: { $0.id == match.id }) else { return nil }
        setActive(match.id)
        return match.id
    }

    func addAccount(_ account: CodexAccount) {
        // Prevent duplicate by accountId (OpenAI account UUID)
        if let idx = accounts.firstIndex(where: { $0.accountId == account.accountId }) {
            accounts[idx].accessToken = account.accessToken
            accounts[idx].refreshToken = account.refreshToken
            accounts[idx].idToken = account.idToken
            accounts[idx].lastRefreshed = account.lastRefreshed
            // Fresh tokens clear dead-token state (e.g. after re-login or refresh)
            deadTokenAccountIds.remove(accounts[idx].id)
        } else {
            accounts.append(account)
        }
    }

    func recordSwap(_ event: SwapEvent) {
        swapHistory.append(event)
    }

    private func storedActiveAccountId() -> UUID? {
        guard let stored = userDefaults.string(forKey: Self.activeAccountDefaultsKey) else {
            return nil
        }
        return UUID(uuidString: stored)
    }

    private func authMatchFromProvider() async -> CodexAccount? {
        guard let authAccountId = await authAccountIdProvider() else {
            return nil
        }
        return accounts.first(where: { $0.accountId == authAccountId })
    }
}
