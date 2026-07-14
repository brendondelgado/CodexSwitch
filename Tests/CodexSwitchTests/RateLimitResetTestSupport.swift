import Foundation
@testable import CodexSwitch

extension RateLimitResetService {
    func consume(
        for account: CodexAccount,
        bank: RateLimitResetBank,
        now: Date = Date(),
        redeemRequestId: UUID = UUID()
    ) async throws -> RateLimitResetConsumeResult {
        try await consume(
            for: account,
            bank: bank,
            now: now,
            redeemRequestId: redeemRequestId,
            authorizeSubmission: { attempt in
                authorizedResetSubmissionPermit(for: attempt)
            }
        )
    }
}

func authorizedResetSubmissionPermit(
    for attempt: RateLimitResetAttempt
) -> RateLimitResetSubmissionPermit {
    let issuedAt = Date()
    let targetAccountId = UUID()
    let activationGeneration = UUID()
    let evidence = AccountActivationRuntimeEvidence(
        generation: UUID(),
        runtimeCurrentAccountId: targetAccountId,
        observedAt: issuedAt.addingTimeInterval(-1),
        expiresAt: issuedAt.addingTimeInterval(60),
        discoveredRuntimeCount: 1,
        acknowledgedRuntimeCount: 1
    )
    let state = AccountActivationState(
        version: AccountActivationState.currentVersion,
        phase: .confirmed,
        activationGeneration: activationGeneration,
        configuredAccountId: targetAccountId,
        runtimeCurrentAccountId: targetAccountId,
        updatedAt: issuedAt,
        retryAttempt: 0,
        nextRetryAt: nil,
        discoveredRuntimeCount: 1,
        acknowledgedRuntimeCount: 1,
        detail: nil,
        runtimeEvidenceGeneration: evidence.generation,
        runtimeEvidenceObservedAt: evidence.observedAt,
        runtimeEvidenceExpiresAt: evidence.expiresAt
    )
    let runtimePermit = AccountActivationRuntimePermit(
        targetAccountId: targetAccountId,
        activationGeneration: activationGeneration,
        requiredPhase: .confirmed,
        evidence: evidence
    )
    let effectPermit = AccountActivationEffectPermit(
        targetAccountId: targetAccountId,
        activationGeneration: activationGeneration,
        requiredPhase: .confirmed,
        leaseGeneration: 1,
        runtimePermit: runtimePermit,
        leaseAuthorization: { true },
        durableStateProvider: { state }
    )
    return RateLimitResetSubmissionPermit(
        attemptId: attempt.id,
        providerAccountId: attempt.providerAccountId,
        creditId: attempt.creditId,
        targetAccountId: targetAccountId,
        activationGeneration: activationGeneration,
        leaseGeneration: 1,
        runtimePermit: runtimePermit,
        activationEffectPermit: effectPermit,
        issuedAt: issuedAt
    )
}
