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

        let bank = try await service.fetchBank(for: Self.account(), force: true, now: now)

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
                }
            )
        }
        await gate.waitUntilStarted()
        await gate.resume(authorized: false)

        await #expect(throws: RateLimitResetServiceError.submissionUnauthorized) {
            try await consume.value
        }
        #expect(harness.requestBodies().isEmpty)
        #expect(try await service.unresolvedAttempt(for: account.accountId) == nil)
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
