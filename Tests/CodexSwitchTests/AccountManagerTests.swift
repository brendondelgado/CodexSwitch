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

    @Test("Sorted accounts treat weekly-only as usable and windowless as unavailable")
    func sortedAccountsSupportWeeklyOnlyQuota() {
        let manager = AccountManager()
        let now = Date()
        let weeklyOnly = CodexAccount(
            email: "weekly@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "weekly",
            quotaSnapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: now,
                windows: [
                    QuotaWindow(
                        kind: .weekly,
                        durationSeconds: 604_800,
                        usedPercent: 30,
                        resetsAt: now.addingTimeInterval(604_800),
                        source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                    ),
                ]
            ),
            planType: "plus"
        )
        let windowless = CodexAccount(
            email: "unknown@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "unknown",
            quotaSnapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: now,
                windows: []
            ),
            planType: "pro"
        )

        manager.accounts = [windowless, weeklyOnly]

        #expect(manager.sortedAccounts.first?.id == weeklyOnly.id)
    }

    @Test("Weekly-only quota clears quarantined five-hour priming marker")
    func weeklyOnlyQuotaClearsLegacyFiveHourMarker() {
        let manager = AccountManager()
        let now = Date()
        let account = CodexAccount(
            email: "weekly@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "weekly",
            fiveHourPrimedAt: now.addingTimeInterval(-60)
        )
        manager.accounts = [account]

        manager.updateQuota(
            for: account.id,
            snapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: now,
                windows: [
                    QuotaWindow(
                        kind: .weekly,
                        durationSeconds: 604_800,
                        usedPercent: 30,
                        resetsAt: now.addingTimeInterval(604_800),
                        source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                    ),
                ]
            ),
            planType: "plus"
        )

        #expect(manager.accounts.first?.fiveHourPrimedAt == nil)
    }

    @Test("Generic credential upsert cannot mutate the configured account")
    func genericCredentialUpsertRejectsConfiguredAccount() {
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

        let result = manager.upsertInactiveAccount(imported)

        #expect(result == .rejectedConfiguredAccount(active.id))
        #expect(manager.configuredAccount?.accessToken == "old-access")
        #expect(manager.configuredAccount?.refreshToken == "old-refresh")
        #expect(manager.configuredAccount?.idToken == "old-id")
    }

    @Test("Insertion-only add cannot bypass configured credential activation")
    func addAccountCannotMutateConfiguredCredentials() {
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

        let inserted = manager.addAccount(replacement)

        #expect(!inserted)
        #expect(manager.accounts.count == 1)
        #expect(manager.accounts[0].id == existing.id)
        #expect(manager.configuredAccount?.id == existing.id)
        #expect(manager.configuredAccount?.accessToken == "old-access")
        #expect(manager.configuredAccount?.refreshToken == "old-refresh")
        #expect(manager.accounts[0].requiresReauthentication)
        #expect(manager.pollingErrors[existing.id] == "Re-authentication required")
    }

    @Test("Inactive credential upsert preserves stable provider and local identity")
    func inactiveCredentialUpsertPreservesStableIdentity() {
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
            accountId: "stale-account",
            lastRefreshed: Date()
        )

        let result = manager.upsertInactiveAccount(replacement)

        #expect(result == .updated(existing.id))
        #expect(manager.accounts.count == 1)
        #expect(manager.accounts[0].id == existing.id)
        #expect(manager.accounts[0].email == "stale@example.com")
        #expect(manager.accounts[0].accountId == "stale-account")
        #expect(manager.accounts[0].runtimeUnusableUntil == nil)
        #expect(manager.accounts[0].runtimeUnusableReason == nil)
        #expect(!manager.accounts[0].requiresReauthentication)
        #expect(manager.pollingErrors[existing.id] == nil)
    }

    @Test("Same email with a different provider identity cannot overwrite configured credentials")
    func reauthenticationIdentityMismatchStaysInactive() {
        let manager = AccountManager()
        var configured = makeAccount(
            fiveHourRemaining: 80,
            weeklyRemaining: 80,
            planType: "pro",
            isActive: true
        )
        configured.email = "same@example.com"
        configured.accountId = "provider-a"
        configured.accessToken = "old-access"
        configured.refreshToken = "old-refresh"
        manager.accounts = [configured]
        manager.publishActivationState(.committedDegraded(
            targetAccountId: configured.id,
            detail: .activeCredentialMutation,
            activationGeneration: UUID(),
            retryAttempt: 0,
            nextRetryAt: Date(),
            at: Date()
        ))
        let replacement = CodexAccount(
            email: configured.email,
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: "new-id",
            accountId: "provider-b"
        )

        let result = manager.upsertInactiveAccount(replacement)

        #expect(result == .inserted(replacement.id))
        #expect(manager.configuredAccount?.id == configured.id)
        #expect(manager.configuredAccount?.accountId == "provider-a")
        #expect(manager.configuredAccount?.accessToken == "old-access")
        #expect(manager.accounts.first(where: { $0.id == replacement.id })?.isActive == false)
    }

    @Test("Generic insertion always clears configured intent")
    func genericInsertionIsAlwaysInactive() {
        let manager = AccountManager()
        let requestedActive = makeAccount(
            fiveHourRemaining: 50,
            weeklyRemaining: 50,
            planType: "plus",
            isActive: true
        )

        #expect(manager.addAccount(requestedActive))
        #expect(manager.accounts.first?.isActive == false)
        #expect(manager.configuredAccount == nil)
    }

    @Test("Journal target is protected even when its model flag is inactive")
    func genericUpsertRejectsJournalTargetWithoutLease() {
        let manager = AccountManager()
        var protected = makeAccount(
            fiveHourRemaining: 50,
            weeklyRemaining: 50,
            planType: "plus"
        )
        protected.isActive = false
        manager.accounts = [protected]
        manager.publishActivationState(.preparing(
            targetAccountId: protected.id,
            at: Date()
        ))
        let imported = CodexAccount(
            email: protected.email,
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: "new-id",
            accountId: protected.accountId
        )

        #expect(manager.upsertInactiveAccount(imported)
            == .rejectedConfiguredAccount(protected.id))
        #expect(manager.accounts.first?.accessToken == protected.accessToken)
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

    @Test("Quota refresh clears usage-limit runtime block")
    func quotaRefreshClearsUsageLimitRuntimeBlock() {
        let manager = AccountManager()
        let account = makeAccount(
            fiveHourRemaining: 0,
            weeklyRemaining: 69,
            planType: "pro"
        )
        manager.accounts = [account]
        manager.markRuntimeUnusable(
            for: account.id,
            reason: "usage_limit",
            until: Date().addingTimeInterval(6 * 60 * 60)
        )

        manager.updateQuota(
            for: account.id,
            snapshot: QuotaSnapshot(
                fiveHour: QuotaWindow(
                    usedPercent: 10,
                    windowDurationMins: 300,
                    resetsAt: Date().addingTimeInterval(3600)
                ),
                weekly: QuotaWindow(
                    usedPercent: 31,
                    windowDurationMins: 10080,
                    resetsAt: Date().addingTimeInterval(14_400)
                ),
                fetchedAt: Date()
            ),
            planType: "pro"
        )

        #expect(!manager.accounts[0].isRuntimeUnusable)
        #expect(manager.accounts[0].runtimeUnusableReason == nil)
        #expect(manager.accounts[0].realQuotaSnapshot?.weekly?.remainingPercent == 69)
        #expect(manager.pollingErrors[account.id] == nil)
    }
}
