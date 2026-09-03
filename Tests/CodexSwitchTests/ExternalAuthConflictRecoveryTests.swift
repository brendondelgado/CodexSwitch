import Foundation
import Testing
@testable import CodexSwitch

@Suite("External auth conflict recovery")
struct ExternalAuthConflictRecoveryTests {
    private let sourceAccountId = UUID()
    private let targetAccountId = UUID()
    private let providerAccountId = "provider-target"
    private let now = Date(timeIntervalSince1970: 1_800_300_000)

    @Test("Authority target admits a fresh complete observed token generation")
    func authorityTargetAdmitsFreshObservedGeneration() {
        var stored = makeAccount(id: targetAccountId, active: false)
        stored.accountId = providerAccountId
        stored.planType = "pro"
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
            detail: .externalAuthInvalid,
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

    private func makeEvidence(
        state: AccountActivationState? = nil,
        targetAccountId: UUID? = nil,
        authorityIsFresh: Bool = true,
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
            authorityOperationIsAuthorized: true,
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
