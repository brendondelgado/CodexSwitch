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

    @Test("Sorted accounts keep Free accounts behind paid accounts")
    func sortedAccountsDeprioritizeFree() {
        let manager = AccountManager()
        let free = makeAccount(
            fiveHourRemaining: 100,
            weeklyRemaining: 100,
            planType: "free"
        )
        let plus = makeAccount(
            fiveHourRemaining: 20,
            weeklyRemaining: 50,
            planType: "plus"
        )

        manager.accounts = [free, plus]

        #expect(manager.sortedAccounts.first?.id == plus.id)
    }

    @Test("Refresh stored tokens imports rotated tokens for the currently active account")
    func refreshStoredTokensImportsRotatedTokens() {
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

        let imported = CodexAccount(
            id: UUID(),
            email: active.email,
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: "new-id",
            accountId: active.accountId,
            lastRefreshed: Date()
        )

        let refreshedId = manager.refreshStoredTokens(from: imported)

        #expect(refreshedId == active.id)
        #expect(manager.activeAccount?.accessToken == "new-access")
        #expect(manager.activeAccount?.refreshToken == "new-refresh")
        #expect(manager.activeAccount?.idToken == "new-id")
    }

    @Test("Auth sync activates the matching account when auth.json points elsewhere")
    func syncActivatesMatchingAccount() async {
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
        let manager = AccountManager(authAccountIdProvider: {
            pro.accountId
        })
        manager.accounts = [plus, pro]

        let changedId = await manager.syncWithAuthJson()

        #expect(changedId == pro.id)
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
        manager.markRuntimeUnusable(
            for: existing.id,
            reason: "token_expired",
            until: Date().addingTimeInterval(30 * 24 * 60 * 60)
        )

        var replacement = existing
        replacement.accessToken = "new-access"
        replacement.refreshToken = "new-refresh"
        replacement.idToken = "new-id"
        replacement.lastRefreshed = Date()

        manager.addAccount(replacement)

        #expect(manager.accounts.count == 1)
        #expect(manager.accounts[0].id == existing.id)
        #expect(manager.activeAccount?.id == existing.id)
        #expect(manager.activeAccount?.accessToken == "new-access")
        #expect(manager.activeAccount?.refreshToken == "new-refresh")
        #expect(manager.accounts[0].runtimeUnusableUntil == nil)
        #expect(manager.accounts[0].runtimeUnusableReason == nil)
        #expect(!manager.accounts[0].requiresReauthentication)
        #expect(manager.pollingErrors[existing.id] == nil)
    }

    @Test("Re-authenticated account refresh preserves the canonical local id")
    func refreshStoredTokensPreservesCanonicalLocalId() {
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
        manager.markRuntimeUnusable(
            for: existing.id,
            reason: "token_expired",
            until: Date().addingTimeInterval(30 * 24 * 60 * 60)
        )

        let replacement = CodexAccount(
            email: "stale@example.com",
            accessToken: "fresh-access",
            refreshToken: "fresh-refresh",
            idToken: "fresh-id",
            accountId: "fresh-account",
            lastRefreshed: Date()
        )

        let refreshedId = manager.refreshStoredTokens(from: replacement)

        #expect(refreshedId == existing.id)
        #expect(manager.accounts.count == 1)
        #expect(manager.accounts[0].id == existing.id)
        #expect(manager.accounts[0].email == "stale@example.com")
        #expect(manager.accounts[0].accountId == "fresh-account")
        #expect(manager.accounts[0].runtimeUnusableUntil == nil)
        #expect(manager.accounts[0].runtimeUnusableReason == nil)
        #expect(!manager.accounts[0].requiresReauthentication)
        #expect(manager.pollingErrors[existing.id] == nil)
    }

    @Test("Marking re-authentication required persists on the account record")
    func markRuntimeUnusablePersistsReauthenticationState() {
        let manager = AccountManager()
        let account = makeAccount(
            fiveHourRemaining: 75,
            weeklyRemaining: 80,
            planType: "pro"
        )
        manager.accounts = [account]

        manager.markRuntimeUnusable(
            for: account.id,
            reason: "token_expired",
            until: Date().addingTimeInterval(30 * 24 * 60 * 60)
        )

        #expect(manager.accounts[0].requiresReauthentication)
        #expect(manager.accounts[0].runtimeStatusText == "Re-authentication required")
        #expect(manager.pollingErrors[account.id] == "Re-authentication required")
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
        manager.markRuntimeUnusable(
            for: account.id,
            reason: "token_expired",
            until: Date().addingTimeInterval(30 * 24 * 60 * 60)
        )

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

        #expect(manager.accounts[0].requiresReauthentication)
        #expect(manager.accounts[0].runtimeUnusableReason == "token_expired")
        #expect(manager.pollingErrors[account.id] == "Re-authentication required")
    }
}
