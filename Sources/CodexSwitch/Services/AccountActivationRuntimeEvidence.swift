import Foundation

struct AccountActivationRuntimeEvidence: Equatable, Sendable {
    let generation: UUID
    let runtimeCurrentAccountId: UUID
    let observedAt: Date
    let expiresAt: Date
    let discoveredRuntimeCount: Int
    let acknowledgedRuntimeCount: Int
}

struct AccountActivationRuntimePermit: Equatable, Sendable {
    let targetAccountId: UUID
    let activationGeneration: UUID
    let requiredPhase: AccountActivationPhase
    let evidence: AccountActivationRuntimeEvidence

    func authorizes(
        state: AccountActivationState?,
        at date: Date
    ) -> Bool {
        guard let state,
              state.phase == requiredPhase,
              state.configuredAccountId == targetAccountId,
              state.activationGeneration == activationGeneration,
              evidence.observedAt <= date,
              evidence.expiresAt > date,
              evidence.discoveredRuntimeCount > 0,
              evidence.acknowledgedRuntimeCount == evidence.discoveredRuntimeCount else {
            return false
        }
        guard requiredPhase == .confirmed else { return true }
        return state.authorizesAutomaticMutations(
            at: date,
            evidenceGeneration: evidence.generation
        )
    }
}

struct AccountCredentialMutationPermit: Equatable, Sendable {
    let effectPermit: AccountActivationEffectPermit
    let requiresRuntimeEvidence: Bool
    let expectedRuntimeCurrentAccountId: UUID?

    var targetAccountId: UUID { effectPermit.targetAccountId }
    var activationGeneration: UUID { effectPermit.activationGeneration }
    var requiredPhase: AccountActivationPhase { effectPermit.requiredPhase }
    var leaseGeneration: UInt64 { effectPermit.leaseGeneration }
    var runtimePermit: AccountActivationRuntimePermit? { effectPermit.runtimePermit }

    func authorizes(
        state: AccountActivationState?,
        at date: Date
    ) -> Bool {
        guard effectPermit.authorizes(state: state, at: date) else {
            return false
        }
        guard requiresRuntimeEvidence else { return true }
        guard let runtimePermit, let expectedRuntimeCurrentAccountId else {
            return false
        }
        return runtimePermit.evidence.runtimeCurrentAccountId
            == expectedRuntimeCurrentAccountId
    }
}

enum AccountActivationRuntimeEvidenceDecision: Equatable, Sendable {
    case confirmed(AccountActivationRuntimeEvidence)
    case denied(
        detail: AccountActivationDetail,
        discoveredRuntimeCount: Int,
        acknowledgedRuntimeCount: Int
    )
}

enum AccountCredentialMutationRoute: String, CaseIterable, Equatable, Sendable {
    case swap
    case tokenRefresh
    case activeReauthentication
    case planUpgrade
    case firstActivation
    case externalAuthObservation
}

@MainActor
enum AccountCredentialMutationBoundary {
    static func perform<Result>(
        route: AccountCredentialMutationRoute,
        authorize: @MainActor @Sendable () async -> AccountCredentialMutationPermit?,
        mutation: @MainActor @Sendable (AccountCredentialMutationPermit) throws -> Result
    ) async rethrows -> Result? {
        _ = route
        guard let permit = await authorize() else { return nil }
        return try mutation(permit)
    }

    static func performAsync<Result: Sendable>(
        route: AccountCredentialMutationRoute,
        authorize: @MainActor @Sendable () async -> AccountCredentialMutationPermit?,
        mutation: @MainActor @Sendable (
            AccountCredentialMutationPermit
        ) async throws -> Result
    ) async rethrows -> Result? {
        _ = route
        guard let permit = await authorize() else { return nil }
        return try await mutation(permit)
    }
}

enum AccountActivationRuntimeEvidenceEvaluator {
    static func evaluate(
        cli: CodexLocalRuntimeEvidenceSnapshot,
        desktop: CodexLocalRuntimeEvidenceSnapshot,
        expectedAccountId: UUID,
        expectedAuthIdentity: CodexAuthFileIdentity,
        observedAt: Date,
        lifetime: TimeInterval = AccountActivationCoordinator.runtimeEvidenceLifetime,
        generation: UUID = UUID()
    ) -> AccountActivationRuntimeEvidenceDecision {
        let snapshots = [cli, desktop]
        let discovered = snapshots.reduce(0) { $0 + $1.runtimes.count }
        guard snapshots.allSatisfy(\.isComplete) else {
            return .denied(
                detail: .runtimeAcknowledgementIncomplete,
                discoveredRuntimeCount: discovered,
                acknowledgedRuntimeCount: 0
            )
        }
        guard discovered > 0 else {
            return .denied(
                detail: .noLocalRuntime,
                discoveredRuntimeCount: 0,
                acknowledgedRuntimeCount: 0
            )
        }
        let runtimes = snapshots.flatMap(\.runtimes)
        guard runtimes.allSatisfy({ evidence in
            let acknowledgement = evidence.startupAcknowledgement
            return evidence.observation.authFileIdentity == expectedAuthIdentity
                && acknowledgement.binding.authFileIdentity == expectedAuthIdentity
                && acknowledgement.loadedTokenFingerprint
                    == expectedAuthIdentity.completeTokenFingerprint
                && acknowledgement.activeTokenFingerprint
                    == expectedAuthIdentity.completeTokenFingerprint
        }) else {
            return .denied(
                detail: .runtimeAcknowledgementIncomplete,
                discoveredRuntimeCount: discovered,
                acknowledgedRuntimeCount: 0
            )
        }
        let boundedLifetime = max(1, min(lifetime, 30))
        return .confirmed(AccountActivationRuntimeEvidence(
            generation: generation,
            runtimeCurrentAccountId: expectedAccountId,
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(boundedLifetime),
            discoveredRuntimeCount: discovered,
            acknowledgedRuntimeCount: discovered
        ))
    }
}
