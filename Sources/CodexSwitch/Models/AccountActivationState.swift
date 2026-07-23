import Foundation

enum AccountActivationPhase: String, Codable, Equatable, Sendable {
    case preparing
    case committedDegraded = "committed_degraded"
    case confirmed
    case manualReview = "manual_review"
}

enum AccountActivationDetail: String, Codable, Equatable, Sendable {
    case runtimeConfirmationPending = "runtime_confirmation_pending"
    case noLocalRuntime = "no_local_runtime"
    case runtimeAcknowledgementIncomplete = "runtime_ack_incomplete"
    case restartRecoveredCommittedFiles = "restart_recovered_committed_files"
    case launchRuntimeEvidenceExpired = "launch_runtime_evidence_expired"
    case runtimeEvidenceExpired = "runtime_evidence_expired"
    // Retained for existing journals; desktop exit now triggers passive revalidation.
    case desktopRuntimeExited = "desktop_runtime_exited"
    case activeCredentialMutation = "active_credential_mutation"
    case externalAuthObserved = "external_auth_observed"
    case externalAuthConflict = "external_auth_conflict"
    case externalAuthTargetUnknown = "external_auth_target_unknown"
    case externalAuthAbsent = "external_auth_absent"
    case externalAuthInvalid = "external_auth_invalid"
    case externalAuthUnreadable = "external_auth_unreadable"
    case durableConfigurationChanged = "durable_configuration_changed"
    case automaticRetryLimitReached = "automatic_retry_limit_reached"
    case configuredTargetMissing = "configured_target_missing"
    case configuredFilesInconsistent = "configured_files_inconsistent"
    case journalUnavailable = "activation_journal_unavailable"
    case prepareFailed = "activation_prepare_failed"
    case committedJournalUpdateFailed = "committed_journal_update_failed"
    case runtimeEvidencePersistFailed = "runtime_evidence_persist_failed"
    case fileCommitFailed = "activation_file_commit_failed"

    var allowsManualSameTargetRetry: Bool {
        switch self {
        case .automaticRetryLimitReached, .durableConfigurationChanged:
            return true
        default:
            return false
        }
    }

    var allowsManualCrossTargetEscape: Bool {
        self == .automaticRetryLimitReached
    }

    var allowsLaunchSameTargetRecovery: Bool {
        self == .durableConfigurationChanged
    }

    var allowsVerifiedExternalAuthRecovery: Bool {
        switch self {
        case .externalAuthAbsent, .externalAuthInvalid, .externalAuthUnreadable:
            return true
        default:
            return false
        }
    }
}

enum AccountActivationRequestKind: Equatable, Sendable {
    case automatic
    case manual
}

enum AccountActivationRequestDecision: Equatable, Sendable {
    case beginActivation
    case retrySameTarget
    case blocked(String)
}

struct AccountActivationState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let phase: AccountActivationPhase
    let activationGeneration: UUID
    let configuredAccountId: UUID?
    let runtimeCurrentAccountId: UUID?
    let updatedAt: Date
    let retryAttempt: Int
    let nextRetryAt: Date?
    let discoveredRuntimeCount: Int
    let acknowledgedRuntimeCount: Int
    let detail: AccountActivationDetail?
    let runtimeEvidenceGeneration: UUID?
    let runtimeEvidenceObservedAt: Date?
    let runtimeEvidenceExpiresAt: Date?

    var blocksAutomaticMutations: Bool {
        !authorizesAutomaticMutations(at: Date())
    }

    func authorizesAutomaticMutations(
        at date: Date,
        evidenceGeneration: UUID? = nil
    ) -> Bool {
        guard phase == .confirmed,
              runtimeEvidenceObservedAt.map({ $0 <= date }) == true,
              runtimeEvidenceExpiresAt.map({ $0 > date }) == true,
              runtimeEvidenceGeneration != nil else {
            return false
        }
        return evidenceGeneration.map { $0 == runtimeEvidenceGeneration } ?? true
    }

    func runtimeIsCurrent(for accountId: UUID, at date: Date = Date()) -> Bool {
        phase == .confirmed
            && configuredAccountId == accountId
            && runtimeCurrentAccountId == accountId
            && authorizesAutomaticMutations(at: date)
    }

    func automaticRetryTarget(at date: Date) -> UUID? {
        guard phase == .committedDegraded,
              let configuredAccountId,
              nextRetryAt.map({ $0 <= date }) ?? false else {
            return nil
        }
        return configuredAccountId
    }

    func decision(
        forRequestedTarget accountId: UUID,
        kind: AccountActivationRequestKind,
        at date: Date = Date()
    ) -> AccountActivationRequestDecision {
        switch phase {
        case .confirmed:
            guard authorizesAutomaticMutations(at: date) else {
                return .blocked(
                    "Mac runtime confirmation expired; reconcile the configured account"
                )
            }
            return .beginActivation
        case .committedDegraded:
            if kind == .manual {
                return configuredAccountId == accountId
                    ? .retrySameTarget
                    : .beginActivation
            }
            return .blocked(
                "Mac runtime is not confirmed; restart or retry the configured account"
            )
        case .preparing:
            return .blocked("Mac account activation is incomplete; account changes are paused")
        case .manualReview:
            if kind == .manual, let detail {
                if configuredAccountId == accountId,
                   detail.allowsManualSameTargetRetry {
                    return .retrySameTarget
                }
                if detail.allowsManualCrossTargetEscape {
                    return .beginActivation
                }
            }
            return .blocked("Mac activation state needs manual review; account changes are paused")
        }
    }

    static func preparing(
        targetAccountId: UUID,
        activationGeneration: UUID = UUID(),
        retryAttempt: Int = 0,
        at date: Date
    ) -> Self {
        Self(
            version: currentVersion,
            phase: .preparing,
            activationGeneration: activationGeneration,
            configuredAccountId: targetAccountId,
            runtimeCurrentAccountId: nil,
            updatedAt: date,
            retryAttempt: retryAttempt,
            nextRetryAt: nil,
            discoveredRuntimeCount: 0,
            acknowledgedRuntimeCount: 0,
            detail: nil,
            runtimeEvidenceGeneration: nil,
            runtimeEvidenceObservedAt: nil,
            runtimeEvidenceExpiresAt: nil
        )
    }

    static func manualReview(
        targetAccountId: UUID?,
        detail: AccountActivationDetail,
        activationGeneration: UUID = UUID(),
        retryAttempt: Int = 0,
        discoveredRuntimeCount: Int = 0,
        acknowledgedRuntimeCount: Int = 0,
        at date: Date
    ) -> Self {
        Self(
            version: currentVersion,
            phase: .manualReview,
            activationGeneration: activationGeneration,
            configuredAccountId: targetAccountId,
            runtimeCurrentAccountId: nil,
            updatedAt: date,
            retryAttempt: retryAttempt,
            nextRetryAt: nil,
            discoveredRuntimeCount: discoveredRuntimeCount,
            acknowledgedRuntimeCount: acknowledgedRuntimeCount,
            detail: detail,
            runtimeEvidenceGeneration: nil,
            runtimeEvidenceObservedAt: nil,
            runtimeEvidenceExpiresAt: nil
        )
    }

    static func committedDegraded(
        targetAccountId: UUID,
        detail: AccountActivationDetail,
        activationGeneration: UUID,
        retryAttempt: Int,
        nextRetryAt: Date,
        discoveredRuntimeCount: Int = 0,
        acknowledgedRuntimeCount: Int = 0,
        at date: Date
    ) -> Self {
        Self(
            version: currentVersion,
            phase: .committedDegraded,
            activationGeneration: activationGeneration,
            configuredAccountId: targetAccountId,
            runtimeCurrentAccountId: nil,
            updatedAt: date,
            retryAttempt: retryAttempt,
            nextRetryAt: nextRetryAt,
            discoveredRuntimeCount: discoveredRuntimeCount,
            acknowledgedRuntimeCount: acknowledgedRuntimeCount,
            detail: detail,
            runtimeEvidenceGeneration: nil,
            runtimeEvidenceObservedAt: nil,
            runtimeEvidenceExpiresAt: nil
        )
    }
}
