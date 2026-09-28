import Foundation
import CoreFoundation

struct AuthorityConflictRecoveryWitness: Sendable {
    let state: AccountActivationState
    let journalSnapshot: SecureAtomicFileTransaction.Snapshot
    let storePath: String
    let storeSnapshot: SecureAtomicFileTransaction.Snapshot
    let authPath: String
    let authSnapshot: SecureAtomicFileTransaction.Snapshot
    let source: CodexAccount
    let target: CodexAccount
    let originalAccounts: [CodexAccount]
    let replacementAccounts: [CodexAccount]
    let observation: PoolAuthorityObservation
    let authority: PoolAuthorityOperationAuthority

    func authorizes(at now: Date = Date()) -> Bool {
        observation.phase == .stable
            && observation.isFresh(at: now)
            && authority.authorizes(at: now)
            && authority.epoch == observation.epoch
            && authority.providerAccountId == observation.desiredProviderAccountId
            && target.normalizedProviderAccountId == observation.desiredProviderAccountId
            && target.hasUsableInferenceToken(at: now)
    }

    func filesUnchanged() -> Bool {
        do {
            let store = try SecureAtomicFileTransaction(path: storePath).withExclusiveLock {
                try $0.read(allowMissing: false)
            }
            let auth = try SecureAtomicFileTransaction(path: authPath).withExclusiveLock {
                try $0.read(allowMissing: false)
            }
            return store == storeSnapshot && auth == authSnapshot
        } catch {
            return false
        }
    }
}

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
    static func canReconcileConfirmedGeneration(
        state: AccountActivationState?,
        configuredAccountId: UUID?,
        storedTarget: CodexAccount,
        observedTarget: CodexAccount,
        matchingProviderAccountCount: Int,
        now: Date
    ) -> Bool {
        state?.runtimeIsCurrent(for: storedTarget.id, at: now) == true
            && configuredAccountId == storedTarget.id
            && storedTarget.isActive
            && observedTarget.id == storedTarget.id
            && matchingProviderAccountCount == 1
            && storedTarget.normalizedProviderAccountId != nil
            && observedTarget.normalizedProviderAccountId == storedTarget.normalizedProviderAccountId
            && storedTarget.hasCompleteRuntimeCredentials
            && observedTarget.hasCompleteRuntimeCredentials
            && observedTarget.hasStrictlyNewerInferenceToken(than: storedTarget, at: now)
    }

    private struct CredentialRecord: Decodable {
        let id: UUID
        let accountId: String
        let accessToken: String
        let refreshToken: String
        let idToken: String
        let isActive: Bool

        func matches(_ account: CodexAccount) -> Bool {
            id == account.id && accountId == account.accountId
                && accessToken == account.accessToken && refreshToken == account.refreshToken
                && idToken == account.idToken && isActive == account.isActive
        }
    }

    static func storeSnapshot(
        _ snapshot: SecureAtomicFileTransaction.Snapshot,
        matches accounts: [CodexAccount]
    ) -> Bool {
        guard let bytes = snapshot.bytes,
              let records = try? JSONDecoder().decode([CredentialRecord].self, from: bytes),
              records.count == accounts.count else { return false }
        return zip(records, accounts).allSatisfy { $0.0.matches($0.1) }
    }

    static func authorityRecoveryWitness(
        state: AccountActivationState,
        journalSnapshot: SecureAtomicFileTransaction.Snapshot,
        storePath: String,
        storeSnapshot: SecureAtomicFileTransaction.Snapshot,
        authPath: String,
        authSnapshot: SecureAtomicFileTransaction.Snapshot,
        accounts: [CodexAccount],
        observation: PoolAuthorityObservation,
        authority: PoolAuthorityOperationAuthority,
        now: Date
    ) -> AuthorityConflictRecoveryWitness? {
        guard state.phase == .manualReview, state.detail == .externalAuthConflict,
              let journalTarget = state.configuredAccountId,
              accounts.contains(where: { $0.id == journalTarget }),
              accounts.filter(\.isActive).count == 1,
              let source = accounts.first(where: \.isActive),
              Set(accounts.map(\.id)).count == accounts.count,
              accounts.allSatisfy({ $0.normalizedProviderAccountId != nil }),
              Set(accounts.compactMap(\.normalizedProviderAccountId)).count == accounts.count,
              Self.storeSnapshot(storeSnapshot, matches: accounts),
              let authBytes = authSnapshot.bytes,
              let auth = try? JSONDecoder().decode(AuthFile.self, from: authBytes),
              auth.authMode == "chatgpt",
              let observed = try? AccountImporter.accountFromAuthJSON(authBytes),
              let index = accounts.firstIndex(where: {
                  $0.normalizedProviderAccountId == observed.normalizedProviderAccountId
              }),
              let merged = orderedCredentialTarget(stored: accounts[index], observed: observed, now: now)
        else { return nil }
        var replacement = accounts
        replacement[index] = merged
        guard let target = replacement.first(where: {
            $0.normalizedProviderAccountId == observation.desiredProviderAccountId
        }), source.id != target.id, source.hasCompleteRuntimeCredentials,
            target.hasCompleteRuntimeCredentials else { return nil }
        for index in replacement.indices {
            replacement[index].isActive = replacement[index].id == target.id
        }
        let witness = AuthorityConflictRecoveryWitness(
            state: state, journalSnapshot: journalSnapshot,
            storePath: storePath, storeSnapshot: storeSnapshot,
            authPath: authPath, authSnapshot: authSnapshot,
            source: source, target: target, originalAccounts: accounts,
            replacementAccounts: replacement, observation: observation, authority: authority
        )
        return witness.authorizes(at: now) ? witness : nil
    }

    private static func orderedCredentialTarget(
        stored: CodexAccount,
        observed: CodexAccount,
        now: Date
    ) -> CodexAccount? {
        guard stored.hasCompleteRuntimeCredentials, observed.hasCompleteRuntimeCredentials,
              stored.normalizedProviderAccountId == observed.normalizedProviderAccountId,
              let storedExpiry = inferenceExpiration(stored.accessToken),
              let observedExpiry = inferenceExpiration(observed.accessToken) else { return nil }
        if stored.accessToken == observed.accessToken {
            return stored.refreshToken == observed.refreshToken && stored.idToken == observed.idToken
                ? stored : nil
        }
        if storedExpiry > observedExpiry { return stored }
        guard observedExpiry > storedExpiry else { return nil }
        var merged = stored
        merged.accessToken = observed.accessToken
        merged.refreshToken = observed.refreshToken
        merged.idToken = observed.idToken
        merged.lastRefreshed = observed.lastRefreshed ?? stored.lastRefreshed
        if merged.runtimeUnusableReason == "token_expired", merged.hasUsableInferenceToken(at: now) {
            merged.runtimeUnusableReason = nil
            merged.runtimeUnusableUntil = nil
        }
        return merged
    }

    private static func inferenceExpiration(_ token: String) -> Double? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[1].isEmpty, parts[1].utf8.count <= 128 * 1_024 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), data.count <= 64 * 1_024,
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = claims["exp"] as? NSNumber,
              CFGetTypeID(expiry) != CFBooleanGetTypeID(), expiry.doubleValue.isFinite else { return nil }
        return expiry.doubleValue
    }

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
            detailIsRecoverable: {
                $0.allowsObservedSameAccountGenerationRecovery
            },
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
            detailIsRecoverable: {
                $0.allowsExplicitSameAccountReauthenticationRecovery
            },
            configuredAccountId: configuredAccountId,
            storedTarget: storedTarget,
            observedTarget: observedTarget,
            matchingProviderAccountCount: matchingProviderAccountCount,
            now: now
        )
    }

    private static func newerGenerationTarget(
        state: AccountActivationState?,
        detailIsRecoverable: (AccountActivationDetail) -> Bool,
        configuredAccountId: UUID?,
        storedTarget: CodexAccount,
        observedTarget: CodexAccount,
        matchingProviderAccountCount: Int,
        now: Date
    ) -> CodexAccount? {
        guard state?.phase == .manualReview,
              let detail = state?.detail,
              detailIsRecoverable(detail),
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
              storedTarget.hasCompleteRuntimeCredentials,
              observedAuth.hasCompleteRuntimeCredentials,
              observedAuth.hasUsableInferenceToken(at: now) else {
            return nil
        }

        let identical = storedTarget.accessToken == observedAuth.accessToken
            && storedTarget.refreshToken == observedAuth.refreshToken
            && storedTarget.idToken == observedAuth.idToken
        guard identical || observedAuth.hasStrictlyNewerInferenceToken(
            than: storedTarget,
            at: now
        ) else {
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
