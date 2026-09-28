import Foundation
import Testing
@testable import CodexSwitch

@Suite("External auth conflict recovery")
struct ExternalAuthConflictRecoveryTests {
    private let sourceAccountId = UUID()
    private let targetAccountId = UUID()
    private let providerAccountId = "provider-target"
    private let now = Date(timeIntervalSince1970: 1_800_300_000)

    @Test("Confirmed same-account refresh does not depend on an external handoff")
    func confirmedGenerationRoutesToCredentialTransaction() {
        var stored = makeAccount(id: targetAccountId, active: true)
        stored.accountId = providerAccountId
        stored.accessToken = testInferenceToken(expiresAt: now.addingTimeInterval(3_600))
        var observed = stored
        observed.accessToken = testInferenceToken(expiresAt: now.addingTimeInterval(7_200))
        observed.refreshToken = "new-refresh"
        observed.idToken = "new-id"

        func state(
            phase: AccountActivationPhase = .confirmed,
            runtimeAccountId: UUID? = nil,
            expiresAt: Date? = nil
        ) -> AccountActivationState {
            AccountActivationState(
                version: 1, phase: phase, activationGeneration: UUID(),
                configuredAccountId: targetAccountId,
                runtimeCurrentAccountId: runtimeAccountId ?? targetAccountId,
                updatedAt: now, retryAttempt: 0, nextRetryAt: nil,
                discoveredRuntimeCount: 1, acknowledgedRuntimeCount: 1, detail: nil,
                runtimeEvidenceGeneration: UUID(), runtimeEvidenceObservedAt: now,
                runtimeEvidenceExpiresAt: expiresAt ?? now.addingTimeInterval(60),
                runtimeBlockers: nil
            )
        }
        func admits(
            activation: AccountActivationState? = nil,
            configured: UUID? = nil,
            candidate: CodexAccount? = nil,
            storedAccount: CodexAccount? = nil,
            matchingCount: Int = 1
        ) -> Bool {
            ExternalAuthConflictRecoveryPolicy.canReconcileConfirmedGeneration(
                state: activation ?? state(),
                configuredAccountId: configured ?? targetAccountId,
                storedTarget: storedAccount ?? stored,
                observedTarget: candidate ?? observed,
                matchingProviderAccountCount: matchingCount,
                now: now
            )
        }

        #expect(admits())
        #expect(!admits(matchingCount: 0))
        #expect(!admits(matchingCount: 2))
        #expect(!admits(configured: UUID()))
        #expect(!admits(activation: state(runtimeAccountId: UUID())))
        #expect(!admits(activation: state(expiresAt: now)))
        for phase in [AccountActivationPhase.preparing, .committedDegraded, .manualReview] {
            #expect(!admits(activation: state(phase: phase)))
        }
        var inactive = stored
        inactive.isActive = false
        #expect(!admits(storedAccount: inactive))
        var differentProvider = observed
        differentProvider.accountId = "different-provider"
        #expect(!admits(candidate: differentProvider))
        var differentIdentity = observed
        differentIdentity = CodexAccount(
            id: UUID(), email: observed.email, accessToken: observed.accessToken,
            refreshToken: observed.refreshToken, idToken: observed.idToken,
            accountId: observed.accountId, isActive: true
        )
        #expect(!admits(candidate: differentIdentity))
        for expiry in [-60.0, 60, 3_600] {
            var old = observed
            old.accessToken = testInferenceToken(expiresAt: now.addingTimeInterval(expiry))
            #expect(!admits(candidate: old))
        }
        var partial = observed
        partial.refreshToken = ""
        #expect(!admits(candidate: partial))
        partial = observed
        partial.idToken = ""
        #expect(!admits(candidate: partial))
        #expect(!admits(candidate: stored))
    }

    @Test("Authority target admits a fresh complete observed token generation")
    func authorityTargetAdmitsFreshObservedGeneration() {
        var stored = makeAccount(id: targetAccountId, active: false)
        stored.accountId = providerAccountId
        stored.planType = "pro"
        stored.accessToken = testInferenceToken(expiresAt: now.addingTimeInterval(600))
        var observed = makeAccount(id: UUID(), active: false)
        observed.accountId = providerAccountId
        observed.accessToken = testInferenceToken(
            expiresAt: now.addingTimeInterval(3_600)
        )
        observed.refreshToken = "observed-refresh"
        observed.idToken = "observed-id"

        let merged = ExternalAuthConflictRecoveryPolicy.authorityTarget(
            storedTarget: stored,
            observedAuth: observed,
            authorityProviderAccountId: providerAccountId,
            now: now
        )
        #expect(merged?.id == stored.id)
        #expect(merged?.planType == "pro")
        #expect(merged?.accessToken == observed.accessToken)
        #expect(merged?.refreshToken == observed.refreshToken)
        #expect(merged?.idToken == observed.idToken)
    }

    @Test("Authority target rejects stale, partial, or mismatched generations")
    func authorityTargetRejectsUnsafeGeneration() {
        var stored = makeAccount(id: targetAccountId, active: false)
        stored.accountId = providerAccountId
        var observed = makeAccount(id: UUID(), active: false)
        observed.accountId = providerAccountId
        observed.accessToken = testInferenceToken(
            expiresAt: now.addingTimeInterval(60)
        )

        #expect(ExternalAuthConflictRecoveryPolicy.authorityTarget(
            storedTarget: stored,
            observedAuth: observed,
            authorityProviderAccountId: providerAccountId,
            now: now
        )?.id == nil)

        observed.accessToken = testInferenceToken(
            expiresAt: now.addingTimeInterval(3_600)
        )
        observed.refreshToken = ""
        #expect(ExternalAuthConflictRecoveryPolicy.authorityTarget(
            storedTarget: stored,
            observedAuth: observed,
            authorityProviderAccountId: providerAccountId,
            now: now
        )?.id == nil)

        observed.refreshToken = "observed-refresh"
        observed.accountId = "different-provider"
        #expect(ExternalAuthConflictRecoveryPolicy.authorityTarget(
            storedTarget: stored,
            observedAuth: observed,
            authorityProviderAccountId: providerAccountId,
            now: now
        )?.id == nil)
    }

    @Test("Authority recovery never rolls back or splices a complete generation")
    func authorityTargetRequiresOrderedCompleteGeneration() {
        var stored = makeAccount(id: targetAccountId, active: false)
        stored.accountId = providerAccountId
        stored.accessToken = testInferenceToken(expiresAt: now.addingTimeInterval(7_200))

        func recover(_ observed: CodexAccount, storedTarget: CodexAccount? = nil) -> CodexAccount? {
            ExternalAuthConflictRecoveryPolicy.authorityTarget(
                storedTarget: storedTarget ?? stored,
                observedAuth: observed,
                authorityProviderAccountId: providerAccountId,
                now: now
            )
        }

        #expect(recover(stored)?.accessToken == stored.accessToken)
        var observed = stored
        observed.accessToken = testInferenceToken(expiresAt: now.addingTimeInterval(3_600))
        #expect(recover(observed) == nil)
        observed = stored
        observed.refreshToken = "different-refresh"
        #expect(recover(observed) == nil)
        observed = stored
        observed.idToken = "different-id"
        #expect(recover(observed) == nil)
        observed = stored
        observed.accessToken += "different-signature"
        #expect(recover(observed) == nil)

        observed.accessToken = testInferenceToken(expiresAt: now.addingTimeInterval(10_800))
        observed.refreshToken = "new-refresh"
        observed.idToken = "new-id"
        let accepted = recover(observed)
        #expect(accepted?.accessToken == observed.accessToken)
        #expect(accepted?.refreshToken == observed.refreshToken)
        #expect(accepted?.idToken == observed.idToken)
        var malformedStored = stored
        malformedStored.accessToken = "malformed"
        #expect(recover(observed, storedTarget: malformedStored) == nil)
        var incompleteStored = stored
        incompleteStored.refreshToken = ""
        #expect(recover(observed, storedTarget: incompleteStored) == nil)
        observed.accessToken = "malformed"
        #expect(recover(observed) == nil)
    }

    @Test("Identical authority credentials still require the inference safety window")
    func authorityTargetRejectsIdenticalExpiringGeneration() {
        var stored = makeAccount(id: targetAccountId, active: false)
        stored.accountId = providerAccountId
        stored.accessToken = testInferenceToken(expiresAt: now.addingTimeInterval(300))
        #expect(ExternalAuthConflictRecoveryPolicy.authorityTarget(
            storedTarget: stored,
            observedAuth: stored,
            authorityProviderAccountId: providerAccountId,
            now: now
        ) == nil)
    }

    @Test("Same-account recovery admits only a strictly newer usable generation")
    func sameAccountGenerationRecoveryIsStrictlyMonotonic() {
        var stored = makeAccount(id: targetAccountId, active: true)
        stored.accountId = providerAccountId
        stored.accessToken = testInferenceToken(
            expiresAt: now.addingTimeInterval(3_600)
        )
        var observed = stored
        observed.accessToken = testInferenceToken(
            expiresAt: now.addingTimeInterval(7_200)
        )
        observed.refreshToken = "new-refresh"
        observed.idToken = "new-id"
        let review = AccountActivationState.manualReview(
            targetAccountId: targetAccountId,
            detail: .configuredFilesInconsistent,
            at: now
        )

        let accepted = ExternalAuthConflictRecoveryPolicy
            .newerSameAccountGenerationTarget(
                state: review,
                configuredAccountId: targetAccountId,
                storedTarget: stored,
                observedTarget: observed,
                matchingProviderAccountCount: 1,
                now: now
            )
        #expect(accepted?.accessToken == observed.accessToken)
        #expect(accepted?.refreshToken == observed.refreshToken)

        let externalAuthConflict = AccountActivationState.manualReview(
            targetAccountId: targetAccountId,
            detail: .externalAuthConflict,
            at: now
        )
        #expect(ExternalAuthConflictRecoveryPolicy.newerExplicitReauthenticationTarget(
            state: externalAuthConflict,
            configuredAccountId: targetAccountId,
            storedTarget: stored,
            observedTarget: observed,
            matchingProviderAccountCount: 1,
            now: now
        )?.accessToken == observed.accessToken)
        #expect(ExternalAuthConflictRecoveryPolicy.newerSameAccountGenerationTarget(
            state: externalAuthConflict,
            configuredAccountId: targetAccountId,
            storedTarget: stored,
            observedTarget: observed,
            matchingProviderAccountCount: 1,
            now: now
        ) == nil)

        observed.accessToken = stored.accessToken
        #expect(ExternalAuthConflictRecoveryPolicy.newerSameAccountGenerationTarget(
            state: review,
            configuredAccountId: targetAccountId,
            storedTarget: stored,
            observedTarget: observed,
            matchingProviderAccountCount: 1,
            now: now
        ) == nil)
    }

    @Test("Fresh same-account auth heals observation barriers")
    func sameAccountGenerationRecoveryHealsObservationBarriers() {
        var stored = makeAccount(id: targetAccountId, active: true)
        stored.accountId = providerAccountId
        stored.accessToken = testInferenceToken(
            expiresAt: now.addingTimeInterval(3_600)
        )
        var observed = stored
        observed.accessToken = testInferenceToken(
            expiresAt: now.addingTimeInterval(7_200)
        )
        observed.refreshToken = "new-refresh"
        observed.idToken = "new-id"

        for detail in [
            AccountActivationDetail.externalAuthAbsent,
            .externalAuthInvalid,
            .externalAuthUnreadable,
        ] {
            let review = AccountActivationState.manualReview(
                targetAccountId: targetAccountId,
                detail: detail,
                at: now
            )
            #expect(ExternalAuthConflictRecoveryPolicy.newerSameAccountGenerationTarget(
                state: review,
                configuredAccountId: targetAccountId,
                storedTarget: stored,
                observedTarget: observed,
                matchingProviderAccountCount: 1,
                now: now
            )?.accessToken == observed.accessToken)
            #expect(ExternalAuthConflictRecoveryPolicy.newerExplicitReauthenticationTarget(
                state: review,
                configuredAccountId: targetAccountId,
                storedTarget: stored,
                observedTarget: observed,
                matchingProviderAccountCount: 1,
                now: now
            )?.refreshToken == observed.refreshToken)
        }
    }

    @Test("Same-account recovery rejects identity, ambiguity, and credential drift")
    func sameAccountGenerationRecoveryRejectsUnsafeEvidence() {
        var stored = makeAccount(id: targetAccountId, active: true)
        stored.accountId = providerAccountId
        stored.accessToken = testInferenceToken(
            expiresAt: now.addingTimeInterval(3_600)
        )
        var observed = stored
        observed.accessToken = testInferenceToken(
            expiresAt: now.addingTimeInterval(7_200)
        )
        observed.refreshToken = "new-refresh"
        observed.idToken = "new-id"
        let review = AccountActivationState.manualReview(
            targetAccountId: targetAccountId,
            detail: .configuredFilesInconsistent,
            at: now
        )

        func target(
            state: AccountActivationState? = review,
            configuredAccountId: UUID? = targetAccountId,
            observedTarget: CodexAccount? = nil,
            matchingProviderAccountCount: Int = 1
        ) -> CodexAccount? {
            ExternalAuthConflictRecoveryPolicy.newerSameAccountGenerationTarget(
                state: state,
                configuredAccountId: configuredAccountId,
                storedTarget: stored,
                observedTarget: observedTarget ?? observed,
                matchingProviderAccountCount: matchingProviderAccountCount,
                now: now
            )
        }

        #expect(target(configuredAccountId: UUID()) == nil)
        #expect(target(matchingProviderAccountCount: 2) == nil)

        var differentLocalAccount = observed
        differentLocalAccount = CodexAccount(
            id: UUID(),
            email: differentLocalAccount.email,
            accessToken: differentLocalAccount.accessToken,
            refreshToken: differentLocalAccount.refreshToken,
            idToken: differentLocalAccount.idToken,
            accountId: differentLocalAccount.accountId,
            isActive: true
        )
        #expect(target(observedTarget: differentLocalAccount) == nil)

        var differentProvider = observed
        differentProvider.accountId = "different-provider"
        #expect(target(observedTarget: differentProvider) == nil)

        var partial = observed
        partial.refreshToken = ""
        #expect(target(observedTarget: partial) == nil)

        let unrelatedReview = AccountActivationState.manualReview(
            targetAccountId: targetAccountId,
            detail: .configuredTargetMissing,
            at: now
        )
        #expect(target(state: unrelatedReview) == nil)
    }

    @Test("Durable source restores an intentionally cleared in-memory selection")
    func durableSourceRestoresClearedSelection() {
        var durableSource = makeAccount(id: sourceAccountId, active: true)
        let inMemorySource = makeAccount(id: sourceAccountId, active: false)
        let target = makeAccount(id: targetAccountId, active: false)

        let resolved = ExternalAuthConflictRecoveryPolicy.durableSource(
            durableAccounts: [durableSource, target],
            inMemoryAccounts: [inMemorySource, target],
            targetAccountId: targetAccountId
        )
        #expect(resolved?.id == sourceAccountId)

        durableSource.accessToken = "changed-access"
        #expect(ExternalAuthConflictRecoveryPolicy.durableSource(
            durableAccounts: [durableSource, target],
            inMemoryAccounts: [inMemorySource, target],
            targetAccountId: targetAccountId
        )?.id == nil)
    }

    @Test("Durable source rejects ambiguous or target-side selections")
    func durableSourceRejectsAmbiguity() {
        let source = makeAccount(id: sourceAccountId, active: true)
        let second = makeAccount(id: UUID(), active: true)
        let targetActive = makeAccount(id: targetAccountId, active: true)
        let inMemorySource = makeAccount(id: sourceAccountId, active: false)

        #expect(ExternalAuthConflictRecoveryPolicy.durableSource(
            durableAccounts: [source, second],
            inMemoryAccounts: [inMemorySource, second],
            targetAccountId: targetAccountId
        )?.id == nil)
        #expect(ExternalAuthConflictRecoveryPolicy.durableSource(
            durableAccounts: [targetActive],
            inMemoryAccounts: [targetActive],
            targetAccountId: targetAccountId
        )?.id == nil)
        #expect(ExternalAuthConflictRecoveryPolicy.durableSource(
            durableAccounts: [source],
            inMemoryAccounts: [inMemorySource, inMemorySource],
            targetAccountId: targetAccountId
        )?.id == nil)
    }

    @Test("Recovery requires every authority and durable-state proof")
    func policyRequiresCompleteEvidence() {
        let evidence = makeEvidence()
        #expect(ExternalAuthConflictRecoveryPolicy.decision(evidence) == .recover)

        #expect(ExternalAuthConflictRecoveryPolicy.decision(
            makeEvidence(authorityIsFresh: false)
        ) == .blocked(.authority))
        #expect(ExternalAuthConflictRecoveryPolicy.decision(
            makeEvidence(authorityOperationIsAuthorized: false)
        ) == .blocked(.authority))
        #expect(ExternalAuthConflictRecoveryPolicy.decision(
            makeEvidence(matchingProviderAccountCount: 2)
        ) == .blocked(.providerIdentity))
        #expect(ExternalAuthConflictRecoveryPolicy.decision(
            makeEvidence(durableStoreMatchesSource: false)
        ) == .blocked(.durableAccountStore))
        #expect(ExternalAuthConflictRecoveryPolicy.decision(
            makeEvidence(authMatchesTarget: false)
        ) == .blocked(.authFile))
        #expect(ExternalAuthConflictRecoveryPolicy.decision(
            makeEvidence(rustHandoffDisposition: .deferred("in flight"))
        ) == .blocked(.rustJournal))
    }

    @Test("Only the exact external-auth conflict can recover")
    func policyRequiresExactConflictState() {
        let otherReview = AccountActivationState.manualReview(
            targetAccountId: sourceAccountId,
            detail: .externalAuthInvalid,
            at: now
        )
        #expect(ExternalAuthConflictRecoveryPolicy.decision(
            makeEvidence(state: otherReview)
        ) == .blocked(.activationState))
        #expect(ExternalAuthConflictRecoveryPolicy.decision(
            makeEvidence(targetAccountId: sourceAccountId)
        ) == .blocked(.sourceAndTarget))

        let unrelatedReview = AccountActivationState.manualReview(
            targetAccountId: UUID(),
            detail: .externalAuthConflict,
            at: now
        )
        #expect(ExternalAuthConflictRecoveryPolicy.decision(
            makeEvidence(state: unrelatedReview)
        ) == .blocked(.activationState))
    }

    @Test("Coordinator supersedes only the verified conflict generation")
    func coordinatorStartsFreshPreparingGeneration() async throws {
        let url = makeSecureTestFileURL(
            prefix: "codexswitch-external-auth-conflict-recovery",
            fileName: "account-activation.json"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = AccountActivationCoordinator(url: url)
        let review = try await coordinator.markManualReview(
            targetAccountId: sourceAccountId,
            detail: .externalAuthConflict,
            at: now
        )
        let generation = UUID()

        let decision = try await coordinator
            .beginVerifiedExternalAuthConflictRecovery(
                targetAccountId: targetAccountId,
                durableSourceAccountId: sourceAccountId,
                requestedActivationGeneration: generation,
                authorizeEffect: { $0 == review },
                at: now.addingTimeInterval(1)
            )

        guard case .prepared(let preparing, let previousState) = decision else {
            Issue.record("Expected a fresh prepared activation")
            return
        }
        #expect(previousState == review)
        #expect(preparing.phase == AccountActivationPhase.preparing)
        #expect(preparing.configuredAccountId == targetAccountId)
        #expect(preparing.activationGeneration == generation)
        #expect(try await coordinator.load() == preparing)
    }

    @Test("Three-way conflict cannot bypass the existing two-target coordinator")
    func coordinatorPreservesThreeWayConflict() async throws {
        let url = makeSecureTestFileURL(
            prefix: "codexswitch-three-way-conflict",
            fileName: "account-activation.json"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = AccountActivationCoordinator(url: url)
        let review = try await coordinator.markManualReview(
            targetAccountId: UUID(),
            detail: .externalAuthConflict,
            at: now
        )
        let before = try Data(contentsOf: url)
        let result = try await coordinator.beginVerifiedExternalAuthConflictRecovery(
            targetAccountId: targetAccountId,
            durableSourceAccountId: sourceAccountId,
            authorizeEffect: { $0 == review },
            at: now.addingTimeInterval(1)
        )
        guard case .blocked(let unchanged, _) = result else {
            Issue.record("Three-way recovery requires a witnessed transaction, not a journal retarget")
            return
        }
        #expect(unchanged == review)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("A changed journal generation revokes an earlier recovery witness")
    func coordinatorRejectsChangedConflictGeneration() async throws {
        let url = makeSecureTestFileURL(
            prefix: "codexswitch-changed-conflict-generation",
            fileName: "account-activation.json"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = AccountActivationCoordinator(url: url)
        let observed = try await coordinator.markManualReview(
            targetAccountId: sourceAccountId,
            detail: .externalAuthConflict,
            at: now
        )
        _ = try await coordinator.markManualReview(
            targetAccountId: sourceAccountId,
            detail: .externalAuthConflict,
            at: now.addingTimeInterval(1)
        )
        let before = try Data(contentsOf: url)
        do {
            _ = try await coordinator.beginVerifiedExternalAuthConflictRecovery(
                targetAccountId: targetAccountId,
                durableSourceAccountId: sourceAccountId,
                authorizeEffect: { $0 == observed },
                at: now.addingTimeInterval(2)
            )
            Issue.record("A stale journal witness must not prepare recovery")
        } catch AccountActivationCoordinatorError.authorizationRevoked {
            // The exact prior state, not only its account identifier, binds recovery.
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("Coordinator preserves a nonmatching review")
    func coordinatorRejectsOtherReviewState() async throws {
        let url = makeSecureTestFileURL(
            prefix: "codexswitch-external-auth-conflict-recovery",
            fileName: "account-activation.json"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = AccountActivationCoordinator(url: url)
        let review = try await coordinator.markManualReview(
            targetAccountId: sourceAccountId,
            detail: .externalAuthInvalid,
            at: now
        )

        let decision = try await coordinator.beginVerifiedExternalAuthConflictRecovery(
            targetAccountId: targetAccountId,
            durableSourceAccountId: sourceAccountId,
            at: now.addingTimeInterval(1)
        )
        guard case .blocked(let unchanged, _) = decision else {
            Issue.record("Expected the nonmatching review to remain blocked")
            return
        }
        #expect(unchanged == review)
        #expect(try await coordinator.load() == review)
    }

    @Test("Coordinator prepares only the matching same-account generation review")
    func coordinatorPreparesSameAccountGenerationRecovery() async throws {
        let url = makeSecureTestFileURL(
            prefix: "codexswitch-same-account-generation-recovery",
            fileName: "account-activation.json"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = AccountActivationCoordinator(url: url)
        let review = try await coordinator.markManualReview(
            targetAccountId: targetAccountId,
            detail: .configuredFilesInconsistent,
            at: now
        )
        let generation = UUID()

        let decision = try await coordinator
            .beginVerifiedSameAccountGenerationRecovery(
                targetAccountId: targetAccountId,
                requestedActivationGeneration: generation,
                authorizeEffect: { $0 == review },
                at: now.addingTimeInterval(1)
            )
        guard case .prepared(let preparing, let previousState) = decision else {
            Issue.record("Expected same-account recovery to prepare")
            return
        }
        #expect(previousState == review)
        #expect(preparing.configuredAccountId == targetAccountId)
        #expect(preparing.activationGeneration == generation)

        let blocked = try await coordinator.beginVerifiedSameAccountGenerationRecovery(
            targetAccountId: sourceAccountId,
            at: now.addingTimeInterval(2)
        )
        guard case .blocked(let unchanged, _) = blocked else {
            Issue.record("Expected a different target to remain blocked")
            return
        }
        #expect(unchanged == preparing)
    }

    @Test("Coordinator permits a verified reauthentication generation over the same-target conflict")
    func coordinatorPreparesSameAccountExternalAuthConflictRecovery() async throws {
        let url = makeSecureTestFileURL(
            prefix: "codexswitch-same-account-reauth-recovery",
            fileName: "account-activation.json"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = AccountActivationCoordinator(url: url)
        let review = try await coordinator.markManualReview(
            targetAccountId: targetAccountId,
            detail: .externalAuthConflict,
            at: now
        )
        let generation = UUID()

        let decision = try await coordinator.beginVerifiedSameAccountGenerationRecovery(
            targetAccountId: targetAccountId,
            requestedActivationGeneration: generation,
            authorizeEffect: { $0 == review },
            at: now.addingTimeInterval(1)
        )
        guard case .prepared(let preparing, let previousState) = decision else {
            Issue.record("Expected verified reauthentication recovery to prepare")
            return
        }
        #expect(previousState == review)
        #expect(preparing.configuredAccountId == targetAccountId)
        #expect(preparing.activationGeneration == generation)
    }

    @Test(
        "Coordinator prepares verified same-account recovery after auth observation failure",
        arguments: [
            AccountActivationDetail.externalAuthAbsent,
            .externalAuthInvalid,
            .externalAuthUnreadable,
        ]
    )
    func coordinatorPreparesSameAccountObservationRecovery(
        detail: AccountActivationDetail
    ) async throws {
        let url = makeSecureTestFileURL(
            prefix: "codexswitch-same-account-observation-recovery",
            fileName: "account-activation.json"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = AccountActivationCoordinator(url: url)
        let review = try await coordinator.markManualReview(
            targetAccountId: targetAccountId,
            detail: detail,
            at: now
        )
        let generation = UUID()

        let decision = try await coordinator.beginVerifiedSameAccountGenerationRecovery(
            targetAccountId: targetAccountId,
            requestedActivationGeneration: generation,
            authorizeEffect: { $0 == review },
            at: now.addingTimeInterval(1)
        )
        guard case .prepared(let preparing, let previousState) = decision else {
            Issue.record("Expected verified same-account observation recovery to prepare")
            return
        }
        #expect(previousState == review)
        #expect(preparing.configuredAccountId == targetAccountId)
        #expect(preparing.activationGeneration == generation)
    }

    @Test("Authority target journal recovers a durable source and target auth split")
    func targetJournalRecoversLiveConflictShape() async throws {
        let url = makeSecureTestFileURL(
            prefix: "codexswitch-external-auth-target-recovery",
            fileName: "account-activation.json"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = AccountActivationCoordinator(url: url)
        let review = try await coordinator.markManualReview(
            targetAccountId: targetAccountId,
            detail: .externalAuthConflict,
            at: now
        )
        let generation = UUID()

        #expect(ExternalAuthConflictRecoveryPolicy.decision(
            makeEvidence(state: review)
        ) == .recover)

        let decision = try await coordinator.beginVerifiedExternalAuthConflictRecovery(
            targetAccountId: targetAccountId,
            durableSourceAccountId: sourceAccountId,
            requestedActivationGeneration: generation,
            authorizeEffect: { $0 == review },
            at: now.addingTimeInterval(1)
        )
        guard case .prepared(let preparing, let previousState) = decision else {
            Issue.record("Expected target-journal recovery to prepare the authority target")
            return
        }
        #expect(previousState == review)
        #expect(preparing.configuredAccountId == targetAccountId)
        #expect(preparing.activationGeneration == generation)
    }

    @Test("Three-way recovery binds a fresh epoch and preserves a newer known auth generation")
    func witnessedThreeWayRecoverySelectsAuthorityWithoutLosingCredentials() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let witness = try #require(fixture.witness())
        #expect(witness.state.configuredAccountId != witness.source.id)
        #expect(witness.state.configuredAccountId != witness.target.id)
        #expect(witness.replacementAccounts.filter(\.isActive).map(\.id) == [targetAccountId])
        #expect(witness.replacementAccounts[0].refreshToken == "observed-new-refresh")
        #expect(witness.observation.epoch == 271)
        let data = try AccountActivationCredentialCommitter.recoveryStoreData(witness)
        let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(records[0]["hostOwnedFixture"] as? String == "preserved")
        #expect(try fixture.snapshot(fixture.storePath) == fixture.store)
        #expect(try fixture.snapshot(fixture.authPath) == fixture.auth)
    }

    @Test("Same access with divergent refresh or identity tokens blocks witnessed recovery")
    func witnessedRecoveryRejectsUnorderedCompleteTokens() async throws {
        for key in ["refresh", "identity"] {
            let fixture = try await makeRecoveryFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var observed = fixture.accounts[0]
            if key == "refresh" { observed.refreshToken = "unproven-refresh" }
            else { observed.idToken = "unproven-id" }
            try SwapEngine.writeAuthFile(for: observed, path: fixture.authPath)
            #expect(try fixture.witness(auth: fixture.snapshot(fixture.authPath)) == nil)
        }
    }

    @Test("Witnessed recovery rejects unknown auth identities, duplicate accounts and stale authority")
    func witnessedRecoveryRejectsAmbiguousOrStaleInputs() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.witness(at: now.addingTimeInterval(31)) == nil)
        let wrongEpoch = PoolAuthorityOperationAuthority(
            epoch: 272, providerAccountId: providerAccountId, expiresAt: now.addingTimeInterval(30)
        )
        #expect(fixture.witness(authority: wrongEpoch) == nil)
        #expect(fixture.witness(accounts: fixture.accounts + [fixture.accounts[0]]) == nil)
        var unknown = fixture.accounts[0]
        unknown.accountId = "unknown-provider"
        try SwapEngine.writeAuthFile(for: unknown, path: fixture.authPath)
        #expect(try fixture.witness(auth: fixture.snapshot(fixture.authPath)) == nil)
        fixture.authority.revoke()
        #expect(fixture.witness() == nil)
    }

    @Test("Journal, store, or auth drift prevents preparation without clearing the review")
    func witnessedPreparationRejectsEachChangedFile() async throws {
        for changed in ["journal", "store", "auth"] {
            let fixture = try await makeRecoveryFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let witness = try #require(fixture.witness())
            if changed == "journal" {
                _ = try await fixture.coordinator.markManualReview(
                    targetAccountId: fixture.state.configuredAccountId,
                    detail: .externalAuthConflict, at: now.addingTimeInterval(1)
                )
            } else {
                let path = changed == "store" ? fixture.storePath : fixture.authPath
                try SecureAtomicFileTransaction(path: path).withExclusiveLock { locked in
                    let snapshot = try locked.read(allowMissing: false)
                    var data = try #require(snapshot.bytes)
                    data.append(0x20)
                    _ = try locked.replace(data, expectedGeneration: snapshot.generation)
                }
            }
            let journalURL = fixture.root.appendingPathComponent("account-activation.json")
            let before = try Data(contentsOf: journalURL)
            do {
                _ = try await fixture.coordinator.beginVerifiedExternalAuthConflictRecovery(
                    targetAccountId: targetAccountId, durableSourceAccountId: sourceAccountId,
                    recoveryWitness: witness, at: now
                )
                Issue.record("Changed recovery witness must not prepare")
            } catch AccountActivationCoordinatorError.authorizationRevoked { }
            #expect(try Data(contentsOf: journalURL) == before)
        }
    }

    @Test("Owned recovery commits both files with CAS and stays unconfirmed")
    func witnessedRecoveryCommitsUnderRuntimeLease() async throws {
        try await exerciseRecoveryCommit(interruption: nil)
    }

    @Test("Late auth replacement is retained after the store commits")
    func witnessedRecoveryRejectsLateAuthReplacement() async throws {
        try await exerciseRecoveryCommit(interruption: "auth")
    }

    @Test("A newer authority revokes recovery before auth persistence")
    func witnessedRecoveryRejectsRevokedEpochAfterStoreCommit() async throws {
        try await exerciseRecoveryCommit(interruption: "authority")
    }

    @Test("Compensation cannot overwrite a newer account-store generation")
    func witnessedRecoveryPreservesSupersedingStore() async throws {
        try await exerciseRecoveryCommit(interruption: "store")
    }

    private func exerciseRecoveryCommit(interruption: String?) async throws {
        let fixture = try await makeRecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let witness = try #require(fixture.witness())
        let transaction = AccountActivationTransaction(crossProcessLeaseURL: fixture.root
            .appendingPathComponent("accounts.runtime-activation.lock"))
        let generation = UUID()
        let fixedNow = now
        let completed = try await transaction.withActivationLease(
            targetAccountId: witness.target.id, activationGeneration: generation
        ) { lease in
            let decision = try await fixture.coordinator.beginVerifiedExternalAuthConflictRecovery(
                targetAccountId: witness.target.id, durableSourceAccountId: witness.source.id,
                recoveryWitness: witness, requestedActivationGeneration: generation,
                authorizeEffect: { state in
                    state == witness.state && witness.authorizes(at: fixedNow)
                        && transaction.leaseAuthorizes(
                            lease, targetAccountId: witness.target.id, activationGeneration: generation
                        )
                }, at: fixedNow
            )
            guard case .prepared(let preparing, let previous) = decision else {
                Issue.record("Expected a witnessed three-way preparation")
                return false
            }
            #expect(previous == fixture.state)
            let permit = try #require(transaction.makeEffectPermit(
                lease: lease, targetAccountId: witness.target.id,
                activationGeneration: generation, requiredPhase: .preparing,
                runtimePermit: nil, journal: fixture.coordinator, at: fixedNow
            ))
            let committer = AccountActivationCredentialCommitter()
            let committed = try #require(await committer.persistRecoveryAccountStore(
                witness: witness, permit: permit, now: { fixedNow }
            ))
            if interruption == "auth" {
                var changed = witness.source
                changed.refreshToken = "external-replacement"
                try SwapEngine.writeAuthFile(for: changed, path: fixture.authPath)
            } else if interruption == "authority" || interruption == "store" {
                fixture.authority.revoke()
                if interruption == "store" {
                    try SecureAtomicFileTransaction(path: fixture.storePath).withExclusiveLock { store in
                        var bytes = try #require(committed.bytes)
                        bytes.append(0x20)
                        _ = try store.replace(bytes, expectedGeneration: committed.generation)
                    }
                }
            }
            let beforeAuth = try fixture.snapshot(fixture.authPath)
            let result = await committer.persistAuth(
                for: witness.target, path: fixture.authPath, permit: permit,
                recoveryWitness: witness, committedStoreSnapshot: committed, now: { fixedNow }
            )
            if interruption != nil {
                #expect(result != .committed)
                #expect(try fixture.snapshot(fixture.authPath) == beforeAuth)
                let beforeStore = try fixture.snapshot(fixture.storePath)
                let restored = await committer.compensateRecoveryStoreSelection(
                    witness: witness, committedSnapshot: committed,
                    authorizeOwner: {
                        transaction.ownerAuthorizes(
                            lease, state: try? fixture.coordinator.loadDurableState(),
                            targetAccountId: witness.target.id, activationGeneration: generation,
                            allowedPhases: [.preparing]
                        )
                    }
                )
                #expect(try fixture.snapshot(fixture.authPath) == beforeAuth)
                if interruption == "store" {
                    #expect(restored == nil)
                    #expect(try fixture.snapshot(fixture.storePath) == beforeStore)
                    let barrier = try await fixture.coordinator.markManualReview(
                        targetAccountId: witness.target.id, detail: .fileCommitFailed, at: fixedNow
                    )
                    #expect(barrier.phase == .manualReview)
                } else {
                    let restoredSnapshot = try #require(restored)
                    let bytes = try #require(restoredSnapshot.bytes)
                    let accounts = try JSONDecoder().decode([CodexAccount].self, from: bytes)
                    #expect(accounts.filter(\.isActive).map(\.id) == [witness.source.id])
                    #expect(accounts[0].refreshToken == "observed-new-refresh")
                    let records = try #require(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
                    #expect(records[0]["hostOwnedFixture"] as? String == "preserved")
                    let review = try await fixture.coordinator.restoreUncommittedPreparation(
                        targetAccountId: witness.target.id, expectedActivationGeneration: generation,
                        previousState: witness.state,
                        authorizeEffect: { state in
                            transaction.ownerAuthorizes(
                                lease, state: state, targetAccountId: witness.target.id,
                                activationGeneration: generation, allowedPhases: [.preparing]
                            )
                        }
                    )
                    #expect(review == fixture.state)
                    let freshJournal = try fixture.coordinator.snapshotForAuthorityRecovery()
                    let freshAuthority = PoolAuthorityOperationAuthority(
                        epoch: fixture.observation.epoch, providerAccountId: witness.target.accountId,
                        expiresAt: fixedNow.addingTimeInterval(30)
                    )
                    let retry = ExternalAuthConflictRecoveryPolicy.authorityRecoveryWitness(
                        state: review, journalSnapshot: try #require(freshJournal).snapshot,
                        storePath: fixture.storePath, storeSnapshot: restoredSnapshot,
                        authPath: fixture.authPath, authSnapshot: beforeAuth, accounts: accounts,
                        observation: fixture.observation, authority: freshAuthority, now: fixedNow
                    )
                    #expect(retry != nil)
                }
            } else {
                #expect(result == .committed)
                let auth = try JSONDecoder().decode(AuthFile.self, from: Data(contentsOf: URL(fileURLWithPath: fixture.authPath)))
                #expect(auth.tokens.accountId == witness.target.accountId)
                #expect(auth.tokens.refreshToken == witness.target.refreshToken)
            }
            if interruption == nil {
                #expect(try await fixture.coordinator.load() == preparing)
            }
            #expect(preparing.phase != .confirmed)
            return true
        }
        #expect(completed == true)
    }

    private struct RecoveryFixture: Sendable {
        let root: URL
        let coordinator: AccountActivationCoordinator
        let state: AccountActivationState
        let journal: SecureAtomicFileTransaction.Snapshot
        let store: SecureAtomicFileTransaction.Snapshot
        let auth: SecureAtomicFileTransaction.Snapshot
        let accounts: [CodexAccount]
        let observation: PoolAuthorityObservation
        let authority: PoolAuthorityOperationAuthority
        var storePath: String { root.appendingPathComponent("accounts.json").path }
        var authPath: String { root.appendingPathComponent("auth.json").path }

        func snapshot(_ path: String) throws -> SecureAtomicFileTransaction.Snapshot {
            try SecureAtomicFileTransaction(path: path).withExclusiveLock { try $0.read(allowMissing: false) }
        }

        func witness(
            auth: SecureAtomicFileTransaction.Snapshot? = nil,
            accounts: [CodexAccount]? = nil,
            authority: PoolAuthorityOperationAuthority? = nil,
            at date: Date? = nil
        ) -> AuthorityConflictRecoveryWitness? {
            ExternalAuthConflictRecoveryPolicy.authorityRecoveryWitness(
                state: state, journalSnapshot: journal,
                storePath: storePath, storeSnapshot: store, authPath: authPath, authSnapshot: auth ?? self.auth,
                accounts: accounts ?? self.accounts, observation: observation,
                authority: authority ?? self.authority, now: date ?? observation.observedAt
            )
        }
    }

    @Test("Newer but expired non-target credentials retain their runtime block")
    func expiredNonTargetRetainsBlock() async throws {
        try await verifyUnusableNonTargetRemainsBlocked(observedExpiresIn: -1)
    }

    @Test("Newer but near-expiry non-target credentials retain their runtime block")
    func nearExpiryNonTargetRetainsBlock() async throws {
        try await verifyUnusableNonTargetRemainsBlocked(observedExpiresIn: 120)
    }

    private func verifyUnusableNonTargetRemainsBlocked(observedExpiresIn: TimeInterval) async throws {
        let fixture = try await makeRecoveryFixture(
            sourceExpiresIn: -3_600, observedExpiresIn: observedExpiresIn, sourceBlocked: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let witness = try #require(fixture.witness())
        let source = try #require(witness.replacementAccounts.first(where: { $0.id == sourceAccountId }))
        #expect(source.refreshToken == "observed-new-refresh")
        #expect(source.runtimeUnusableReason == "token_expired")
        #expect(source.runtimeUnusableUntil == fixture.accounts[0].runtimeUnusableUntil)
        #expect(!source.hasUsableInferenceToken(at: now))
        #expect(witness.target.id == targetAccountId)
        #expect(witness.target.hasUsableInferenceToken(at: now))
        #expect(try fixture.snapshot(fixture.storePath) == fixture.store)
        #expect(try fixture.snapshot(fixture.authPath) == fixture.auth)
    }

    private func makeRecoveryFixture(
        sourceExpiresIn: TimeInterval = 3_600,
        observedExpiresIn: TimeInterval = 7_200,
        sourceBlocked: Bool = false
    ) async throws -> RecoveryFixture {
        let journalURL = makeSecureTestFileURL(prefix: "codexswitch-witnessed-recovery", fileName: "account-activation.json")
        let root = journalURL.deletingLastPathComponent()
        let coordinator = AccountActivationCoordinator(url: journalURL)
        var source = makeAccount(id: sourceAccountId, active: true)
        source.accessToken = testInferenceToken(expiresAt: now.addingTimeInterval(sourceExpiresIn))
        if sourceBlocked {
            source.runtimeUnusableReason = "token_expired"
            source.runtimeUnusableUntil = now.addingTimeInterval(86_400)
        }
        var target = makeAccount(id: targetAccountId, active: false)
        target.accountId = providerAccountId
        target.accessToken = testInferenceToken(expiresAt: now.addingTimeInterval(10_800))
        let journalTarget = makeAccount(id: UUID(), active: false)
        let accounts = [source, target, journalTarget]
        let state = try await coordinator.markManualReview(
            targetAccountId: journalTarget.id, detail: .externalAuthConflict, at: now
        )
        let journalWitness = try coordinator.snapshotForAuthorityRecovery()
        let journal = try #require(journalWitness).snapshot
        var records = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(accounts)) as? [[String: Any]])
        records[0]["hostOwnedFixture"] = "preserved"
        let storePath = root.appendingPathComponent("accounts.json").path
        let store = try SecureAtomicFileTransaction(path: storePath).withExclusiveLock {
            try $0.replace(JSONSerialization.data(withJSONObject: records), expectedGeneration: .missing)
        }
        var observed = source
        observed.accessToken = testInferenceToken(expiresAt: now.addingTimeInterval(observedExpiresIn))
        observed.refreshToken = "observed-new-refresh"
        let authPath = root.appendingPathComponent("auth.json").path
        try SwapEngine.writeAuthFile(for: observed, path: authPath)
        let auth = try SecureAtomicFileTransaction(path: authPath).withExclusiveLock { try $0.read(allowMissing: false) }
        let observation = try PoolAuthorityObservation(
            epoch: 271, phase: .stable, desiredProviderAccountId: providerAccountId,
            requestId: UUID().uuidString, reason: "fixture", observedAt: now, updatedAt: now,
            previousProviderAccountId: source.accountId, detail: nil
        )
        let authority = PoolAuthorityOperationAuthority(
            epoch: observation.epoch, providerAccountId: providerAccountId, expiresAt: now.addingTimeInterval(30)
        )
        return RecoveryFixture(root: root, coordinator: coordinator, state: state, journal: journal,
                               store: store, auth: auth, accounts: accounts, observation: observation, authority: authority)
    }

    private func makeEvidence(
        state: AccountActivationState? = nil,
        targetAccountId: UUID? = nil,
        authorityIsFresh: Bool = true,
        authorityOperationIsAuthorized: Bool = true,
        matchingProviderAccountCount: Int = 1,
        durableStoreMatchesSource: Bool = true,
        authMatchesTarget: Bool = true,
        rustHandoffDisposition: RustActivationHandoffDisposition = .ready
    ) -> ExternalAuthConflictRecoveryEvidence {
        ExternalAuthConflictRecoveryEvidence(
            activationState: state ?? .manualReview(
                targetAccountId: sourceAccountId,
                detail: .externalAuthConflict,
                at: now
            ),
            sourceAccountId: sourceAccountId,
            targetAccountId: targetAccountId ?? self.targetAccountId,
            authorityProviderAccountId: providerAccountId,
            targetProviderAccountId: providerAccountId,
            matchingProviderAccountCount: matchingProviderAccountCount,
            authorityIsFresh: authorityIsFresh,
            authorityOperationIsAuthorized: authorityOperationIsAuthorized,
            durableStoreMatchesSource: durableStoreMatchesSource,
            authMatchesTarget: authMatchesTarget,
            rustHandoffDisposition: rustHandoffDisposition
        )
    }

    private func makeAccount(id: UUID, active: Bool) -> CodexAccount {
        CodexAccount(
            id: id,
            email: "\(id.uuidString)@example.com",
            accessToken: "access-\(id.uuidString)",
            refreshToken: "refresh-\(id.uuidString)",
            idToken: "id-\(id.uuidString)",
            accountId: "provider-\(id.uuidString)",
            isActive: active
        )
    }
}
