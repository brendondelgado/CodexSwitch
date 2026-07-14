import Foundation
import Testing
@testable import CodexSwitch

@Suite("Quota freshness policy")
struct QuotaFreshnessPolicyTests {
    @Test("Quota freshness includes the maximum-age boundary only")
    func maximumAgeBoundary() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let boundary = snapshot(fetchedAt: now.addingTimeInterval(
            -QuotaFreshnessPolicy.maximumSnapshotAge
        ))
        let stale = snapshot(fetchedAt: boundary.fetchedAt.addingTimeInterval(-0.001))
        let future = snapshot(fetchedAt: now.addingTimeInterval(0.001))

        #expect(boundary.isFresh(at: now))
        #expect(!stale.isFresh(at: now))
        #expect(!future.isFresh(at: now))
    }

    @Test("Stale positive quota cannot score or activate")
    func stalePositiveQuotaIsIneligible() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let stale = account(
            email: "stale@example.com",
            snapshot: snapshot(fetchedAt: now.addingTimeInterval(
                -QuotaFreshnessPolicy.maximumSnapshotAge - 1
            ))
        )

        #expect(SwapEngine.score(stale, now: now) == -1)
        #expect(!SwapEngine.isImmediatelyUsable(stale, now: now))
        #expect(SwapEngine.selectOptimalAccount(from: [stale], now: now) == nil)
        #expect(SwapEngine.selectAutoSwapCandidate(from: [stale], now: now) == nil)
    }

    @Test("Stale blocked quota cannot authorize a banked reset")
    func staleBlockedQuotaCannotSpendReset() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var blocked = account(
            email: "blocked@example.com",
            snapshot: snapshot(
                fetchedAt: now.addingTimeInterval(
                    -QuotaFreshnessPolicy.maximumSnapshotAge - 1
                ),
                usedPercent: 100
            ),
            isActive: true
        )
        blocked.runtimeUnusableUntil = now.addingTimeInterval(3_600)
        blocked.runtimeUnusableReason = "usage_limit"

        #expect(RateLimitResetPolicy.redemptionReason(
            for: blocked,
            allAccounts: [blocked],
            bank: bank(fetchedAt: now),
            runtimeUsageLimit: true,
            now: now
        ) == nil)
        #expect(RateLimitResetPolicy.selectRedemptionCandidate(
            from: [blocked],
            now: now
        ) == nil)
    }

    @Test("Switch entry points share one ranking implementation")
    func selectionWrappersHaveParity() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let lower = account(
            email: "lower@example.com",
            snapshot: snapshot(fetchedAt: now, usedPercent: 20),
            planType: "plus"
        )
        let higher = account(
            email: "higher@example.com",
            snapshot: snapshot(fetchedAt: now, usedPercent: 50),
            planType: "pro"
        )

        let optimal = SwapEngine.selectOptimalAccount(from: [lower, higher], now: now)
        let automatic = SwapEngine.selectAutoSwapCandidate(from: [lower, higher], now: now)
        let ranked = SwapEngine.rankedEligibleCandidates(
            from: [lower, higher],
            now: now
        ).first

        #expect(optimal?.id == higher.id)
        #expect(automatic?.id == optimal?.id)
        #expect(ranked?.id == optimal?.id)
    }

    private func snapshot(
        fetchedAt: Date,
        usedPercent: Double = 10
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: fetchedAt,
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 604_800,
                    usedPercent: usedPercent,
                    resetsAt: fetchedAt.addingTimeInterval(604_800),
                    source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary),
                    hardLimitReached: usedPercent >= 100
                ),
            ]
        )
    }

    private func account(
        email: String,
        snapshot: QuotaSnapshot,
        planType: String = "pro",
        isActive: Bool = false
    ) -> CodexAccount {
        CodexAccount(
            email: email,
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: email,
            quotaSnapshot: snapshot,
            planType: planType,
            isActive: isActive
        )
    }

    private func bank(fetchedAt: Date) -> RateLimitResetBank {
        RateLimitResetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [
                RateLimitResetCredit(
                    id: "credit",
                    resetType: "full",
                    status: "available",
                    grantedAt: fetchedAt,
                    expiresAt: fetchedAt.addingTimeInterval(86_400),
                    redeemedAt: nil,
                    title: nil,
                    description: nil
                ),
            ],
            fetchedAt: fetchedAt
        )
    }
}

@Suite("Rate-limit reset policy")
struct RateLimitResetPolicyAuditTests {
    @Test("An exhausted window can spend before reset but requires refresh at and after reset")
    func naturalResetBoundaryRequiresRefresh() {
        let resetAt = Date(timeIntervalSince1970: 2_100_000_000)
        let fetchedAt = resetAt.addingTimeInterval(-1)
        let snapshot = exhaustedSnapshot(fetchedAt: fetchedAt, resetsAt: resetAt)
        var exhausted = account(
            email: "blocked@example.com",
            providerAccountId: "blocked",
            snapshot: snapshot
        )
        let resetBank = bank(fetchedAt: fetchedAt, identifiers: ["credit"])
        exhausted.rateLimitResetBank = resetBank
        let before = resetAt.addingTimeInterval(-0.001)
        let after = resetAt.addingTimeInterval(0.001)

        #expect(!snapshot.hasExpiredExhaustedWindow(now: before))
        #expect(RateLimitResetPolicy.redemptionReason(
            for: exhausted,
            allAccounts: [exhausted],
            bank: resetBank,
            now: before
        ) == .weeklyPressure)

        #expect(snapshot.hasExpiredExhaustedWindow(now: resetAt))
        #expect(RateLimitResetPolicy.redemptionReason(
            for: exhausted,
            allAccounts: [exhausted],
            bank: resetBank,
            now: resetAt
        ) == nil)
        #expect(RateLimitResetPolicy.selectRedemptionCandidate(
            from: [exhausted],
            now: resetAt
        ) == nil)

        #expect(snapshot.hasExpiredExhaustedWindow(now: after))
        #expect(RateLimitResetPolicy.redemptionReason(
            for: exhausted,
            allAccounts: [exhausted],
            bank: resetBank,
            now: after
        ) == nil)
    }

    @Test("A denied blocking window requires refresh after its reset even below exhaustion")
    func deniedBlockingWindowRequiresRefreshAfterReset() {
        let resetAt = Date(timeIntervalSince1970: 2_100_000_000)
        let fetchedAt = resetAt.addingTimeInterval(-1)
        let snapshot = deniedSnapshot(fetchedAt: fetchedAt, resetsAt: resetAt)
        var denied = account(
            email: "denied@example.com",
            providerAccountId: "denied",
            snapshot: snapshot
        )
        let resetBank = bank(fetchedAt: fetchedAt, identifiers: ["credit"])
        denied.rateLimitResetBank = resetBank

        #expect(!snapshot.hasExpiredExhaustedWindow(now: resetAt))
        #expect(RateLimitResetPolicy.redemptionReason(
            for: denied,
            allAccounts: [denied],
            bank: resetBank,
            now: resetAt.addingTimeInterval(-0.001)
        ) == .weeklyPressure)
        #expect(RateLimitResetPolicy.redemptionReason(
            for: denied,
            allAccounts: [denied],
            bank: resetBank,
            now: resetAt
        ) == nil)
        #expect(RateLimitResetPolicy.selectRedemptionCandidate(
            from: [denied],
            now: resetAt
        ) == nil)
        #expect(RateLimitResetPolicy.redemptionReason(
            for: denied,
            allAccounts: [denied],
            bank: resetBank,
            now: resetAt.addingTimeInterval(0.001)
        ) == nil)
    }

    @Test("Natural reset protection includes the exact 24-hour boundary")
    func naturalResetProtectionBoundary() {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let readyPlus = account(
            email: "ready-plus@example.com",
            providerAccountId: "ready-plus",
            snapshot: usableSnapshot(fetchedAt: now),
            planType: "plus"
        )
        let justBefore = resetCandidate(
            now: now,
            resetAfter: RateLimitResetPolicy.naturalResetProtectionInterval - 0.001
        )
        let exactlyAt = resetCandidate(
            now: now,
            resetAfter: RateLimitResetPolicy.naturalResetProtectionInterval
        )
        let justAfter = resetCandidate(
            now: now,
            resetAfter: RateLimitResetPolicy.naturalResetProtectionInterval + 0.001
        )

        #expect(reason(for: justBefore, with: readyPlus, now: now) == nil)
        #expect(reason(for: exactlyAt, with: readyPlus, now: now) == nil)
        #expect(reason(for: justAfter, with: readyPlus, now: now) == .preserveFasterTier)
    }

    @Test("Selection-facing credits require trimmed nonempty unique identifiers")
    func resetInventoryIdentifierValidation() throws {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let valid = bank(
            fetchedAt: now,
            identifiers: [" beta-credit ", "alpha-credit"]
        )

        #expect(valid.credits.map(\.id) == [" beta-credit ", "alpha-credit"])
        #expect(valid.availableCredits(at: now).map(\.id) == ["alpha-credit", "beta-credit"])
        #expect(valid.oldestExpiringCredit(at: now)?.id == "alpha-credit")
        #expect(valid.hasAvailableReset(at: now))

        let encoded = try JSONEncoder().encode(valid)
        let decoded = try JSONDecoder().decode(RateLimitResetBank.self, from: encoded)
        #expect(decoded.credits.map(\.id) == valid.credits.map(\.id))
        #expect(decoded.availableCredits(at: now).map(\.id) == ["alpha-credit", "beta-credit"])

        let countOnly = bank(fetchedAt: now, availableCount: 1, identifiers: [])
        let blank = bank(fetchedAt: now, identifiers: ["valid", " \n\t "])
        let duplicate = bank(fetchedAt: now, identifiers: ["credit", " credit "])
        let zeroCount = bank(fetchedAt: now, availableCount: 0, identifiers: ["credit"])

        for malformed in [countOnly, blank, duplicate, zeroCount] {
            #expect(malformed.availableCredits(at: now).isEmpty)
            #expect(malformed.oldestExpiringCredit(at: now) == nil)
            #expect(!malformed.hasAvailableReset(at: now))
        }
    }

    @Test("Reset conservation uses complete immediately-usable replacements only")
    func resetConservationUsesSharedReplacementEligibility() {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        var target = resetCandidate(now: now, resetAfter: 3 * 86_400)
        target.planType = "plus"
        var incompletePro = account(
            email: "incomplete-pro@example.com",
            providerAccountId: "incomplete-pro",
            snapshot: usableSnapshot(fetchedAt: now),
            planType: "pro"
        )
        incompletePro.refreshToken = " \n "

        #expect(!incompletePro.isImmediatelyUsableReplacement(at: now))
        #expect(reason(for: target, with: incompletePro, now: now) == .weeklyPressure)

        incompletePro.refreshToken = "refresh"
        #expect(incompletePro.isImmediatelyUsableReplacement(at: now))
        #expect(reason(for: target, with: incompletePro, now: now) == nil)

        incompletePro.runtimeUnusableUntil = now.addingTimeInterval(3_600)
        incompletePro.runtimeUnusableReason = "usage_limit"
        #expect(incompletePro.realQuotaSnapshot(at: now) != nil)
        #expect(!incompletePro.isImmediatelyUsableReplacement(at: now))
        #expect(reason(for: target, with: incompletePro, now: now) == .weeklyPressure)
    }

    @Test("Same-tier reset ordering starts with normalized provider identity")
    func sameTierResetOrderingIsStable() throws {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let alphaProvider = resetCandidate(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004")),
            email: "zulu@example.com",
            providerAccountId: " alpha-provider ",
            now: now
        )
        let betaProvider = resetCandidate(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003")),
            email: "alpha@example.com",
            providerAccountId: "BETA-PROVIDER",
            now: now
        )

        #expect(selected(from: [betaProvider, alphaProvider], now: now) == alphaProvider.id)
        #expect(selected(from: [alphaProvider, betaProvider], now: now) == alphaProvider.id)

        let alphaEmail = resetCandidate(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            email: " Alpha@Example.com ",
            providerAccountId: "SAME-PROVIDER",
            now: now
        )
        let zuluEmail = resetCandidate(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            email: "zulu@example.com",
            providerAccountId: " same-provider ",
            now: now
        )

        #expect(selected(from: [zuluEmail, alphaEmail], now: now) == alphaEmail.id)
        #expect(selected(from: [alphaEmail, zuluEmail], now: now) == alphaEmail.id)

        let earlierID = resetCandidate(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000005")),
            email: "alpha@example.com",
            providerAccountId: " same-provider ",
            now: now
        )
        let laterID = resetCandidate(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000006")),
            email: " Alpha@Example.com ",
            providerAccountId: "SAME-PROVIDER",
            now: now
        )

        #expect(selected(from: [laterID, earlierID], now: now) == earlierID.id)
        #expect(selected(from: [earlierID, laterID], now: now) == earlierID.id)
    }

    private func reason(
        for target: CodexAccount,
        with alternative: CodexAccount,
        now: Date
    ) -> RateLimitResetRedemptionReason? {
        RateLimitResetPolicy.redemptionReason(
            for: target,
            allAccounts: [target, alternative],
            bank: target.rateLimitResetBank!,
            now: now
        )
    }

    private func selected(from accounts: [CodexAccount], now: Date) -> UUID? {
        RateLimitResetPolicy.selectRedemptionCandidate(from: accounts, now: now)?.accountId
    }

    private func resetCandidate(
        id: UUID = UUID(),
        email: String = "blocked-pro@example.com",
        providerAccountId: String = "blocked-pro",
        now: Date,
        resetAfter: TimeInterval = 3 * 86_400
    ) -> CodexAccount {
        var candidate = account(
            id: id,
            email: email,
            providerAccountId: providerAccountId,
            snapshot: exhaustedSnapshot(
                fetchedAt: now,
                resetsAt: now.addingTimeInterval(resetAfter)
            ),
            planType: "pro"
        )
        candidate.rateLimitResetBank = bank(fetchedAt: now, identifiers: ["credit-\(id.uuidString)"])
        return candidate
    }

    private func account(
        id: UUID = UUID(),
        email: String,
        providerAccountId: String,
        snapshot: QuotaSnapshot,
        planType: String = "pro"
    ) -> CodexAccount {
        CodexAccount(
            id: id,
            email: email,
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: providerAccountId,
            quotaSnapshot: snapshot,
            planType: planType
        )
    }

    private func exhaustedSnapshot(fetchedAt: Date, resetsAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: fetchedAt,
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 604_800,
                    usedPercent: 100,
                    resetsAt: resetsAt,
                    source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary),
                    hardLimitReached: true
                ),
            ]
        )
    }

    private func deniedSnapshot(fetchedAt: Date, resetsAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            allowed: false,
            limitReached: true,
            fetchedAt: fetchedAt,
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 604_800,
                    usedPercent: 42,
                    resetsAt: resetsAt,
                    source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary),
                    hardLimitReached: false
                ),
            ]
        )
    }

    private func usableSnapshot(fetchedAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
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
    }

    private func bank(
        fetchedAt: Date,
        availableCount: Int? = nil,
        identifiers: [String]
    ) -> RateLimitResetBank {
        RateLimitResetBank(
            availableCount: availableCount ?? identifiers.count,
            totalEarnedCount: max(availableCount ?? identifiers.count, identifiers.count),
            credits: identifiers.map { identifier in
                RateLimitResetCredit(
                    id: identifier,
                    resetType: "full",
                    status: "available",
                    grantedAt: fetchedAt,
                    expiresAt: fetchedAt.addingTimeInterval(7 * 86_400),
                    redeemedAt: nil,
                    title: nil,
                    description: nil
                )
            },
            fetchedAt: fetchedAt
        )
    }
}

@Suite("Account persistence coordinator")
struct AccountPersistenceCoordinatorTests {
    @Test("Telemetry persistence is delayed and coalesces a polling burst")
    func coalescesTelemetry() async throws {
        let recorder = PersistenceRecorder()
        let clock = PersistenceClock()
        let coordinator = AccountPersistenceCoordinator(
            telemetryDelay: .seconds(60),
            now: { clock.now() },
            load: { [] },
            save: { recorder.record($0) },
            deleteAll: {}
        )
        for revision in 1...20 {
            await coordinator.queueTelemetry(
                [account(id: "telemetry-\(revision)")],
                revision: UInt64(revision)
            )
        }

        #expect(recorder.savedAccountIds().isEmpty)
        clock.advance(by: 60)
        #expect(try await coordinator.flushTelemetryIfDue())

        #expect(recorder.savedAccountIds() == [["telemetry-20"]])
    }

    @Test("All freshness-only timestamps are suppressed until the heartbeat")
    func freshnessOnlyTelemetryUsesHeartbeat() async throws {
        let recorder = PersistenceRecorder()
        let clock = PersistenceClock()
        let localAccountId = UUID()
        let initial = telemetryAccount(
            localAccountId: localAccountId,
            id: "quota",
            fetchedAt: clock.now()
        )
        let coordinator = AccountPersistenceCoordinator(
            telemetryDelay: .seconds(60),
            now: { clock.now() },
            load: { initial },
            save: { recorder.record($0) },
            deleteAll: {}
        )
        _ = try await coordinator.loadAll()

        await coordinator.queueTelemetry(
            telemetryAccount(
                localAccountId: localAccountId,
                id: "quota",
                fetchedAt: clock.now().addingTimeInterval(30)
            ),
            revision: 1
        )
        clock.advance(by: 60)
        #expect(try await coordinator.flushTelemetryIfDue() == false)
        #expect(recorder.savedAccountIds().isEmpty)

        clock.advance(by: 240)
        await coordinator.queueTelemetry(
            telemetryAccount(
                localAccountId: localAccountId,
                id: "quota",
                fetchedAt: clock.now()
            ),
            revision: 2
        )
        #expect(try await coordinator.flushTelemetryIfDue())
        #expect(recorder.savedAccountIds() == [["quota"]])
        let saved = try #require(recorder.lastSavedAccount())
        #expect(saved.lastRefreshed == clock.now())
        #expect(saved.quotaSnapshot?.fetchedAt == clock.now())
        #expect(saved.rateLimitResetBank?.fetchedAt == clock.now())

        clock.advance(by: 60)
        await coordinator.queueTelemetry(
            telemetryAccount(
                localAccountId: localAccountId,
                id: "quota",
                fetchedAt: clock.now()
            ),
            revision: 3
        )
        #expect(try await coordinator.flushTelemetryIfDue() == false)
        #expect(recorder.savedAccountIds() == [["quota"]])
    }

    @Test("Semantic telemetry waits for the minimum write cadence")
    func semanticTelemetryUsesMinimumCadence() async throws {
        let recorder = PersistenceRecorder()
        let clock = PersistenceClock()
        let initial = telemetryAccount(id: "quota", fetchedAt: clock.now())
        let coordinator = AccountPersistenceCoordinator(
            telemetryDelay: .seconds(60),
            now: { clock.now() },
            load: { initial },
            save: { recorder.record($0) },
            deleteAll: {}
        )
        _ = try await coordinator.loadAll()

        var changed = telemetryAccount(id: "quota", fetchedAt: clock.now())
        changed[0].planType = "pro"
        await coordinator.queueTelemetry(changed, revision: 1)
        clock.advance(by: 59)
        #expect(try await coordinator.flushTelemetryIfDue() == false)
        #expect(recorder.savedAccountIds().isEmpty)

        clock.advance(by: 1)
        #expect(try await coordinator.flushTelemetryIfDue())
        #expect(recorder.lastSavedPlanType() == "pro")
    }

    @Test("Explicit telemetry flush bypasses cadence and suppression")
    func explicitFlushIsForced() async throws {
        let recorder = PersistenceRecorder()
        let clock = PersistenceClock()
        let initial = telemetryAccount(id: "quota", fetchedAt: clock.now())
        let coordinator = AccountPersistenceCoordinator(
            telemetryDelay: .seconds(60),
            now: { clock.now() },
            load: { initial },
            save: { recorder.record($0) },
            deleteAll: {}
        )
        _ = try await coordinator.loadAll()

        await coordinator.queueTelemetry(
            telemetryAccount(id: "quota", fetchedAt: clock.now().addingTimeInterval(1)),
            revision: 1
        )
        try await coordinator.flushTelemetry()

        #expect(recorder.savedAccountIds() == [["quota"]])
    }

    @Test("A durable user mutation supersedes already queued telemetry")
    func durableMutationSupersedesQueuedTelemetry() async throws {
        let recorder = PersistenceRecorder()
        let coordinator = AccountPersistenceCoordinator(
            telemetryDelay: .seconds(60),
            load: { [] },
            save: { recorder.record($0) },
            deleteAll: {}
        )

        await coordinator.queueTelemetry([account(id: "telemetry")], revision: 1)
        try await coordinator.persistDurably([account(id: "user-mutation")], revision: 2)
        try await coordinator.flushTelemetry()

        #expect(recorder.savedAccountIds() == [["user-mutation"]])
    }

    @Test("A delayed telemetry revision cannot overwrite a durable revision")
    func staleTelemetryCannotOverwriteDurableState() async throws {
        let recorder = PersistenceRecorder()
        let coordinator = AccountPersistenceCoordinator(
            telemetryDelay: .seconds(60),
            load: { [] },
            save: { recorder.record($0) },
            deleteAll: {}
        )

        try await coordinator.persistDurably([account(id: "durable")], revision: 2)
        await coordinator.queueTelemetry([account(id: "stale")], revision: 1)
        try await coordinator.flushTelemetry()

        #expect(recorder.savedAccountIds() == [["durable"]])
    }

    @Test("Failed telemetry flush remains retryable")
    func failedFlushCanRetry() async throws {
        let recorder = PersistenceRecorder(failFirstSave: true)
        let coordinator = AccountPersistenceCoordinator(
            telemetryDelay: .seconds(60),
            load: { [] },
            save: { try recorder.recordOrThrow($0) },
            deleteAll: {}
        )

        await coordinator.queueTelemetry([account(id: "retry")], revision: 1)
        await #expect(throws: PersistenceRecorder.Failure.self) {
            try await coordinator.flushTelemetry()
        }
        try await coordinator.flushTelemetry()

        #expect(recorder.savedAccountIds() == [["retry"]])
    }

    private func account(id: String) -> CodexAccount {
        CodexAccount(
            email: "\(id)@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: id,
            isActive: true
        )
    }

    private func telemetryAccount(
        localAccountId: UUID = UUID(),
        id: String,
        fetchedAt: Date
    ) -> [CodexAccount] {
        [CodexAccount(
            id: localAccountId,
            email: "\(id)@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: id,
            quotaSnapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: fetchedAt,
                windows: [
                    QuotaWindow(
                        kind: .fiveHour,
                        durationSeconds: 5 * 60 * 60,
                        usedPercent: 25,
                        resetsAt: Date(timeIntervalSince1970: 2_000_000_000),
                        source: QuotaWindowSourceMetadata(
                            rateLimit: .main,
                            slot: .primary
                        )
                    ),
                ]
            ),
            planType: "plus",
            lastRefreshed: fetchedAt,
            rateLimitResetBank: RateLimitResetBank(
                availableCount: 0,
                totalEarnedCount: 0,
                credits: [],
                fetchedAt: fetchedAt
            ),
            isActive: true
        )]
    }
}

private final class PersistenceRecorder: @unchecked Sendable {
    enum Failure: Error {
        case injected
    }

    private let lock = NSLock()
    private var saves: [[CodexAccount]] = []
    private var shouldFail: Bool

    init(failFirstSave: Bool = false) {
        self.shouldFail = failFirstSave
    }

    func record(_ accounts: [CodexAccount]) {
        lock.withLock { saves.append(accounts) }
    }

    func recordOrThrow(_ accounts: [CodexAccount]) throws {
        try lock.withLock {
            if shouldFail {
                shouldFail = false
                throw Failure.injected
            }
            saves.append(accounts)
        }
    }

    func savedAccountIds() -> [[String]] {
        lock.withLock { saves.map { $0.map(\.accountId) } }
    }

    func lastSavedPlanType() -> String? {
        lock.withLock { saves.last?.first?.planType }
    }

    func lastSavedAccount() -> CodexAccount? {
        lock.withLock { saves.last?.first }
    }
}

private final class PersistenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_900_000_000)

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}
