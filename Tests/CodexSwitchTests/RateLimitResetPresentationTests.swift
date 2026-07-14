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
            holdUntil: holdUntil,
            refreshing: true,
            fresh: false
        ) == .redeeming)
        #expect(resolve(
            expiration: expiration,
            reconciling: true,
            holdUntil: holdUntil,
            refreshing: true,
            fresh: false
        ) == .reconciling)
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
            .current(availableCount: 3, nextExpiration: earlyExpiration),
        ])

        #expect(summary.currentAvailableCount == 5)
        #expect(summary.nextCurrentExpiration == earlyExpiration)
        #expect(summary.pendingAccountCount == 2)
        #expect(summary.staleAccountCount == 1)
        #expect(summary.hasIncompleteInventory)
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

    private func resolve(
        expiration: Date? = nil,
        redeeming: Bool = false,
        reconciling: Bool = false,
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
            externalHoldUntil: holdUntil,
            isRefreshing: refreshing,
            now: now
        )
    }
}
