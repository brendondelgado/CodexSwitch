import Foundation
import Observation

@Observable
final class AccountManager: @unchecked Sendable {
    var accounts: [CodexAccount] = []
    var swapHistory: [SwapEvent] = []

    var activeAccount: CodexAccount? {
        accounts.first(where: \.isActive)
    }

    var sortedAccounts: [CodexAccount] {
        accounts.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            let aRemaining = a.quotaSnapshot?.fiveHour.remainingPercent ?? 0
            let bRemaining = b.quotaSnapshot?.fiveHour.remainingPercent ?? 0
            return aRemaining > bRemaining
        }
    }

    func updateQuota(for accountId: UUID, snapshot: QuotaSnapshot) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        accounts[idx].quotaSnapshot = snapshot
    }

    func setActive(_ accountId: UUID) {
        for i in accounts.indices {
            accounts[i].isActive = (accounts[i].id == accountId)
        }
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
