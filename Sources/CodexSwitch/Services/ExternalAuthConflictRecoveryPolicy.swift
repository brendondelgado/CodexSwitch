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
    static func decision(
        _ evidence: ExternalAuthConflictRecoveryEvidence
    ) -> ExternalAuthConflictRecoveryDecision {
        guard evidence.activationState?.phase == .manualReview,
              evidence.activationState?.detail == .externalAuthConflict,
              evidence.activationState?.configuredAccountId == evidence.sourceAccountId else {
            return .blocked(.activationState)
        }
        guard evidence.sourceAccountId != evidence.targetAccountId else {
            return .blocked(.sourceAndTarget)
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
