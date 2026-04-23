import Foundation
import Testing
@testable import CodexSwitch

@MainActor
@Suite("AccountManager")
struct AccountManagerTests {
    private func makeAccount(
        id: UUID = UUID(),
        fiveHourRemaining: Double,
        weeklyRemaining: Double,
        planType: String,
        isActive: Bool = false
    ) -> CodexAccount {
        CodexAccount(
            id: id,
            email: "test-\(id.uuidString.prefix(4))@test.com",
            accessToken: "t",
            refreshToken: "r",
            idToken: "i",
            accountId: "acc-\(id.uuidString.prefix(8))",
            quotaSnapshot: QuotaSnapshot(
                fiveHour: QuotaWindow(
                    usedPercent: 100 - fiveHourRemaining,
                    windowDurationMins: 300,
                    resetsAt: Date().addingTimeInterval(3600)
                ),
                weekly: QuotaWindow(
                    usedPercent: 100 - weeklyRemaining,
                    windowDurationMins: 10080,
                    resetsAt: Date().addingTimeInterval(14400)
                ),
                fetchedAt: Date()
            ),
            planType: planType,
            isActive: isActive
        )
    }

    @Test("Sorted accounts prefer higher-value Pro accounts over full Plus accounts")
    func sortedAccountsPreferPro() {
        let manager = AccountManager()
        let plus = makeAccount(
            fiveHourRemaining: 100,
            weeklyRemaining: 50,
            planType: "plus"
        )
        let pro = makeAccount(
            fiveHourRemaining: 20,
            weeklyRemaining: 50,
            planType: "pro"
        )

        manager.accounts = [plus, pro]

        #expect(manager.sortedAccounts.first?.id == pro.id)
    }

    @Test("Auth sync imports rotated tokens for the currently active account")
    func syncImportsRotatedTokens() {
        let manager = AccountManager()
        var active = makeAccount(
            fiveHourRemaining: 80,
            weeklyRemaining: 80,
            planType: "pro",
            isActive: true
        )
        active.accessToken = "old-access"
        active.refreshToken = "old-refresh"
        active.idToken = "old-id"
        manager.accounts = [active]

        let authFile = AuthFile(
            authMode: "chatgpt",
            openaiApiKey: nil,
            tokens: AuthTokens(
                idToken: "new-id",
                accessToken: "new-access",
                refreshToken: "new-refresh",
                accountId: active.accountId
            ),
            lastRefresh: "2026-04-21T17:00:00.000Z"
        )

        let result = manager.sync(with: authFile)

        #expect(result?.activeAccountId == active.id)
        #expect(result?.activeAccountChanged == false)
        #expect(result?.tokensUpdated == true)
        #expect(manager.activeAccount?.accessToken == "new-access")
        #expect(manager.activeAccount?.refreshToken == "new-refresh")
        #expect(manager.activeAccount?.idToken == "new-id")
    }

    @Test("Auth sync activates the matching account when auth.json points elsewhere")
    func syncActivatesMatchingAccount() {
        let manager = AccountManager()
        let plus = makeAccount(
            fiveHourRemaining: 90,
            weeklyRemaining: 50,
            planType: "plus",
            isActive: true
        )
        let pro = makeAccount(
            fiveHourRemaining: 40,
            weeklyRemaining: 90,
            planType: "pro"
        )
        manager.accounts = [plus, pro]

        let authFile = AuthFile(
            authMode: "chatgpt",
            openaiApiKey: nil,
            tokens: AuthTokens(
                idToken: pro.idToken,
                accessToken: pro.accessToken,
                refreshToken: pro.refreshToken,
                accountId: pro.accountId
            ),
            lastRefresh: "2026-04-21T17:00:00Z"
        )

        let result = manager.sync(with: authFile)

        #expect(result?.activeAccountId == pro.id)
        #expect(result?.activeAccountChanged == true)
        #expect(manager.activeAccount?.id == pro.id)
    }

    @Test("Adding a re-authenticated account preserves the canonical local id")
    func addAccountPreservesCanonicalLocalId() {
        let manager = AccountManager()
        var existing = makeAccount(
            fiveHourRemaining: 90,
            weeklyRemaining: 90,
            planType: "plus",
            isActive: true
        )
        existing.email = "brendon@delgadoforge.dev"
        existing.accountId = "df3c3241-56e1-4dfb-b6aa-dd0f6e3286a1"
        existing.accessToken = "old-access"
        existing.refreshToken = "old-refresh"
        manager.accounts = [existing]
        manager.markReauthenticationRequired(for: existing.id, detail: "refresh token rejected")

        var replacement = existing
        replacement.accessToken = "new-access"
        replacement.refreshToken = "new-refresh"
        replacement.idToken = "new-id"
        replacement.lastRefreshed = Date()

        let result = manager.addAccount(replacement)

        #expect(result.localId == existing.id)
        #expect(result.action == .updated)
        #expect(manager.accounts.count == 1)
        #expect(manager.activeAccount?.id == existing.id)
        #expect(manager.activeAccount?.accessToken == "new-access")
        #expect(manager.activeAccount?.refreshToken == "new-refresh")
        #expect(manager.accounts[0].reauthenticationError == nil)
        #expect(manager.pollingErrors[existing.id] == nil)
    }

    @Test("Preferred local id forces re-auth to update the selected stale account")
    func addAccountUsesPreferredLocalId() {
        let manager = AccountManager()
        var existing = makeAccount(
            fiveHourRemaining: 30,
            weeklyRemaining: 60,
            planType: "plus",
            isActive: false
        )
        existing.email = "stale@example.com"
        existing.accountId = "stale-account"
        manager.accounts = [existing]
        manager.markReauthenticationRequired(for: existing.id)

        let replacement = CodexAccount(
            email: "fresh@example.com",
            accessToken: "fresh-access",
            refreshToken: "fresh-refresh",
            idToken: "fresh-id",
            accountId: "fresh-account",
            lastRefreshed: Date()
        )

        let result = manager.addAccount(replacement, preferredLocalId: existing.id)

        #expect(result.localId == existing.id)
        #expect(result.action == .updated)
        #expect(manager.accounts.count == 1)
        #expect(manager.accounts[0].id == existing.id)
        #expect(manager.accounts[0].email == "fresh@example.com")
        #expect(manager.accounts[0].accountId == "fresh-account")
        #expect(manager.accounts[0].reauthenticationError == nil)
        #expect(manager.pollingErrors[existing.id] == nil)
    }

    @Test("Marking re-authentication required persists on the account record")
    func markReauthenticationRequiredPersists() {
        let manager = AccountManager()
        let account = makeAccount(
            fiveHourRemaining: 75,
            weeklyRemaining: 80,
            planType: "pro"
        )
        manager.accounts = [account]

        manager.markReauthenticationRequired(for: account.id, detail: "refresh token rejected")

        #expect(manager.requiresReauthentication(for: account.id))
        #expect(manager.accounts[0].reauthenticationError == "Re-authentication required — refresh token rejected")
    }

    @Test("Quota refresh does not clear a known stale refresh token")
    func quotaRefreshDoesNotClearReauthenticationState() {
        let manager = AccountManager()
        let account = makeAccount(
            fiveHourRemaining: 75,
            weeklyRemaining: 80,
            planType: "pro"
        )
        manager.accounts = [account]
        manager.markReauthenticationRequired(for: account.id, detail: "refresh token rejected")

        manager.updateQuota(
            for: account.id,
            snapshot: QuotaSnapshot(
                fiveHour: QuotaWindow(
                    usedPercent: 5,
                    windowDurationMins: 300,
                    resetsAt: Date().addingTimeInterval(3600)
                ),
                weekly: QuotaWindow(
                    usedPercent: 15,
                    windowDurationMins: 10080,
                    resetsAt: Date().addingTimeInterval(14_400)
                ),
                fetchedAt: Date()
            ),
            planType: "pro"
        )

        #expect(manager.requiresReauthentication(for: account.id))
        #expect(manager.accounts[0].reauthenticationError == "Re-authentication required — refresh token rejected")
    }
}
