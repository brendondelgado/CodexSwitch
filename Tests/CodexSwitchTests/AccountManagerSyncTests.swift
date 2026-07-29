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

    @Test("Authoritative VPS telemetry projects without changing credentials or selection")
    @MainActor func authoritativeVPSTelemetryPreservesCredentialsAndSelection() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        let now = Date()
        let selected = CodexAccount(
            email: "selected@test.com",
            accessToken: "selected-access",
            refreshToken: "selected-refresh",
            idToken: "selected-id",
            accountId: "acc-selected",
            isActive: true
        )
        let target = CodexAccount(
            email: "local-target@test.com",
            accessToken: "target-access",
            refreshToken: "target-refresh",
            idToken: "target-id",
            accountId: "  PROVIDER-TARGET  "
        )
        manager.addAccount(selected)
        manager.addAccount(target)
        manager.setConfiguredAccount(selected.id)

        let quota = quotaSnapshot(
            fiveHourRemaining: 44,
            weeklyRemaining: 31,
            fetchedAt: now.addingTimeInterval(-10)
        )
        let blockedUntil = now.addingTimeInterval(3_600)
        let resetBank = RateLimitResetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [
                RateLimitResetCredit(
                    id: "reset-one",
                    resetType: "usage",
                    status: "available",
                    grantedAt: now.addingTimeInterval(-60),
                    expiresAt: now.addingTimeInterval(86_400),
                    redeemedAt: nil,
                    title: nil,
                    description: nil
                ),
            ],
            fetchedAt: now.addingTimeInterval(-5)
        )
        let result = manager.applyLinuxDevboxAccountStates(
            [
                LinuxDevboxAccountState(
                    email: "remote-target@test.com",
                    providerAccountId: "provider-target",
                    isActive: true,
                    quotaSnapshot: quota,
                    planType: "pro",
                    lastRefreshed: quota.fetchedAt,
                    subscriptionRenewsAt: now.addingTimeInterval(86_400),
                    subscriptionExpiresAt: nil,
                    subscriptionWillRenew: true,
                    hasActiveSubscription: true,
                    rateLimitResetBank: resetBank,
                    runtimeUnusableUntil: blockedUntil,
                    runtimeUnusableReason: "usage_limit"
                ),
            ],
            observedAt: now
        )

        let projected = manager.accounts.first { $0.id == target.id }
        #expect(result.stateChanged)
        #expect(projected?.quotaSnapshot == quota)
        #expect(projected?.planType == "pro")
        #expect(projected?.rateLimitResetBank == resetBank)
        #expect(projected?.runtimeUnusableUntil == blockedUntil)
        #expect(projected?.runtimeUnusableReason == "usage_limit")
        #expect(projected?.id == target.id)
        #expect(projected?.email == target.email)
        #expect(projected?.accessToken == "target-access")
        #expect(projected?.refreshToken == "target-refresh")
        #expect(projected?.idToken == "target-id")
        #expect(projected?.isActive == false)
        #expect(manager.configuredAccount?.id == selected.id)
        #expect(defaults.string(forKey: "activeAccountId") == selected.id.uuidString)
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
                providerAccountId: "acc-brenchat",
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

    @Test("Duplicate canonical provider identity rejects the whole projection")
    @MainActor func duplicateProviderIdentityRejectsProjection() {
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let now = Date(timeIntervalSince1970: 1_777_200_000)
        let account = CodexAccount(
            email: "account@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "provider-one",
            planType: "plus"
        )
        manager.addAccount(account)
        let first = quotaSnapshot(
            fiveHourRemaining: 50,
            weeklyRemaining: 50,
            fetchedAt: now.addingTimeInterval(-10)
        )
        let second = quotaSnapshot(
            fiveHourRemaining: 1,
            weeklyRemaining: 1,
            fetchedAt: now.addingTimeInterval(-5)
        )

        let changed = manager.projectAuthoritativeLinuxDevboxTelemetry(
            from: [
                LinuxDevboxAccountState(
                    email: "first@test.com",
                    providerAccountId: " PROVIDER-ONE ",
                    isActive: true,
                    quotaSnapshot: first,
                    planType: "pro",
                    lastRefreshed: first.fetchedAt,
                    subscriptionRenewsAt: nil,
                    subscriptionExpiresAt: nil,
                    subscriptionWillRenew: true,
                    hasActiveSubscription: true
                ),
                LinuxDevboxAccountState(
                    email: "second@test.com",
                    providerAccountId: "provider-one",
                    isActive: false,
                    quotaSnapshot: second,
                    planType: "pro",
                    lastRefreshed: second.fetchedAt,
                    subscriptionRenewsAt: nil,
                    subscriptionExpiresAt: nil,
                    subscriptionWillRenew: true,
                    hasActiveSubscription: true
                ),
            ],
            observedAt: now,
            now: now
        )

        #expect(!changed)
        #expect(manager.accounts.first?.quotaSnapshot == nil)
        #expect(manager.accounts.first?.planType == "plus")
    }

    @Test("Future and malformed authoritative observations fail closed")
    @MainActor func futureAndMalformedAuthoritativeObservationsFailClosed() {
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let now = Date(timeIntervalSince1970: 1_777_200_000)
        let account = CodexAccount(
            email: "guarded@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "guarded-provider",
            planType: "plus"
        )
        manager.addAccount(account)
        let validQuota = quotaSnapshot(
            fiveHourRemaining: 70,
            weeklyRemaining: 80,
            fetchedAt: now
        )
        let malformedQuota = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: now,
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 7 * 24 * 60 * 60,
                    usedPercent: .nan,
                    resetsAt: now.addingTimeInterval(86_400),
                    source: QuotaWindowSourceMetadata(
                        rateLimit: .main,
                        slot: .primary
                    )
                ),
            ]
        )

        func state(with quota: QuotaSnapshot) -> LinuxDevboxAccountState {
            LinuxDevboxAccountState(
                email: "guarded@test.com",
                providerAccountId: "guarded-provider",
                isActive: false,
                quotaSnapshot: quota,
                planType: "pro",
                lastRefreshed: quota.fetchedAt,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: nil,
                subscriptionWillRenew: true,
                hasActiveSubscription: true
            )
        }

        #expect(!manager.projectAuthoritativeLinuxDevboxTelemetry(
            from: [state(with: validQuota)],
            observedAt: now.addingTimeInterval(1),
            now: now
        ))
        #expect(!manager.projectAuthoritativeLinuxDevboxTelemetry(
            from: [state(with: malformedQuota)],
            observedAt: now,
            now: now
        ))
        #expect(manager.accounts.first?.quotaSnapshot == nil)
        #expect(manager.accounts.first?.planType == "plus")
    }

    @Test("Weekly-only authoritative quota projects without inventing five-hour usage")
    @MainActor func weeklyOnlyAuthoritativeQuotaProjects() {
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let now = Date(timeIntervalSince1970: 1_777_200_000)
        let account = CodexAccount(
            email: "weekly@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "weekly-provider"
        )
        manager.addAccount(account)
        let weeklyOnly = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: now.addingTimeInterval(-5),
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 7 * 24 * 60 * 60,
                    usedPercent: 37,
                    resetsAt: now.addingTimeInterval(86_400),
                    source: QuotaWindowSourceMetadata(
                        rateLimit: .main,
                        slot: .primary
                    )
                ),
            ]
        )

        let changed = manager.projectAuthoritativeLinuxDevboxTelemetry(
            from: [
                LinuxDevboxAccountState(
                    email: "weekly@test.com",
                    providerAccountId: "WEEKLY-PROVIDER",
                    isActive: false,
                    quotaSnapshot: weeklyOnly,
                    planType: "pro",
                    lastRefreshed: weeklyOnly.fetchedAt,
                    subscriptionRenewsAt: nil,
                    subscriptionExpiresAt: nil,
                    subscriptionWillRenew: true,
                    hasActiveSubscription: true
                ),
            ],
            observedAt: now,
            now: now
        )

        #expect(changed)
        #expect(manager.accounts.first?.quotaSnapshot?.fiveHour == nil)
        #expect(manager.accounts.first?.quotaSnapshot?.weekly?.remainingPercent == 63)
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
        manager.setConfiguredAccount(account.id)

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
        manager.setConfiguredAccount(account.id)

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
        manager.setConfiguredAccount(account.id)

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

    @Test("Recovery discovers auth.json target without changing configured state")
    @MainActor func recoveryDiscoversAuthTargetWithoutMutation() async {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)

        let current = CodexAccount(email: "current@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc-current")
        let target = CodexAccount(email: "target@test.com", accessToken: "t2", refreshToken: "r2", idToken: "i2", accountId: "acc-target")
        manager.addAccount(current)
        manager.addAccount(target)
        defaults.set(current.id.uuidString, forKey: "activeAccountId")

        let recovery = AccountActivationRecoveryCoordinator.configuredAccountRecovery(
            accounts: manager.accounts,
            observedProviderAccountId: target.accountId
        )

        #expect(recovery == .recovered(target.id))
        #expect(manager.configuredAccount == nil)
        #expect(defaults.string(forKey: "activeAccountId") == current.id.uuidString)
    }

    @Test("Configured credential staging is pure until durable publication")
    func configuredCredentialStagingIsPure() {
        let source = CodexAccount(
            email: "source@test.com",
            accessToken: "source-access",
            refreshToken: "source-refresh",
            idToken: "source-id",
            accountId: "source-provider",
            isActive: true
        )
        let target = CodexAccount(
            email: "target@test.com",
            accessToken: "old-access",
            refreshToken: "old-refresh",
            idToken: "old-id",
            accountId: "target-provider"
        )
        var refreshedTarget = target
        refreshedTarget.accessToken = "new-access"
        refreshedTarget.refreshToken = "new-refresh"
        refreshedTarget.idToken = "new-id"
        let original = [source, target]
        let latestQuota = quotaSnapshot(
            fiveHourRemaining: 100,
            weeklyRemaining: 42
        )
        var latest = original
        latest[1].quotaSnapshot = latestQuota

        let staged = AccountManager.configuredCredentialSnapshot(
            from: latest,
            applying: refreshedTarget,
            at: Date(timeIntervalSince1970: 1_800_100_300)
        )

        #expect(original.filter(\.isActive).map(\.id) == [source.id])
        #expect(staged?.filter(\.isActive).map(\.id) == [target.id])
        #expect(staged?.first(where: { $0.id == target.id })?.accessToken
            == "new-access")
        #expect(staged?.first(where: { $0.id == target.id })?.refreshToken
            == "new-refresh")
        #expect(staged?.first(where: { $0.id == target.id })?.idToken == "new-id")
        #expect(staged?.first(where: { $0.id == target.id })?.quotaSnapshot
            == latestQuota)
    }

    @Test("Durable credential publication preserves telemetry updated during persistence")
    @MainActor func durableCredentialPublicationPreservesConcurrentTelemetry() throws {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        var source = CodexAccount(
            email: "source@test.com",
            accessToken: "source-access",
            refreshToken: "source-refresh",
            idToken: "source-id",
            accountId: "source-provider",
            isActive: true
        )
        var target = CodexAccount(
            email: "target@test.com",
            accessToken: "old-access",
            refreshToken: "old-refresh",
            idToken: "old-id",
            accountId: "target-provider"
        )
        let expected = [source, target]
        var refreshedTarget = target
        refreshedTarget.accessToken = "new-access"
        refreshedTarget.refreshToken = "new-refresh"
        refreshedTarget.idToken = "new-id"
        let persisted = try #require(
            AccountManager.configuredCredentialSnapshot(
                from: expected,
                applying: refreshedTarget
            )
        )

        let latestQuota = quotaSnapshot(
            fiveHourRemaining: 100,
            weeklyRemaining: 37
        )
        target.quotaSnapshot = latestQuota
        manager.accounts = [source, target]
        defaults.set(source.id.uuidString, forKey: "activeAccountId")

        #expect(manager.adoptVerifiedCommittedCredentialHandoff(
            persisted,
            expectedCredentialAuthority: expected,
            targetAccountId: target.id
        ))
        let publishedTarget = try #require(manager.configuredAccount)
        #expect(publishedTarget.id == target.id)
        #expect(publishedTarget.accessToken == "new-access")
        #expect(publishedTarget.refreshToken == "new-refresh")
        #expect(publishedTarget.idToken == "new-id")
        #expect(publishedTarget.quotaSnapshot == latestQuota)
        #expect(defaults.string(forKey: "activeAccountId") == target.id.uuidString)

        source.accessToken = "unexpected-concurrent-credential"
        manager.accounts = [source, target]
        let beforeRejected = manager.accounts
        #expect(!manager.adoptVerifiedCommittedCredentialHandoff(
            persisted,
            expectedCredentialAuthority: expected,
            targetAccountId: target.id
        ))
        #expect(manager.accounts.map(\.accessToken) == beforeRejected.map(\.accessToken))
        #expect(manager.accounts.map(\.isActive) == beforeRejected.map(\.isActive))

        let firstDefaults = isolatedDefaults()
        let firstManager = AccountManager(userDefaults: firstDefaults)
        var firstAccount = CodexAccount(
            email: "first@test.com",
            accessToken: "first-access",
            refreshToken: "first-refresh",
            idToken: "first-id",
            accountId: "first-provider"
        )
        firstAccount.isActive = true
        #expect(firstManager.adoptVerifiedCommittedCredentialHandoff(
            [firstAccount],
            expectedCredentialAuthority: [],
            targetAccountId: firstAccount.id
        ))
        #expect(firstManager.configuredAccount?.id == firstAccount.id)
        #expect(firstDefaults.string(forKey: "activeAccountId")
            == firstAccount.id.uuidString)
    }

    @Test("Recovery ignores stale defaults when no durable configured record exists")
    @MainActor func recoveryRejectsStaleStoredPreference() async {
        let defaults = isolatedDefaults()
        let current = CodexAccount(email: "current@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc-current")
        let manager = AccountManager(userDefaults: defaults)

        manager.addAccount(current)
        defaults.set(current.id.uuidString, forKey: "activeAccountId")

        let recovery = AccountActivationRecoveryCoordinator.configuredAccountRecovery(
            accounts: manager.accounts,
            observedProviderAccountId: nil
        )

        #expect(recovery == .ambiguous)
        #expect(manager.configuredAccount == nil)
        #expect(defaults.string(forKey: "activeAccountId") == current.id.uuidString)
    }

    @Test("Recovery reports the durable selection without rewriting defaults")
    @MainActor func recoveryReportsDurableSelectionWithoutMutation() async {
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

        let recovery = AccountActivationRecoveryCoordinator.configuredAccountRecovery(
            accounts: manager.accounts,
            observedProviderAccountId: nil
        )

        #expect(recovery == .recovered(original.id))
        #expect(manager.configuredAccount?.id == original.id)
        #expect(defaults.string(forKey: "activeAccountId") == fallback.id.uuidString)
        #expect(manager.pollingErrors[fallback.id] == nil)
    }

    @Test("Recovery fails closed without rewriting an ambiguous durable selection")
    @MainActor func recoveryRejectsMultipleDurableSelections() {
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

        let recovery = AccountActivationRecoveryCoordinator.configuredAccountRecovery(
            accounts: manager.accounts,
            observedProviderAccountId: nil
        )

        #expect(recovery == .ambiguous)
        #expect(manager.accounts.filter(\.isActive).map(\.id) == [first.id, second.id])
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

    @Test("An older poll callback cannot overwrite newer quota")
    @MainActor func olderQuotaUpdateIsIgnored() {
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let current = quotaSnapshot(
            fiveHourRemaining: 80,
            weeklyRemaining: 70,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let stale = quotaSnapshot(
            fiveHourRemaining: 1,
            weeklyRemaining: 2,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let account = CodexAccount(
            email: "current@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "provider-account",
            quotaSnapshot: current,
            planType: "pro"
        )
        manager.addAccount(account)

        manager.updateQuota(for: account.id, snapshot: stale, planType: "free")

        #expect(manager.accounts.first?.quotaSnapshot == current)
        #expect(manager.accounts.first?.planType == "pro")
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

    @Test("Sorted accounts do not treat a local active flag as pool authority")
    @MainActor func sortedAccountsIgnoreLocalActiveFlagWithoutAuthority() {
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
        manager.setConfiguredAccount(exhaustedPro.id)

        #expect(manager.sortedAccounts.first?.id == usablePlus.id)
        #expect(manager.sortedAccounts.dropFirst().first?.id == exhaustedPro.id)
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

    @Test("Verified external handoff replaces memory only for one exact active target")
    @MainActor func verifiedExternalHandoffAdoptsExactSnapshot() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        var source = CodexAccount(
            email: "source@example.com",
            accessToken: "source-access",
            refreshToken: "source-refresh",
            idToken: "source-id",
            accountId: "source-provider",
            isActive: true
        )
        var target = CodexAccount(
            email: "target@example.com",
            accessToken: "target-access",
            refreshToken: "target-refresh",
            idToken: "target-id",
            accountId: "target-provider"
        )
        manager.accounts = [source, target]
        defaults.set(source.id.uuidString, forKey: "activeAccountId")

        source.isActive = false
        target.isActive = true
        let externalSnapshot = [source, target]
        #expect(manager.adoptVerifiedExternalHandoff(
            externalSnapshot,
            targetAccountId: target.id
        ))
        #expect(manager.accounts.map(\.id) == externalSnapshot.map(\.id))
        #expect(manager.accounts.map(\.accountId) == externalSnapshot.map(\.accountId))
        #expect(manager.accounts.map(\.accessToken) == externalSnapshot.map(\.accessToken))
        #expect(manager.accounts.map(\.isActive) == [false, true])
        #expect(manager.configuredAccount?.id == target.id)
        #expect(defaults.string(forKey: "activeAccountId") == target.id.uuidString)

        var invalidSource = source
        invalidSource.isActive = true
        let beforeRejectedIds = manager.accounts.map(\.id)
        let beforeRejectedActiveFlags = manager.accounts.map(\.isActive)
        #expect(!manager.adoptVerifiedExternalHandoff(
            [invalidSource, target],
            targetAccountId: target.id
        ))
        #expect(manager.accounts.map(\.id) == beforeRejectedIds)
        #expect(manager.accounts.map(\.isActive) == beforeRejectedActiveFlags)
        #expect(defaults.string(forKey: "activeAccountId") == target.id.uuidString)
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
