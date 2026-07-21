import Foundation

struct AccountActivationRuntimeEvidence: Equatable, Sendable {
    let generation: UUID
    let runtimeCurrentAccountId: UUID
    let observedAt: Date
    let expiresAt: Date
    let discoveredRuntimeCount: Int
    let acknowledgedRuntimeCount: Int
    let runtimeBindings: [CodexReloadBinding]

    init(
        generation: UUID,
        runtimeCurrentAccountId: UUID,
        observedAt: Date,
        expiresAt: Date,
        discoveredRuntimeCount: Int,
        acknowledgedRuntimeCount: Int,
        runtimeBindings: [CodexReloadBinding] = []
    ) {
        self.generation = generation
        self.runtimeCurrentAccountId = runtimeCurrentAccountId
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.discoveredRuntimeCount = discoveredRuntimeCount
        self.acknowledgedRuntimeCount = acknowledgedRuntimeCount
        self.runtimeBindings = runtimeBindings
    }

    var hasConcreteRuntimeBindings: Bool {
        discoveredRuntimeCount > 0
            && acknowledgedRuntimeCount == discoveredRuntimeCount
            && runtimeBindings.count == discoveredRuntimeCount
            && Set(runtimeBindings.map(\.processIdentity.pid)).count == runtimeBindings.count
    }

    func hasSameRuntimeTopology(as current: AccountActivationRuntimeEvidence) -> Bool {
        guard hasConcreteRuntimeBindings,
              current.hasConcreteRuntimeBindings,
              runtimeCurrentAccountId == current.runtimeCurrentAccountId,
              runtimeBindings.count == current.runtimeBindings.count else {
            return false
        }
        let expected = sortedRuntimeBindings
        let observed = current.sortedRuntimeBindings
        return zip(expected, observed).allSatisfy { pair in
            SwapEngine.bindingHasSameRuntimeAuthority(pair.0, pair.1)
        }
    }

    func matchesRediscoveredRuntimeTopology(
        cli: CodexLocalRuntimeEvidenceSnapshot,
        desktop: CodexLocalRuntimeEvidenceSnapshot
    ) -> Bool {
        let snapshots = [cli, desktop]
        guard snapshots.allSatisfy(\.isComplete) else { return false }
        let bindings = snapshots
            .flatMap(\.runtimes)
            .map(\.startupAcknowledgement.binding)
        let rediscovered = AccountActivationRuntimeEvidence(
            generation: generation,
            runtimeCurrentAccountId: runtimeCurrentAccountId,
            observedAt: observedAt,
            expiresAt: expiresAt,
            discoveredRuntimeCount: bindings.count,
            acknowledgedRuntimeCount: bindings.count,
            runtimeBindings: bindings
        )
        return hasSameRuntimeTopology(as: rediscovered)
    }

    private var sortedRuntimeBindings: [CodexReloadBinding] {
        runtimeBindings.sorted { lhs, rhs in
            if lhs.processIdentity.pid != rhs.processIdentity.pid {
                return lhs.processIdentity.pid < rhs.processIdentity.pid
            }
            if lhs.runtimeKind.rawValue != rhs.runtimeKind.rawValue {
                return lhs.runtimeKind.rawValue < rhs.runtimeKind.rawValue
            }
            return lhs.requestNonce < rhs.requestNonce
        }
    }
}

struct AccountActivationRuntimeRenewal: Equatable, Sendable {
    let cliReload: CodexReloadSummary
    let desktopReload: DesktopReloadResult
}

struct AccountActivationRuntimeSnapshotSet: Sendable {
    let cli: CodexLocalRuntimeEvidenceSnapshot
    let desktop: CodexLocalRuntimeEvidenceSnapshot
    let observedAt: Date
}

enum AccountActivationRuntimeEvidencePreflight {
    static func performRenewal(
        desktopReload: @Sendable () async -> DesktopReloadResult,
        cliReload: @Sendable () async -> CodexReloadSummary
    ) async -> AccountActivationRuntimeRenewal {
        let desktop = await desktopReload()
        let cli: CodexReloadSummary
        switch desktop {
        case .reloaded, .noDesktopRuntime:
            cli = await cliReload()
        case .failed, .unsupported:
            cli = CodexReloadSummary(
                discoveredRuntimeCount: 0,
                acknowledgedRuntimeCount: 0
            )
        }
        return AccountActivationRuntimeRenewal(
            cliReload: cli,
            desktopReload: desktop
        )
    }

    static func renewAndEvaluate(
        expectedAccountId: UUID,
        expectedAuthIdentity: CodexAuthFileIdentity,
        lifetime: TimeInterval = AccountActivationCoordinator.runtimeEvidenceLifetime,
        generation: UUID = UUID(),
        renew: @Sendable () async -> AccountActivationRuntimeRenewal,
        capture: @Sendable () async -> AccountActivationRuntimeSnapshotSet?,
        runtimeBindingIsCurrent: @Sendable (CodexReloadBinding) -> Bool
    ) async -> AccountActivationRuntimeEvidenceDecision {
        let renewal = await renew()
        let completion = AccountActivationConvergenceEvaluator.completion(
            cliReload: renewal.cliReload,
            desktopReload: renewal.desktopReload
        )
        guard completion.outcome == .runtimeCurrent else {
            return .denied(
                detail: completion.outcome == .configuredOnly
                    ? .noLocalRuntime
                    : .runtimeAcknowledgementIncomplete,
                discoveredRuntimeCount: completion.discoveredRuntimeCount,
                acknowledgedRuntimeCount: completion.acknowledgedRuntimeCount
            )
        }
        guard let snapshots = await capture() else {
            return .denied(
                detail: .durableConfigurationChanged,
                discoveredRuntimeCount: completion.discoveredRuntimeCount,
                acknowledgedRuntimeCount: completion.acknowledgedRuntimeCount
            )
        }
        return AccountActivationRuntimeEvidenceEvaluator.evaluate(
            cli: snapshots.cli,
            desktop: snapshots.desktop,
            expectedAccountId: expectedAccountId,
            expectedAuthIdentity: expectedAuthIdentity,
            observedAt: snapshots.observedAt,
            lifetime: lifetime,
            generation: generation,
            runtimeBindingIsCurrent: runtimeBindingIsCurrent
        )
    }
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

enum AccountCredentialMutationRuntimePolicy {
    static func requiresSourceRuntimeEvidence(
        route: AccountCredentialMutationRoute,
        reason: SwapEvent.SwapReason
    ) -> Bool {
        switch route {
        case .swap:
            return reason != .manual
        case .tokenRefresh, .activeReauthentication, .planUpgrade:
            return true
        case .firstActivation, .externalAuthObservation:
            return false
        }
    }
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
    static let maximumAcknowledgementAge = SwapEngine.maximumReloadAcknowledgementAge

    static func evaluate(
        cli: CodexLocalRuntimeEvidenceSnapshot,
        desktop: CodexLocalRuntimeEvidenceSnapshot,
        expectedAccountId: UUID,
        expectedAuthIdentity: CodexAuthFileIdentity,
        observedAt: Date,
        lifetime: TimeInterval = AccountActivationCoordinator.runtimeEvidenceLifetime,
        generation: UUID = UUID(),
        runtimeBindingIsCurrent: (CodexReloadBinding) -> Bool
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
                && SwapEngine.acknowledgementSupportsPassiveRuntimeEvidence(
                    acknowledgement,
                    observation: evidence.observation
                )
                && runtimeBindingIsCurrent(acknowledgement.binding)
        }) else {
            return .denied(
                detail: .runtimeAcknowledgementIncomplete,
                discoveredRuntimeCount: discovered,
                acknowledgedRuntimeCount: 0
            )
        }
        let acknowledgementDates = runtimes.map {
            Date(
                timeIntervalSince1970: TimeInterval(
                    $0.startupAcknowledgement.acknowledgedAtUnixMilliseconds
                ) / 1_000
            )
        }
        guard acknowledgementDates.allSatisfy({ acknowledgementDate in
            let age = observedAt.timeIntervalSince(acknowledgementDate)
            return age >= 0 && age <= maximumAcknowledgementAge
        }), let evidenceObservedAt = acknowledgementDates.min() else {
            return .denied(
                detail: .runtimeAcknowledgementIncomplete,
                discoveredRuntimeCount: discovered,
                acknowledgedRuntimeCount: 0
            )
        }
        let boundedLifetime = max(1, min(lifetime, 30))
        let expiresAt = evidenceObservedAt.addingTimeInterval(boundedLifetime)
        guard expiresAt > observedAt else {
            return .denied(
                detail: .runtimeAcknowledgementIncomplete,
                discoveredRuntimeCount: discovered,
                acknowledgedRuntimeCount: 0
            )
        }
        return .confirmed(AccountActivationRuntimeEvidence(
            generation: generation,
            runtimeCurrentAccountId: expectedAccountId,
            observedAt: evidenceObservedAt,
            expiresAt: expiresAt,
            discoveredRuntimeCount: discovered,
            acknowledgedRuntimeCount: discovered,
            runtimeBindings: runtimes.map(\.startupAcknowledgement.binding)
        ))
    }
}
