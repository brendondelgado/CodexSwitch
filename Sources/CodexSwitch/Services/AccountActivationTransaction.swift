import Dispatch
import Foundation

enum AccountActivationCommitFailureStage: Equatable, Sendable {
    case mutationAuthorization
    case credentialMutation
    case accountStoreAuthorization
    case accountStorePersistence
    case authAuthorization
    case authPersistence
    case durableReadbackAuthorization
    case durableReadback
    case journalAuthorization
    case journalPersistence
    case convergenceAuthorization
    case convergence
}

enum AccountActivationCommitResult: Equatable, Sendable {
    case committed
    case failed(AccountActivationCommitFailureStage)
}

enum AccountAutomaticPolicyTrigger: Equatable, Sendable {
    case routine
    case usageUnavailable(accountId: UUID)
    case tokenInvalidated(accountId: UUID)

    var requestedAccountId: UUID? {
        switch self {
        case .routine:
            nil
        case .usageUnavailable(let accountId), .tokenInvalidated(let accountId):
            accountId
        }
    }
}

final class AccountAutomaticPolicyAuthority: @unchecked Sendable {
    let generation: UUID
    let deadlineUptimeNanoseconds: UInt64

    private let lock = NSLock()
    private var revoked = false

    init(generation: UUID, deadlineUptimeNanoseconds: UInt64) {
        self.generation = generation
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
    }

    func authorizes(
        uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !revoked && uptimeNanoseconds < deadlineUptimeNanoseconds
    }

    func revoke() {
        lock.lock()
        revoked = true
        lock.unlock()
    }
}

struct AccountAutomaticPolicyLease: Equatable, Sendable {
    let generation: UUID
    let startedAt: Date
    let startedAtUptimeNanoseconds: UInt64
    let deadlineUptimeNanoseconds: UInt64
    let authority: AccountAutomaticPolicyAuthority

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.generation == rhs.generation
            && lhs.startedAt == rhs.startedAt
            && lhs.startedAtUptimeNanoseconds == rhs.startedAtUptimeNanoseconds
            && lhs.deadlineUptimeNanoseconds == rhs.deadlineUptimeNanoseconds
    }
}

enum AccountAutomaticPolicyLeaseFinish: Equatable, Sendable {
    case completed
    case expired
    case stale
}

struct AccountAutomaticPolicyLeaseState: Equatable, Sendable {
    private(set) var current: AccountAutomaticPolicyLease?

    mutating func begin(
        at date: Date,
        uptimeNanoseconds: UInt64,
        timeout: TimeInterval
    ) -> AccountAutomaticPolicyLease? {
        guard current == nil else { return nil }
        let boundedTimeout = timeout.isFinite ? max(0, timeout) : 0
        let maximumTimeout = TimeInterval(UInt64.max / 1_000_000_000)
        let timeoutNanoseconds = boundedTimeout >= maximumTimeout
            ? UInt64.max
            : UInt64(boundedTimeout * 1_000_000_000)
        let deadline = uptimeNanoseconds.addingReportingOverflow(timeoutNanoseconds)
        let generation = UUID()
        let deadlineUptimeNanoseconds = deadline.overflow
            ? UInt64.max
            : deadline.partialValue
        let lease = AccountAutomaticPolicyLease(
            generation: generation,
            startedAt: date,
            startedAtUptimeNanoseconds: uptimeNanoseconds,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            authority: AccountAutomaticPolicyAuthority(
                generation: generation,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            )
        )
        current = lease
        return lease
    }

    func authorizes(
        _ lease: AccountAutomaticPolicyLease,
        uptimeNanoseconds: UInt64
    ) -> Bool {
        current?.generation == lease.generation
            && lease.authority.authorizes(uptimeNanoseconds: uptimeNanoseconds)
    }

    @discardableResult
    mutating func finish(
        _ lease: AccountAutomaticPolicyLease,
        uptimeNanoseconds: UInt64
    ) -> AccountAutomaticPolicyLeaseFinish {
        guard current?.generation == lease.generation else { return .stale }
        current = nil
        guard uptimeNanoseconds < lease.deadlineUptimeNanoseconds else {
            lease.authority.revoke()
            return .expired
        }
        return .completed
    }

    @discardableResult
    mutating func expire(
        _ lease: AccountAutomaticPolicyLease,
        uptimeNanoseconds: UInt64
    ) -> Bool {
        guard current?.generation == lease.generation,
              uptimeNanoseconds >= lease.deadlineUptimeNanoseconds else {
            return false
        }
        current = nil
        lease.authority.revoke()
        return true
    }

    mutating func cancel() {
        current?.authority.revoke()
        current = nil
    }

    @discardableResult
    mutating func cancel(_ lease: AccountAutomaticPolicyLease) -> Bool {
        guard current?.generation == lease.generation else { return false }
        current = nil
        lease.authority.revoke()
        return true
    }
}

enum AccountAutomaticPolicyGate {
    static func authorizes(
        trigger: AccountAutomaticPolicyTrigger,
        configuredAccountId: UUID?,
        state: AccountActivationState?,
        permit: AccountActivationRuntimePermit?,
        at date: Date
    ) -> Bool {
        guard let configuredAccountId,
              permit?.targetAccountId == configuredAccountId,
              permit?.evidence.runtimeCurrentAccountId == configuredAccountId,
              permit?.requiredPhase == .confirmed,
              permit?.authorizes(state: state, at: date) == true else {
            return false
        }
        return trigger.requestedAccountId.map { $0 == configuredAccountId } ?? true
    }
}

enum AccountCredentialMutationPolicy {
    static func stillAllows(
        route: AccountCredentialMutationRoute,
        from: CodexAccount,
        to: CodexAccount,
        reason: SwapEvent.SwapReason,
        accounts: [CodexAccount],
        configuredAccount: CodexAccount?,
        now: Date
    ) -> Bool {
        guard accounts.contains(where: { $0.id == to.id }) || route == .firstActivation else {
            return false
        }
        switch route {
        case .planUpgrade:
            guard configuredAccount?.id == from.id else { return false }
            return SwapEngine.selectPlanUpgradeCandidate(
                active: from,
                from: accounts,
                now: now
            )?.id == to.id
        case .swap:
            if case .higherPlanAvailable = reason { return false }
            if case .manual = reason { return true }
            guard let configuredAccount, configuredAccount.id == from.id else {
                return false
            }
            if case .usageUnavailable = reason,
               SwapEngine.selectPlanUpgradeCandidate(
                   active: configuredAccount,
                   from: accounts,
                   now: now
               )?.id == to.id {
                return true
            }
            let tokenInvalidated: Bool
            if case .tokenInvalidated = reason {
                tokenInvalidated = true
            } else {
                tokenInvalidated = false
            }
            guard tokenInvalidated || configuredAccount.needsQuotaRelief(at: now) else {
                return false
            }
            return SwapEngine.selectAutoSwapCandidate(
                from: accounts,
                now: now
            )?.id == to.id
        case .tokenRefresh, .activeReauthentication, .firstActivation,
             .externalAuthObservation:
            return true
        }
    }
}

struct AccountActivationEffectPermit: Sendable, Equatable {
    let targetAccountId: UUID
    let activationGeneration: UUID
    let requiredPhase: AccountActivationPhase
    let leaseGeneration: UInt64
    let runtimePermit: AccountActivationRuntimePermit?

    private let nonce: UUID
    private let leaseAuthorization: @Sendable () -> Bool
    private let durableStateProvider: @Sendable () -> AccountActivationState?

    init(
        targetAccountId: UUID,
        activationGeneration: UUID,
        requiredPhase: AccountActivationPhase,
        leaseGeneration: UInt64,
        runtimePermit: AccountActivationRuntimePermit?,
        leaseAuthorization: @escaping @Sendable () -> Bool,
        durableStateProvider: @escaping @Sendable () -> AccountActivationState?
    ) {
        self.targetAccountId = targetAccountId
        self.activationGeneration = activationGeneration
        self.requiredPhase = requiredPhase
        self.leaseGeneration = leaseGeneration
        self.runtimePermit = runtimePermit
        self.nonce = UUID()
        self.leaseAuthorization = leaseAuthorization
        self.durableStateProvider = durableStateProvider
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.nonce == rhs.nonce
    }

    func authorizes(state: AccountActivationState?, at date: Date) -> Bool {
        guard leaseAuthorization(),
              state?.phase == requiredPhase,
              state?.configuredAccountId == targetAccountId,
              state?.activationGeneration == activationGeneration else {
            return false
        }
        guard let runtimePermit else { return true }
        return runtimePermit.targetAccountId == targetAccountId
            && runtimePermit.activationGeneration == activationGeneration
            && runtimePermit.requiredPhase == requiredPhase
            && runtimePermit.authorizes(state: state, at: date)
    }

    func isCurrentlyAuthorized(at date: Date = Date()) -> Bool {
        authorizes(state: durableStateProvider(), at: date)
    }
}

@MainActor
struct AccountActivationCommitOperations {
    let authorizeMutation: @MainActor @Sendable () async -> AccountCredentialMutationPermit?
    let mutateCredentials: @MainActor @Sendable (AccountCredentialMutationPermit) -> Bool
    let authorizePreparingEffect: @MainActor @Sendable () async -> AccountActivationEffectPermit?
    let persistAccountStore: @MainActor @Sendable (AccountActivationEffectPermit) async -> Bool
    let persistAuth: @MainActor @Sendable (AccountActivationEffectPermit) async -> Bool
    let verifyDurableFiles: @MainActor @Sendable (AccountActivationEffectPermit) async -> Bool
    let markCommittedDegraded: @MainActor @Sendable (AccountActivationEffectPermit) async -> Bool
    let authorizeConvergence: @MainActor @Sendable () async -> AccountActivationEffectPermit?
    let convergeRuntime: @MainActor @Sendable (AccountActivationEffectPermit) async -> Bool
}

struct AccountActivationOperationProof: Equatable, Sendable {
    let state: AccountActivationState?
    let targetAccountId: UUID
    let activationGeneration: UUID
    let requiredPhase: AccountActivationPhase
    let expectedSwapGeneration: UInt64
    let currentSwapGeneration: UInt64
    let pendingTargetAccountId: UUID?
    let configuredAccountId: UUID?
    let expectedConfiguredAccountId: UUID?
    let leaseOwned: Bool
    let isExiting: Bool

    var authorizesEffect: Bool {
        !isExiting
            && leaseOwned
            && expectedSwapGeneration == currentSwapGeneration
            && pendingTargetAccountId == targetAccountId
            && configuredAccountId == expectedConfiguredAccountId
            && state?.phase == requiredPhase
            && state?.configuredAccountId == targetAccountId
            && state?.activationGeneration == activationGeneration
    }
}

struct AccountActivationTransaction: Sendable {
    private let leases: AccountMutationLeaseCoordinator

    init(leases: AccountMutationLeaseCoordinator = AccountMutationLeaseCoordinator()) {
        self.leases = leases
    }

    func withActivationLease<Value: Sendable>(
        targetAccountId: UUID,
        activationGeneration: UUID,
        operation: @MainActor @Sendable (AccountMutationLease) async throws -> Value
    ) async rethrows -> Value? {
        try await leases.withLease(
            .activation(
                targetAccountId: targetAccountId,
                activationGeneration: activationGeneration
            ),
            operation: operation
        )
    }

    func withResetLease<Value: Sendable>(
        accountId: UUID,
        activationGeneration: UUID,
        operation: @MainActor @Sendable (AccountMutationLease) async throws -> Value
    ) async rethrows -> Value? {
        try await leases.withLease(
            .resetRedemption(
                accountId: accountId,
                activationGeneration: activationGeneration
            ),
            operation: operation
        )
    }

    func owns(_ lease: AccountMutationLease) async -> Bool {
        await leases.owns(lease)
    }

    nonisolated func ownsSynchronously(_ lease: AccountMutationLease) -> Bool {
        leases.ownsSynchronously(lease)
    }

    func invalidateCurrentActivation(targetAccountId: UUID? = nil) async -> Bool {
        await leases.invalidateCurrentActivation(targetAccountId: targetAccountId)
    }

    @discardableResult
    nonisolated func invalidateCurrentActivationSynchronously(
        targetAccountId: UUID? = nil
    ) -> Bool {
        leases.invalidateCurrentActivationSynchronously(
            targetAccountId: targetAccountId
        )
    }

    @discardableResult
    nonisolated func invalidateCurrentMutationSynchronously() -> Bool {
        leases.invalidateCurrentLeaseSynchronously()
    }

    nonisolated func ownerAuthorizes(
        _ lease: AccountMutationLease,
        state: AccountActivationState?,
        targetAccountId: UUID,
        activationGeneration: UUID,
        allowedPhases: [AccountActivationPhase]
    ) -> Bool {
        leases.ownsSynchronously(lease)
            && lease.purpose.accountId == targetAccountId
            && lease.purpose.activationGeneration == activationGeneration
            && state?.configuredAccountId == targetAccountId
            && state?.activationGeneration == activationGeneration
            && state.map { allowedPhases.contains($0.phase) } == true
    }

    nonisolated func leaseAuthorizes(
        _ lease: AccountMutationLease,
        targetAccountId: UUID,
        activationGeneration: UUID
    ) -> Bool {
        leases.ownsSynchronously(lease)
            && lease.purpose.accountId == targetAccountId
            && lease.purpose.activationGeneration == activationGeneration
    }

    nonisolated func makeEffectPermit(
        lease: AccountMutationLease,
        targetAccountId: UUID,
        activationGeneration: UUID,
        requiredPhase: AccountActivationPhase,
        runtimePermit: AccountActivationRuntimePermit?,
        journal: AccountActivationCoordinator,
        at date: Date = Date()
    ) -> AccountActivationEffectPermit? {
        guard lease.purpose.activationGeneration == activationGeneration else {
            return nil
        }
        if case .activation(let leaseTarget, _) = lease.purpose,
           leaseTarget != targetAccountId {
            return nil
        }
        let permit = AccountActivationEffectPermit(
            targetAccountId: targetAccountId,
            activationGeneration: activationGeneration,
            requiredPhase: requiredPhase,
            leaseGeneration: lease.generation,
            runtimePermit: runtimePermit,
            leaseAuthorization: { [leases] in
                leases.ownsSynchronously(lease)
            },
            durableStateProvider: {
                try? journal.loadDurableState()
            }
        )
        return permit.isCurrentlyAuthorized(at: date) ? permit : nil
    }

    @MainActor
    func commitConfiguredCredentials(
        _ operations: AccountActivationCommitOperations
    ) async -> AccountActivationCommitResult {
        guard let permit = await operations.authorizeMutation() else {
            return .failed(.mutationAuthorization)
        }
        guard operations.mutateCredentials(permit) else {
            return .failed(.credentialMutation)
        }
        guard let accountStorePermit = await operations.authorizePreparingEffect() else {
            return .failed(.accountStoreAuthorization)
        }
        guard await operations.persistAccountStore(accountStorePermit) else {
            return .failed(.accountStorePersistence)
        }
        guard let authPermit = await operations.authorizePreparingEffect() else {
            return .failed(.authAuthorization)
        }
        guard await operations.persistAuth(authPermit) else {
            return .failed(.authPersistence)
        }
        guard let durableReadPermit = await operations.authorizePreparingEffect() else {
            return .failed(.durableReadbackAuthorization)
        }
        guard await operations.verifyDurableFiles(durableReadPermit) else {
            return .failed(.durableReadback)
        }
        guard let journalPermit = await operations.authorizePreparingEffect() else {
            return .failed(.journalAuthorization)
        }
        guard await operations.markCommittedDegraded(journalPermit) else {
            return .failed(.journalPersistence)
        }
        guard let convergencePermit = await operations.authorizeConvergence() else {
            return .failed(.convergenceAuthorization)
        }
        guard await operations.convergeRuntime(convergencePermit) else {
            return .failed(.convergence)
        }
        return .committed
    }
}
