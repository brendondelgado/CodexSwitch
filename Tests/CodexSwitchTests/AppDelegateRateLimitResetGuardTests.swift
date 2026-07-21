import Foundation
import Testing
@testable import CodexSwitch

private final class ResetTransportCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func record() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@Suite("AppDelegate rate-limit reset guard")
struct AppDelegateRateLimitResetGuardTests {
    @Test("A same-generation phase demotion revokes the reset permit before POST")
    func resetSubmissionRevalidatesPhaseImmediatelyBeforeTransport() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let activationGeneration = UUID()
        let account = Self.makeResetAccount()
        let activationURL = makeSecureTestFileURL(
            prefix: "codexswitch-reset-activation",
            fileName: "activation.json"
        )
        let resetURL = makeSecureTestFileURL(
            prefix: "codexswitch-reset-journal",
            fileName: "reset.json"
        )
        defer {
            try? FileManager.default.removeItem(at: activationURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: resetURL.deletingLastPathComponent())
        }

        let coordinator = AccountActivationCoordinator(url: activationURL)
        _ = try await coordinator.beginPreparing(
            targetAccountId: account.id,
            kind: .automatic,
            requestedActivationGeneration: activationGeneration,
            at: now
        )
        _ = try await coordinator.markCommittedDegraded(
            targetAccountId: account.id,
            expectedActivationGeneration: activationGeneration,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            detail: .runtimeConfirmationPending,
            at: now
        )
        let evidence = AccountActivationRuntimeEvidence(
            generation: UUID(),
            runtimeCurrentAccountId: account.id,
            observedAt: now,
            expiresAt: now.addingTimeInterval(60),
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1
        )
        _ = try await coordinator.markConfirmed(
            targetAccountId: account.id,
            expectedActivationGeneration: activationGeneration,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            evidenceGeneration: evidence.generation,
            evidenceObservedAt: evidence.observedAt,
            evidenceExpiresAt: evidence.expiresAt,
            at: now
        )
        let runtimePermit = AccountActivationRuntimePermit(
            targetAccountId: account.id,
            activationGeneration: activationGeneration,
            requiredPhase: .confirmed,
            evidence: evidence
        )
        let transportCalls = ResetTransportCounter()
        let service = RateLimitResetService(
            transport: { _ in
                transportCalls.record()
                return RateLimitResetHTTPResponse(statusCode: 200, data: Data())
            },
            journalURL: resetURL
        )
        let transaction = AccountActivationTransaction()

        let submissionWasDenied = try await transaction.withResetLease(
            accountId: account.id,
            activationGeneration: activationGeneration
        ) { lease in
            let effectPermit = try #require(transaction.makeEffectPermit(
                lease: lease,
                targetAccountId: account.id,
                activationGeneration: activationGeneration,
                requiredPhase: .confirmed,
                runtimePermit: runtimePermit,
                journal: coordinator,
                at: now
            ))
            do {
                _ = try await service.consume(
                    for: account,
                    bank: Self.makeResetBank(now: now),
                    now: now,
                    authorizeSubmission: { attempt in
                        _ = try? await coordinator.demoteForRuntimeEvidenceLoss(
                            targetAccountId: account.id,
                            expectedActivationGeneration: activationGeneration,
                            detail: .runtimeEvidenceExpired,
                            at: now.addingTimeInterval(1)
                        )
                        return RateLimitResetSubmissionPermit(
                            attemptId: attempt.id,
                            providerAccountId: attempt.providerAccountId,
                            creditId: attempt.creditId,
                            targetAccountId: account.id,
                            activationGeneration: activationGeneration,
                            leaseGeneration: lease.generation,
                            runtimePermit: runtimePermit,
                            activationEffectPermit: effectPermit,
                            issuedAt: now.addingTimeInterval(1)
                        )
                    }
                )
                return false
            } catch RateLimitResetServiceError.submissionUnauthorized {
                return true
            }
        }

        #expect(submissionWasDenied == true)
        #expect(transportCalls.read() == 0)
    }

    @Test("Preflight inventory loss is external and cannot become a new authorization baseline")
    func preflightInventoryLossCannotRebaseAuthorization() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = Self.makeResetBank(
            now: now,
            creditIds: ["credit-1", "credit-2", "credit-3"]
        )
        let refreshed = Self.removingCredits(
            ["credit-1"],
            from: initial,
            fetchedAt: now.addingTimeInterval(1)
        )
        let transition = RateLimitResetInventoryTransition.classify(
            previousBank: initial,
            refreshedBank: refreshed,
            localExpectation: nil,
            observedProviderAccountId: "provider-account-1",
            now: now
        )

        #expect(transition.disposition == .externalRedemption)
        #expect(!AppDelegate.rateLimitResetAvailableInventoryMatches(
            initial,
            refreshed,
            at: now
        ))
        let blockedUntil = now.addingTimeInterval(
            AppDelegate.externalRateLimitResetRedemptionCooldown
        )
        #expect(AppDelegate.rateLimitResetRedemptionIsBlocked(until: blockedUntil, at: now))
        #expect(!AppDelegate.rateLimitResetRedemptionIsBlocked(
            until: blockedUntil,
            at: now.addingTimeInterval(900)
        ))
    }

    @Test("A local expectation explains exactly one selected-credit decrement")
    func localSubmissionExplainsOnlyOneExactDecrement() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = Self.makeResetBank(
            now: now,
            creditIds: ["credit-1", "credit-2", "credit-3"]
        )
        let attempt = Self.makeAttempt(bank: initial, now: now)
        let expectedLocalBank = Self.removingCredits(
            ["credit-1"],
            from: initial,
            fetchedAt: now.addingTimeInterval(1)
        )
        let local = RateLimitResetInventoryTransition.classify(
            previousBank: initial,
            refreshedBank: expectedLocalBank,
            localExpectation: RateLimitResetSubmissionExpectation(attempt: attempt),
            observedProviderAccountId: "provider-account-1",
            now: now
        )

        #expect(local.disposition == .expectedLocalDecrement)
        #expect(local.updatedExpectation?.attemptId == attempt.id)
        #expect(local.updatedExpectation?.explainedExpectedDecrement == true)

        let additionalDrop = RateLimitResetInventoryTransition.classify(
            previousBank: expectedLocalBank,
            refreshedBank: Self.removingCredits(
                ["credit-2"],
                from: expectedLocalBank,
                fetchedAt: now.addingTimeInterval(2)
            ),
            localExpectation: local.updatedExpectation,
            observedProviderAccountId: "provider-account-1",
            now: now
        )
        #expect(additionalDrop.disposition == .externalRedemption)
    }

    @Test("A naturally expired credit is inventory churn, not an external redemption")
    func naturalCreditExpirationIsNotExternalRedemption() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiring = RateLimitResetCredit(
            id: "credit-expiring",
            resetType: "weekly",
            status: "available",
            grantedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(10),
            redeemedAt: nil,
            title: nil,
            description: nil
        )
        let retained = RateLimitResetCredit(
            id: "credit-retained",
            resetType: "weekly",
            status: "available",
            grantedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(3_600),
            redeemedAt: nil,
            title: nil,
            description: nil
        )
        let previous = RateLimitResetBank(
            availableCount: 2,
            totalEarnedCount: 2,
            credits: [expiring, retained],
            fetchedAt: now
        )
        let observedAt = now.addingTimeInterval(20)
        let refreshed = RateLimitResetBank(
            availableCount: 1,
            totalEarnedCount: 2,
            credits: [retained],
            fetchedAt: observedAt
        )

        let transition = RateLimitResetInventoryTransition.classify(
            previousBank: previous,
            refreshedBank: refreshed,
            localExpectation: nil,
            observedProviderAccountId: "provider-account-1",
            now: observedAt
        )

        #expect(transition.disposition == .changedWithoutRedemption)
        #expect(!transition.observedExternalRedemption)

        let expiringAttempt = RateLimitResetAttempt(
            id: UUID(),
            providerAccountId: "provider-account-1",
            creditId: expiring.id,
            startingAvailableCount: previous.availableCount,
            startingBankFetchedAt: previous.fetchedAt,
            startingQuotaFetchedAt: now,
            creditExpiresAt: expiring.expiresAt,
            createdAt: now,
            submittedAt: now,
            state: .submitted,
            consumeResponseCode: nil,
            updatedAt: now
        )
        let expectedButExpired = RateLimitResetInventoryTransition.classify(
            previousBank: previous,
            refreshedBank: refreshed,
            localExpectation: RateLimitResetSubmissionExpectation(attempt: expiringAttempt),
            observedProviderAccountId: expiringAttempt.providerAccountId,
            now: observedAt
        )
        #expect(expectedButExpired.disposition == .changedWithoutRedemption)
        #expect(!expectedButExpired.observedExternalRedemption)
    }

    @Test("An unresolved exact attempt retains attribution through a delayed decrement")
    func delayedLocalDecrementRetainsExactAttemptExpectation() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = Self.makeResetBank(
            now: now,
            creditIds: ["credit-1", "credit-2", "credit-3"]
        )
        var unresolvedAttempt = Self.makeAttempt(bank: initial, now: now)
        unresolvedAttempt.state = .reconciling
        unresolvedAttempt.updatedAt = now.addingTimeInterval(1)
        let unchangedBank = RateLimitResetBank(
            availableCount: initial.availableCount,
            totalEarnedCount: initial.totalEarnedCount,
            credits: initial.credits,
            fetchedAt: now.addingTimeInterval(1)
        )
        let unchanged = RateLimitResetInventoryTransition.classify(
            previousBank: initial,
            refreshedBank: unchangedBank,
            localExpectation: RateLimitResetSubmissionExpectation(
                attempt: unresolvedAttempt
            ),
            observedProviderAccountId: "  PROVIDER-ACCOUNT-1\n",
            now: now
        )
        let retained = unchanged.updatedExpectation?.retained(
            while: unresolvedAttempt
        )

        #expect(unchanged.disposition == .unchanged)
        #expect(retained?.attemptId == unresolvedAttempt.id)

        let delayedDrop = RateLimitResetInventoryTransition.classify(
            previousBank: unchangedBank,
            refreshedBank: Self.removingCredits(
                ["credit-1"],
                from: unchangedBank,
                fetchedAt: now.addingTimeInterval(2)
            ),
            localExpectation: retained,
            observedProviderAccountId: "provider-account-1",
            now: now
        )
        #expect(delayedDrop.disposition == .expectedLocalDecrement)

        unresolvedAttempt.state = .succeeded
        #expect(retained?.retained(while: unresolvedAttempt) == nil)
        #expect(retained?.retained(while: nil) == nil)
    }

    @Test("A three-to-one drop and wrong-credit drop remain external")
    func oversizedAndWrongCreditDropsAreExternal() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = Self.makeResetBank(
            now: now,
            creditIds: ["credit-1", "credit-2", "credit-3"]
        )
        let expectation = RateLimitResetSubmissionExpectation(
            attempt: Self.makeAttempt(bank: initial, now: now)
        )

        let oversized = RateLimitResetInventoryTransition.classify(
            previousBank: initial,
            refreshedBank: Self.removingCredits(
                ["credit-1", "credit-2"],
                from: initial,
                fetchedAt: now.addingTimeInterval(1)
            ),
            localExpectation: expectation,
            observedProviderAccountId: expectation.providerAccountId,
            now: now
        )
        let wrongCredit = RateLimitResetInventoryTransition.classify(
            previousBank: initial,
            refreshedBank: Self.removingCredits(
                ["credit-2"],
                from: initial,
                fetchedAt: now.addingTimeInterval(1)
            ),
            localExpectation: expectation,
            observedProviderAccountId: expectation.providerAccountId,
            now: now
        )

        #expect(oversized.disposition == .externalRedemption)
        #expect(wrongCredit.disposition == .externalRedemption)
    }

    @Test("Unreadable external hold state disables automatic redemption")
    func externalHoldStateFailsClosed() {
        #expect(AppDelegate.automaticRateLimitResetRedemptionIsEnabled(
            preferenceEnabled: true,
            externalHoldStateIsReadable: true
        ))
        #expect(!AppDelegate.automaticRateLimitResetRedemptionIsEnabled(
            preferenceEnabled: true,
            externalHoldStateIsReadable: false
        ))
    }

    @Test("Unreadable reset journal blocks automatic routing")
    func unreadableResetJournalFailsClosed() {
        #expect(AppDelegate.rateLimitResetJournalAllowsAutomaticRouting(isReadable: true))
        #expect(!AppDelegate.rateLimitResetJournalAllowsAutomaticRouting(isReadable: false))
    }

    @Test("Manual redemption accepts durable committed state without weakening automatic redemption")
    func manualRedemptionActivationPhasesAreExplicit() {
        let confirmed = Self.makeActivationState(phase: .confirmed)
        let committedDegraded = Self.makeActivationState(phase: .committedDegraded)
        let preparing = Self.makeActivationState(phase: .preparing)

        #expect(AppDelegate.rateLimitResetActivationStateAllows(confirmed, reason: .manual))
        #expect(AppDelegate.rateLimitResetActivationStateAllows(committedDegraded, reason: .manual))
        #expect(!AppDelegate.rateLimitResetActivationStateAllows(preparing, reason: .manual))
        #expect(AppDelegate.rateLimitResetActivationStateAllows(confirmed, reason: .weeklyPressure))
        #expect(!AppDelegate.rateLimitResetActivationStateAllows(
            committedDegraded,
            reason: .weeklyPressure
        ))
    }

    @Test("Manual orchestration requests no runtime or account mutation capability")
    @MainActor
    func manualOrchestrationHasNoRuntimeOrMutationEffects() async {
        let manualCounter = ResetTransportCounter()
        let automaticCounter = ResetTransportCounter()
        let manual = RateLimitResetOrchestrationPlan(reason: .manual)
        let automatic = RateLimitResetOrchestrationPlan(reason: .weeklyPressure)

        _ = await manual.requestRuntimeAuthorization {
            manualCounter.record()
            return nil
        }
        _ = await automatic.requestRuntimeAuthorization {
            automaticCounter.record()
            return nil
        }

        #expect(manualCounter.read() == 0)
        #expect(automaticCounter.read() == 1)
        #expect(manual.requestedCapabilities.isEmpty)
        #expect(automatic.requestedCapabilities == [.runtimeAuthorization])
        for forbidden in [
            RateLimitResetOrchestrationCapability.authWrite,
            .accountSwap,
            .accountActivation,
        ] {
            #expect(!manual.requestedCapabilities.contains(forbidden))
            #expect(!automatic.requestedCapabilities.contains(forbidden))
        }
    }

    @Test("Manual reset route suppressions survive restart until durably released")
    func manualResetSwapSuppressionsRestoreFromJournal() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bank = Self.makeResetBank(now: now)
        var unresolvedAccount = Self.makeResetAccount()
        unresolvedAccount.accountId = "provider-unresolved"
        var succeededAccount = Self.makeResetAccount()
        succeededAccount.accountId = "provider-succeeded"
        var automaticAccount = Self.makeResetAccount()
        automaticAccount.accountId = "provider-automatic"
        var notAppliedAccount = Self.makeResetAccount()
        notAppliedAccount.accountId = "provider-not-applied"
        var releasedAccount = Self.makeResetAccount()
        releasedAccount.accountId = "provider-released"

        let unresolved = Self.makeAttempt(
            bank: bank,
            now: now,
            providerAccountId: unresolvedAccount.accountId,
            reason: .manual,
            state: .reconciling
        )
        let succeeded = Self.makeAttempt(
            bank: bank,
            now: now,
            providerAccountId: succeededAccount.accountId,
            reason: .manual,
            state: .succeeded,
            updatedAt: now.addingTimeInterval(-10)
        )
        let laterPendingForSucceeded = Self.makeAttempt(
            bank: bank,
            now: now,
            providerAccountId: succeededAccount.accountId,
            reason: .manual,
            state: .reconciling
        )
        let automatic = Self.makeAttempt(
            bank: bank,
            now: now,
            providerAccountId: automaticAccount.accountId,
            reason: .weeklyPressure,
            state: .reconciling
        )
        let notApplied = Self.makeAttempt(
            bank: bank,
            now: now,
            providerAccountId: notAppliedAccount.accountId,
            reason: .manual,
            state: .notApplied
        )
        let released = Self.makeAttempt(
            bank: bank,
            now: now,
            providerAccountId: releasedAccount.accountId,
            reason: .manual,
            state: .succeeded,
            routineSwapSuppressionReleasedAt: now
        )

        let suppressions = AppDelegate.manualRateLimitResetSwapSuppressions(
            attempts: [
                unresolved,
                succeeded,
                laterPendingForSucceeded,
                automatic,
                notApplied,
                released,
            ]
        )

        #expect(suppressions[unresolvedAccount.accountId] == .pending)
        #expect(suppressions[succeededAccount.accountId] == .durable)
        #expect(suppressions[automaticAccount.accountId] == nil)
        #expect(suppressions[notAppliedAccount.accountId] == nil)
        #expect(suppressions[releasedAccount.accountId] == nil)
    }

    @Test("Manual reset route suppression transitions preserve and release durable holds")
    func manualResetSwapSuppressionTransitions() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bank = Self.makeResetBank(now: now)
        let succeeded = Self.makeAttempt(
            bank: bank,
            now: now,
            providerAccountId: "provider-succeeded",
            reason: .manual,
            state: .succeeded
        )
        let released = Self.makeAttempt(
            bank: bank,
            now: now,
            providerAccountId: "provider-released",
            reason: .manual,
            state: .succeeded,
            routineSwapSuppressionReleasedAt: now
        )

        #expect(AppDelegate.manualRateLimitResetSwapSuppressionAfterStarting(nil) == .pending)
        #expect(
            AppDelegate.manualRateLimitResetSwapSuppressionAfterStarting(.durable) == .durable
        )
        #expect(AppDelegate.manualRateLimitResetSwapSuppressionAfterClearingPending(.pending) == nil)
        #expect(
            AppDelegate.manualRateLimitResetSwapSuppressionAfterClearingPending(.durable) == .durable
        )
        #expect(
            AppDelegate.manualRateLimitResetSwapSuppressionAfterSuccess(
                .pending,
                attempt: succeeded
            ) == .durable
        )
        #expect(
            AppDelegate.manualRateLimitResetSwapSuppressionAfterSuccess(
                .pending,
                attempt: released
            ) == nil
        )
        #expect(AppDelegate.manualRateLimitResetReleaseMayClearLiveSuppression(
            observedRevision: 7,
            currentRevision: 7
        ))
        #expect(!AppDelegate.manualRateLimitResetReleaseMayClearLiveSuppression(
            observedRevision: 7,
            currentRevision: 8
        ))
        #expect(AppDelegate.manualRateLimitResetRestoreMayApply(
            capturedRevision: 7,
            currentRevision: 7,
            releaseInFlight: false,
            currentSuppression: .durable,
            restoredSuppression: nil
        ))
        #expect(!AppDelegate.manualRateLimitResetRestoreMayApply(
            capturedRevision: 7,
            currentRevision: 8,
            releaseInFlight: false,
            currentSuppression: .durable,
            restoredSuppression: .durable
        ))
        #expect(!AppDelegate.manualRateLimitResetRestoreMayApply(
            capturedRevision: 7,
            currentRevision: 7,
            releaseInFlight: true,
            currentSuppression: .durable,
            restoredSuppression: .durable
        ))
        #expect(!AppDelegate.manualRateLimitResetRestoreMayApply(
            capturedRevision: 7,
            currentRevision: 7,
            releaseInFlight: false,
            currentSuppression: .pending,
            restoredSuppression: nil
        ))
    }

    @Test("Final reset authorization requires the complete available-credit inventory")
    func resetInventoryMustRemainIdenticalBeforeSubmission() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let authorized = Self.makeResetBank(now: now, creditIds: ["credit-1", "credit-2"])
        let attempt = RateLimitResetAttempt(
            id: UUID(),
            providerAccountId: "provider-reset-guard",
            creditId: "credit-1",
            startingAvailableCount: 2,
            startingBankFetchedAt: now,
            startingQuotaFetchedAt: now,
            creditExpiresAt: authorized.oldestExpiringCredit(at: now)?.expiresAt,
            createdAt: now,
            submittedAt: now,
            state: .submitted,
            consumeResponseCode: nil,
            updatedAt: now
        )

        #expect(AppDelegate.rateLimitResetInventoryStillAuthorizesSubmission(
            attempt: attempt,
            authorizedBank: authorized,
            refreshedBank: RateLimitResetBank(
                availableCount: authorized.availableCount,
                totalEarnedCount: authorized.totalEarnedCount,
                credits: authorized.credits,
                fetchedAt: now.addingTimeInterval(1)
            ),
            now: now.addingTimeInterval(1)
        ))
        #expect(!AppDelegate.rateLimitResetInventoryStillAuthorizesSubmission(
            attempt: attempt,
            authorizedBank: authorized,
            refreshedBank: Self.makeResetBank(
                now: now.addingTimeInterval(1),
                creditIds: ["credit-1", "credit-3"]
            ),
            now: now.addingTimeInterval(1)
        ))
        #expect(!AppDelegate.rateLimitResetInventoryStillAuthorizesSubmission(
            attempt: attempt,
            authorizedBank: authorized,
            refreshedBank: Self.makeResetBank(
                now: now.addingTimeInterval(1),
                creditIds: ["credit-1"]
            ),
            now: now.addingTimeInterval(1)
        ))
    }

    private static func makeResetAccount() -> CodexAccount {
        CodexAccount(
            email: "reset-guard@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "provider-reset-guard"
        )
    }

    private static func makeResetBank(now: Date) -> RateLimitResetBank {
        makeResetBank(now: now, creditIds: ["credit-1"])
    }

    private static func makeResetBank(
        now: Date,
        creditIds: [String]
    ) -> RateLimitResetBank {
        RateLimitResetBank(
            availableCount: creditIds.count,
            totalEarnedCount: creditIds.count,
            credits: creditIds.enumerated().map { offset, creditId in
                RateLimitResetCredit(
                    id: creditId,
                    resetType: "weekly",
                    status: "available",
                    grantedAt: now.addingTimeInterval(-60),
                    expiresAt: now.addingTimeInterval(3_600 + Double(offset)),
                    redeemedAt: nil,
                    title: nil,
                    description: nil
                )
            },
            fetchedAt: now
        )
    }

    private static func removingCredits(
        _ removedCreditIds: Set<String>,
        from bank: RateLimitResetBank,
        fetchedAt: Date
    ) -> RateLimitResetBank {
        let remaining = bank.credits.filter { !removedCreditIds.contains($0.id) }
        return RateLimitResetBank(
            availableCount: remaining.count,
            totalEarnedCount: bank.totalEarnedCount,
            credits: remaining,
            fetchedAt: fetchedAt
        )
    }

    private static func makeAttempt(
        bank: RateLimitResetBank,
        now: Date,
        providerAccountId: String = "provider-account-1",
        reason: RateLimitResetRedemptionReason? = nil,
        state: RateLimitResetAttemptState = .submitted,
        routineSwapSuppressionReleasedAt: Date? = nil,
        updatedAt: Date? = nil
    ) -> RateLimitResetAttempt {
        RateLimitResetAttempt(
            id: UUID(),
            providerAccountId: providerAccountId,
            creditId: bank.oldestExpiringCredit(at: now)?.id ?? "credit-1",
            startingAvailableCount: bank.availableCount,
            startingBankFetchedAt: bank.fetchedAt,
            startingQuotaFetchedAt: now,
            creditExpiresAt: bank.oldestExpiringCredit(at: now)?.expiresAt,
            redemptionReason: reason,
            createdAt: now,
            submittedAt: now,
            state: state,
            consumeResponseCode: nil,
            routineSwapSuppressionReleasedAt: routineSwapSuppressionReleasedAt,
            updatedAt: updatedAt ?? now
        )
    }

    private static func makeActivationState(
        phase: AccountActivationPhase
    ) -> AccountActivationState {
        let accountId = UUID()
        let generation = UUID()
        return AccountActivationState(
            version: AccountActivationState.currentVersion,
            phase: phase,
            activationGeneration: generation,
            configuredAccountId: accountId,
            runtimeCurrentAccountId: phase == .confirmed ? accountId : nil,
            updatedAt: Date(),
            retryAttempt: 0,
            nextRetryAt: nil,
            discoveredRuntimeCount: phase == .confirmed ? 1 : 0,
            acknowledgedRuntimeCount: phase == .confirmed ? 1 : 0,
            detail: nil,
            runtimeEvidenceGeneration: nil,
            runtimeEvidenceObservedAt: nil,
            runtimeEvidenceExpiresAt: nil
        )
    }
}
