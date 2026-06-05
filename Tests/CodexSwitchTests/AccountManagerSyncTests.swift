import Foundation
import Testing
@testable import CodexSwitch

@Suite("AccountManager Sync")
struct AccountManagerSyncTests {
    @Test("syncWithAuthJson promotes auth target immediately")
    @MainActor func syncPromotesAuthTarget() async {
        let defaults = isolatedDefaults()
        let manager = AccountManager(
            userDefaults: defaults,
            authAccountIdProvider: { "acc-target" },
            authFileWriter: { _ in }
        )

        let current = CodexAccount(email: "current@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc-current", isActive: true)
        let target = CodexAccount(email: "target@test.com", accessToken: "t2", refreshToken: "r2", idToken: "i2", accountId: "acc-target")
        manager.addAccount(current)
        manager.addAccount(target)
        manager.setActive(current.id)

        let changed = await manager.syncWithAuthJson()

        #expect(changed == target.id)
        #expect(manager.activeAccount?.id == target.id)
    }

    @Test("syncWithAuthJson returns nil when already in sync")
    @MainActor func syncReturnsNilWhenAlreadyInSync() async {
        let defaults = isolatedDefaults()
        let manager = AccountManager(
            userDefaults: defaults,
            authAccountIdProvider: { "acc-current" },
            authFileWriter: { _ in }
        )

        let current = CodexAccount(email: "current@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc-current", isActive: true)
        manager.addAccount(current)
        manager.setActive(current.id)

        let changed = await manager.syncWithAuthJson()

        #expect(changed == nil)
        #expect(manager.activeAccount?.id == current.id)
    }

    @Test("setActiveByEmail mirrors Linux devbox active account")
    @MainActor func setActiveByEmailMirrorsLinuxDevboxActive() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(
            userDefaults: defaults,
            authFileWriter: { _ in }
        )

        let current = CodexAccount(email: "current@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc-current", isActive: true)
        let remoteActive = CodexAccount(email: "REMOTE@test.com", accessToken: "t2", refreshToken: "r2", idToken: "i2", accountId: "acc-remote")
        manager.addAccount(current)
        manager.addAccount(remoteActive)
        manager.setActive(current.id)

        let changed = manager.setActiveByEmail("remote@test.com")

        #expect(changed == remoteActive.id)
        #expect(manager.activeAccount?.id == remoteActive.id)
        #expect(defaults.string(forKey: "activeAccountId") == remoteActive.id.uuidString)
    }

    @Test("Linux devbox account state mirrors active account and quota without replacing tokens")
    @MainActor func linuxDevboxAccountStateMirrorsActiveAndQuotaWithoutReplacingTokens() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(
            userDefaults: defaults,
            authFileWriter: { _ in }
        )

        let current = CodexAccount(
            email: "current@test.com",
            accessToken: "local-current-access",
            refreshToken: "local-current-refresh",
            idToken: "local-current-id",
            accountId: "acc-current",
            isActive: true
        )
        let remoteActive = CodexAccount(
            email: "remote@test.com",
            accessToken: "local-remote-access",
            refreshToken: "local-remote-refresh",
            idToken: "local-remote-id",
            accountId: "acc-remote"
        )
        let remoteSnapshot = quotaSnapshot(fiveHourRemaining: 92, weeklyRemaining: 10)
        manager.addAccount(current)
        manager.addAccount(remoteActive)
        manager.setActive(current.id)

        let changed = manager.applyLinuxDevboxAccountStates([
            LinuxDevboxAccountState(
                email: "REMOTE@test.com",
                isActive: true,
                quotaSnapshot: remoteSnapshot,
                planType: "plus",
                lastRefreshed: remoteSnapshot.fetchedAt,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: nil,
                subscriptionWillRenew: nil,
                hasActiveSubscription: true
            ),
        ])

        #expect(changed == remoteActive.id)
        #expect(manager.activeAccount?.id == remoteActive.id)
        #expect(manager.activeAccount?.accessToken == "local-remote-access")
        #expect(manager.activeAccount?.refreshToken == "local-remote-refresh")
        #expect(manager.activeAccount?.quotaSnapshot?.fiveHour.remainingPercent == 92)
        #expect(manager.activeAccount?.quotaSnapshot?.weekly.remainingPercent == 10)
        #expect(manager.activeAccount?.planType == "plus")
        #expect(manager.activeAccount?.hasActiveSubscription == true)
        #expect(defaults.string(forKey: "activeAccountId") == remoteActive.id.uuidString)
    }

    @Test("Linux devbox account state can skip active takeover while updating quota")
    @MainActor func linuxDevboxAccountStateCanSkipActiveTakeoverWhileUpdatingQuota() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(
            userDefaults: defaults,
            authFileWriter: { _ in }
        )

        let localActive = CodexAccount(
            email: "bd7349@me.com",
            accessToken: "local-active-access",
            refreshToken: "local-active-refresh",
            idToken: "local-active-id",
            accountId: "acc-local",
            isActive: true
        )
        let remoteActive = CodexAccount(
            email: "apps7349@gmail.com",
            accessToken: "local-remote-access",
            refreshToken: "local-remote-refresh",
            idToken: "local-remote-id",
            accountId: "acc-remote"
        )
        let remoteSnapshot = quotaSnapshot(fiveHourRemaining: 89, weeklyRemaining: 79)
        manager.addAccount(localActive)
        manager.addAccount(remoteActive)
        manager.setActive(localActive.id)

        let result = manager.applyLinuxDevboxAccountStatesWithResult([
            LinuxDevboxAccountState(
                email: "apps7349@gmail.com",
                isActive: true,
                quotaSnapshot: remoteSnapshot,
                planType: "pro",
                lastRefreshed: remoteSnapshot.fetchedAt,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: nil,
                subscriptionWillRenew: nil,
                hasActiveSubscription: true
            ),
        ], mirrorRemoteActive: false)

        #expect(result.activeChangedId == nil)
        #expect(result.stateChanged)
        #expect(manager.activeAccount?.id == localActive.id)
        #expect(manager.accounts.first(where: { $0.id == remoteActive.id })?.quotaSnapshot?.fiveHour.remainingPercent == 89)
        #expect(defaults.string(forKey: "activeAccountId") == localActive.id.uuidString)
    }

    @Test("Linux devbox stale account state cannot overwrite fresher local quota")
    @MainActor func linuxDevboxStaleAccountStateCannotOverwriteFresherLocalQuota() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(
            userDefaults: defaults,
            authFileWriter: { _ in }
        )

        let freshSnapshot = quotaSnapshot(
            fiveHourRemaining: 95,
            weeklyRemaining: 99,
            fetchedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
        let staleSnapshot = quotaSnapshot(
            fiveHourRemaining: 0,
            weeklyRemaining: 1,
            fetchedAt: Date(timeIntervalSince1970: 1_776_000_000)
        )
        let account = CodexAccount(
            email: "brenchat7795@gmail.com",
            accessToken: "local-access",
            refreshToken: "local-refresh",
            idToken: "local-id",
            accountId: "acc-brenchat",
            quotaSnapshot: freshSnapshot,
            planType: "pro",
            lastRefreshed: freshSnapshot.fetchedAt
        )
        manager.addAccount(account)

        let changed = manager.applyLinuxDevboxAccountStates([
            LinuxDevboxAccountState(
                email: "brenchat7795@gmail.com",
                isActive: true,
                quotaSnapshot: staleSnapshot,
                planType: "pro",
                lastRefreshed: staleSnapshot.fetchedAt,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: nil,
                subscriptionWillRenew: nil,
                hasActiveSubscription: true
            ),
        ])

        #expect(changed == account.id)
        #expect(manager.activeAccount?.id == account.id)
        #expect(manager.activeAccount?.quotaSnapshot?.fetchedAt == freshSnapshot.fetchedAt)
        #expect(manager.activeAccount?.quotaSnapshot?.fiveHour.remainingPercent == 95)
        #expect(manager.activeAccount?.quotaSnapshot?.weekly.remainingPercent == 99)
        #expect(manager.activeAccount?.lastRefreshed == freshSnapshot.fetchedAt)
    }

    @Test("Linux devbox placeholder quota cannot overwrite real local quota")
    @MainActor func linuxDevboxPlaceholderQuotaCannotOverwriteRealLocalQuota() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(
            userDefaults: defaults,
            authFileWriter: { _ in }
        )
        let localFetchedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let placeholderFetchedAt = localFetchedAt.addingTimeInterval(600)
        let realSnapshot = quotaSnapshot(
            fiveHourRemaining: 77,
            weeklyRemaining: 88,
            fetchedAt: localFetchedAt
        )
        let placeholderSnapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: 0,
                windowDurationMins: 300,
                resetsAt: placeholderFetchedAt,
                hardLimitReached: false
            ),
            weekly: QuotaWindow(
                usedPercent: 0,
                windowDurationMins: 10_080,
                resetsAt: placeholderFetchedAt.addingTimeInterval(604_800),
                hardLimitReached: false
            ),
            fetchedAt: placeholderFetchedAt
        )
        let account = CodexAccount(
            email: "brenchat7795@gmail.com",
            accessToken: "local-access",
            refreshToken: "local-refresh",
            idToken: "local-id",
            accountId: "acc-brenchat",
            quotaSnapshot: realSnapshot,
            planType: "pro",
            lastRefreshed: realSnapshot.fetchedAt,
            isActive: true
        )
        manager.addAccount(account)

        let result = manager.applyLinuxDevboxAccountStatesWithResult([
            LinuxDevboxAccountState(
                email: "brenchat7795@gmail.com",
                isActive: true,
                quotaSnapshot: placeholderSnapshot,
                planType: "pro",
                lastRefreshed: placeholderSnapshot.fetchedAt,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: nil,
                subscriptionWillRenew: nil,
                hasActiveSubscription: true
            ),
        ])

        #expect(result.activeChangedId == nil)
        #expect(manager.activeAccount?.quotaSnapshot?.fetchedAt == realSnapshot.fetchedAt)
        #expect(manager.activeAccount?.quotaSnapshot?.fiveHour.remainingPercent == 77)
        #expect(manager.activeAccount?.quotaSnapshot?.weekly.remainingPercent == 88)
        #expect(manager.activeAccount?.lastRefreshed == realSnapshot.fetchedAt)
    }

    @Test("Linux devbox placeholder quota clears existing placeholder quota")
    @MainActor func linuxDevboxPlaceholderQuotaClearsExistingPlaceholderQuota() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(
            userDefaults: defaults,
            authFileWriter: { _ in }
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let placeholderSnapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: 0,
                windowDurationMins: 300,
                resetsAt: fetchedAt,
                hardLimitReached: false
            ),
            weekly: QuotaWindow(
                usedPercent: 0,
                windowDurationMins: 10_080,
                resetsAt: fetchedAt.addingTimeInterval(604_800),
                hardLimitReached: false
            ),
            fetchedAt: fetchedAt
        )
        let account = CodexAccount(
            email: "brenchat7795@gmail.com",
            accessToken: "local-access",
            refreshToken: "local-refresh",
            idToken: "local-id",
            accountId: "acc-brenchat",
            quotaSnapshot: placeholderSnapshot,
            planType: "pro",
            lastRefreshed: fetchedAt,
            isActive: true
        )
        manager.addAccount(account)

        _ = manager.applyLinuxDevboxAccountStatesWithResult([
            LinuxDevboxAccountState(
                email: "brenchat7795@gmail.com",
                isActive: true,
                quotaSnapshot: placeholderSnapshot,
                planType: "pro",
                lastRefreshed: fetchedAt,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: nil,
                subscriptionWillRenew: nil,
                hasActiveSubscription: true
            ),
        ])

        #expect(manager.activeAccount?.quotaSnapshot == nil)
        #expect(manager.activeAccount?.lastRefreshed == nil)
        #expect(manager.activeAccount?.planType == "pro")
    }

    @Test("Linux devbox no-op state does not report changes")
    @MainActor func linuxDevboxNoOpStateDoesNotReportChanges() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(
            userDefaults: defaults,
            authFileWriter: { _ in }
        )
        let snapshot = quotaSnapshot(
            fiveHourRemaining: 97,
            weeklyRemaining: 88,
            fetchedAt: Date(timeIntervalSince1970: 1_777_100_000)
        )
        let account = CodexAccount(
            email: "apps7349@gmail.com",
            accessToken: "local-access",
            refreshToken: "local-refresh",
            idToken: "local-id",
            accountId: "acc-apps",
            quotaSnapshot: snapshot,
            planType: "plus",
            lastRefreshed: snapshot.fetchedAt,
            hasActiveSubscription: true,
            isActive: true
        )
        manager.addAccount(account)

        let result = manager.applyLinuxDevboxAccountStatesWithResult([
            LinuxDevboxAccountState(
                email: "apps7349@gmail.com",
                isActive: true,
                quotaSnapshot: snapshot,
                planType: "plus",
                lastRefreshed: snapshot.fetchedAt,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: nil,
                subscriptionWillRenew: nil,
                hasActiveSubscription: true
            ),
        ])

        #expect(result == LinuxDevboxAccountApplyResult(activeChangedId: nil, stateChanged: false))
    }

    @Test("Linux devbox runtime auth block overrides stale quota")
    @MainActor func linuxDevboxRuntimeAuthBlockOverridesStaleQuota() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(
            userDefaults: defaults,
            authFileWriter: { _ in }
        )
        let staleSnapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: 100,
                windowDurationMins: 300,
                resetsAt: Date().addingTimeInterval(-300),
                hardLimitReached: true
            ),
            weekly: QuotaWindow(
                usedPercent: 0,
                windowDurationMins: 10_080,
                resetsAt: Date().addingTimeInterval(604_800),
                hardLimitReached: false
            ),
            fetchedAt: Date().addingTimeInterval(-600)
        )
        let account = CodexAccount(
            email: "bren78349@gmail.com",
            accessToken: "local-access",
            refreshToken: "local-refresh",
            idToken: "local-id",
            accountId: "acc-bren",
            quotaSnapshot: staleSnapshot,
            planType: "plus",
            lastRefreshed: staleSnapshot.fetchedAt
        )
        manager.addAccount(account)

        let blockedUntil = Date().addingTimeInterval(30 * 24 * 60 * 60)
        let result = manager.applyLinuxDevboxAccountStatesWithResult([
            LinuxDevboxAccountState(
                email: "bren78349@gmail.com",
                isActive: false,
                quotaSnapshot: nil,
                planType: "plus",
                lastRefreshed: nil,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: nil,
                subscriptionWillRenew: nil,
                hasActiveSubscription: true,
                runtimeUnusableUntil: blockedUntil,
                runtimeUnusableReason: "token_expired"
            ),
        ])

        let updated = manager.accounts.first { $0.id == account.id }
        #expect(result.stateChanged)
        #expect(updated?.requiresReauthentication == true)
        #expect(updated?.realQuotaSnapshot == nil)
        #expect(manager.pollingErrors[account.id] == "Re-authentication required")
    }

    @Test("Restore prefers stored preference over auth.json — CodexSwitch state is authoritative")
    @MainActor func restorePrefersStored() async {
        let defaults = isolatedDefaults()
        let manager = AccountManager(
            userDefaults: defaults,
            authAccountIdProvider: { "acc-target" },
            authFileWriter: { _ in }
        )

        let current = CodexAccount(email: "current@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc-current")
        let target = CodexAccount(email: "target@test.com", accessToken: "t2", refreshToken: "r2", idToken: "i2", accountId: "acc-target")
        manager.addAccount(current)
        manager.addAccount(target)
        defaults.set(current.id.uuidString, forKey: "activeAccountId")

        await manager.restoreActiveAccount()

        // Stored preference wins — auth.json may be stale from a swap chain
        // before the app was killed. CodexSwitch re-writes auth.json to match.
        #expect(manager.activeAccount?.id == current.id)
    }

    @Test("Restore falls back to stored preference when no auth.json")
    @MainActor func restoreFallsBackToStored() async {
        let defaults = isolatedDefaults()
        let current = CodexAccount(email: "current@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc-current")
        let manager = AccountManager(
            userDefaults: defaults,
            authAccountIdProvider: { nil },
            authFileWriter: { _ in }
        )

        manager.addAccount(current)
        defaults.set(current.id.uuidString, forKey: "activeAccountId")

        await manager.restoreActiveAccount()

        #expect(manager.activeAccount?.id == current.id)
    }

    @Test("Quota updates record fetch time as last refreshed")
    @MainActor func quotaUpdatesRecordFetchTime() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        let fetchedAt = Date(timeIntervalSince1970: 1_773_333_333)
        let account = CodexAccount(
            email: "current@test.com",
            accessToken: "t1",
            refreshToken: "r1",
            idToken: "i1",
            accountId: "acc-current"
        )
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: fetchedAt.addingTimeInterval(300), hardLimitReached: false),
            weekly: QuotaWindow(usedPercent: 20, windowDurationMins: 10_080, resetsAt: fetchedAt.addingTimeInterval(10_000), hardLimitReached: false),
            fetchedAt: fetchedAt
        )

        manager.addAccount(account)
        manager.updateQuota(for: account.id, snapshot: snapshot, planType: "plus")

        #expect(manager.accounts.first?.lastRefreshed == fetchedAt)
    }

    @Test("Quota updates normalize subscription flag from plan type")
    @MainActor func quotaUpdatesNormalizeSubscriptionFlagFromPlanType() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        let account = CodexAccount(
            email: "shopszn17@gmail.com",
            accessToken: "t1",
            refreshToken: "r1",
            idToken: "i1",
            accountId: "acc-shopszn",
            planType: "free",
            hasActiveSubscription: false
        )
        let snapshot = quotaSnapshot(fiveHourRemaining: 100, weeklyRemaining: 100)

        manager.addAccount(account)
        manager.updateQuota(for: account.id, snapshot: snapshot, planType: "pro")

        #expect(manager.accounts.first?.planType == "pro")
        #expect(manager.accounts.first?.hasActiveSubscription == true)
    }

    @Test("Quota updates clear stale 5h primed marker when backend window is still unstarted")
    @MainActor func quotaUpdatesClearStaleFiveHourPrimedMarker() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        let fetchedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let account = CodexAccount(
            email: "brenchat7795@gmail.com",
            accessToken: "t1",
            refreshToken: "r1",
            idToken: "i1",
            accountId: "acc-brenchat",
            fiveHourPrimedAt: fetchedAt.addingTimeInterval(-11 * 60)
        )
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: 0,
                windowDurationMins: 300,
                resetsAt: fetchedAt.addingTimeInterval(299.5 * 60),
                hardLimitReached: false
            ),
            weekly: QuotaWindow(
                usedPercent: 20,
                windowDurationMins: 10_080,
                resetsAt: fetchedAt.addingTimeInterval(86_400),
                hardLimitReached: false
            ),
            fetchedAt: fetchedAt
        )

        manager.addAccount(account)
        manager.updateQuota(for: account.id, snapshot: snapshot, planType: "pro")

        #expect(manager.accounts.first?.fiveHourPrimedAt == nil)
    }

    @Test("Quota updates clear unconfirmed 5h marker as soon as post-prime snapshot is still unstarted")
    @MainActor func quotaUpdatesClearPostPrimeUnconfirmedFiveHourMarkerImmediately() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        let fetchedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let account = CodexAccount(
            email: "shopszn17@gmail.com",
            accessToken: "t1",
            refreshToken: "r1",
            idToken: "i1",
            accountId: "acc-shopszn",
            fiveHourPrimedAt: fetchedAt.addingTimeInterval(-2)
        )
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: 0,
                windowDurationMins: 300,
                resetsAt: fetchedAt.addingTimeInterval(299.5 * 60),
                hardLimitReached: false
            ),
            weekly: QuotaWindow(
                usedPercent: 20,
                windowDurationMins: 10_080,
                resetsAt: fetchedAt.addingTimeInterval(86_400),
                hardLimitReached: false
            ),
            fetchedAt: fetchedAt
        )

        manager.addAccount(account)
        manager.updateQuota(for: account.id, snapshot: snapshot, planType: "pro")

        #expect(manager.accounts.first?.fiveHourPrimedAt == nil)
    }

    @Test("Sorted accounts put immediately usable accounts before exhausted active/pro accounts")
    @MainActor func sortedAccountsPreferImmediateUsabilityBeforePlanAndActive() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        let exhaustedPro = CodexAccount(
            email: "exhausted-pro@test.com",
            accessToken: "t1",
            refreshToken: "r1",
            idToken: "i1",
            accountId: "acc-exhausted",
            quotaSnapshot: quotaSnapshot(fiveHourRemaining: 0, weeklyRemaining: 90),
            planType: "pro",
            isActive: true
        )
        let usablePlus = CodexAccount(
            email: "usable-plus@test.com",
            accessToken: "t2",
            refreshToken: "r2",
            idToken: "i2",
            accountId: "acc-usable",
            quotaSnapshot: quotaSnapshot(fiveHourRemaining: 80, weeklyRemaining: 80),
            planType: "plus"
        )

        manager.addAccount(exhaustedPro)
        manager.addAccount(usablePlus)

        #expect(manager.sortedAccounts.first?.id == usablePlus.id)
    }

    @Test("Imported auth refreshes stored tokens for existing account")
    @MainActor func importedAuthRefreshesStoredTokens() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        let existing = CodexAccount(
            email: "brendon.delgado3@gmail.com",
            accessToken: "old-access",
            refreshToken: "old-refresh",
            idToken: "old-id",
            accountId: "acc-existing"
        )
        let imported = CodexAccount(
            email: "brendon.delgado3@gmail.com",
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: "new-id",
            accountId: "acc-existing",
            lastRefreshed: Date(timeIntervalSince1970: 1_777_777_777)
        )

        manager.addAccount(existing)
        manager.updatePollingError(for: existing.id, error: "Re-authentication required")

        let refreshedId = manager.refreshStoredTokens(from: imported)

        #expect(refreshedId == existing.id)
        #expect(manager.accounts.first?.accessToken == "new-access")
        #expect(manager.accounts.first?.refreshToken == "new-refresh")
        #expect(manager.pollingErrors[existing.id] == nil)
    }

    @Test("Imported auth clears stored reauthentication block even when tokens match")
    @MainActor func importedAuthClearsStoredReauthenticationBlockEvenWhenTokensMatch() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        let blockedUntil = Date().addingTimeInterval(30 * 24 * 60 * 60)
        let existing = CodexAccount(
            email: "amazonforest40@gmail.com",
            accessToken: "same-access",
            refreshToken: "same-refresh",
            idToken: "same-id",
            accountId: "acc-existing",
            lastRefreshed: Date(timeIntervalSince1970: 1_777_000_000),
            runtimeUnusableUntil: blockedUntil,
            runtimeUnusableReason: "token_expired"
        )
        let imported = CodexAccount(
            email: "amazonforest40@gmail.com",
            accessToken: "same-access",
            refreshToken: "same-refresh",
            idToken: "same-id",
            accountId: "acc-existing",
            lastRefreshed: Date(timeIntervalSince1970: 1_778_000_000)
        )

        manager.addAccount(existing)
        manager.updatePollingError(for: existing.id, error: "Re-authentication required")

        let refreshedId = manager.refreshStoredTokens(from: imported)

        let updated = manager.accounts.first
        #expect(refreshedId == existing.id)
        #expect(updated?.runtimeUnusableUntil == nil)
        #expect(updated?.runtimeUnusableReason == nil)
        #expect(updated?.requiresReauthentication == false)
        #expect(updated?.lastRefreshed == imported.lastRefreshed)
        #expect(manager.pollingErrors[existing.id] == nil)
    }

    @Test("Stale VPS auth block cannot overwrite newer local reauthentication")
    @MainActor func staleVPSAuthBlockCannotOverwriteNewerLocalReauthentication() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        let localRefreshedAt = Date(timeIntervalSince1970: 1_778_000_000)
        let remoteRefreshedAt = localRefreshedAt.addingTimeInterval(-600)
        let account = CodexAccount(
            email: "brendon.delgado3@gmail.com",
            accessToken: "fresh-access",
            refreshToken: "fresh-refresh",
            idToken: "fresh-id",
            accountId: "acc-existing",
            planType: "plus",
            lastRefreshed: localRefreshedAt,
            hasActiveSubscription: true
        )

        manager.addAccount(account)

        let result = manager.applyLinuxDevboxAccountStatesWithResult([
            LinuxDevboxAccountState(
                email: "brendon.delgado3@gmail.com",
                isActive: false,
                quotaSnapshot: nil,
                planType: "plus",
                lastRefreshed: remoteRefreshedAt,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: nil,
                subscriptionWillRenew: nil,
                hasActiveSubscription: true,
                runtimeUnusableUntil: Date().addingTimeInterval(30 * 24 * 60 * 60),
                runtimeUnusableReason: "token_expired"
            ),
        ])

        let updated = manager.accounts.first
        #expect(result.stateChanged == false)
        #expect(updated?.runtimeUnusableUntil == nil)
        #expect(updated?.runtimeUnusableReason == nil)
        #expect(updated?.requiresReauthentication == false)
        #expect(manager.pollingErrors[account.id] == nil)
    }

    @Test("Imported auth clears expired exhausted quota snapshot")
    @MainActor func importedAuthClearsExpiredExhaustedQuotaSnapshot() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        let expired = Date(timeIntervalSinceNow: -60)
        let existing = CodexAccount(
            email: "brendon.delgado3@gmail.com",
            accessToken: "old-access",
            refreshToken: "old-refresh",
            idToken: "old-id",
            accountId: "acc-existing",
            quotaSnapshot: QuotaSnapshot(
                fiveHour: QuotaWindow(
                    usedPercent: 100,
                    windowDurationMins: 300,
                    resetsAt: expired,
                    hardLimitReached: true
                ),
                weekly: QuotaWindow(
                    usedPercent: 20,
                    windowDurationMins: 10_080,
                    resetsAt: expired.addingTimeInterval(86_400),
                    hardLimitReached: false
                ),
                fetchedAt: expired
            )
        )
        let imported = CodexAccount(
            email: "brendon.delgado3@gmail.com",
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: "new-id",
            accountId: "acc-existing"
        )

        manager.addAccount(existing)

        let refreshedId = manager.refreshStoredTokens(from: imported)

        #expect(refreshedId == existing.id)
        #expect(manager.accounts.first?.quotaSnapshot == nil)
    }

    @Test("Imported auth can match existing account by email")
    @MainActor func importedAuthCanMatchByEmail() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        let existing = CodexAccount(
            email: "brendon.delgado3@gmail.com",
            accessToken: "old-access",
            refreshToken: "old-refresh",
            idToken: "old-id",
            accountId: "old-account-id"
        )
        let imported = CodexAccount(
            email: "BRENDON.DELGADO3@gmail.com",
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: "new-id",
            accountId: "new-account-id"
        )

        manager.addAccount(existing)

        let refreshedId = manager.refreshStoredTokens(from: imported)

        #expect(refreshedId == existing.id)
        #expect(manager.accounts.first?.accountId == "new-account-id")
        #expect(manager.accounts.first?.accessToken == "new-access")
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "CodexSwitchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func quotaSnapshot(
        fiveHourRemaining: Double,
        weeklyRemaining: Double,
        fetchedAt: Date = Date()
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: 100 - fiveHourRemaining,
                windowDurationMins: 300,
                resetsAt: fetchedAt.addingTimeInterval(3600),
                hardLimitReached: false
            ),
            weekly: QuotaWindow(
                usedPercent: 100 - weeklyRemaining,
                windowDurationMins: 10_080,
                resetsAt: fetchedAt.addingTimeInterval(86_400),
                hardLimitReached: false
            ),
            fetchedAt: fetchedAt
        )
    }
}
