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
