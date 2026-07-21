import Foundation
import Testing
@testable import CodexSwitch

@Suite("Banked rate-limit resets")
struct RateLimitResetServiceTests {
    @Test("Inventory parses fractional dates and chooses the oldest expiration")
    func parsesInventoryAndOrdersCredits() async throws {
        let data = Data(
            """
            {
              "available_count": 2,
              "total_earned_count": 3,
              "credits": [
                {
                  "id": "later",
                  "reset_type": "full",
                  "status": "available",
                  "granted_at": "2026-07-01T12:00:00.123Z",
                  "expires_at": "2026-07-31T12:00:00.456Z",
                  "redeemed_at": null,
                  "title": "Full reset (Weekly + 5 hr)",
                  "description": "Later"
                },
                {
                  "id": "earlier",
                  "reset_type": "full",
                  "status": "available",
                  "granted_at": "2026-07-01T12:00:00Z",
                  "expires_at": "2026-07-18T12:00:00Z",
                  "redeemed_at": null,
                  "title": "Full reset (Weekly + 5 hr)",
                  "description": "Earlier"
                }
              ]
            }
            """.utf8
        )
        let service = RateLimitResetService { _ in
            RateLimitResetHTTPResponse(statusCode: 200, data: data)
        }
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))

        let bank = try await service.fetchBank(
            for: Self.account(),
            force: true,
            now: now,
            observationCompletedAt: now
        )

        #expect(bank.availableCount == 2)
        #expect(bank.totalEarnedCount == 3)
        #expect(bank.oldestExpiringCredit(at: now)?.id == "earlier")
        #expect(bank.nextExpiration(at: now) == Self.isoDate("2026-07-18T12:00:00Z"))
    }

    @Test("Malformed inventory is rejected")
    func rejectsMalformedInventory() async {
        let service = RateLimitResetService { _ in
            RateLimitResetHTTPResponse(
                statusCode: 200,
                data: Data("{\"available_count\":-1,\"total_earned_count\":0,\"credits\":[]}".utf8)
            )
        }

        await #expect(throws: RateLimitResetServiceError.malformedInventory) {
            try await service.fetchBank(for: Self.account(), force: true)
        }
    }

    @Test("Timestamp-fresh malformed cached inventory is refreshed")
    func refreshesStructurallyInvalidCachedInventory() async throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let response = RateLimitResetHTTPResponse(
            statusCode: 200,
            data: Data(
                """
                {
                  "available_count": 1,
                  "total_earned_count": 1,
                  "credits": [
                    {
                      "id": "fresh-credit",
                      "status": "available",
                      "expires_at": "2026-07-31T12:00:00Z"
                    }
                  ]
                }
                """.utf8
            )
        )
        let harness = ResetTransportHarness([.response(response)])
        let service = RateLimitResetService { request in try harness.send(request) }
        var account = Self.account()
        account.rateLimitResetBank = RateLimitResetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [],
            fetchedAt: now.addingTimeInterval(-1)
        )

        let refreshed = try await service.fetchBank(
            for: account,
            now: now,
            observationCompletedAt: now
        )

        #expect(refreshed.oldestExpiringCredit(at: now)?.id == "fresh-credit")
        #expect(harness.requestBodies().count == 1)
    }

    @Test("Inventory count must match the complete available-credit list")
    func rejectsPartialInventoryPayload() async throws {
        let data = Data(
            """
            {
              "available_count": 2,
              "total_earned_count": 2,
              "credits": [
                {
                  "id": "only-credit",
                  "status": "available",
                  "expires_at": "2026-07-31T12:00:00Z"
                }
              ]
            }
            """.utf8
        )
        let service = RateLimitResetService { _ in
            RateLimitResetHTTPResponse(statusCode: 200, data: data)
        }
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))

        await #expect(throws: RateLimitResetServiceError.malformedInventory) {
            try await service.fetchBank(
                for: Self.account(),
                force: true,
                now: now,
                observationCompletedAt: now
            )
        }
    }

    @Test("Zero count with an unexpired available credit is malformed")
    func rejectsContradictoryZeroCountInventory() async throws {
        let data = Data(
            """
            {
              "available_count": 0,
              "total_earned_count": 1,
              "credits": [
                {
                  "id": "hidden-credit",
                  "status": "available",
                  "expires_at": "2026-07-31T12:00:00Z"
                }
              ]
            }
            """.utf8
        )
        let service = RateLimitResetService { _ in
            RateLimitResetHTTPResponse(statusCode: 200, data: data)
        }
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))

        await #expect(throws: RateLimitResetServiceError.malformedInventory) {
            try await service.fetchBank(
                for: Self.account(),
                force: true,
                now: now,
                observationCompletedAt: now
            )
        }
    }

    @Test("Available credits require a present future expiration")
    func rejectsAvailableCreditWithoutExpiration() async throws {
        let data = Data(
            """
            {
              "available_count": 1,
              "total_earned_count": 1,
              "credits": [
                {
                  "id": "expiry-unknown",
                  "status": "available",
                  "expires_at": null
                }
              ]
            }
            """.utf8
        )
        let service = RateLimitResetService { _ in
            RateLimitResetHTTPResponse(statusCode: 200, data: data)
        }
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))

        await #expect(throws: RateLimitResetServiceError.malformedInventory) {
            try await service.fetchBank(
                for: Self.account(),
                force: true,
                now: now,
                observationCompletedAt: now
            )
        }
    }

    @Test("Inventory completion time prevents mid-request expiry attribution")
    func rejectsCreditThatExpiredDuringInventoryRequest() async throws {
        let data = Data(
            """
            {
              "available_count": 1,
              "total_earned_count": 1,
              "credits": [
                {
                  "id": "expired-during-request",
                  "status": "available",
                  "expires_at": "2026-07-12T12:00:10Z"
                }
              ]
            }
            """.utf8
        )
        let service = RateLimitResetService { _ in
            RateLimitResetHTTPResponse(statusCode: 200, data: data)
        }
        let requestStartedAt = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let requestCompletedAt = requestStartedAt.addingTimeInterval(20)

        await #expect(throws: RateLimitResetServiceError.malformedInventory) {
            try await service.fetchBank(
                for: Self.account(),
                force: true,
                now: requestStartedAt,
                observationCompletedAt: requestCompletedAt
            )
        }
    }

    @Test("Count-only inventory cannot trigger redemption without a credit ID")
    func countOnlyInventoryIsNotRedeemable() {
        let bank = RateLimitResetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [],
            fetchedAt: Date()
        )

        #expect(!bank.hasAvailableReset())
        #expect(bank.oldestExpiringCredit() == nil)
    }

    @Test("Partial credit inventory cannot authorize redemption")
    func partialInventoryIsNotRedeemable() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let complete = Self.bank(now: now, expiresIn: 86_400)
        let partial = RateLimitResetBank(
            availableCount: 2,
            totalEarnedCount: 2,
            credits: complete.credits,
            fetchedAt: now
        )

        #expect(!partial.hasAvailableReset(at: now))
        #expect(partial.oldestExpiringCredit(at: now) == nil)
    }

    @Test("Conservation policy rotates within a tier before spending resets")
    func conservationPolicy() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let bank = Self.bank(now: now, expiresIn: 7 * 86_400)
        let readyAlternative = Self.account(
            email: "ready@example.com",
            snapshot: Self.snapshot(fiveHourUsed: 10, weeklyUsed: 10, now: now)
        )

        let weeklyAccount = Self.account(
            snapshot: Self.snapshot(fiveHourUsed: 20, weeklyUsed: 100, now: now)
        )
        #expect(RateLimitResetPolicy.redemptionReason(
            for: weeklyAccount,
            allAccounts: [weeklyAccount, readyAlternative],
            bank: bank,
            now: now
        ) == nil)

        let fiveHourOnly = Self.account(
            snapshot: Self.snapshot(fiveHourUsed: 100, weeklyUsed: 20, now: now)
        )
        #expect(RateLimitResetPolicy.redemptionReason(
            for: fiveHourOnly,
            allAccounts: [fiveHourOnly, readyAlternative],
            bank: bank,
            now: now
        ) == nil)

        #expect(RateLimitResetPolicy.redemptionReason(
            for: fiveHourOnly,
            allAccounts: [fiveHourOnly],
            bank: bank,
            now: now
        ) == .poolExhausted)
    }

    @Test("Pro reset is used before Plus only when natural recovery is not close")
    func proTierAndNaturalResetPolicy() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let bank = Self.bank(now: now, expiresIn: 7 * 86_400)
        let plusAlternative = Self.account(
            email: "plus@example.com",
            snapshot: Self.snapshot(fiveHourUsed: 10, weeklyUsed: 10, now: now),
            planType: "plus"
        )
        let longWait = Self.account(
            snapshot: Self.snapshot(
                fiveHourUsed: 20,
                weeklyUsed: 100,
                now: now,
                weeklyResetAfter: 36 * 60 * 60
            )
        )
        #expect(RateLimitResetPolicy.redemptionReason(
            for: longWait,
            allAccounts: [longWait, plusAlternative],
            bank: bank,
            now: now
        ) == .preserveFasterTier)

        let nearReset = Self.account(
            snapshot: Self.snapshot(
                fiveHourUsed: 20,
                weeklyUsed: 100,
                now: now,
                weeklyResetAfter: 12 * 60 * 60
            )
        )
        #expect(RateLimitResetPolicy.redemptionReason(
            for: nearReset,
            allAccounts: [nearReset, plusAlternative],
            bank: bank,
            now: now
        ) == nil)
        #expect(RateLimitResetPolicy.redemptionReason(
            for: nearReset,
            allAccounts: [nearReset],
            bank: bank,
            now: now
        ) == .weeklyPressure)
    }

    @Test("Weekly-only reset policy never invents a five-hour recovery")
    func weeklyOnlyResetPolicy() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let bank = Self.bank(now: now, expiresIn: 7 * 86_400)
        let healthy = Self.account(
            snapshot: Self.weeklyOnlySnapshot(used: 20, now: now, resetAfter: 3 * 86_400)
        )
        let exhausted = Self.account(
            snapshot: Self.weeklyOnlySnapshot(used: 100, now: now, resetAfter: 3 * 86_400)
        )
        let nearNaturalReset = Self.account(
            snapshot: Self.weeklyOnlySnapshot(used: 100, now: now, resetAfter: 12 * 60 * 60)
        )

        #expect(RateLimitResetPolicy.redemptionReason(
            for: healthy,
            allAccounts: [healthy],
            bank: bank,
            now: now
        ) == nil)
        #expect(RateLimitResetPolicy.redemptionReason(
            for: exhausted,
            allAccounts: [exhausted],
            bank: bank,
            now: now
        ) == .weeklyPressure)
        #expect(RateLimitResetPolicy.redemptionReason(
            for: nearNaturalReset,
            allAccounts: [nearNaturalReset],
            bank: bank,
            now: now
        ) == .weeklyPressure)
    }

    @Test("Inactive exhausted Pro resets ahead of active usable Plus when recovery is not close")
    func inactiveProResetPrecedesActiveUsablePlus() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        var plus = Self.account(
            email: "plus@example.com",
            snapshot: Self.weeklyOnlySnapshot(used: 20, now: now, resetAfter: 3 * 86_400),
            planType: "plus"
        )
        plus.isActive = true
        var exhaustedPro = Self.account(
            email: "pro@example.com",
            snapshot: Self.weeklyOnlySnapshot(used: 100, now: now, resetAfter: 3 * 86_400),
            planType: "pro"
        )
        let bank = Self.bank(now: now, expiresIn: 7 * 86_400)
        exhaustedPro.rateLimitResetBank = bank

        #expect(SwapEngine.isImmediatelyUsable(plus, now: now))
        #expect(!exhaustedPro.isActive)
        #expect(RateLimitResetPolicy.redemptionReason(
            for: exhaustedPro,
            allAccounts: [plus, exhaustedPro],
            bank: bank,
            now: now
        ) == .preserveFasterTier)

        let selection = RateLimitResetPolicy.selectRedemptionCandidate(
            from: [plus, exhaustedPro],
            now: now
        )

        #expect(selection?.accountId == exhaustedPro.id)
        #expect(selection?.reason == .preserveFasterTier)
    }

    @Test("Usable active Pro suppresses inactive lower-tier reset redemption")
    func activeUsableProSuppressesInactivePlusReset() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        var activePro = Self.account(
            email: "active-pro@example.com",
            snapshot: Self.weeklyOnlySnapshot(used: 20, now: now, resetAfter: 3 * 86_400),
            planType: "pro"
        )
        activePro.isActive = true
        var exhaustedPlus = Self.account(
            email: "exhausted-plus@example.com",
            snapshot: Self.weeklyOnlySnapshot(used: 100, now: now, resetAfter: 3 * 86_400),
            planType: "plus"
        )
        let bank = Self.bank(now: now, expiresIn: 7 * 86_400)
        exhaustedPlus.rateLimitResetBank = bank

        #expect(SwapEngine.isImmediatelyUsable(activePro, now: now))
        #expect(!exhaustedPlus.isActive)
        #expect(RateLimitResetPolicy.redemptionReason(
            for: exhaustedPlus,
            allAccounts: [activePro, exhaustedPlus],
            bank: bank,
            now: now
        ) == nil)
        #expect(RateLimitResetPolicy.selectRedemptionCandidate(
            from: [activePro, exhaustedPlus],
            now: now
        ) == nil)
    }

    @Test("Pool selector preserves reset near natural recovery and with usable same-tier capacity")
    func poolSelectorPreservesProtectedResets() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let plus = Self.account(
            email: "plus@example.com",
            snapshot: Self.weeklyOnlySnapshot(used: 20, now: now, resetAfter: 3 * 86_400),
            planType: "plus"
        )
        let usablePro = Self.account(
            email: "usable-pro@example.com",
            snapshot: Self.weeklyOnlySnapshot(used: 20, now: now, resetAfter: 3 * 86_400),
            planType: "pro"
        )
        var nearResetPro = Self.account(
            email: "near-pro@example.com",
            snapshot: Self.weeklyOnlySnapshot(used: 100, now: now, resetAfter: 12 * 60 * 60),
            planType: "pro"
        )
        nearResetPro.rateLimitResetBank = Self.bank(now: now, expiresIn: 7 * 86_400)
        var blockedPro = Self.account(
            email: "blocked-pro@example.com",
            snapshot: Self.weeklyOnlySnapshot(used: 100, now: now, resetAfter: 3 * 86_400),
            planType: "pro"
        )
        blockedPro.rateLimitResetBank = Self.bank(now: now, expiresIn: 7 * 86_400)

        #expect(RateLimitResetPolicy.selectRedemptionCandidate(
            from: [plus, nearResetPro],
            now: now
        ) == nil)
        #expect(RateLimitResetPolicy.selectRedemptionCandidate(
            from: [usablePro, blockedPro],
            now: now
        ) == nil)
    }

    @Test("Pool selector uses stable identity to break same-tier ties")
    func poolSelectorIsDeterministicWithinTier() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        var alpha = Self.account(
            email: "alpha@example.com",
            snapshot: Self.weeklyOnlySnapshot(used: 100, now: now, resetAfter: 3 * 86_400)
        )
        var zulu = Self.account(
            email: "zulu@example.com",
            snapshot: Self.weeklyOnlySnapshot(used: 100, now: now, resetAfter: 3 * 86_400)
        )
        alpha.rateLimitResetBank = Self.bank(now: now, expiresIn: 7 * 86_400)
        zulu.rateLimitResetBank = Self.bank(now: now, expiresIn: 7 * 86_400)

        let forward = RateLimitResetPolicy.selectRedemptionCandidate(from: [zulu, alpha], now: now)
        let reverse = RateLimitResetPolicy.selectRedemptionCandidate(from: [alpha, zulu], now: now)

        #expect(forward?.accountId == alpha.id)
        #expect(reverse?.accountId == alpha.id)
    }

    @Test("Pool selector spends the earliest-expiring reset within a tier")
    func poolSelectorPrioritizesExpirationWithinTier() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        var alpha = Self.account(
            email: "alpha@example.com",
            snapshot: Self.weeklyOnlySnapshot(used: 100, now: now, resetAfter: 3 * 86_400)
        )
        var zulu = Self.account(
            email: "zulu@example.com",
            snapshot: Self.weeklyOnlySnapshot(used: 100, now: now, resetAfter: 3 * 86_400)
        )
        alpha.rateLimitResetBank = Self.bank(now: now, expiresIn: 7 * 86_400)
        zulu.rateLimitResetBank = Self.bank(now: now, expiresIn: 2 * 86_400)

        let forward = RateLimitResetPolicy.selectRedemptionCandidate(from: [alpha, zulu], now: now)
        let reverse = RateLimitResetPolicy.selectRedemptionCandidate(from: [zulu, alpha], now: now)

        #expect(forward?.accountId == zulu.id)
        #expect(reverse?.accountId == zulu.id)
    }

    @Test("Windowless snapshot cannot spend a reset")
    func windowlessSnapshotCannotSpendReset() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let account = Self.account(
            snapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: now,
                windows: []
            )
        )
        let unknownOnly = Self.account(
            email: "diagnostic@example.com",
            snapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: now,
                windows: [
                    QuotaWindow(
                        kind: .unknown,
                        durationSeconds: 86_400,
                        usedPercent: 100,
                        resetsAt: now.addingTimeInterval(86_400),
                        source: QuotaWindowSourceMetadata(rateLimit: .additional, slot: .secondary)
                    ),
                ]
            )
        )

        #expect(RateLimitResetPolicy.redemptionReason(
            for: account,
            allAccounts: [account],
            bank: Self.bank(now: now, expiresIn: 86_400),
            now: now
        ) == nil)
        #expect(RateLimitResetPolicy.redemptionReason(
            for: unknownOnly,
            allAccounts: [unknownOnly],
            bank: Self.bank(now: now, expiresIn: 86_400),
            now: now
        ) == nil)
    }

    @Test("Automatic reset candidates require paid plans and complete runtime credentials")
    func automaticRedemptionRequiresPaidCompleteAccount() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let bank = Self.bank(now: now, expiresIn: 86_400)
        var free = Self.account(
            email: "free@example.com",
            snapshot: Self.weeklyOnlySnapshot(
                used: 100,
                now: now,
                resetAfter: 3 * 86_400
            ),
            planType: "free"
        )
        free.rateLimitResetBank = bank
        var incomplete = Self.account(
            email: "incomplete@example.com",
            snapshot: Self.weeklyOnlySnapshot(
                used: 100,
                now: now,
                resetAfter: 3 * 86_400
            ),
            planType: "pro"
        )
        incomplete.refreshToken = "  "
        incomplete.rateLimitResetBank = bank
        var complete = Self.account(
            email: "complete@example.com",
            snapshot: Self.weeklyOnlySnapshot(
                used: 100,
                now: now,
                resetAfter: 3 * 86_400
            ),
            planType: "pro"
        )
        complete.rateLimitResetBank = bank

        #expect(RateLimitResetPolicy.redemptionReason(
            for: free,
            allAccounts: [free],
            bank: bank,
            now: now
        ) == nil)
        #expect(RateLimitResetPolicy.redemptionReason(
            for: incomplete,
            allAccounts: [incomplete],
            bank: bank,
            now: now
        ) == nil)
        #expect(RateLimitResetPolicy.selectRedemptionCandidate(
            from: [free, incomplete],
            now: now
        ) == nil)
        #expect(RateLimitResetPolicy.selectRedemptionCandidate(
            from: [free, incomplete, complete],
            now: now
        )?.accountId == complete.id)
    }

    @Test("Manual redemption targets one fresh blocked Pro without applying pool conservation")
    func manualRedemptionEligibilityIsAccountSpecific() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let bank = Self.bank(now: now, expiresIn: 7 * 86_400)
        let blockedPro = Self.account(
            email: "blocked-pro@example.com",
            snapshot: Self.weeklyOnlySnapshot(
                used: 100,
                now: now,
                resetAfter: 12 * 60 * 60
            ),
            planType: "pro"
        )
        let usablePro = Self.account(
            email: "usable-pro@example.com",
            snapshot: Self.weeklyOnlySnapshot(
                used: 20,
                now: now,
                resetAfter: 3 * 86_400
            ),
            planType: "pro"
        )

        #expect(RateLimitResetPolicy.redemptionReason(
            for: blockedPro,
            allAccounts: [blockedPro, usablePro],
            bank: bank,
            now: now
        ) == nil)
        #expect(RateLimitResetPolicy.canManuallyRedeem(
            for: blockedPro,
            bank: bank,
            now: now
        ))
    }

    @Test("Manual redemption fails closed for usable, free, and stale evidence")
    func manualRedemptionRequiresFreshBlockedPaidEvidence() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let freshBank = Self.bank(now: now, expiresIn: 7 * 86_400)
        let usablePro = Self.account(
            snapshot: Self.weeklyOnlySnapshot(
                used: 20,
                now: now,
                resetAfter: 3 * 86_400
            ),
            planType: "pro"
        )
        let blockedPlus = Self.account(
            snapshot: Self.weeklyOnlySnapshot(
                used: 100,
                now: now,
                resetAfter: 3 * 86_400
            ),
            planType: "plus"
        )
        let blockedFree = Self.account(
            snapshot: Self.weeklyOnlySnapshot(
                used: 100,
                now: now,
                resetAfter: 3 * 86_400
            ),
            planType: "free"
        )
        let blockedPro = Self.account(
            snapshot: Self.weeklyOnlySnapshot(
                used: 100,
                now: now,
                resetAfter: 3 * 86_400
            ),
            planType: "pro"
        )
        let staleBank = Self.bank(
            now: now.addingTimeInterval(-61),
            expiresIn: 7 * 86_400
        )
        var incompletePro = blockedPro
        incompletePro.idToken = "\n"

        #expect(!RateLimitResetPolicy.canManuallyRedeem(
            for: usablePro,
            bank: freshBank,
            now: now
        ))
        #expect(RateLimitResetPolicy.canManuallyRedeem(
            for: blockedPlus,
            bank: freshBank,
            now: now
        ))
        #expect(!RateLimitResetPolicy.canManuallyRedeem(
            for: blockedFree,
            bank: freshBank,
            now: now
        ))
        #expect(!RateLimitResetPolicy.canManuallyRedeem(
            for: blockedPro,
            bank: staleBank,
            now: now
        ))
        #expect(!RateLimitResetPolicy.canManuallyRedeem(
            for: incompletePro,
            bank: freshBank,
            now: now
        ))
    }

    @Test("Manual redemption never resumes automatic account switching")
    func manualRedemptionDoesNotResumeAutomaticSwap() {
        #expect(!AppDelegate.automaticSwapMayResume(
            after: .manual,
            operationRequestedResume: true
        ))
        #expect(AppDelegate.automaticSwapMayResume(
            after: .weeklyPressure,
            operationRequestedResume: true
        ))
        #expect(!AppDelegate.automaticSwapMayResume(
            after: .weeklyPressure,
            operationRequestedResume: false
        ))
    }

    @Test("A reset near expiration is used for an exhausted window")
    func expiringResetPolicy() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let bank = Self.bank(now: now, expiresIn: 60 * 60)
        let exhausted = Self.account(
            snapshot: Self.snapshot(fiveHourUsed: 100, weeklyUsed: 20, now: now)
        )
        let readyAlternative = Self.account(
            email: "ready@example.com",
            snapshot: Self.snapshot(fiveHourUsed: 10, weeklyUsed: 10, now: now)
        )

        #expect(RateLimitResetPolicy.redemptionReason(
            for: exhausted,
            allAccounts: [exhausted, readyAlternative],
            bank: bank,
            now: now
        ) == nil)
        #expect(RateLimitResetPolicy.redemptionReason(
            for: exhausted,
            allAccounts: [exhausted],
            bank: bank,
            now: now
        ) == .expiringSoon)
    }

    @Test("New journal writes canonicalize stable provider account identity")
    func newJournalWritesCanonicalProviderIdentity() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let harness = ResetTransportHarness([.transportFailure])
        let service = RateLimitResetService(
            transport: { request in try harness.send(request) },
            journalURL: journalURL
        )
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        var account = Self.account()
        account.accountId = "  Provider-New\n"

        await #expect(throws: RateLimitResetServiceError.self) {
            try await service.consume(
                for: account,
                bank: Self.bank(now: now, expiresIn: 86_400),
                now: now
            )
        }

        let unresolved = try #require(await service.unresolvedAttempt(
            for: "PROVIDER-NEW"
        ))
        #expect(unresolved.providerAccountId == "provider-new")
        let persisted = try JSONSerialization.jsonObject(
            with: Data(contentsOf: journalURL)
        ) as? [String: Any]
        let attempts = try #require(persisted?["attempts"] as? [[String: Any]])
        #expect(attempts.first?["providerAccountId"] as? String == "provider-new")
    }

    @Test("Journal persists manual redemption intent")
    func journalPersistsManualRedemptionIntent() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let harness = ResetTransportHarness([.transportFailure])
        let service = RateLimitResetService(
            transport: { request in try harness.send(request) },
            journalURL: journalURL
        )
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))

        await #expect(throws: RateLimitResetServiceError.self) {
            try await service.consume(
                for: Self.account(),
                bank: Self.bank(now: now, expiresIn: 86_400),
                now: now,
                redemptionReason: .manual
            )
        }

        let attempt = try #require(await service.allAttempts().first)
        #expect(attempt.redemptionReason == .manual)
    }

    @Test("Legacy attempts without redemption reason decode safely")
    func legacyAttemptWithoutRedemptionReasonDecodes() throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let attempt = RateLimitResetAttempt(
            id: UUID(),
            providerAccountId: "provider-legacy",
            creditId: "credit-legacy",
            startingAvailableCount: 1,
            startingBankFetchedAt: now,
            startingQuotaFetchedAt: now,
            createdAt: now,
            submittedAt: now,
            state: .reconciling,
            consumeResponseCode: "reset",
            updatedAt: now
        )
        let encoded = try JSONEncoder().encode(attempt)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["redemptionReason"] == nil)

        let decoded = try JSONDecoder().decode(RateLimitResetAttempt.self, from: encoded)
        #expect(decoded.redemptionReason == nil)
        #expect(decoded.creditExpiresAt == nil)
        #expect(decoded.routineSwapSuppressionReleasedAt == nil)
    }

    @Test("Malformed reset journal is unreadable rather than empty")
    func malformedResetJournalFailsClosed() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let transaction = SecureAtomicFileTransaction(
            path: journalURL.path,
            subject: "malformed reset journal test"
        )
        try transaction.withExclusiveLock { lockedFile in
            let current = try lockedFile.read()
            _ = try lockedFile.replace(
                Data("not-json".utf8),
                expectedGeneration: current.generation
            )
        }
        let service = RateLimitResetService(
            transport: { _ in throw ResetTransportFailure() },
            journalURL: journalURL
        )

        await #expect(throws: RateLimitResetServiceError.self) {
            _ = try await service.allAttempts()
        }
    }

    @Test("Unreleased manual route suppression is exempt from terminal pruning")
    func unreleasedManualSuppressionSurvivesPruning() throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-(31 * 24 * 60 * 60))
        let protected = RateLimitResetAttempt(
            id: UUID(),
            providerAccountId: "provider-protected",
            creditId: "credit-protected",
            startingAvailableCount: 1,
            startingBankFetchedAt: old,
            startingQuotaFetchedAt: old,
            creditExpiresAt: old.addingTimeInterval(3_600),
            redemptionReason: .manual,
            createdAt: old,
            submittedAt: old,
            state: .succeeded,
            consumeResponseCode: "reset",
            updatedAt: old
        )
        let released = RateLimitResetAttempt(
            id: UUID(),
            providerAccountId: "provider-released",
            creditId: "credit-released",
            startingAvailableCount: 1,
            startingBankFetchedAt: old,
            startingQuotaFetchedAt: old,
            creditExpiresAt: old.addingTimeInterval(3_600),
            redemptionReason: .manual,
            createdAt: old,
            submittedAt: old,
            state: .succeeded,
            consumeResponseCode: "reset",
            routineSwapSuppressionReleasedAt: old.addingTimeInterval(1),
            updatedAt: old.addingTimeInterval(1)
        )
        let transaction = SecureAtomicFileTransaction(
            path: journalURL.path,
            subject: "manual suppression prune test"
        )
        let data = try JSONEncoder().encode(LegacyResetJournalEnvelope(
            version: RateLimitResetAttemptJournal.version,
            attempts: [protected, released]
        ))
        try transaction.withExclusiveLock { lockedFile in
            let current = try lockedFile.read()
            _ = try lockedFile.replace(data, expectedGeneration: current.generation)
        }
        var journal = RateLimitResetAttemptJournal(url: journalURL)
        let current = RateLimitResetAttempt(
            id: UUID(),
            providerAccountId: "provider-current",
            creditId: "credit-current",
            startingAvailableCount: 1,
            startingBankFetchedAt: now,
            startingQuotaFetchedAt: now,
            creditExpiresAt: now.addingTimeInterval(3_600),
            createdAt: now,
            submittedAt: nil,
            state: .prepared,
            consumeResponseCode: nil,
            updatedAt: now
        )

        try journal.prepare(current, now: now)
        let attempts = try journal.allAttempts()

        #expect(attempts.contains(where: { $0.id == protected.id }))
        #expect(!attempts.contains(where: { $0.id == released.id }))
        #expect(attempts.contains(where: { $0.id == current.id }))
    }

    @Test("Consume rejects incomplete runtime credentials before journal or transport")
    func consumeRejectsIncompleteRuntimeCredentials() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let harness = ResetTransportHarness([
            .response(RateLimitResetHTTPResponse(
                statusCode: 200,
                data: Data("{\"code\":\"reset\"}".utf8)
            )),
        ])
        let service = RateLimitResetService(
            transport: { request in try harness.send(request) },
            journalURL: journalURL
        )
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        var account = Self.account()
        account.refreshToken = " "

        await #expect(throws: RateLimitResetServiceError.submissionUnauthorized) {
            try await service.consume(
                for: account,
                bank: Self.bank(now: now, expiresIn: 86_400),
                now: now
            )
        }
        #expect(harness.requestBodies().isEmpty)
        #expect(try await service.allAttempts().isEmpty)
    }

    @Test("Legacy journal identity variants block a parallel reset owner")
    func legacyJournalIdentityVariantsRemainOneOwner() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let legacyAttempt = RateLimitResetAttempt(
            id: UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!,
            providerAccountId: "  Provider-Legacy\n",
            creditId: "credit-legacy",
            startingAvailableCount: 1,
            startingBankFetchedAt: now,
            startingQuotaFetchedAt: now,
            createdAt: now,
            submittedAt: now,
            state: .reconciling,
            consumeResponseCode: "reset",
            updatedAt: now
        )
        let legacyData = try JSONEncoder().encode(LegacyResetJournalEnvelope(
            version: RateLimitResetAttemptJournal.version,
            attempts: [legacyAttempt]
        ))
        let transaction = SecureAtomicFileTransaction(
            path: journalURL.path,
            subject: "legacy reset journal test"
        )
        try transaction.withExclusiveLock { lockedFile in
            let current = try lockedFile.read()
            _ = try lockedFile.replace(
                legacyData,
                expectedGeneration: current.generation
            )
        }

        let harness = ResetTransportHarness([])
        let service = RateLimitResetService(
            transport: { request in try harness.send(request) },
            journalURL: journalURL
        )
        let loaded = try #require(await service.unresolvedAttempt(
            for: "provider-legacy"
        ))
        #expect(loaded.id == legacyAttempt.id)
        #expect(loaded.providerAccountId == "provider-legacy")

        var account = Self.account()
        account.accountId = "\tPROVIDER-LEGACY  "
        await #expect(throws: RateLimitResetServiceError.unresolvedAttempt(legacyAttempt.id)) {
            try await service.consume(
                for: account,
                bank: Self.bank(now: now.addingTimeInterval(1), expiresIn: 86_400),
                now: now.addingTimeInterval(1)
            )
        }
        #expect(harness.requestBodies().isEmpty)
    }

    @Test("Transport uncertainty sends exactly one POST and survives restart")
    func transportFailureIsJournaledWithoutRetry() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let harness = ResetTransportHarness([
            .transportFailure,
        ])
        let service = RateLimitResetService(
            transport: { request in try harness.send(request) },
            journalURL: journalURL
        )
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let account = Self.account(snapshot: Self.snapshot(
            fiveHourUsed: 20,
            weeklyUsed: 100,
            now: now
        ))
        let requestId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        await #expect(throws: RateLimitResetServiceError.self) {
            try await service.consume(
                for: account,
                bank: Self.bank(now: now, expiresIn: 86_400),
                now: now,
                redeemRequestId: requestId
            )
        }

        let bodies = harness.requestBodies()
        #expect(bodies.count == 1)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: bodies[0]) as? [String: String]
        )
        #expect(payload["credit_id"] == "credit-1")
        #expect(payload["redeem_request_id"] == "11111111-2222-3333-4444-555555555555")
        let attempt = try #require(await service.unresolvedAttempt(for: account.accountId))
        #expect(attempt.id == requestId)
        #expect(attempt.creditId == "credit-1")
        #expect(attempt.startingAvailableCount == 1)
        #expect(attempt.startingBankFetchedAt == now)
        #expect(attempt.startingQuotaFetchedAt == account.quotaSnapshot?.fetchedAt)
        #expect(attempt.state == .reconciling)

        let restartedHarness = ResetTransportHarness([
            .response(RateLimitResetHTTPResponse(
                statusCode: 200,
                data: Data("{\"code\":\"reset\"}".utf8)
            )),
        ])
        let restarted = RateLimitResetService(
            transport: { request in try restartedHarness.send(request) },
            journalURL: journalURL
        )
        await #expect(throws: RateLimitResetServiceError.unresolvedAttempt(requestId)) {
            try await restarted.consume(
                for: account,
                bank: Self.bank(now: now.addingTimeInterval(60), expiresIn: 86_400),
                now: now.addingTimeInterval(60)
            )
        }
        #expect(restartedHarness.requestBodies().isEmpty)

        let directoryMode = try #require(
            FileManager.default.attributesOfItem(
                atPath: journalURL.deletingLastPathComponent().path
            )[.posixPermissions] as? NSNumber
        ).intValue
        let fileMode = try #require(
            FileManager.default.attributesOfItem(atPath: journalURL.path)[.posixPermissions] as? NSNumber
        ).intValue
        #expect(directoryMode & 0o777 == 0o700)
        #expect(fileMode & 0o777 == 0o600)
    }

    @Test("Expired authorization during final suspension submits no reset POST")
    func finalSubmissionAuthorizationFailsBeforeTransport() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let harness = ResetTransportHarness([
            .response(RateLimitResetHTTPResponse(
                statusCode: 200,
                data: Data("{\"code\":\"reset\"}".utf8)
            )),
        ])
        let service = RateLimitResetService(
            transport: { request in try harness.send(request) },
            journalURL: journalURL
        )
        let gate = ResetSubmissionAuthorizationGate()
        let submissionTracker = ResetSubmissionCallbackCounter()
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let account = Self.account()
        let consume = Task {
            try await service.consume(
                for: account,
                bank: Self.bank(now: now, expiresIn: 86_400),
                now: now,
                authorizeSubmission: { attempt in
                    await gate.waitForDecision()
                        ? authorizedResetSubmissionPermit(for: attempt)
                        : nil
                },
                submissionWillStart: { _ in
                    submissionTracker.record()
                }
            )
        }
        await gate.waitUntilStarted()
        await gate.resume(authorized: false)

        await #expect(throws: RateLimitResetServiceError.submissionUnauthorized) {
            try await consume.value
        }
        #expect(harness.requestBodies().isEmpty)
        #expect(submissionTracker.read() == 0)
        #expect(try await service.unresolvedAttempt(for: account.accountId) == nil)
    }

    @Test("Submission callback runs once after a lease-only manual permit is authorized")
    func submissionCallbackRunsAtTransportBoundary() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let harness = ResetTransportHarness([
            .response(RateLimitResetHTTPResponse(
                statusCode: 200,
                data: Data("{\"code\":\"nothing_to_reset\"}".utf8)
            )),
        ])
        let service = RateLimitResetService(
            transport: { request in try harness.send(request) },
            journalURL: journalURL
        )
        let submissionTracker = ResetSubmissionCallbackCounter()
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))

        let result = try await service.consume(
            for: Self.account(),
            bank: Self.bank(now: now, expiresIn: 86_400),
            now: now,
            authorizeSubmission: { attempt in
                authorizedResetSubmissionPermit(
                    for: attempt,
                    requiredPhase: .committedDegraded,
                    includesRuntimePermit: false,
                    runtimeAuthorizationRequired: false
                )
            },
            submissionWillStart: { _ in
                submissionTracker.record()
            }
        )

        #expect(result == .nothingToReset)
        #expect(submissionTracker.read() == 1)
        #expect(harness.requestBodies().count == 1)
    }

    @Test("Lease-only transport authorization expires after ten seconds")
    func leaseOnlySubmissionPermitHasBoundedLifetime() throws {
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let attempt = RateLimitResetAttempt(
            id: UUID(),
            providerAccountId: "provider-permit-age",
            creditId: "credit-1",
            startingAvailableCount: 1,
            startingBankFetchedAt: issuedAt,
            startingQuotaFetchedAt: issuedAt,
            createdAt: issuedAt,
            submittedAt: issuedAt,
            state: .submitted,
            consumeResponseCode: nil,
            updatedAt: issuedAt
        )
        let permit = authorizedResetSubmissionPermit(
            for: attempt,
            requiredPhase: .committedDegraded,
            includesRuntimePermit: false,
            runtimeAuthorizationRequired: false,
            issuedAt: issuedAt
        )

        #expect(permit.matches(attempt, at: issuedAt.addingTimeInterval(9.999)))
        #expect(!permit.matches(
            attempt,
            at: issuedAt.addingTimeInterval(
                RateLimitResetSubmissionPermit.transportAuthorizationLifetime
            )
        ))
    }

    @Test("Final journal readback must exactly equal the submitted attempt")
    func finalJournalReadbackRejectsTimestampMutation() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let harness = ResetTransportHarness([
            .response(RateLimitResetHTTPResponse(
                statusCode: 200,
                data: Data("{\"code\":\"reset\"}".utf8)
            )),
        ])
        let callback = ResetSubmissionCallbackCounter()
        let service = RateLimitResetService(
            transport: { request in try harness.send(request) },
            journalURL: journalURL
        )
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))

        await #expect(throws: RateLimitResetServiceError.submissionUnauthorized) {
            try await service.consume(
                for: Self.account(),
                bank: Self.bank(now: now, expiresIn: 86_400),
                now: now,
                authorizeSubmission: { submittedAttempt in
                    var competingJournal = RateLimitResetAttemptJournal(url: journalURL)
                    _ = try? competingJournal.markSubmitted(
                        id: submittedAttempt.id,
                        at: now.addingTimeInterval(1)
                    )
                    return authorizedResetSubmissionPermit(for: submittedAttempt)
                },
                submissionWillStart: { _ in callback.record() }
            )
        }

        #expect(callback.read() == 0)
        #expect(harness.requestBodies().isEmpty)
        #expect(try await service.unresolvedAttempt(for: Self.account().accountId) == nil)
    }

    @Test("A required runtime permit cannot be omitted before reset transport")
    func requiredRuntimePermitFailsClosed() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let harness = ResetTransportHarness([
            .response(RateLimitResetHTTPResponse(
                statusCode: 200,
                data: Data("{\"code\":\"reset\"}".utf8)
            )),
        ])
        let service = RateLimitResetService(
            transport: { request in try harness.send(request) },
            journalURL: journalURL
        )
        let submissionTracker = ResetSubmissionCallbackCounter()
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))

        await #expect(throws: RateLimitResetServiceError.submissionUnauthorized) {
            try await service.consume(
                for: Self.account(),
                bank: Self.bank(now: now, expiresIn: 86_400),
                now: now,
                authorizeSubmission: { attempt in
                    authorizedResetSubmissionPermit(
                        for: attempt,
                        includesRuntimePermit: false
                    )
                },
                submissionWillStart: { _ in
                    submissionTracker.record()
                }
            )
        }

        #expect(submissionTracker.read() == 0)
        #expect(harness.requestBodies().isEmpty)
    }

    @Test(arguments: [500, 503])
    func serverFailuresRemainUnresolved(statusCode: Int) async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let harness = ResetTransportHarness([
            .response(RateLimitResetHTTPResponse(statusCode: statusCode, data: Data())),
        ])
        let service = RateLimitResetService(
            transport: { request in try harness.send(request) },
            journalURL: journalURL
        )
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let account = Self.account()

        await #expect(throws: RateLimitResetServiceError.httpError(statusCode)) {
            try await service.consume(
                for: account,
                bank: Self.bank(now: now, expiresIn: 86_400),
                now: now
            )
        }
        #expect(harness.requestBodies().count == 1)
        #expect(try await service.unresolvedAttempt(for: account.accountId)?.state == .reconciling)
    }

    @Test("Malformed consume response remains unresolved")
    func malformedConsumeResponseRemainsUnresolved() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let harness = ResetTransportHarness([
            .response(RateLimitResetHTTPResponse(statusCode: 200, data: Data("{}".utf8))),
        ])
        let service = RateLimitResetService(
            transport: { request in try harness.send(request) },
            journalURL: journalURL
        )
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let account = Self.account()

        await #expect(throws: RateLimitResetServiceError.malformedConsumeResponse) {
            try await service.consume(
                for: account,
                bank: Self.bank(now: now, expiresIn: 86_400),
                now: now
            )
        }
        #expect(harness.requestBodies().count == 1)
        #expect(try await service.unresolvedAttempt(for: account.accountId)?.state == .reconciling)
    }

    @Test(arguments: [
        ("no_credit", RateLimitResetConsumeResult.noCredit),
        ("nothing_to_reset", RateLimitResetConsumeResult.nothingToReset),
    ])
    func explicitNonConsumptionIsTerminal(
        code: String,
        expected: RateLimitResetConsumeResult
    ) async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let service = RateLimitResetService(
            transport: { _ in
                RateLimitResetHTTPResponse(
                    statusCode: 200,
                    data: Data("{\"code\":\"\(code)\"}".utf8)
                )
            },
            journalURL: journalURL
        )
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let account = Self.account()

        let result = try await service.consume(
            for: account,
            bank: Self.bank(now: now, expiresIn: 86_400),
            now: now
        )

        #expect(result == expected)
        #expect(try await service.unresolvedAttempt(for: account.accountId) == nil)
        #expect(try await service.allAttempts().last?.state == .notApplied)
    }

    @Test("Reset response requires delayed inventory and quota proof")
    func delayedInventoryReconciliation() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let service = RateLimitResetService(
            transport: { _ in
                RateLimitResetHTTPResponse(
                    statusCode: 200,
                    data: Data("{\"code\":\"reset\"}".utf8)
                )
            },
            journalURL: journalURL
        )
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let exhausted = Self.snapshot(fiveHourUsed: 20, weeklyUsed: 100, now: now.addingTimeInterval(-60))
        let account = Self.account(snapshot: exhausted)
        let result = try await service.consume(
            for: account,
            bank: Self.bank(now: now, expiresIn: 86_400),
            now: now
        )
        guard case .reconciliationRequired(let attemptId) = result else {
            Issue.record("Expected reconciliation-required consume result")
            return
        }

        let healthyQuota = Self.snapshot(
            fiveHourUsed: 10,
            weeklyUsed: 10,
            now: now.addingTimeInterval(30)
        )
        let delayedBank = Self.bank(now: now.addingTimeInterval(30), expiresIn: 86_400)
        let delayedOutcome = try await service.reconcile(
            for: account,
            bank: delayedBank,
            snapshot: healthyQuota,
            now: now.addingTimeInterval(30)
        )
        guard case .unresolved(let delayedAttempt) = delayedOutcome else {
            Issue.record("Delayed inventory must remain unresolved")
            return
        }
        #expect(delayedAttempt.id == attemptId)

        let missingWithoutDecrease = RateLimitResetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [],
            fetchedAt: now.addingTimeInterval(60)
        )
        guard case .unresolved = try await service.reconcile(
            for: account,
            bank: missingWithoutDecrease,
            snapshot: healthyQuota,
            now: now.addingTimeInterval(60)
        ) else {
            Issue.record("Missing credit without a count decrease must remain unresolved")
            return
        }

        let consumedBank = RateLimitResetBank(
            availableCount: 0,
            totalEarnedCount: 1,
            credits: [],
            fetchedAt: now.addingTimeInterval(90)
        )
        guard case .unresolved = try await service.reconcile(
            for: account,
            bank: consumedBank,
            snapshot: Self.snapshot(
                fiveHourUsed: 20,
                weeklyUsed: 100,
                now: now.addingTimeInterval(90)
            ),
            now: now.addingTimeInterval(90)
        ) else {
            Issue.record("Inventory proof without usable quota must remain unresolved")
            return
        }

        let pendingPersistence = try await service.reconcile(
            for: account,
            bank: consumedBank,
            snapshot: Self.snapshot(
                fiveHourUsed: 10,
                weeklyUsed: 10,
                now: now.addingTimeInterval(120)
            ),
            now: now.addingTimeInterval(120)
        )

        guard case .pendingPersistence(let attempt) = pendingPersistence else {
            Issue.record("Expected proven reconciliation to await account persistence")
            return
        }
        #expect(attempt.id == attemptId)
        #expect(attempt.state == .pendingPersistence)
        #expect(try await service.unresolvedAttempt(for: account.accountId)?.id == attemptId)

        let succeeded = try await service.finalizeReconciliationAfterPersistence(
            attemptId: attemptId,
            now: now.addingTimeInterval(121)
        )
        #expect(succeeded.state == .succeeded)
        #expect(try await service.unresolvedAttempt(for: account.accountId) == nil)
    }

    @Test("Selected credit expiration cannot prove reset consumption")
    func selectedCreditExpirationRemainsUnresolved() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let service = RateLimitResetService(
            transport: { _ in
                RateLimitResetHTTPResponse(
                    statusCode: 200,
                    data: Data("{\"code\":\"reset\"}".utf8)
                )
            },
            journalURL: journalURL
        )
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let account = Self.account(snapshot: Self.snapshot(
            fiveHourUsed: 20,
            weeklyUsed: 100,
            now: now
        ))
        _ = try await service.consume(
            for: account,
            bank: Self.bank(now: now, expiresIn: 10),
            now: now
        )
        let observedAt = now.addingTimeInterval(20)
        let expiredBank = RateLimitResetBank(
            availableCount: 0,
            totalEarnedCount: 1,
            credits: [],
            fetchedAt: observedAt
        )

        let outcome = try await service.reconcile(
            for: account,
            bank: expiredBank,
            snapshot: Self.snapshot(
                fiveHourUsed: 10,
                weeklyUsed: 10,
                now: observedAt
            ),
            now: observedAt
        )

        guard case .unresolved(let attempt) = outcome else {
            Issue.record("Natural expiration must not finalize the reset attempt")
            return
        }
        #expect(attempt.creditExpiresAt == now.addingTimeInterval(10))
    }

    @Test("Successful activation release is durable in the reset journal")
    func manualSwapSuppressionReleasePersists() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let service = RateLimitResetService(
            transport: { _ in
                RateLimitResetHTTPResponse(
                    statusCode: 200,
                    data: Data("{\"code\":\"reset\"}".utf8)
                )
            },
            journalURL: journalURL
        )
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let account = Self.account(snapshot: Self.snapshot(
            fiveHourUsed: 20,
            weeklyUsed: 100,
            now: now
        ))
        let result = try await service.consume(
            for: account,
            bank: Self.bank(now: now, expiresIn: 86_400),
            now: now,
            redemptionReason: .manual
        )
        guard case .reconciliationRequired(let attemptId) = result else {
            Issue.record("Expected a reconciliation-required manual reset")
            return
        }
        let observedAt = now.addingTimeInterval(30)
        let consumedBank = RateLimitResetBank(
            availableCount: 0,
            totalEarnedCount: 1,
            credits: [],
            fetchedAt: observedAt
        )
        guard case .pendingPersistence = try await service.reconcile(
            for: account,
            bank: consumedBank,
            snapshot: Self.snapshot(
                fiveHourUsed: 10,
                weeklyUsed: 10,
                now: observedAt
            ),
            now: observedAt
        ) else {
            Issue.record("Expected the manual reset to await persistence")
            return
        }
        _ = try await service.finalizeReconciliationAfterPersistence(
            attemptId: attemptId,
            now: observedAt
        )

        let didRelease = try await service.releaseManualSwapSuppression(
            for: account.accountId,
            now: observedAt.addingTimeInterval(1)
        )

        #expect(didRelease)
        let attempts = try await service.allAttempts()
        let released = try #require(attempts.first {
            $0.id == attemptId
        })
        #expect(released.routineSwapSuppressionReleasedAt == observedAt.addingTimeInterval(1))
    }

    @Test("Activation can durably release suppression while reconciliation is pending")
    func pendingManualSwapSuppressionReleasePersists() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let service = RateLimitResetService(
            transport: { _ in throw ResetTransportFailure() },
            journalURL: journalURL
        )
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let account = Self.account()

        await #expect(throws: RateLimitResetServiceError.self) {
            try await service.consume(
                for: account,
                bank: Self.bank(now: now, expiresIn: 86_400),
                now: now,
                redemptionReason: .manual
            )
        }
        let releasedAt = now.addingTimeInterval(1)
        #expect(try await service.releaseManualSwapSuppression(
            for: account.accountId,
            now: releasedAt
        ))

        let attempt = try #require(await service.unresolvedAttempt(
            for: account.accountId
        ))
        #expect(attempt.state == .reconciling)
        #expect(attempt.routineSwapSuppressionReleasedAt == releasedAt)
    }

    @Test("Reconciliation matches consumed credit through normalized identifier")
    func reconciliationNormalizesBankCreditIdentifier() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let account = Self.account(snapshot: Self.snapshot(
            fiveHourUsed: 20,
            weeklyUsed: 100,
            now: now.addingTimeInterval(-60)
        ))
        let harness = ResetTransportHarness([
            .response(RateLimitResetHTTPResponse(
                statusCode: 200,
                data: Data("{\"code\":\"reset\"}".utf8)
            )),
        ])
        let service = RateLimitResetService(
            transport: { request in try harness.send(request) },
            journalURL: journalURL
        )
        let initialBank = RateLimitResetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [
                RateLimitResetCredit(
                    id: "  credit-1\n",
                    resetType: "full",
                    status: "available",
                    grantedAt: now,
                    expiresAt: now.addingTimeInterval(86_400),
                    redeemedAt: nil,
                    title: nil,
                    description: nil
                ),
            ],
            fetchedAt: now
        )

        _ = try await service.consume(for: account, bank: initialBank, now: now)
        let requestBody = try #require(harness.requestBodies().first)
        let requestJSON = try #require(
            try JSONSerialization.jsonObject(with: requestBody) as? [String: String]
        )
        #expect(requestJSON["credit_id"] == "credit-1")
        #expect(try await service.unresolvedAttempt(
            for: account.accountId
        )?.creditId == "credit-1")

        let consumedStatusBank = RateLimitResetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [
                RateLimitResetCredit(
                    id: "\tcredit-1  ",
                    resetType: "full",
                    status: "redeemed",
                    grantedAt: now,
                    expiresAt: now.addingTimeInterval(86_400),
                    redeemedAt: now.addingTimeInterval(60),
                    title: nil,
                    description: nil
                ),
            ],
            fetchedAt: now.addingTimeInterval(60)
        )
        let outcome = try await service.reconcile(
            for: account,
            bank: consumedStatusBank,
            snapshot: Self.snapshot(
                fiveHourUsed: 10,
                weeklyUsed: 10,
                now: now.addingTimeInterval(60)
            ),
            now: now.addingTimeInterval(60)
        )

        guard case .pendingPersistence(let attempt) = outcome else {
            Issue.record("Normalized consumed credit status must prove reconciliation")
            return
        }
        #expect(attempt.creditId == "credit-1")
    }

    @Test("Account persistence failure remains suppressing across restart")
    func accountPersistenceFailureKeepsPendingAttempt() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let account = Self.account(snapshot: Self.snapshot(
            fiveHourUsed: 20,
            weeklyUsed: 100,
            now: now.addingTimeInterval(-60)
        ))
        let service = RateLimitResetService(
            transport: { _ in
                RateLimitResetHTTPResponse(
                    statusCode: 200,
                    data: Data("{\"code\":\"reset\"}".utf8)
                )
            },
            journalURL: journalURL
        )
        let requestId = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        _ = try await service.consume(
            for: account,
            bank: Self.bank(now: now, expiresIn: 86_400),
            now: now,
            redeemRequestId: requestId
        )
        let consumedBank = RateLimitResetBank(
            availableCount: 0,
            totalEarnedCount: 1,
            credits: [],
            fetchedAt: now.addingTimeInterval(60)
        )
        let outcome = try await service.reconcile(
            for: account,
            bank: consumedBank,
            snapshot: Self.snapshot(
                fiveHourUsed: 10,
                weeklyUsed: 10,
                now: now.addingTimeInterval(60)
            ),
            now: now.addingTimeInterval(60)
        )
        guard case .pendingPersistence(let pending) = outcome else {
            Issue.record("Expected pending account persistence")
            return
        }
        #expect(pending.state == .pendingPersistence)

        // AppDelegate leaves this state unfinalized when account persistence fails.
        let restartedHarness = ResetTransportHarness([
            .response(RateLimitResetHTTPResponse(
                statusCode: 200,
                data: Data("{\"code\":\"reset\"}".utf8)
            )),
        ])
        let restarted = RateLimitResetService(
            transport: { request in try restartedHarness.send(request) },
            journalURL: journalURL
        )
        #expect(try await restarted.unresolvedAttempt(
            for: account.accountId
        )?.state == .pendingPersistence)
        await #expect(throws: RateLimitResetServiceError.unresolvedAttempt(requestId)) {
            try await restarted.consume(
                for: account,
                bank: Self.bank(now: now.addingTimeInterval(120), expiresIn: 86_400),
                now: now.addingTimeInterval(120)
            )
        }
        #expect(restartedHarness.requestBodies().isEmpty)

        let retryOutcome = try await restarted.reconcile(
            for: account,
            bank: RateLimitResetBank(
                availableCount: 0,
                totalEarnedCount: 1,
                credits: [],
                fetchedAt: now.addingTimeInterval(180)
            ),
            snapshot: Self.snapshot(
                fiveHourUsed: 10,
                weeklyUsed: 10,
                now: now.addingTimeInterval(180)
            ),
            now: now.addingTimeInterval(180)
        )
        guard case .pendingPersistence(let restartedPending) = retryOutcome else {
            Issue.record("Restarted reconciliation must still await account persistence")
            return
        }
        #expect(restartedPending.id == requestId)

        let finalized = try await restarted.finalizeReconciliationAfterPersistence(
            attemptId: requestId,
            now: now.addingTimeInterval(181)
        )
        #expect(finalized.state == .succeeded)
        #expect(try await restarted.unresolvedAttempt(for: account.accountId) == nil)
    }

    @Test("Success-finalization persistence failure survives restart")
    func finalizationPersistenceFailureRemainsPending() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let account = Self.account(snapshot: Self.snapshot(
            fiveHourUsed: 20,
            weeklyUsed: 100,
            now: now.addingTimeInterval(-60)
        ))
        let service = RateLimitResetService(
            transport: { _ in
                RateLimitResetHTTPResponse(
                    statusCode: 200,
                    data: Data("{\"code\":\"reset\"}".utf8)
                )
            },
            journalURL: journalURL,
            journalTestHooks: .init(beforeCommit: { boundary in
                if boundary == .terminal {
                    throw InjectedJournalFailure()
                }
            })
        )
        let requestId = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        _ = try await service.consume(
            for: account,
            bank: Self.bank(now: now, expiresIn: 86_400),
            now: now,
            redeemRequestId: requestId
        )
        _ = try await service.reconcile(
            for: account,
            bank: RateLimitResetBank(
                availableCount: 0,
                totalEarnedCount: 1,
                credits: [],
                fetchedAt: now.addingTimeInterval(60)
            ),
            snapshot: Self.snapshot(
                fiveHourUsed: 10,
                weeklyUsed: 10,
                now: now.addingTimeInterval(60)
            ),
            now: now.addingTimeInterval(60)
        )

        await #expect(throws: RateLimitResetServiceError.self) {
            try await service.finalizeReconciliationAfterPersistence(
                attemptId: requestId,
                now: now.addingTimeInterval(61)
            )
        }
        #expect(try await service.unresolvedAttempt(
            for: account.accountId
        )?.state == .pendingPersistence)

        let restartedHarness = ResetTransportHarness([
            .response(RateLimitResetHTTPResponse(
                statusCode: 200,
                data: Data("{\"code\":\"reset\"}".utf8)
            )),
        ])
        let restarted = RateLimitResetService(
            transport: { request in try restartedHarness.send(request) },
            journalURL: journalURL
        )
        #expect(try await restarted.unresolvedAttempt(
            for: account.accountId
        )?.state == .pendingPersistence)
        await #expect(throws: RateLimitResetServiceError.unresolvedAttempt(requestId)) {
            try await restarted.consume(
                for: account,
                bank: Self.bank(now: now.addingTimeInterval(120), expiresIn: 86_400),
                now: now.addingTimeInterval(120)
            )
        }
        #expect(restartedHarness.requestBodies().isEmpty)
    }

    @Test("A succeeded credit ID cannot be submitted again")
    func succeededCreditCannotBeReused() async throws {
        let journalURL = Self.temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let account = Self.account(snapshot: Self.snapshot(
            fiveHourUsed: 20,
            weeklyUsed: 100,
            now: now.addingTimeInterval(-60)
        ))
        let harness = ResetTransportHarness([
            .response(RateLimitResetHTTPResponse(
                statusCode: 200,
                data: Data("{\"code\":\"reset\"}".utf8)
            )),
        ])
        let service = RateLimitResetService(
            transport: { request in try harness.send(request) },
            journalURL: journalURL
        )
        let requestId = UUID(uuidString: "44444444-5555-6666-7777-888888888888")!
        _ = try await service.consume(
            for: account,
            bank: Self.bank(now: now, expiresIn: 86_400),
            now: now,
            redeemRequestId: requestId
        )
        _ = try await service.reconcile(
            for: account,
            bank: RateLimitResetBank(
                availableCount: 0,
                totalEarnedCount: 1,
                credits: [],
                fetchedAt: now.addingTimeInterval(60)
            ),
            snapshot: Self.snapshot(
                fiveHourUsed: 10,
                weeklyUsed: 10,
                now: now.addingTimeInterval(60)
            ),
            now: now.addingTimeInterval(60)
        )
        _ = try await service.finalizeReconciliationAfterPersistence(
            attemptId: requestId,
            now: now.addingTimeInterval(61)
        )

        await #expect(throws: RateLimitResetServiceError.creditAlreadySucceeded("credit-1")) {
            try await service.consume(
                for: account,
                bank: Self.bank(now: now.addingTimeInterval(120), expiresIn: 86_400),
                now: now.addingTimeInterval(120)
            )
        }
        #expect(harness.requestBodies().count == 1)
    }

    @Test("Journal failures preserve the last proven pre-POST state")
    func journalPhaseFailuresNeverDuplicateSpend() async throws {
        let now = try #require(Self.isoDate("2026-07-12T12:00:00Z"))
        let account = Self.account(snapshot: Self.snapshot(
            fiveHourUsed: 20,
            weeklyUsed: 100,
            now: now
        ))
        let cases: [(
            boundary: RateLimitResetAttemptJournal.PersistenceBoundary,
            expectedPosts: Int,
            expectedState: RateLimitResetAttemptState?
        )] = [
            (.prepared, 0, nil),
            (.submitted, 0, .prepared),
            (.reconciling, 1, .submitted),
        ]

        for testCase in cases {
            let journalURL = Self.temporaryJournalURL()
            defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
            let harness = ResetTransportHarness([
                .response(RateLimitResetHTTPResponse(
                    statusCode: 200,
                    data: Data("{\"code\":\"reset\"}".utf8)
                )),
            ])
            let service = RateLimitResetService(
                transport: { request in try harness.send(request) },
                journalURL: journalURL,
                journalTestHooks: .init(beforeCommit: { boundary in
                    if boundary == testCase.boundary {
                        throw InjectedJournalFailure()
                    }
                })
            )

            await #expect(throws: RateLimitResetServiceError.self) {
                try await service.consume(
                    for: account,
                    bank: Self.bank(now: now, expiresIn: 86_400),
                    now: now
                )
            }
            #expect(harness.requestBodies().count == testCase.expectedPosts)
            #expect(try await service.allAttempts().last?.state == testCase.expectedState)

            let restartedHarness = ResetTransportHarness([])
            let restarted = RateLimitResetService(
                transport: { request in try restartedHarness.send(request) },
                journalURL: journalURL
            )
            #expect(try await restarted.allAttempts().last?.state == testCase.expectedState)
            if testCase.expectedState != nil {
                await #expect(throws: RateLimitResetServiceError.self) {
                    try await restarted.consume(
                        for: account,
                        bank: Self.bank(now: now.addingTimeInterval(1), expiresIn: 86_400),
                        now: now.addingTimeInterval(1)
                    )
                }
                #expect(restartedHarness.requestBodies().isEmpty)
            }
        }
    }

    @Test("Reset journal flock excludes a true independent process")
    func resetJournalLockExcludesIndependentProcesses() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let role = environment["CODEXSWITCH_RESET_LOCK_ROLE"] {
            try await Self.runResetLockChild(role: role, environment: environment)
            return
        }

        let journalURL = Self.temporaryJournalURL()
        let directory = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("holder-ready")
        let release = directory.appendingPathComponent("holder-release")
        let contenderStarted = directory.appendingPathComponent("contender-started")
        let holderPost = directory.appendingPathComponent("holder-post")
        let contenderPost = directory.appendingPathComponent("contender-post")
        let common = [
            "CODEXSWITCH_RESET_JOURNAL_PATH": journalURL.path,
            "CODEXSWITCH_RESET_READY_PATH": ready.path,
            "CODEXSWITCH_RESET_RELEASE_PATH": release.path,
            "CODEXSWITCH_RESET_CONTENDER_STARTED_PATH": contenderStarted.path,
            "CODEXSWITCH_RESET_HOLDER_POST_PATH": holderPost.path,
            "CODEXSWITCH_RESET_CONTENDER_POST_PATH": contenderPost.path,
        ]

        let holder = try Self.startResetLockChild(role: "holder", commonEnvironment: common)
        guard await Self.waitForFile(ready, timeout: 5) else {
            let result = await Self.waitForProcess(holder, timeout: 1)
            Issue.record("Holder did not acquire the reset journal lock: \(result.output)")
            return
        }
        let contender = try Self.startResetLockChild(role: "contender", commonEnvironment: common)
        guard await Self.waitForFile(contenderStarted, timeout: 5) else {
            holder.terminate()
            contender.terminate()
            Issue.record("Contender did not start")
            return
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: contenderPost.path))
        try Data().write(to: release)

        let holderResult = await Self.waitForProcess(holder, timeout: 8)
        let contenderResult = await Self.waitForProcess(contender, timeout: 8)
        #expect(holderResult.status == 0, Comment(rawValue: holderResult.output))
        #expect(contenderResult.status == 0, Comment(rawValue: contenderResult.output))
        #expect(FileManager.default.fileExists(atPath: holderPost.path))
        #expect(!FileManager.default.fileExists(atPath: contenderPost.path))
    }

    private static func runResetLockChild(
        role: String,
        environment: [String: String]
    ) async throws {
        let journalURL = URL(fileURLWithPath: try #require(
            environment["CODEXSWITCH_RESET_JOURNAL_PATH"]
        ))
        let now = try #require(isoDate("2026-07-12T12:00:00Z"))
        let account = account(snapshot: snapshot(
            fiveHourUsed: 20,
            weeklyUsed: 100,
            now: now
        ))

        switch role {
        case "holder":
            let gate = ResetLockGate(
                readyPath: try #require(environment["CODEXSWITCH_RESET_READY_PATH"]),
                releasePath: try #require(environment["CODEXSWITCH_RESET_RELEASE_PATH"])
            )
            let postPath = try #require(environment["CODEXSWITCH_RESET_HOLDER_POST_PATH"])
            let service = RateLimitResetService(
                transport: { _ in
                    try Data().write(to: URL(fileURLWithPath: postPath))
                    return RateLimitResetHTTPResponse(
                        statusCode: 200,
                        data: Data("{\"code\":\"reset\"}".utf8)
                    )
                },
                journalURL: journalURL,
                journalTestHooks: .init(transaction: .init(afterLock: {
                    try gate.enter()
                }))
            )
            _ = try await service.consume(
                for: account,
                bank: bank(now: now, expiresIn: 86_400),
                now: now
            )
        case "contender":
            let startedPath = try #require(
                environment["CODEXSWITCH_RESET_CONTENDER_STARTED_PATH"]
            )
            try Data().write(to: URL(fileURLWithPath: startedPath))
            let postPath = try #require(environment["CODEXSWITCH_RESET_CONTENDER_POST_PATH"])
            let service = RateLimitResetService(
                transport: { _ in
                    try Data().write(to: URL(fileURLWithPath: postPath))
                    return RateLimitResetHTTPResponse(
                        statusCode: 200,
                        data: Data("{\"code\":\"reset\"}".utf8)
                    )
                },
                journalURL: journalURL
            )
            await #expect(throws: RateLimitResetServiceError.self) {
                try await service.consume(
                    for: account,
                    bank: bank(now: now, expiresIn: 86_400),
                    now: now
                )
            }
        default:
            Issue.record("Unknown reset lock child role: \(role)")
        }
    }

    private static func startResetLockChild(
        role: String,
        commonEnvironment: [String: String]
    ) throws -> Process {
        let process = Process()
        let output = Pipe()
        try configureSwiftTestingSubprocess(
            process,
            filter: "resetJournalLockExcludesIndependentProcesses"
        )
        var environment = ProcessInfo.processInfo.environment
        commonEnvironment.forEach { environment[$0.key] = $0.value }
        environment["CODEXSWITCH_RESET_LOCK_ROLE"] = role
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return process
    }

    private static func waitForFile(_ url: URL, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private static func waitForProcess(
        _ process: Process,
        timeout: TimeInterval
    ) async -> (status: Int32, output: String) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning {
            process.terminate()
            while process.isRunning {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let pipe = process.standardOutput as? Pipe
        let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func account(
        email: String = "active@example.com",
        snapshot: QuotaSnapshot? = nil,
        planType: String = "pro"
    ) -> CodexAccount {
        CodexAccount(
            email: email,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: "id-token",
            accountId: "account-id-\(email)",
            quotaSnapshot: snapshot,
            planType: planType,
            isActive: email == "active@example.com"
        )
    }

    private static func snapshot(
        fiveHourUsed: Double,
        weeklyUsed: Double,
        now: Date,
        fiveHourResetAfter: TimeInterval = 5 * 60 * 60,
        weeklyResetAfter: TimeInterval = 7 * 86_400
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: fiveHourUsed,
                windowDurationMins: 300,
                resetsAt: now.addingTimeInterval(fiveHourResetAfter),
                hardLimitReached: fiveHourUsed >= 100
            ),
            weekly: QuotaWindow(
                usedPercent: weeklyUsed,
                windowDurationMins: 10_080,
                resetsAt: now.addingTimeInterval(weeklyResetAfter),
                hardLimitReached: weeklyUsed >= 100
            ),
            fetchedAt: now
        )
    }

    private static func weeklyOnlySnapshot(
        used: Double,
        now: Date,
        resetAfter: TimeInterval
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: now,
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 604_800,
                    usedPercent: used,
                    resetsAt: now.addingTimeInterval(resetAfter),
                    source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                ),
            ]
        )
    }

    private static func bank(now: Date, expiresIn: TimeInterval) -> RateLimitResetBank {
        RateLimitResetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [
                RateLimitResetCredit(
                    id: "credit-1",
                    resetType: "full",
                    status: "available",
                    grantedAt: now,
                    expiresAt: now.addingTimeInterval(expiresIn),
                    redeemedAt: nil,
                    title: "Full reset (Weekly + 5 hr)",
                    description: nil
                ),
            ],
            fetchedAt: now
        )
    }

    private static func isoDate(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    private static func temporaryJournalURL() -> URL {
        makeSecureTestFileURL(
            prefix: "codexswitch-reset-journal",
            fileName: "reset-attempts.json"
        )
    }
}

private struct LegacyResetJournalEnvelope: Codable {
    let version: Int
    let attempts: [RateLimitResetAttempt]
}

private struct InjectedJournalFailure: Error {}

private actor ResetSubmissionAuthorizationGate {
    private var decisionContinuation: CheckedContinuation<Bool, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func waitForDecision() async -> Bool {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        return await withCheckedContinuation { decisionContinuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resume(authorized: Bool) {
        decisionContinuation?.resume(returning: authorized)
        decisionContinuation = nil
    }
}

private final class ResetSubmissionCallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.withLock { count += 1 }
    }

    func read() -> Int {
        lock.withLock { count }
    }
}

private final class ResetLockGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entryCount = 0
    private let readyPath: String
    private let releasePath: String

    init(readyPath: String, releasePath: String) {
        self.readyPath = readyPath
        self.releasePath = releasePath
    }

    func enter() throws {
        let shouldBlock = lock.withLock { () -> Bool in
            entryCount += 1
            return entryCount == 2
        }
        guard shouldBlock else { return }
        try Data().write(to: URL(fileURLWithPath: readyPath))
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: releasePath), Date() < deadline {
            usleep(10_000)
        }
        guard FileManager.default.fileExists(atPath: releasePath) else {
            throw InjectedJournalFailure()
        }
    }
}

private enum ResetTransportStep: Sendable {
    case transportFailure
    case response(RateLimitResetHTTPResponse)
}

private struct ResetTransportFailure: Error {}

private final class ResetTransportHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [ResetTransportStep]
    private var bodies: [Data] = []

    init(_ steps: [ResetTransportStep]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) throws -> RateLimitResetHTTPResponse {
        try lock.withLock {
            bodies.append(request.httpBody ?? Data())
            guard !steps.isEmpty else { throw ResetTransportFailure() }
            switch steps.removeFirst() {
            case .transportFailure:
                throw ResetTransportFailure()
            case .response(let response):
                return response
            }
        }
    }

    func requestBodies() -> [Data] {
        lock.withLock { bodies }
    }
}
