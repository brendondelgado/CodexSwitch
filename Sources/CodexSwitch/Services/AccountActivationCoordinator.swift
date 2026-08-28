import Foundation

enum AccountActivationCoordinatorError: Error, Equatable, LocalizedError {
    case authorizationRevoked
    case corruptJournal(String)
    case invalidTransition(String)
    case journalTooLarge(Int)
    case readbackMismatch

    var errorDescription: String? {
        switch self {
        case .authorizationRevoked:
            "Mac activation authorization expired before journal persistence"
        case .corruptJournal(let reason):
            "Mac activation journal is corrupt: \(reason)"
        case .invalidTransition(let reason):
            "Mac activation journal transition was rejected: \(reason)"
        case .journalTooLarge(let byteCount):
            "Mac activation journal exceeds its size limit (\(byteCount) bytes)"
        case .readbackMismatch:
            "Mac activation journal did not match its secure-file readback"
        }
    }
}

enum AccountActivationCredentialMutationDecision: Equatable, Sendable {
    case prepared(
        AccountActivationState,
        previousState: AccountActivationState?
    )
    case retrySameTarget(AccountActivationState)
    case blocked(AccountActivationState?, String)
}

actor AccountActivationCoordinator {
    typealias StateEffectAuthorization = @Sendable (AccountActivationState?) -> Bool

    static let defaultURL = URL(fileURLWithPath: NSString(
        string: "~/.codexswitch/account-activation.json"
    ).expandingTildeInPath)
    static let maximumJournalBytes = 4 * 1024
    static let maximumDetailBytes = 512
    static let maximumRuntimeCount = 256
    static let maximumRetryAttempt = 10_000
    static let legacyAutomaticRetryLimit = 4
    static let runtimeEvidenceLifetime: TimeInterval = 10

    let url: URL
    nonisolated private let transaction: SecureAtomicFileTransaction
    private let crossProcessLeaseURL: URL
    private let baseRetryInterval: TimeInterval
    private let maximumRetryInterval: TimeInterval

    init(
        url: URL = AccountActivationCoordinator.defaultURL,
        crossProcessLeaseURL: URL? = nil,
        baseRetryInterval: TimeInterval = 30,
        maximumRetryInterval: TimeInterval = 5 * 60,
        transactionTestHooks: SecureAtomicFileTransaction.TestHooks = .init()
    ) {
        let boundedBaseRetryInterval = max(1, baseRetryInterval)
        self.url = url
        self.crossProcessLeaseURL = crossProcessLeaseURL
            ?? url.deletingLastPathComponent()
                .appendingPathComponent("accounts.runtime-activation.lock")
        self.baseRetryInterval = boundedBaseRetryInterval
        self.maximumRetryInterval = max(boundedBaseRetryInterval, maximumRetryInterval)
        self.transaction = SecureAtomicFileTransaction(
            path: url.path,
            subject: "Mac account activation journal",
            testHooks: transactionTestHooks
        )
    }

    func load(at date: Date = Date()) throws -> AccountActivationState? {
        let state = try loadDurableState()
        guard state?.phase == .manualReview,
              state?.detail == .automaticRetryLimitReached else {
            return state
        }
        return try migrateLegacyRetryLimitReview(at: date)
    }

    nonisolated func loadDurableState() throws -> AccountActivationState? {
        try transaction.withExclusiveLock { lockedFile in
            try Self.decode(lockedFile.read().bytes)
        }
    }

    @discardableResult
    func beginPreparing(
        targetAccountId: UUID,
        kind: AccountActivationRequestKind,
        requestedActivationGeneration: UUID? = nil,
        at date: Date = Date()
    ) throws -> AccountActivationState {
        let decision = try beginAuthorizedCredentialMutation(
            targetAccountId: targetAccountId,
            kind: kind,
            requestedActivationGeneration: requestedActivationGeneration,
            at: date
        )
        switch decision {
        case .prepared(let state, previousState: _):
            return state
        case .retrySameTarget:
            throw AccountActivationCoordinatorError.invalidTransition(
                "the configured target requires runtime reconciliation"
            )
        case .blocked(_, let reason):
            throw AccountActivationCoordinatorError.invalidTransition(reason)
        }
    }

    @discardableResult
    func beginCredentialMutation(
        targetAccountId: UUID,
        kind: AccountActivationRequestKind,
        requestedActivationGeneration: UUID? = nil,
        at date: Date = Date()
    ) throws -> AccountActivationState {
        try beginPreparing(
            targetAccountId: targetAccountId,
            kind: kind,
            requestedActivationGeneration: requestedActivationGeneration,
            at: date
        )
    }

    func beginAuthorizedCredentialMutation(
        targetAccountId: UUID,
        kind: AccountActivationRequestKind,
        requestedActivationGeneration: UUID? = nil,
        authorizeEffect: @escaping StateEffectAuthorization = { _ in true },
        at date: Date = Date()
    ) throws -> AccountActivationCredentialMutationDecision {
        try withRuntimeLease {
            try beginAuthorizedCredentialMutationUnderRuntimeLease(
                targetAccountId: targetAccountId,
                kind: kind,
                requestedActivationGeneration: requestedActivationGeneration,
                authorizeEffect: authorizeEffect,
                at: date
            )
        }
    }

    func beginVerifiedExternalAuthConflictRecovery(
        targetAccountId: UUID,
        durableSourceAccountId: UUID,
        requestedActivationGeneration: UUID = UUID(),
        authorizeEffect: @escaping StateEffectAuthorization = { _ in true },
        at date: Date = Date()
    ) throws -> AccountActivationCredentialMutationDecision {
        try withRuntimeLease {
            try transaction.withExclusiveLock { lockedFile in
                let snapshot = try lockedFile.read()
                let current = try Self.decode(snapshot.bytes)
                guard let current,
                      current.phase == .manualReview,
                      current.detail == .externalAuthConflict,
                      current.configuredAccountId == durableSourceAccountId
                        || current.configuredAccountId == targetAccountId,
                      targetAccountId != durableSourceAccountId else {
                    return .blocked(
                        current,
                        "authority recovery requires the matching external-auth conflict"
                    )
                }
                guard authorizeEffect(current) else {
                    throw AccountActivationCoordinatorError.authorizationRevoked
                }

                let preparing = AccountActivationState.preparing(
                    targetAccountId: targetAccountId,
                    activationGeneration: requestedActivationGeneration,
                    at: date
                )
                try Self.validate(preparing)
                let readback = try lockedFile.replace(
                    try Self.encode(preparing),
                    expectedGeneration: snapshot.generation
                )
                guard try Self.decode(readback.bytes) == preparing else {
                    throw AccountActivationCoordinatorError.readbackMismatch
                }
                return .prepared(preparing, previousState: current)
            }
        }
    }

    func beginVerifiedSameAccountGenerationRecovery(
        targetAccountId: UUID,
        requestedActivationGeneration: UUID = UUID(),
        authorizeEffect: @escaping StateEffectAuthorization = { _ in true },
        at date: Date = Date()
    ) throws -> AccountActivationCredentialMutationDecision {
        try withRuntimeLease {
            try transaction.withExclusiveLock { lockedFile in
                let snapshot = try lockedFile.read()
                let current = try Self.decode(snapshot.bytes)
                guard let current,
                      current.phase == .manualReview,
                      current.detail == .configuredFilesInconsistent
                        || current.detail == .externalAuthConflict,
                      current.configuredAccountId == targetAccountId else {
                    return .blocked(
                        current,
                        "same-account generation recovery requires a matching recoverable review"
                    )
                }
                guard authorizeEffect(current) else {
                    throw AccountActivationCoordinatorError.authorizationRevoked
                }

                let preparing = AccountActivationState.preparing(
                    targetAccountId: targetAccountId,
                    activationGeneration: requestedActivationGeneration,
                    at: date
                )
                try Self.validate(preparing)
                let readback = try lockedFile.replace(
                    try Self.encode(preparing),
                    expectedGeneration: snapshot.generation
                )
                guard try Self.decode(readback.bytes) == preparing else {
                    throw AccountActivationCoordinatorError.readbackMismatch
                }
                return .prepared(preparing, previousState: current)
            }
        }
    }

    private func beginAuthorizedCredentialMutationUnderRuntimeLease(
        targetAccountId: UUID,
        kind: AccountActivationRequestKind,
        requestedActivationGeneration: UUID?,
        authorizeEffect: @escaping StateEffectAuthorization,
        at date: Date
    ) throws -> AccountActivationCredentialMutationDecision {
        try transaction.withExclusiveLock { lockedFile in
            let snapshot = try lockedFile.read()
            let current = try Self.decode(snapshot.bytes)
            let effective: AccountActivationState?
            if kind.permitsOperatorRecovery,
               let current,
               current.phase == .confirmed,
               !current.authorizesAutomaticMutations(at: date) {
                effective = .committedDegraded(
                    targetAccountId: current.configuredAccountId!,
                    detail: .runtimeEvidenceExpired,
                    activationGeneration: current.activationGeneration,
                    retryAttempt: current.retryAttempt,
                    nextRetryAt: date,
                    discoveredRuntimeCount: current.discoveredRuntimeCount,
                    acknowledgedRuntimeCount: current.acknowledgedRuntimeCount,
                    at: date
                )
            } else {
                effective = current
            }

            let requestDecision = effective?.decision(
                forRequestedTarget: targetAccountId,
                kind: kind,
                at: date
            ) ?? .beginActivation
            let result: AccountActivationCredentialMutationDecision
            let proposed: AccountActivationState?
            switch requestDecision {
            case .beginActivation:
                let preparing = AccountActivationState.preparing(
                    targetAccountId: targetAccountId,
                    activationGeneration: requestedActivationGeneration ?? UUID(),
                    at: date
                )
                proposed = preparing
                result = .prepared(preparing, previousState: effective)
            case .retrySameTarget:
                proposed = effective
                result = .retrySameTarget(effective!)
            case .blocked(let reason):
                proposed = effective
                result = .blocked(effective, reason)
            }

            if proposed != current, let proposed {
                guard authorizeEffect(current) else {
                    throw AccountActivationCoordinatorError.authorizationRevoked
                }
                try Self.validate(proposed)
                let data = try Self.encode(proposed)
                let readback = try lockedFile.replace(
                    data,
                    expectedGeneration: snapshot.generation
                )
                guard try Self.decode(readback.bytes) == proposed else {
                    throw AccountActivationCoordinatorError.readbackMismatch
                }
            }
            return result
        }
    }

    @discardableResult
    func restoreUncommittedPreparation(
        targetAccountId: UUID,
        expectedActivationGeneration: UUID,
        previousState: AccountActivationState,
        authorizeEffect: @escaping StateEffectAuthorization = { _ in true }
    ) throws -> AccountActivationState {
        try transition(authorizeEffect: authorizeEffect) { current in
            guard let current,
                  current.phase == .preparing,
                  current.configuredAccountId == targetAccountId,
                  current.activationGeneration == expectedActivationGeneration else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "uncommitted recovery does not match the prepared activation"
                )
            }
            return previousState
        }
    }

    @discardableResult
    func recoverFileCommitFailure(
        targetAccountId: UUID,
        at date: Date = Date()
    ) throws -> AccountActivationState {
        try transition { current in
            guard let current,
                  current.phase == .manualReview,
                  current.detail == .fileCommitFailed else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "file-commit recovery requires a matching manual-review record"
                )
            }
            return .committedDegraded(
                targetAccountId: targetAccountId,
                detail: .restartRecoveredCommittedFiles,
                activationGeneration: UUID(),
                retryAttempt: 0,
                nextRetryAt: date,
                at: date
            )
        }
    }

    @discardableResult
    func bootstrapCommittedDegraded(
        targetAccountId: UUID,
        detail: AccountActivationDetail,
        at date: Date = Date()
    ) throws -> AccountActivationState {
        try transition { current in
            guard current == nil else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "bootstrap requires a missing activation journal"
                )
            }
            return .committedDegraded(
                targetAccountId: targetAccountId,
                detail: detail,
                activationGeneration: UUID(),
                retryAttempt: 0,
                nextRetryAt: date,
                at: date
            )
        }
    }

    @discardableResult
    func markCommittedDegraded(
        targetAccountId: UUID,
        expectedActivationGeneration: UUID? = nil,
        discoveredRuntimeCount: Int,
        acknowledgedRuntimeCount: Int,
        detail: AccountActivationDetail,
        runtimeBlockers: Set<CodexRuntimeDiscoveryBlocker> = [],
        authorizeEffect: @escaping StateEffectAuthorization = { _ in true },
        at date: Date = Date()
    ) throws -> AccountActivationState {
        try transition(authorizeEffect: authorizeEffect) { current in
            guard let current,
                  current.configuredAccountId == targetAccountId,
                  expectedActivationGeneration.map({
                      $0 == current.activationGeneration
                  }) ?? true,
                  current.phase == .preparing else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "degraded evidence does not match the prepared target"
                )
            }
            return .committedDegraded(
                targetAccountId: targetAccountId,
                detail: detail,
                activationGeneration: current.activationGeneration,
                retryAttempt: current.retryAttempt,
                nextRetryAt: date,
                discoveredRuntimeCount: discoveredRuntimeCount,
                acknowledgedRuntimeCount: acknowledgedRuntimeCount,
                runtimeBlockers: runtimeBlockers,
                at: date
            )
        }
    }

    @discardableResult
    func recordConvergenceFailure(
        targetAccountId: UUID,
        discoveredRuntimeCount: Int,
        acknowledgedRuntimeCount: Int,
        detail: AccountActivationDetail,
        runtimeBlockers: Set<CodexRuntimeDiscoveryBlocker> = [],
        authorizeEffect: @escaping StateEffectAuthorization = { _ in true },
        at date: Date = Date()
    ) throws -> AccountActivationState {
        try transition(authorizeEffect: authorizeEffect) { current in
            guard let current,
                  current.phase == .committedDegraded,
                  current.configuredAccountId == targetAccountId else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "runtime failure does not match committed activation"
                )
            }
            return advancingConvergenceFailure(
                current: current,
                targetAccountId: targetAccountId,
                detail: detail,
                discoveredRuntimeCount: discoveredRuntimeCount,
                acknowledgedRuntimeCount: acknowledgedRuntimeCount,
                runtimeBlockers: runtimeBlockers,
                at: date
            )
        }
    }

    @discardableResult
    func recordRuntimeRevalidationFailure(
        targetAccountId: UUID,
        expectedActivationGeneration: UUID,
        authorizeEffect: @escaping StateEffectAuthorization = { _ in true },
        at date: Date = Date()
    ) throws -> AccountActivationState {
        try transition(authorizeEffect: authorizeEffect) { current in
            guard let current,
                  current.phase == .committedDegraded,
                  current.configuredAccountId == targetAccountId,
                  current.activationGeneration == expectedActivationGeneration else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "runtime revalidation failure does not match committed activation"
                )
            }
            return advancingConvergenceFailure(
                current: current,
                targetAccountId: targetAccountId,
                detail: .runtimeConfirmationPending,
                discoveredRuntimeCount: current.discoveredRuntimeCount,
                acknowledgedRuntimeCount: current.acknowledgedRuntimeCount,
                runtimeBlockers: current.convergenceBlockers,
                at: date
            )
        }
    }

    private func advancingConvergenceFailure(
        current: AccountActivationState,
        targetAccountId: UUID,
        detail: AccountActivationDetail,
        discoveredRuntimeCount: Int,
        acknowledgedRuntimeCount: Int,
        runtimeBlockers: Set<CodexRuntimeDiscoveryBlocker>,
        at date: Date
    ) -> AccountActivationState {
        let nextAttempt = min(
            current.retryAttempt + 1,
            Self.maximumRetryAttempt
        )
        let delay = Self.retryDelay(
            attempt: nextAttempt,
            base: baseRetryInterval,
            maximum: maximumRetryInterval
        )
        return .committedDegraded(
            targetAccountId: targetAccountId,
            detail: detail,
            activationGeneration: current.activationGeneration,
            retryAttempt: nextAttempt,
            nextRetryAt: date.addingTimeInterval(delay),
            discoveredRuntimeCount: discoveredRuntimeCount,
            acknowledgedRuntimeCount: acknowledgedRuntimeCount,
            runtimeBlockers: runtimeBlockers,
            at: date
        )
    }

    private func migrateLegacyRetryLimitReview(
        at date: Date
    ) throws -> AccountActivationState? {
        try withRuntimeLease {
            try transaction.withExclusiveLock { lockedFile in
                let snapshot = try lockedFile.read()
                guard let current = try Self.decode(snapshot.bytes) else {
                    return nil
                }
                guard current.phase == .manualReview,
                      current.detail == .automaticRetryLimitReached else {
                    return current
                }
                guard let targetAccountId = current.configuredAccountId else {
                    throw AccountActivationCoordinatorError.corruptJournal(
                        "retry-limit review is missing its target"
                    )
                }
                let retryAttempt = min(
                    max(current.retryAttempt, Self.legacyAutomaticRetryLimit),
                    Self.maximumRetryAttempt
                )
                let detail: AccountActivationDetail
                if current.discoveredRuntimeCount == 0 {
                    detail = .noLocalRuntime
                } else if current.acknowledgedRuntimeCount
                            < current.discoveredRuntimeCount {
                    detail = .runtimeAcknowledgementIncomplete
                } else {
                    detail = .runtimeConfirmationPending
                }
                let migrated = AccountActivationState.committedDegraded(
                    targetAccountId: targetAccountId,
                    detail: detail,
                    activationGeneration: current.activationGeneration,
                    retryAttempt: retryAttempt,
                    nextRetryAt: date.addingTimeInterval(Self.retryDelay(
                        attempt: retryAttempt,
                        base: baseRetryInterval,
                        maximum: maximumRetryInterval
                    )),
                    discoveredRuntimeCount: current.discoveredRuntimeCount,
                    acknowledgedRuntimeCount: current.acknowledgedRuntimeCount,
                    runtimeBlockers: current.convergenceBlockers,
                    at: date
                )
                try Self.validate(migrated)
                let readback = try lockedFile.replace(
                    try Self.encode(migrated),
                    expectedGeneration: snapshot.generation
                )
                guard try Self.decode(readback.bytes) == migrated else {
                    throw AccountActivationCoordinatorError.readbackMismatch
                }
                return migrated
            }
        }
    }

    @discardableResult
    func resetForManualSameTargetRetry(
        targetAccountId: UUID,
        newActivationGeneration: UUID = UUID(),
        authorizeEffect: @escaping StateEffectAuthorization = { _ in true },
        at date: Date = Date()
    ) throws -> AccountActivationState {
        try transition(authorizeEffect: authorizeEffect) { current in
            guard let current,
                  current.configuredAccountId == targetAccountId,
                  current.phase == .committedDegraded
                    || (current.phase == .manualReview
                        && current.detail?.allowsManualSameTargetRetry == true) else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "manual retry is not authorized for this target"
                )
            }
            return .committedDegraded(
                targetAccountId: targetAccountId,
                detail: .runtimeConfirmationPending,
                activationGeneration: newActivationGeneration,
                retryAttempt: 0,
                nextRetryAt: date,
                at: date
            )
        }
    }

    @discardableResult
    func recoverVerifiedExternalAuth(
        targetAccountId: UUID,
        newActivationGeneration: UUID = UUID(),
        authorizeEffect: @escaping StateEffectAuthorization = { _ in true },
        at date: Date = Date()
    ) throws -> AccountActivationState {
        try transition(authorizeEffect: authorizeEffect) { current in
            guard let current,
                  current.phase == .manualReview,
                  current.configuredAccountId == targetAccountId,
                  current.detail?.allowsVerifiedExternalAuthRecovery == true else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "external-auth recovery requires a matching observation barrier"
                )
            }
            return .committedDegraded(
                targetAccountId: targetAccountId,
                detail: .externalAuthObserved,
                activationGeneration: newActivationGeneration,
                retryAttempt: 0,
                nextRetryAt: date,
                at: date
            )
        }
    }

    @discardableResult
    func recoverConvergedConfiguredFiles(
        targetAccountId: UUID,
        newActivationGeneration: UUID = UUID(),
        authorizeEffect: @escaping StateEffectAuthorization = { _ in true },
        at date: Date = Date()
    ) throws -> AccountActivationState {
        try transition(authorizeEffect: authorizeEffect) { current in
            guard let current,
                  current.phase == .manualReview,
                  current.configuredAccountId == targetAccountId,
                  current.detail == .configuredFilesInconsistent else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "configured-file recovery requires the matching review"
                )
            }
            return .committedDegraded(
                targetAccountId: targetAccountId,
                detail: .externalAuthObserved,
                activationGeneration: newActivationGeneration,
                retryAttempt: 0,
                nextRetryAt: date,
                at: date
            )
        }
    }

    @discardableResult
    func adoptVerifiedExternalHandoff(
        targetAccountId: UUID,
        expectedState: AccountActivationState,
        newActivationGeneration: UUID = UUID(),
        authorizeEffect: @escaping StateEffectAuthorization = { _ in true },
        at date: Date = Date()
    ) throws -> AccountActivationState {
        try transition(authorizeEffect: authorizeEffect) { current in
            guard let current,
                  current == expectedState,
                  current.phase == .confirmed || current.phase == .committedDegraded else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "external handoff cannot replace an active activation barrier"
                )
            }
            return .committedDegraded(
                targetAccountId: targetAccountId,
                detail: .externalAuthObserved,
                activationGeneration: newActivationGeneration,
                retryAttempt: 0,
                nextRetryAt: date,
                at: date
            )
        }
    }

    @discardableResult
    func failVerifiedExternalHandoff(
        targetAccountId: UUID,
        expectedActivationGeneration: UUID,
        authorizeEffect: @escaping StateEffectAuthorization = { _ in true },
        at date: Date = Date()
    ) throws -> AccountActivationState {
        try transition(authorizeEffect: authorizeEffect) { current in
            guard let current,
                  current.phase == .committedDegraded,
                  current.configuredAccountId == targetAccountId,
                  current.activationGeneration == expectedActivationGeneration,
                  current.detail == .externalAuthObserved else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "external handoff failure does not match the adopted generation"
                )
            }
            return .manualReview(
                targetAccountId: targetAccountId,
                detail: .configuredFilesInconsistent,
                activationGeneration: expectedActivationGeneration,
                at: date
            )
        }
    }

    @discardableResult
    func markConfirmed(
        targetAccountId: UUID,
        expectedActivationGeneration: UUID,
        discoveredRuntimeCount: Int,
        acknowledgedRuntimeCount: Int,
        evidenceGeneration: UUID,
        evidenceObservedAt: Date,
        evidenceExpiresAt: Date,
        authorizeEffect: @escaping StateEffectAuthorization = { _ in true },
        at date: Date = Date()
    ) throws -> AccountActivationState {
        try transition(authorizeEffect: authorizeEffect) { current in
            guard let current,
                  current.configuredAccountId == targetAccountId,
                  current.activationGeneration == expectedActivationGeneration,
                  current.phase == .committedDegraded else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "confirmation does not match committed activation evidence"
                )
            }
            return AccountActivationState(
                version: AccountActivationState.currentVersion,
                phase: .confirmed,
                activationGeneration: current.activationGeneration,
                configuredAccountId: targetAccountId,
                runtimeCurrentAccountId: targetAccountId,
                updatedAt: date,
                retryAttempt: 0,
                nextRetryAt: nil,
                discoveredRuntimeCount: discoveredRuntimeCount,
                acknowledgedRuntimeCount: acknowledgedRuntimeCount,
                detail: nil,
                runtimeEvidenceGeneration: evidenceGeneration,
                runtimeEvidenceObservedAt: evidenceObservedAt,
                runtimeEvidenceExpiresAt: evidenceExpiresAt,
                runtimeBlockers: nil
            )
        }
    }

    @discardableResult
    func demoteForRuntimeEvidenceLoss(
        targetAccountId: UUID,
        expectedActivationGeneration: UUID? = nil,
        detail: AccountActivationDetail,
        discoveredRuntimeCount: Int = 0,
        acknowledgedRuntimeCount: Int = 0,
        at date: Date = Date()
    ) throws -> AccountActivationState {
        try transition { current in
            guard let current,
                  current.configuredAccountId == targetAccountId,
                  expectedActivationGeneration.map({ $0 == current.activationGeneration }) ?? true,
                  current.phase == .confirmed || current.phase == .committedDegraded else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "runtime evidence loss does not match the configured activation"
                )
            }
            return .committedDegraded(
                targetAccountId: targetAccountId,
                detail: detail,
                activationGeneration: current.activationGeneration,
                retryAttempt: current.retryAttempt,
                nextRetryAt: date,
                discoveredRuntimeCount: discoveredRuntimeCount,
                acknowledgedRuntimeCount: acknowledgedRuntimeCount,
                at: date
            )
        }
    }

    @discardableResult
    func refreshConfirmedRuntimeEvidence(
        targetAccountId: UUID,
        expectedActivationGeneration: UUID,
        evidence: AccountActivationRuntimeEvidence,
        at date: Date = Date(),
        authorizeEffect: StateEffectAuthorization = { _ in true }
    ) throws -> AccountActivationState {
        try transition { current in
            guard authorizeEffect(current),
                  let current,
                  current.phase == .confirmed,
                  current.configuredAccountId == targetAccountId,
                  current.activationGeneration == expectedActivationGeneration else {
                throw AccountActivationCoordinatorError.invalidTransition(
                    "runtime evidence refresh does not match confirmed activation"
                )
            }
            return AccountActivationState(
                version: AccountActivationState.currentVersion,
                phase: .confirmed,
                activationGeneration: current.activationGeneration,
                configuredAccountId: targetAccountId,
                runtimeCurrentAccountId: targetAccountId,
                updatedAt: date,
                retryAttempt: 0,
                nextRetryAt: nil,
                discoveredRuntimeCount: evidence.discoveredRuntimeCount,
                acknowledgedRuntimeCount: evidence.acknowledgedRuntimeCount,
                detail: nil,
                runtimeEvidenceGeneration: evidence.generation,
                runtimeEvidenceObservedAt: evidence.observedAt,
                runtimeEvidenceExpiresAt: evidence.expiresAt,
                runtimeBlockers: nil
            )
        }
    }

    @discardableResult
    func markManualReview(
        targetAccountId: UUID?,
        detail: AccountActivationDetail,
        authorizeEffect: StateEffectAuthorization = { _ in true },
        at date: Date = Date()
    ) throws -> AccountActivationState {
        try transition(authorizeEffect: authorizeEffect) { current in
            .manualReview(
                targetAccountId: targetAccountId ?? current?.configuredAccountId,
                detail: detail,
                activationGeneration: current?.activationGeneration ?? UUID(),
                retryAttempt: current?.retryAttempt ?? 0,
                at: date
            )
        }
    }

    nonisolated static func retryDelay(
        attempt: Int,
        base: TimeInterval = 30,
        maximum: TimeInterval = 5 * 60
    ) -> TimeInterval {
        let boundedAttempt = min(max(attempt, 1), 20)
        let multiplier = pow(2, Double(boundedAttempt - 1))
        return min(maximum, base * multiplier)
    }

    private func transition(
        authorizeEffect: StateEffectAuthorization = { _ in true },
        _ makeState: (AccountActivationState?) throws -> AccountActivationState
    ) throws -> AccountActivationState {
        try withRuntimeLease {
            try transitionUnderRuntimeLease(
                authorizeEffect: authorizeEffect,
                makeState
            )
        }
    }

    private func withRuntimeLease<Value>(
        _ operation: () throws -> Value
    ) throws -> Value {
        if AccountActivationCrossProcessLeaseContext.holds(crossProcessLeaseURL) {
            return try operation()
        }
        guard let crossProcessLease =
                AccountActivationCrossProcessLease.acquireForAccountMutation(
                    at: crossProcessLeaseURL
                ) else {
            throw AccountActivationCoordinatorError.authorizationRevoked
        }
        defer { crossProcessLease.release() }
        return try AccountActivationCrossProcessLeaseContext.$heldLease.withValue(
            crossProcessLease
        ) {
            try operation()
        }
    }

    private func transitionUnderRuntimeLease(
        authorizeEffect: StateEffectAuthorization,
        _ makeState: (AccountActivationState?) throws -> AccountActivationState
    ) throws -> AccountActivationState {
        try transaction.withExclusiveLock { lockedFile in
            let currentSnapshot = try lockedFile.read()
            let current = try Self.decode(currentSnapshot.bytes)
            let proposed = try makeState(current)
            guard authorizeEffect(current) else {
                throw AccountActivationCoordinatorError.authorizationRevoked
            }
            try Self.validate(proposed)
            let data = try Self.encode(proposed)
            let readback = try lockedFile.replace(
                data,
                expectedGeneration: currentSnapshot.generation
            )
            guard try Self.decode(readback.bytes) == proposed else {
                throw AccountActivationCoordinatorError.readbackMismatch
            }
            return proposed
        }
    }

    nonisolated private static func encode(_ state: AccountActivationState) throws -> Data {
        try validate(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= maximumJournalBytes else {
            throw AccountActivationCoordinatorError.journalTooLarge(data.count)
        }
        return data
    }

    nonisolated private static func decode(_ data: Data?) throws -> AccountActivationState? {
        guard let data else { return nil }
        guard data.count <= maximumJournalBytes else {
            throw AccountActivationCoordinatorError.journalTooLarge(data.count)
        }
        let allowedKeys: Set<String> = [
            "version",
            "phase",
            "activationGeneration",
            "configuredAccountId",
            "runtimeCurrentAccountId",
            "updatedAt",
            "retryAttempt",
            "nextRetryAt",
            "discoveredRuntimeCount",
            "acknowledgedRuntimeCount",
            "detail",
            "runtimeEvidenceGeneration",
            "runtimeEvidenceObservedAt",
            "runtimeEvidenceExpiresAt",
            "runtimeBlockers",
        ]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: allowedKeys) else {
                throw AccountActivationCoordinatorError.corruptJournal(
                    "unexpected structure or fields"
                )
            }
        } catch let error as AccountActivationCoordinatorError {
            throw error
        } catch {
            throw AccountActivationCoordinatorError.corruptJournal("invalid JSON or schema")
        }
        let state: AccountActivationState
        do {
            state = try JSONDecoder().decode(AccountActivationState.self, from: data)
        } catch {
            throw AccountActivationCoordinatorError.corruptJournal("invalid JSON or schema")
        }
        try validate(state)
        return state
    }

    nonisolated private static func validate(_ state: AccountActivationState) throws {
        guard state.version == AccountActivationState.currentVersion else {
            throw AccountActivationCoordinatorError.corruptJournal(
                "unsupported version \(state.version)"
            )
        }
        guard state.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AccountActivationCoordinatorError.corruptJournal("invalid update time")
        }
        let evidenceDates = [state.runtimeEvidenceObservedAt, state.runtimeEvidenceExpiresAt]
            .compactMap { $0 }
        guard evidenceDates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw AccountActivationCoordinatorError.corruptJournal("invalid runtime evidence time")
        }
        guard (0...maximumRuntimeCount).contains(state.discoveredRuntimeCount),
              (0...state.discoveredRuntimeCount).contains(state.acknowledgedRuntimeCount),
              state.convergenceBlockers.count <= state.discoveredRuntimeCount,
              state.convergenceBlockers.count <= maximumRuntimeCount,
              state.convergenceBlockers.allSatisfy({ $0.pid > 0 }),
              (0...maximumRetryAttempt).contains(state.retryAttempt) else {
            throw AccountActivationCoordinatorError.corruptJournal("counter is outside its bound")
        }
        if let detail = state.detail,
           detail.rawValue.lengthOfBytes(using: .utf8) > maximumDetailBytes {
            throw AccountActivationCoordinatorError.corruptJournal("detail exceeds its bound")
        }

        switch state.phase {
        case .preparing:
            guard state.configuredAccountId != nil,
                  state.runtimeCurrentAccountId == nil,
                  (0..<legacyAutomaticRetryLimit).contains(state.retryAttempt),
                  state.nextRetryAt == nil,
                  state.discoveredRuntimeCount == 0,
                  state.acknowledgedRuntimeCount == 0,
                  state.convergenceBlockers.isEmpty,
                  state.runtimeEvidenceGeneration == nil,
                  state.runtimeEvidenceObservedAt == nil,
                  state.runtimeEvidenceExpiresAt == nil else {
                throw AccountActivationCoordinatorError.corruptJournal("invalid preparing state")
            }
        case .committedDegraded:
            guard state.configuredAccountId != nil,
                  state.runtimeCurrentAccountId == nil,
                  (0...maximumRetryAttempt).contains(state.retryAttempt),
                  let nextRetryAt = state.nextRetryAt,
                  nextRetryAt >= state.updatedAt,
                  state.runtimeEvidenceGeneration == nil,
                  state.runtimeEvidenceObservedAt == nil,
                  state.runtimeEvidenceExpiresAt == nil else {
                throw AccountActivationCoordinatorError.corruptJournal("invalid degraded state")
            }
        case .confirmed:
            guard let configuredAccountId = state.configuredAccountId,
                  state.runtimeCurrentAccountId == configuredAccountId,
                  state.retryAttempt == 0,
                  state.nextRetryAt == nil,
                  state.discoveredRuntimeCount > 0,
                  state.acknowledgedRuntimeCount == state.discoveredRuntimeCount,
                  state.convergenceBlockers.isEmpty,
                  state.detail == nil,
                  state.runtimeEvidenceGeneration != nil,
                  let observedAt = state.runtimeEvidenceObservedAt,
                  let expiresAt = state.runtimeEvidenceExpiresAt,
                  observedAt <= state.updatedAt,
                  expiresAt > state.updatedAt,
                  expiresAt > observedAt else {
                throw AccountActivationCoordinatorError.corruptJournal("invalid confirmed state")
            }
        case .manualReview:
            guard state.runtimeCurrentAccountId == nil,
                  state.nextRetryAt == nil,
                  state.detail != nil,
                  state.runtimeEvidenceGeneration == nil,
                  state.runtimeEvidenceObservedAt == nil,
                  state.runtimeEvidenceExpiresAt == nil else {
                throw AccountActivationCoordinatorError.corruptJournal("invalid manual-review state")
            }
            if state.detail == .automaticRetryLimitReached,
               (state.configuredAccountId == nil
                    || state.retryAttempt < legacyAutomaticRetryLimit) {
                throw AccountActivationCoordinatorError.corruptJournal(
                    "retry-limit review is missing its target"
                )
            }
            if state.detail != .automaticRetryLimitReached,
               (state.discoveredRuntimeCount != 0
                    || state.acknowledgedRuntimeCount != 0
                    || !state.convergenceBlockers.isEmpty) {
                throw AccountActivationCoordinatorError.corruptJournal(
                    "manual-review runtime counts are not authorized"
                )
            }
        }
    }
}
