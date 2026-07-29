import Foundation
import Testing
@testable import CodexSwitch

@Suite("Rate-limit reset presentation")
struct RateLimitResetPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Account state priority preserves operations over inventory")
    func accountStatePriority() {
        let holdUntil = now.addingTimeInterval(900)
        let expiration = now.addingTimeInterval(86_400)

        #expect(resolve(
            expiration: expiration,
            redeeming: true,
            reconciling: true,
            error: "inventory failed",
            holdUntil: holdUntil,
            refreshing: true,
            fresh: false
        ) == .redeeming)
        #expect(resolve(
            expiration: expiration,
            reconciling: true,
            error: "inventory failed",
            holdUntil: holdUntil,
            refreshing: true,
            fresh: false
        ) == .reconciling)
        #expect(resolve(
            expiration: expiration,
            error: "inventory failed",
            holdUntil: holdUntil,
            refreshing: true,
            fresh: true
        ) == .error(message: "inventory failed", lastKnownCount: 4))
        #expect(resolve(
            expiration: expiration,
            holdUntil: holdUntil,
            refreshing: true,
            fresh: false
        ) == .externalHold(until: holdUntil))
        #expect(resolve(
            expiration: expiration,
            refreshing: true,
            fresh: false
        ) == .refreshing)
        #expect(resolve(
            expiration: expiration,
            fresh: false
        ) == .stale(lastKnownCount: 4))
        #expect(resolve(
            expiration: expiration,
            fresh: false,
            exists: false
        ) == .unknown(lastKnownCount: 4))
        #expect(resolve(
            expiration: expiration,
            fresh: false,
            hasExpiredAvailableCredit: true
        ) == .expired(lastKnownCount: 4))
        #expect(resolve(
            expiration: expiration,
            fresh: true,
            structurallyValid: false
        ) == .unknown(lastKnownCount: 4))
        #expect(resolve(
            expiration: expiration,
            fresh: true
        ) == .current(availableCount: 4, nextExpiration: expiration))
    }

    @Test("Expired holds yield to the next applicable state")
    func expiredHoldDoesNotMaskInventory() {
        #expect(resolve(
            holdUntil: now.addingTimeInterval(-1),
            refreshing: true,
            fresh: true
        ) == .refreshing)
    }

    @Test("Pooled inventory excludes stale and pending account counts")
    func pooledInventoryUsesOnlyCurrentCounts() {
        let earlyExpiration = now.addingTimeInterval(3_600)
        let lateExpiration = now.addingTimeInterval(7_200)
        let summary = PooledRateLimitResetPresentation.summarize([
            .current(availableCount: 2, nextExpiration: lateExpiration),
            .stale(lastKnownCount: 40),
            .refreshing,
            .externalHold(until: now.addingTimeInterval(900)),
            .error(message: "offline", lastKnownCount: 50),
            .current(availableCount: 3, nextExpiration: earlyExpiration),
        ])

        #expect(summary.currentAvailableCount == 5)
        #expect(summary.nextCurrentExpiration == earlyExpiration)
        #expect(summary.pendingAccountCount == 2)
        #expect(summary.staleAccountCount == 2)
        #expect(summary.hasIncompleteInventory)
    }

    @Test("Verified counts carry fetched-at freshness and stale data fails closed")
    func verifiedCountsRequireFreshMatchingBank() {
        let fetchedAt = now.addingTimeInterval(-30)
        let expiration = now.addingTimeInterval(86_400)
        let bank = makeBank(fetchedAt: fetchedAt, expirations: [expiration])

        let current = RateLimitResetInventoryObservation.resolve(
            presentation: .current(availableCount: 1, nextExpiration: expiration),
            bank: bank,
            now: now
        )
        #expect(current.freshness == .current)
        #expect(current.verifiedCount == VerifiedRateLimitResetCount(
            availableCount: 1,
            fetchedAt: fetchedAt
        ))
        #expect(current.freshness.authorizesCount)

        let stale = RateLimitResetInventoryObservation.resolve(
            presentation: .current(availableCount: 1, nextExpiration: expiration),
            bank: makeBank(
                fetchedAt: now.addingTimeInterval(
                    -RateLimitResetInventoryObservation.presentationMaximumAge - 1
                ),
                expirations: [expiration]
            ),
            now: now
        )
        #expect(stale.freshness == .stale)
        #expect(stale.verifiedCount == nil)
        #expect(!stale.freshness.authorizesCount)
    }

    @Test("Unknown, expired, stale, and refresh-failed inventories stay distinct")
    func nonCurrentInventoryStatesAreDistinct() {
        let expiredBank = makeBank(
            fetchedAt: now.addingTimeInterval(-30),
            expirations: [now.addingTimeInterval(-1)]
        )
        let staleBank = makeBank(
            fetchedAt: now.addingTimeInterval(-600),
            expirations: [now.addingTimeInterval(86_400)]
        )

        let unknown = RateLimitResetInventoryObservation.resolve(
            presentation: nil,
            bank: nil,
            now: now
        )
        let expired = RateLimitResetInventoryObservation.resolve(
            presentation: .stale(lastKnownCount: 1),
            bank: expiredBank,
            now: now
        )
        let stale = RateLimitResetInventoryObservation.resolve(
            presentation: .stale(lastKnownCount: 1),
            bank: staleBank,
            now: now
        )
        let failed = RateLimitResetInventoryObservation.resolve(
            presentation: .error(
                message: "Reset inventory request failed (HTTP 429)",
                lastKnownCount: 1
            ),
            bank: staleBank,
            now: now
        )
        let manualFailure = RateLimitResetInventoryObservation.resolve(
            presentation: .error(
                message: "This account still has usable quota",
                lastKnownCount: 1
            ),
            bank: staleBank,
            now: now
        )

        #expect(unknown.freshness == .unknown)
        #expect(expired.freshness == .expired)
        #expect(stale.freshness == .stale)
        #expect(failed.freshness == .refreshFailed)
        #expect(manualFailure.freshness == .pending)
        #expect(failed.failureMessage == "Reset inventory request failed (HTTP 429)")
        #expect([unknown, expired, stale, failed].allSatisfy { $0.verifiedCount == nil })
    }

    @Test("Pooled reset total includes only timestamped verified counts")
    func pooledInventorySummarizesFreshnessStates() {
        let expiration = now.addingTimeInterval(86_400)
        let currentFetchedAt = now.addingTimeInterval(-30)
        var current = makeAccount(email: "current@example.com", providerAccountId: "current")
        current.rateLimitResetBank = makeBank(
            fetchedAt: currentFetchedAt,
            expirations: [expiration]
        )
        var stale = makeAccount(email: "stale@example.com", providerAccountId: "stale")
        stale.rateLimitResetBank = makeBank(
            fetchedAt: now.addingTimeInterval(-600),
            expirations: [expiration]
        )
        var expired = makeAccount(email: "expired@example.com", providerAccountId: "expired")
        expired.rateLimitResetBank = makeBank(
            fetchedAt: now.addingTimeInterval(-30),
            expirations: [now.addingTimeInterval(-1)]
        )
        let failed = makeAccount(email: "failed@example.com", providerAccountId: "failed")
        let unknown = makeAccount(email: "unknown@example.com", providerAccountId: "unknown")

        let summary = PooledRateLimitResetPresentation.summarize(
            accounts: [current, stale, expired, failed, unknown],
            presentations: [
                current.id: .current(availableCount: 1, nextExpiration: expiration),
                stale.id: .stale(lastKnownCount: 1),
                expired.id: .stale(lastKnownCount: 1),
                failed.id: .error(
                    message: "Reset inventory transport failed: offline",
                    lastKnownCount: 2
                ),
            ],
            now: now
        )

        #expect(summary.currentAvailableCount == 1)
        #expect(summary.currentCountFetchedAt == currentFetchedAt)
        #expect(summary.nextCurrentExpiration == expiration)
        #expect(summary.staleAccountCount == 1)
        #expect(summary.expiredAccountCount == 1)
        #expect(summary.refreshFailedAccountCount == 1)
        #expect(summary.unknownAccountCount == 1)
        #expect(summary.hasIncompleteInventory)
    }

    @Test("Expiration urgency uses exact inclusive boundaries")
    func expirationUrgencyBoundaries() {
        #expect(RateLimitResetExpirationUrgency.resolve(
            expiration: now.addingTimeInterval(7 * 86_400 + 1),
            now: now
        ) == .normal)
        #expect(RateLimitResetExpirationUrgency.resolve(
            expiration: now.addingTimeInterval(7 * 86_400),
            now: now
        ) == .advisory)
        #expect(RateLimitResetExpirationUrgency.resolve(
            expiration: now.addingTimeInterval(72 * 3_600 + 1),
            now: now
        ) == .advisory)
        #expect(RateLimitResetExpirationUrgency.resolve(
            expiration: now.addingTimeInterval(72 * 3_600),
            now: now
        ) == .urgent)
        #expect(RateLimitResetExpirationUrgency.resolve(
            expiration: now.addingTimeInterval(24 * 3_600 + 1),
            now: now
        ) == .urgent)
        #expect(RateLimitResetExpirationUrgency.resolve(
            expiration: now.addingTimeInterval(24 * 3_600),
            now: now
        ) == .critical)
    }

    @Test("Critical pulses faster and Reduce Motion holds opacity stable")
    func pulseBehavior() throws {
        let urgentPeriod = try #require(RateLimitResetExpirationUrgency.urgent.pulsePeriod)
        let criticalPeriod = try #require(RateLimitResetExpirationUrgency.critical.pulsePeriod)

        #expect(RateLimitResetExpirationUrgency.normal.pulsePeriod == nil)
        #expect(RateLimitResetExpirationUrgency.advisory.pulsePeriod == nil)
        #expect(criticalPeriod < urgentPeriod)
        #expect(RateLimitResetExpirationUrgency.urgent.pulseOpacity(
            at: Date(timeIntervalSinceReferenceDate: urgentPeriod / 2),
            reduceMotion: false
        ) == 0.65)
        #expect(RateLimitResetExpirationUrgency.urgent.pulseOpacity(
            at: Date(timeIntervalSinceReferenceDate: urgentPeriod / 2),
            reduceMotion: true
        ) == 1)
    }

    @Test("Overview sorts expirations by exact time and account, then errors")
    func overviewSortingAndErrors() throws {
        let early = now.addingTimeInterval(3_600)
        let late = now.addingTimeInterval(7_200)
        let accountB = makeAccount(email: "b@example.com", providerAccountId: "provider-b")
        let accountA = makeAccount(email: "a@example.com", providerAccountId: "provider-a")
        let lateAccount = makeAccount(email: "late@example.com", providerAccountId: "provider-c")
        let errorAccount = makeAccount(email: "error@example.com", providerAccountId: "provider-d")

        let items = RateLimitResetOverviewItem.make(
            accounts: [accountB, errorAccount, lateAccount, accountA],
            presentations: [
                accountB.id: .current(availableCount: 2, nextExpiration: early),
                accountA.id: .current(availableCount: 1, nextExpiration: early),
                lateAccount.id: .current(availableCount: 3, nextExpiration: late),
                errorAccount.id: .error(message: "inventory unavailable", lastKnownCount: 4),
            ],
            now: now
        )

        #expect(items.map(\.id) == [accountA.id, accountB.id, lateAccount.id, errorAccount.id])
        let errorItem = try #require(items.last)
        #expect(errorItem.isError)
        #expect(errorItem.errorMessage == "inventory unavailable")
        #expect(errorItem.availableCount == 4)
    }

    @Test("Card labels distinguish current, last-known, and pending inventory")
    @MainActor
    func accountCardLabels() {
        #expect(AccountCardView.rateLimitResetText(
            for: .current(availableCount: 2, nextExpiration: now),
            nextExpirationText: "Jul 14"
        ) == "2 banked resets • next expires Jul 14")
        #expect(AccountCardView.rateLimitResetText(
            for: .stale(lastKnownCount: 2)
        ) == "Last-known/unverified: 2 banked resets")
        #expect(AccountCardView.rateLimitResetText(
            for: .expired(lastKnownCount: 2)
        ) == "Expired/unavailable: 2 banked resets")
        #expect(AccountCardView.rateLimitResetText(
            for: .unknown(lastKnownCount: 0)
        ) == "Reset inventory not verified")
        #expect(AccountCardView.rateLimitResetText(
            for: .error(message: "Inventory unavailable", lastKnownCount: 2)
        ) == "Reset error: Inventory unavailable • last-known/unverified: 2 banked resets")
        #expect(AccountCardView.rateLimitResetText(for: .redeeming) == "Redeeming banked reset")
        #expect(AccountCardView.rateLimitResetText(for: .reconciling) == "Reconciling reset inventory")
        #expect(AccountCardView.rateLimitResetText(for: .refreshing) == "Refreshing reset inventory")
        #expect(AccountCardView.rateLimitResetText(
            for: .externalHold(until: now),
            holdUntilText: "4:30 PM"
        ) == "Reset hold until 4:30 PM")
    }

    @Test("Pooled label marks stale inventory as last-known and unverified")
    @MainActor
    func pooledLabel() {
        let summary = PooledRateLimitResetPresentation(
            currentAvailableCount: 5,
            nextCurrentExpiration: now,
            pendingAccountCount: 2,
            staleAccountCount: 1
        )

        #expect(PooledUsageMeterView.rateLimitResetStatusText(
            for: summary,
            nextExpirationText: "Jul 14"
        ) == "5 verified resets • next expires Jul 14 • 2 pending • 1 last-known/unverified")
    }

    @Test("Pooled labels expose every non-current reset state")
    @MainActor
    func pooledFreshnessLabel() {
        let summary = PooledRateLimitResetPresentation(
            currentAvailableCount: 1,
            nextCurrentExpiration: now.addingTimeInterval(86_400),
            pendingAccountCount: 1,
            staleAccountCount: 2,
            expiredAccountCount: 3,
            refreshFailedAccountCount: 4,
            unknownAccountCount: 5,
            currentCountFetchedAt: now.addingTimeInterval(-120)
        )

        #expect(PooledUsageMeterView.rateLimitResetStatusText(
            for: summary,
            nextExpirationText: "Jul 14",
            fetchedAtText: "2m ago"
        ) == "1 verified reset • next expires Jul 14 • checked 2m ago • 1 pending • 2 last-known/unverified • 3 expired • 4 refresh failed • 5 not checked")
    }

    @Test("Settings exposes routing order and reset freshness without account-card warnings")
    @MainActor
    func settingsRoutingAndResetStatus() {
        var pro = makeAccount(
            email: "pro@example.com",
            providerAccountId: "pro",
            planType: "pro"
        )
        let plus = makeAccount(
            email: "plus@example.com",
            providerAccountId: "plus",
            planType: "plus"
        )
        let free = makeAccount(
            email: "free@example.com",
            providerAccountId: "free",
            planType: "free"
        )
        let expiration = now.addingTimeInterval(86_400)
        pro.rateLimitResetBank = makeBank(fetchedAt: now, expirations: [expiration])

        #expect(PooledUsageMeterView.routingTierStatusText(
            for: [free, plus, pro]
        ) == "Routing: 1 Pro > 1 Plus > 1 Free (last resort)")
        #expect(SettingsView.resetInventoryStatusText(
            accounts: [pro, plus, free],
            presentations: [
                pro.id: .current(availableCount: 1, nextExpiration: expiration),
            ],
            now: now
        ) == "1 verified reset • checked just now • 2 not checked")
    }

    @Test("Automatic redemption defaults on while preserving explicit false")
    func automaticRedemptionDefault() throws {
        let suiteName = "RateLimitResetPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        #expect(RateLimitResetSettings.automaticRedemptionEnabled(in: defaults))
        defaults.set(false, forKey: RateLimitResetSettings.automaticRedemptionDefaultsKey)
        #expect(!RateLimitResetSettings.automaticRedemptionEnabled(in: defaults))
        defaults.set(true, forKey: RateLimitResetSettings.automaticRedemptionDefaultsKey)
        #expect(RateLimitResetSettings.automaticRedemptionEnabled(in: defaults))
    }

    @Test("Settings uses VPS policy instead of local preference when remote is configured")
    @MainActor
    func settingsUsesAuthoritativeVPSAutomaticResetPolicy() {
        let remoteSettings = LinuxDevboxMonitorSettings(
            enabled: false,
            host: "authority.example.test",
            user: "codex",
            sshKeyPath: "~/.ssh/id_ed25519",
            port: 22
        )
        let remoteDisabled = LinuxDevboxAutomaticResetPolicyObservation(
            schemaVersion: 1,
            automaticRateLimitResetRedemption: false,
            state: .configured,
            authority: "vps"
        )

        #expect(!SettingsView.automaticResetPolicyToggleValue(
            localPreference: true,
            settings: remoteSettings,
            remoteObservation: remoteDisabled
        ))
        #expect(!SettingsView.automaticResetPolicyToggleValue(
            localPreference: true,
            settings: remoteSettings,
            remoteObservation: nil
        ))
        #expect(!SettingsView.automaticResetPolicyToggleAllowsMutation(
            settings: remoteSettings,
            remoteObservation: nil,
            isBusy: false
        ))
        #expect(SettingsView.automaticResetPolicyToggleAllowsMutation(
            settings: remoteSettings,
            remoteObservation: remoteDisabled,
            isBusy: false
        ))

        let standaloneSettings = LinuxDevboxMonitorSettings(
            enabled: false,
            host: "",
            user: "",
            sshKeyPath: "",
            port: 22,
            resetAuthorityMode: .macStandalone
        )
        #expect(SettingsView.automaticResetPolicyToggleValue(
            localPreference: true,
            settings: standaloneSettings,
            remoteObservation: nil
        ))

        let corruptedVPSEndpoint = LinuxDevboxMonitorSettings(
            enabled: false,
            host: " invalid host ",
            user: "codex",
            sshKeyPath: "~/.ssh/id_ed25519",
            port: 22,
            resetAuthorityMode: .vpsAuthority
        )
        #expect(!SettingsView.automaticResetPolicyToggleValue(
            localPreference: true,
            settings: corruptedVPSEndpoint,
            remoteObservation: nil
        ))
        #expect(!SettingsView.automaticResetPolicyToggleAllowsMutation(
            settings: corruptedVPSEndpoint,
            remoteObservation: nil,
            isBusy: false
        ))
    }

    @Test("Settings fallback distinguishes missing and expired reset inventory")
    @MainActor
    func settingsFallbackDistinguishesMissingAndExpiredInventory() {
        let missing = makeAccount(
            email: "missing@example.com",
            providerAccountId: "missing",
            planType: "pro"
        )
        var expired = makeAccount(
            email: "expired@example.com",
            providerAccountId: "expired",
            planType: "pro"
        )
        expired.rateLimitResetBank = RateLimitResetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [RateLimitResetCredit(
                id: "expired-credit",
                resetType: nil,
                status: "available",
                grantedAt: now.addingTimeInterval(-7_200),
                expiresAt: now.addingTimeInterval(-60),
                redeemedAt: nil,
                title: nil,
                description: nil
            )],
            fetchedAt: now
        )

        #expect(SettingsView.resetInventoryStatusText(
            accounts: [missing],
            presentations: [:],
            now: now
        ) == "0 verified resets • 1 not checked")
        #expect(SettingsView.resetInventoryStatusText(
            accounts: [expired],
            presentations: [:],
            now: now
        ) == "0 verified resets • 1 expired")
    }

    @Test("Coordinator authorization exposes every global blocker before confirmation")
    func coordinatorAuthorizationIsHonest() {
        #expect(RateLimitResetCoordinatorAuthorization.resolve(
            state: coordinatorState(externalHoldStateIsReadable: false),
            now: now
        ).unavailableReason == "Reset ownership state is unavailable; refresh and try again")
        #expect(RateLimitResetCoordinatorAuthorization.resolve(
            state: coordinatorState(redemptionIsInProgress: true),
            now: now
        ).unavailableReason == "Another reset redemption is already in progress")
        #expect(RateLimitResetCoordinatorAuthorization.resolve(
            state: coordinatorState(configuredAccountIsAvailable: false),
            now: now
        ).unavailableReason == "The active runtime is not ready; wait for account activation to finish")
        #expect(RateLimitResetCoordinatorAuthorization.resolve(
            state: coordinatorState(activationAllowsManualRedemption: false),
            now: now
        ).unavailableReason == "The active runtime is not ready; wait for account activation to finish")
        #expect(RateLimitResetCoordinatorAuthorization.resolve(
            state: coordinatorState(accountHasUnresolvedAttempt: true),
            now: now
        ).unavailableReason == "This account already has a reset awaiting reconciliation")
        #expect(RateLimitResetCoordinatorAuthorization.resolve(
            state: coordinatorState(externalHoldUntil: now.addingTimeInterval(60)),
            now: now
        ).unavailableReason == "Reset redemption is temporarily held while recent inventory changes settle")
        #expect(RateLimitResetCoordinatorAuthorization.resolve(
            state: coordinatorState(localHoldUntil: now.addingTimeInterval(60)),
            now: now
        ).unavailableReason == "Reset redemption is temporarily held while recent inventory changes settle")
        #expect(RateLimitResetCoordinatorAuthorization.resolve(
            state: coordinatorState(),
            now: now
        ) == .authorized)
    }

    @Test("Account context menu uses the guarded manual-redemption policy")
    func accountContextMenuRedemptionPolicy() {
        let expiration = now.addingTimeInterval(86_400)
        var pro = makeAccount(
            email: "pro@example.com",
            providerAccountId: "pro",
            planType: "pro"
        )
        pro.rateLimitResetBank = makeBank(fetchedAt: now, expirations: [expiration])
        pro.quotaSnapshot = exhaustedSnapshot(fetchedAt: now)

        let eligible = RateLimitResetContextMenuPresentation.resolve(
            account: pro,
            inventory: .current(availableCount: 1, nextExpiration: expiration),
            now: now
        )
        #expect(eligible.title == "Redeem banked reset for pro@example.com")
        #expect(eligible.isEnabled)
        #expect(eligible.unavailableReason == nil)

        let stale = RateLimitResetContextMenuPresentation.resolve(
            account: pro,
            inventory: .stale(lastKnownCount: 1),
            now: now
        )
        #expect(!stale.isEnabled)
        #expect(
            stale.unavailableReason
                == "Reset inventory is last-known and unverified; refresh it before redeeming"
        )
        #expect(
            stale.menuItemTitle
                == "Redeem banked reset for pro@example.com - Reset inventory is last-known and unverified; refresh it before redeeming"
        )

        let refreshFailed = RateLimitResetContextMenuPresentation.resolve(
            account: pro,
            inventory: .error(message: "HTTP 429", lastKnownCount: 1),
            now: now
        )
        #expect(!refreshFailed.isEnabled)
        #expect(
            refreshFailed.unavailableReason
                == "Reset inventory is unverified because refresh failed; refresh it before redeeming: HTTP 429"
        )

        let expired = RateLimitResetContextMenuPresentation.resolve(
            account: pro,
            inventory: .expired(lastKnownCount: 1),
            now: now
        )
        #expect(!expired.isEnabled)
        #expect(
            expired.unavailableReason
                == "Banked reset inventory has expired; refresh it before redeeming"
        )

        let unknown = RateLimitResetContextMenuPresentation.resolve(
            account: pro,
            inventory: .unknown(lastKnownCount: 1),
            now: now
        )
        #expect(!unknown.isEnabled)
        #expect(
            unknown.unavailableReason
                == "Reset inventory has not been verified; refresh it before redeeming"
        )

        var expiredCredentials = pro
        expiredCredentials.accessToken = testInferenceToken(
            expiresAt: now.addingTimeInterval(300)
        )
        let expiredCredentialAction = RateLimitResetContextMenuPresentation.resolve(
            account: expiredCredentials,
            inventory: .current(availableCount: 1, nextExpiration: expiration),
            now: now
        )
        #expect(!expiredCredentialAction.isEnabled)
        #expect(
            expiredCredentialAction.unavailableReason
                == "Refresh this account's credentials before redeeming a reset"
        )

        var staleBank = pro
        staleBank.rateLimitResetBank = makeBank(
            fetchedAt: now.addingTimeInterval(-61),
            expirations: [expiration]
        )
        let staleBehindCurrentLabel = RateLimitResetContextMenuPresentation.resolve(
            account: staleBank,
            inventory: .current(availableCount: 1, nextExpiration: expiration),
            now: now
        )
        #expect(!staleBehindCurrentLabel.isEnabled)
        #expect(
            staleBehindCurrentLabel.unavailableReason
                == "Reset inventory is last-known and unverified; refresh it before redeeming"
        )

        var free = makeAccount(
            email: "free@example.com",
            providerAccountId: "free",
            planType: "free"
        )
        free.rateLimitResetBank = makeBank(fetchedAt: now, expirations: [expiration])
        free.quotaSnapshot = exhaustedSnapshot(fetchedAt: now)
        let freePlan = RateLimitResetContextMenuPresentation.resolve(
            account: free,
            inventory: .current(availableCount: 1, nextExpiration: expiration),
            now: now
        )
        #expect(!freePlan.isEnabled)
        #expect(freePlan.unavailableReason == "Manual redemption is available only for paid accounts")
    }

    private func resolve(
        expiration: Date? = nil,
        redeeming: Bool = false,
        reconciling: Bool = false,
        error: String? = nil,
        holdUntil: Date? = nil,
        refreshing: Bool = false,
        fresh: Bool,
        exists: Bool = true,
        hasExpiredAvailableCredit: Bool = false,
        structurallyValid: Bool = true
    ) -> RateLimitResetInventoryPresentation {
        RateLimitResetInventoryPresentation.resolve(
            availableCount: 4,
            nextExpiration: expiration,
            inventoryIsFresh: fresh,
            inventoryExists: exists,
            inventoryHasExpiredAvailableCredit: hasExpiredAvailableCredit,
            inventoryIsStructurallyValid: structurallyValid,
            isRedeeming: redeeming,
            isReconciling: reconciling,
            error: error,
            externalHoldUntil: holdUntil,
            isRefreshing: refreshing,
            now: now
        )
    }

    private func coordinatorState(
        externalHoldStateIsReadable: Bool = true,
        redemptionIsInProgress: Bool = false,
        configuredAccountIsAvailable: Bool = true,
        activationAllowsManualRedemption: Bool = true,
        accountHasUnresolvedAttempt: Bool = false,
        externalHoldUntil: Date? = nil,
        localHoldUntil: Date? = nil
    ) -> RateLimitResetCoordinatorState {
        RateLimitResetCoordinatorState(
            externalHoldStateIsReadable: externalHoldStateIsReadable,
            redemptionIsInProgress: redemptionIsInProgress,
            configuredAccountIsAvailable: configuredAccountIsAvailable,
            activationAllowsManualRedemption: activationAllowsManualRedemption,
            accountHasUnresolvedAttempt: accountHasUnresolvedAttempt,
            externalHoldUntil: externalHoldUntil,
            localHoldUntil: localHoldUntil
        )
    }

    private func makeAccount(
        email: String,
        providerAccountId: String,
        planType: String? = nil
    ) -> CodexAccount {
        CodexAccount(
            email: email,
            accessToken: testInferenceToken(expiresAt: now.addingTimeInterval(3_600)),
            refreshToken: "refresh",
            idToken: "id",
            accountId: providerAccountId,
            planType: planType
        )
    }

    private func makeBank(
        fetchedAt: Date,
        expirations: [Date]
    ) -> RateLimitResetBank {
        RateLimitResetBank(
            availableCount: expirations.count,
            totalEarnedCount: expirations.count,
            credits: expirations.enumerated().map { index, expiration in
                RateLimitResetCredit(
                    id: "credit-\(index)",
                    resetType: "full",
                    status: "available",
                    grantedAt: fetchedAt,
                    expiresAt: expiration,
                    redeemedAt: nil,
                    title: nil,
                    description: nil
                )
            },
            fetchedAt: fetchedAt
        )
    }

    private func exhaustedSnapshot(fetchedAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            allowed: false,
            limitReached: true,
            fetchedAt: fetchedAt,
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 7 * 86_400,
                    usedPercent: 100,
                    resetsAt: fetchedAt.addingTimeInterval(3 * 86_400),
                    source: QuotaWindowSourceMetadata(
                        rateLimit: .main,
                        slot: .primary
                    )
                ),
            ]
        )
    }
}
