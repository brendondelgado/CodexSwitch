import Foundation

enum ExternalAuthConflictRecoveryBarrier: Equatable, Sendable {
    case activationState
    case sourceAndTarget
    case authority
    case providerIdentity
    case durableAccountStore
    case authFile
    case rustJournal
}

enum ExternalAuthConflictRecoveryDecision: Equatable, Sendable {
    case recover
    case blocked(ExternalAuthConflictRecoveryBarrier)
}

struct ExternalAuthConflictRecoveryEvidence: Sendable {
    let activationState: AccountActivationState?
    let sourceAccountId: UUID
    let targetAccountId: UUID
    let authorityProviderAccountId: String
    let targetProviderAccountId: String?
    let matchingProviderAccountCount: Int
    let authorityIsFresh: Bool
    let authorityOperationIsAuthorized: Bool
    let durableStoreMatchesSource: Bool
    let authMatchesTarget: Bool
    let rustHandoffDisposition: RustActivationHandoffDisposition
}

enum ExternalAuthConflictRecoveryPolicy {
    static func newerSameAccountGenerationTarget(
        state: AccountActivationState?,
        configuredAccountId: UUID?,
        storedTarget: CodexAccount,
        observedTarget: CodexAccount,
        matchingProviderAccountCount: Int,
        now: Date
    ) -> CodexAccount? {
        newerGenerationTarget(
            state: state,
            recoverableDetails: [.configuredFilesInconsistent],
            configuredAccountId: configuredAccountId,
            storedTarget: storedTarget,
            observedTarget: observedTarget,
            matchingProviderAccountCount: matchingProviderAccountCount,
            now: now
        )
    }

    static func newerExplicitReauthenticationTarget(
        state: AccountActivationState?,
        configuredAccountId: UUID?,
        storedTarget: CodexAccount,
        observedTarget: CodexAccount,
        matchingProviderAccountCount: Int,
        now: Date
    ) -> CodexAccount? {
        newerGenerationTarget(
            state: state,
            recoverableDetails: [
                .configuredFilesInconsistent,
                .externalAuthConflict,
            ],
            configuredAccountId: configuredAccountId,
            storedTarget: storedTarget,
            observedTarget: observedTarget,
            matchingProviderAccountCount: matchingProviderAccountCount,
            now: now
        )
    }

    private static func newerGenerationTarget(
        state: AccountActivationState?,
        recoverableDetails: [AccountActivationDetail],
        configuredAccountId: UUID?,
        storedTarget: CodexAccount,
        observedTarget: CodexAccount,
        matchingProviderAccountCount: Int,
        now: Date
    ) -> CodexAccount? {
        guard state?.phase == .manualReview,
              let detail = state?.detail,
              recoverableDetails.contains(detail),
              let targetAccountId = state?.configuredAccountId,
              targetAccountId == configuredAccountId,
              targetAccountId == storedTarget.id,
              observedTarget.id == storedTarget.id,
              matchingProviderAccountCount == 1,
              let storedProviderAccountId = storedTarget.normalizedProviderAccountId,
              observedTarget.normalizedProviderAccountId == storedProviderAccountId,
              storedTarget.hasCompleteRuntimeCredentials,
              observedTarget.hasCompleteRuntimeCredentials,
              observedTarget.hasStrictlyNewerInferenceToken(
                  than: storedTarget,
                  at: now
              ) else {
            return nil
        }
        return observedTarget
    }

    static func authorityTarget(
        storedTarget: CodexAccount,
        observedAuth: CodexAccount,
        authorityProviderAccountId: String,
        now: Date
    ) -> CodexAccount? {
        guard storedTarget.normalizedProviderAccountId == authorityProviderAccountId,
              observedAuth.normalizedProviderAccountId == authorityProviderAccountId,
              observedAuth.hasCompleteRuntimeCredentials,
              observedAuth.hasUsableInferenceToken(at: now) else {
            return nil
        }

        var target = storedTarget
        target.email = observedAuth.email
        target.accessToken = observedAuth.accessToken
        target.refreshToken = observedAuth.refreshToken
        target.idToken = observedAuth.idToken
        target.accountId = observedAuth.accountId
        target.lastRefreshed = observedAuth.lastRefreshed ?? now
        target.runtimeUnusableUntil = nil
        target.runtimeUnusableReason = nil
        return target
    }

    static func durableSource(
        durableAccounts: [CodexAccount],
        inMemoryAccounts: [CodexAccount],
        targetAccountId: UUID
    ) -> CodexAccount? {
        let configured = durableAccounts.filter(\.isActive)
        guard configured.count == 1,
              let durableSource = configured.first,
              durableSource.id != targetAccountId,
              durableSource.hasCompleteRuntimeCredentials else {
            return nil
        }

        let matchingSources = inMemoryAccounts.filter {
            $0.id == durableSource.id
                && $0.accountId == durableSource.accountId
                && $0.hasCompleteRuntimeCredentials
                && $0.accessToken == durableSource.accessToken
                && $0.refreshToken == durableSource.refreshToken
                && $0.idToken == durableSource.idToken
        }
        guard matchingSources.count == 1 else { return nil }
        return matchingSources[0]
    }

    static func decision(
        _ evidence: ExternalAuthConflictRecoveryEvidence
    ) -> ExternalAuthConflictRecoveryDecision {
        guard evidence.activationState?.phase == .manualReview,
              evidence.activationState?.detail == .externalAuthConflict else {
            return .blocked(.activationState)
        }
        guard evidence.sourceAccountId != evidence.targetAccountId else {
            return .blocked(.sourceAndTarget)
        }
        guard evidence.activationState?.configuredAccountId == evidence.sourceAccountId
                || evidence.activationState?.configuredAccountId == evidence.targetAccountId else {
            return .blocked(.activationState)
        }
        guard evidence.authorityIsFresh,
              evidence.authorityOperationIsAuthorized else {
            return .blocked(.authority)
        }
        guard evidence.matchingProviderAccountCount == 1,
              evidence.targetProviderAccountId == evidence.authorityProviderAccountId else {
            return .blocked(.providerIdentity)
        }
        guard evidence.durableStoreMatchesSource else {
            return .blocked(.durableAccountStore)
        }
        guard evidence.authMatchesTarget else {
            return .blocked(.authFile)
        }
        guard evidence.rustHandoffDisposition == .ready else {
            return .blocked(.rustJournal)
        }
        return .recover
    }
}
