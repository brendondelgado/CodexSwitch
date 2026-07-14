import Foundation
import Testing
@testable import CodexSwitch

@Suite("AccountManager Sync")
struct AccountManagerSyncTests {
    @Test("Email lookup resolves a local account without changing configuration")
    @MainActor func emailLookupDoesNotSelectAccount() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)

        let current = CodexAccount(email: "current@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc-current", isActive: true)
        let remoteActive = CodexAccount(email: "REMOTE@test.com", accessToken: "t2", refreshToken: "r2", idToken: "i2", accountId: "acc-remote")
        manager.addAccount(current)
        manager.addAccount(remoteActive)
        manager.setConfiguredAccount(current.id)

        let resolved = manager.accountId(matchingEmail: "remote@test.com")

        #expect(resolved == remoteActive.id)
        #expect(manager.configuredAccount?.id == current.id)
        #expect(defaults.string(forKey: "activeAccountId") == current.id.uuidString)
    }

    @Test("Linux devbox observations remain separate from Mac policy and active ownership")
    @MainActor func linuxDevboxObservationsRemainPresentationOnly() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)

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
        manager.setConfiguredAccount(current.id)

        let observation = LinuxDevboxAccountState(
                email: "REMOTE@test.com",
                isActive: true,
                quotaSnapshot: remoteSnapshot,
                planType: "plus",
                lastRefreshed: remoteSnapshot.fetchedAt,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: nil,
                subscriptionWillRenew: nil,
                hasActiveSubscription: true
            )
        let result = manager.applyLinuxDevboxAccountStates([observation])

        #expect(result.stateChanged)
        #expect(manager.configuredAccount?.id == current.id)
        let mirrored = manager.accounts.first(where: { $0.id == remoteActive.id })
        #expect(mirrored?.accessToken == "local-remote-access")
        #expect(mirrored?.refreshToken == "local-remote-refresh")
        #expect(mirrored?.quotaSnapshot == nil)
        #expect(mirrored?.planType == nil)
        #expect(mirrored?.hasActiveSubscription == nil)
        #expect(manager.linuxDevboxAccountStates == [observation])
        #expect(defaults.string(forKey: "activeAccountId") == current.id.uuidString)
    }

    @Test("Linux devbox remote active status never mutates the Mac active account")
    @MainActor func linuxDevboxRemoteActiveDoesNotMutateMacActiveAccount() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)

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
        manager.setConfiguredAccount(localActive.id)

        let result = manager.applyLinuxDevboxAccountStates([
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
        ])

        #expect(result.stateChanged)
        #expect(manager.configuredAccount?.id == localActive.id)
        #expect(manager.accounts.first(where: { $0.id == remoteActive.id })?.quotaSnapshot == nil)
        #expect(manager.linuxDevboxAccountStates.first?.quotaSnapshot?.fiveHour?.remainingPercent == 89)
        #expect(defaults.string(forKey: "activeAccountId") == localActive.id.uuidString)
    }

    @Test("Linux devbox stale account state cannot overwrite fresher local quota")
    @MainActor func linuxDevboxStaleAccountStateCannotOverwriteFresherLocalQuota() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)

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

        _ = manager.applyLinuxDevboxAccountStates([
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

        #expect(manager.configuredAccount == nil)
        #expect(manager.accounts.first?.quotaSnapshot?.fetchedAt == freshSnapshot.fetchedAt)
        #expect(manager.accounts.first?.quotaSnapshot?.fiveHour?.remainingPercent == 95)
        #expect(manager.accounts.first?.quotaSnapshot?.weekly?.remainingPercent == 99)
        #expect(manager.accounts.first?.lastRefreshed == freshSnapshot.fetchedAt)
        #expect(manager.linuxDevboxAccountStates.first?.quotaSnapshot == staleSnapshot)
    }

    @Test("Linux devbox placeholder quota cannot overwrite real local quota")
    @MainActor func linuxDevboxPlaceholderQuotaCannotOverwriteRealLocalQuota() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
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

        let result = manager.applyLinuxDevboxAccountStates([
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

        #expect(manager.configuredAccount?.quotaSnapshot?.fetchedAt == realSnapshot.fetchedAt)
        #expect(manager.configuredAccount?.quotaSnapshot?.fiveHour?.remainingPercent == 77)
        #expect(manager.configuredAccount?.quotaSnapshot?.weekly?.remainingPercent == 88)
        #expect(manager.configuredAccount?.lastRefreshed == realSnapshot.fetchedAt)
        #expect(result.stateChanged)
        #expect(manager.linuxDevboxAccountStates.first?.quotaSnapshot == placeholderSnapshot)
    }

    @Test("Linux devbox placeholder quota does not clear local placeholder diagnostics")
    @MainActor func linuxDevboxPlaceholderQuotaDoesNotMutateLocalPlaceholder() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
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

        _ = manager.applyLinuxDevboxAccountStates([
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

        #expect(manager.configuredAccount?.quotaSnapshot == placeholderSnapshot)
        #expect(manager.configuredAccount?.lastRefreshed == fetchedAt)
        #expect(manager.configuredAccount?.planType == "pro")
        #expect(manager.linuxDevboxAccountStates.first?.quotaSnapshot == placeholderSnapshot)
    }

    @Test("Linux devbox no-op state does not report changes")
    @MainActor func linuxDevboxNoOpStateDoesNotReportChanges() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
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

        let state = LinuxDevboxAccountState(
                email: "apps7349@gmail.com",
                isActive: true,
                quotaSnapshot: snapshot,
                planType: "plus",
                lastRefreshed: snapshot.fetchedAt,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: nil,
                subscriptionWillRenew: nil,
                hasActiveSubscription: true
            )
        _ = manager.applyLinuxDevboxAccountStates([state])
        let result = manager.applyLinuxDevboxAccountStates([state])

        #expect(result == LinuxDevboxAccountApplyResult(stateChanged: false))
    }

    @Test("Linux devbox runtime auth block remains presentation-only")
    @MainActor func linuxDevboxRuntimeAuthBlockDoesNotBlockMacAccount() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
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
        let result = manager.applyLinuxDevboxAccountStates([
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
        #expect(updated?.requiresReauthentication == false)
        #expect(updated?.realQuotaSnapshot == staleSnapshot)
        #expect(manager.pollingErrors[account.id] == nil)
        #expect(manager.linuxDevboxAccountStates.first?.runtimeUnusableUntil == blockedUntil)
        #expect(manager.linuxDevboxAccountStates.first?.runtimeUnusableReason == "token_expired")
    }

    @Test("Restore prefers auth.json over stale stored preference")
    @MainActor func restorePrefersAuthJsonOverStaleStoredPreference() async {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)

        let current = CodexAccount(email: "current@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc-current")
        let target = CodexAccount(email: "target@test.com", accessToken: "t2", refreshToken: "r2", idToken: "i2", accountId: "acc-target")
        manager.addAccount(current)
        manager.addAccount(target)
        defaults.set(current.id.uuidString, forKey: "activeAccountId")

        manager.restoreConfiguredAccount(observedProviderAccountId: target.accountId)

        #expect(manager.configuredAccount?.id == target.id)
        #expect(defaults.string(forKey: "activeAccountId") == target.id.uuidString)
    }

    @Test("Restore ignores stale defaults when no durable configured record exists")
    @MainActor func restoreRejectsStaleStoredPreference() async {
        let defaults = isolatedDefaults()
        let current = CodexAccount(email: "current@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc-current")
        let manager = AccountManager(userDefaults: defaults)

        manager.addAccount(current)
        defaults.set(current.id.uuidString, forKey: "activeAccountId")

        let recovery = manager.restoreConfiguredAccount(observedProviderAccountId: nil)

        #expect(recovery == .ambiguous)
        #expect(manager.configuredAccount == nil)
        #expect(defaults.string(forKey: "activeAccountId") == nil)
    }

    @Test("Restore preserves the durable selected account without writing auth")
    @MainActor func restorePreservesDurableSelection() async {
        let defaults = isolatedDefaults()
        let original = CodexAccount(
            email: "original@test.com",
            accessToken: "t1",
            refreshToken: "r1",
            idToken: "i1",
            accountId: "acc-original",
            isActive: true
        )
        let fallback = CodexAccount(
            email: "fallback@test.com",
            accessToken: "t2",
            refreshToken: "r2",
            idToken: "i2",
            accountId: "acc-fallback"
        )
        let manager = AccountManager(userDefaults: defaults)
        #expect(manager.restorePersistedAccounts([original, fallback]))
        defaults.set(fallback.id.uuidString, forKey: "activeAccountId")

        let recovery = manager.restoreConfiguredAccount(observedProviderAccountId: nil)

        #expect(recovery == .recovered(original.id))
        #expect(manager.configuredAccount?.id == original.id)
        #expect(defaults.string(forKey: "activeAccountId") == original.id.uuidString)
        #expect(manager.pollingErrors[fallback.id] == nil)
    }

    @Test("Restart recovery fails closed when durable selection is ambiguous")
    @MainActor func restoreRejectsMultipleDurableSelections() {
        let defaults = isolatedDefaults()
        let first = CodexAccount(
            email: "first@test.com",
            accessToken: "t1",
            refreshToken: "r1",
            idToken: "i1",
            accountId: "acc-first",
            isActive: true
        )
        let second = CodexAccount(
            email: "second@test.com",
            accessToken: "t2",
            refreshToken: "r2",
            idToken: "i2",
            accountId: "acc-second",
            isActive: true
        )
        let manager = AccountManager(userDefaults: defaults)
        #expect(manager.restorePersistedAccounts([first, second]))

        let recovery = manager.restoreConfiguredAccount(observedProviderAccountId: nil)

        #expect(recovery == .ambiguous)
        #expect(manager.configuredAccount == nil)
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
                usedPercent: 1,
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
                usedPercent: 1,
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

    @Test("Weekly-only quota clears legacy five-hour presentation state")
    @MainActor func weeklyOnlyQuotaClearsLegacyFiveHourMarker() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        let fetchedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let account = CodexAccount(
            email: "weekly-only@test.com",
            accessToken: "t1",
            refreshToken: "r1",
            idToken: "i1",
            accountId: "acc-weekly-only",
            fiveHourPrimedAt: fetchedAt.addingTimeInterval(-60)
        )
        let snapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: fetchedAt,
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 604_800,
                    usedPercent: 20,
                    resetsAt: fetchedAt.addingTimeInterval(604_800),
                    source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                ),
            ]
        )

        manager.addAccount(account)
        manager.updateQuota(for: account.id, snapshot: snapshot, planType: "plus")

        #expect(manager.accounts.first?.fiveHourPrimedAt == nil)
        #expect(manager.accounts.first?.quotaSnapshot?.fiveHour == nil)
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

    @Test("Inactive imported credentials refresh an existing account")
    @MainActor func inactiveImportedCredentialsRefreshStoredTokens() {
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

        let result = manager.upsertInactiveAccount(imported)

        #expect(result == .updated(existing.id))
        #expect(manager.accounts.first?.accessToken == "new-access")
        #expect(manager.accounts.first?.refreshToken == "new-refresh")
        #expect(manager.pollingErrors[existing.id] == nil)
    }

    @Test("Inactive imported credentials clear a stored reauthentication block")
    @MainActor func inactiveImportedCredentialsClearStoredReauthenticationBlock() {
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

        let result = manager.upsertInactiveAccount(imported)

        let updated = manager.accounts.first
        #expect(result == .updated(existing.id))
        #expect(updated?.runtimeUnusableUntil == nil)
        #expect(updated?.runtimeUnusableReason == nil)
        #expect(updated?.requiresReauthentication == false)
        #expect(updated?.lastRefreshed == imported.lastRefreshed)
        #expect(manager.pollingErrors[existing.id] == nil)
    }

    @Test("VPS auth observations never overwrite local runtime state")
    @MainActor func vpsAuthObservationDoesNotOverwriteLocalRuntimeState() {
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

        let result = manager.applyLinuxDevboxAccountStates([
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
        #expect(result.stateChanged)
        #expect(updated?.runtimeUnusableUntil == nil)
        #expect(updated?.runtimeUnusableReason == nil)
        #expect(updated?.requiresReauthentication == false)
        #expect(manager.pollingErrors[account.id] == nil)
        #expect(manager.linuxDevboxAccountStates.first?.runtimeUnusableReason == "token_expired")
    }

    @Test("Inactive imported credentials clear expired exhausted quota snapshot")
    @MainActor func inactiveImportedCredentialsClearExpiredExhaustedQuotaSnapshot() {
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

        let result = manager.upsertInactiveAccount(imported)

        #expect(result == .updated(existing.id))
        #expect(manager.accounts.first?.quotaSnapshot == nil)
    }

    @Test("Same email with a different provider identity inserts a separate inactive account")
    @MainActor func inactiveImportedCredentialsDoNotMatchByEmailAlone() {
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

        let result = manager.upsertInactiveAccount(imported)

        #expect(result == .inserted(imported.id))
        #expect(manager.accounts.count == 2)
        #expect(manager.accounts.first?.accountId == "old-account-id")
        #expect(manager.accounts.first?.accessToken == "old-access")
        #expect(manager.accounts.last?.accountId == "new-account-id")
        #expect(manager.accounts.last?.isActive == false)
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
