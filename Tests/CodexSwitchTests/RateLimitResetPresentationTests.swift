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
        ) == "Last-known: 2 banked resets")
        #expect(AccountCardView.rateLimitResetText(
            for: .error(message: "Inventory unavailable", lastKnownCount: 2)
        ) == "Reset error: Inventory unavailable • last-known: 2 banked resets")
        #expect(AccountCardView.rateLimitResetText(for: .redeeming) == "Redeeming banked reset")
        #expect(AccountCardView.rateLimitResetText(for: .reconciling) == "Reconciling reset inventory")
        #expect(AccountCardView.rateLimitResetText(for: .refreshing) == "Refreshing reset inventory")
        #expect(AccountCardView.rateLimitResetText(
            for: .externalHold(until: now),
            holdUntilText: "4:30 PM"
        ) == "Reset hold until 4:30 PM")
    }

    @Test("Pooled label reports one current total and compact uncertainty counts")
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
        ) == "5 current resets • next expires Jul 14 • 2 pending • 1 stale")
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

    private func resolve(
        expiration: Date? = nil,
        redeeming: Bool = false,
        reconciling: Bool = false,
        error: String? = nil,
        holdUntil: Date? = nil,
        refreshing: Bool = false,
        fresh: Bool
    ) -> RateLimitResetInventoryPresentation {
        RateLimitResetInventoryPresentation.resolve(
            availableCount: 4,
            nextExpiration: expiration,
            inventoryIsFresh: fresh,
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
        providerAccountId: String
    ) -> CodexAccount {
        CodexAccount(
            email: email,
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: providerAccountId
        )
    }
}
