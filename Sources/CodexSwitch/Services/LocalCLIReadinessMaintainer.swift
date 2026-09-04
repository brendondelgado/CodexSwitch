import Foundation

struct LocalCLIReadinessMaintenanceAuthority: Equatable, Sendable {
    let accountId: UUID
    let providerAccountId: String
    let activationGeneration: UUID
}

struct LocalCLIReadinessMaintenanceAttempt: Equatable, Sendable {
    let id: UUID
    let authority: LocalCLIReadinessMaintenanceAuthority
}

enum LocalCLIReadinessMaintenanceOutcome: Equatable, Sendable {
    case maintained
    case noRuntime
    case leaseContended
    case authorizationRevoked
    case failed
}

struct LocalCLIReadinessMaintainer {
    struct Configuration: Equatable, Sendable {
        let acknowledgementLifetime: TimeInterval
        let renewalLeadTime: TimeInterval
        let initialRetryDelay: TimeInterval
        let maximumRetryDelay: TimeInterval

        static let production = Configuration(
            acknowledgementLifetime: SwapEngine.maximumReloadAcknowledgementAge,
            renewalLeadTime: SwapEngine.localCLIReadinessRenewalLeadTime,
            initialRetryDelay: 15,
            maximumRetryDelay: 60
        )
    }

    private let configuration: Configuration
    private var observedAuthority: LocalCLIReadinessMaintenanceAuthority?
    private var observedTopology: CodexRuntimeDiscoverySnapshot?
    private var inFlightAttempt: LocalCLIReadinessMaintenanceAttempt?
    private var retryFailureCount = 0
    private var retryAfter: Date?

    init(configuration: Configuration = .production) {
        self.configuration = configuration
    }

    var hasInFlightAttempt: Bool {
        inFlightAttempt != nil
    }

    mutating func beginMaintenanceIfNeeded(
        observation: CodexLocalRuntimeReadinessObservation,
        authority: LocalCLIReadinessMaintenanceAuthority,
        at now: Date
    ) -> LocalCLIReadinessMaintenanceAttempt? {
        guard inFlightAttempt == nil else { return nil }

        let authorityChanged = observedAuthority != authority
        let topologyChanged = observedTopology != observation.discovery
        if authorityChanged || topologyChanged {
            retryFailureCount = 0
            retryAfter = nil
        }
        observedAuthority = authority
        observedTopology = observation.discovery

        guard observation.discovery.isComplete else { return nil }
        guard !observation.discovery.targets.isEmpty else {
            retryFailureCount = 0
            retryAfter = nil
            return nil
        }
        guard observation.discovery.targets.allSatisfy({
            $0.runtimeKind == .localInteractiveCLI
        }) else {
            return nil
        }
        if let retryAfter, now < retryAfter { return nil }

        let evidenceIsCurrent = observation.evidence.isComplete
            && observation.evidence.runtimes.count == observation.discovery.targets.count
            && observation.evidence.runtimes.allSatisfy {
                $0.observation.authFileIdentity.accountID == authority.providerAccountId
                    && $0.startupAcknowledgement.binding.authFileIdentity
                        == $0.observation.authFileIdentity
            }
        if evidenceIsCurrent,
           let oldestAcknowledgement = observation.evidence.runtimes
            .map(\.startupAcknowledgement.acknowledgedAtUnixMilliseconds)
            .min() {
            let renewalAge = max(
                0,
                configuration.acknowledgementLifetime - configuration.renewalLeadTime
            )
            let renewalDate = Date(
                timeIntervalSince1970:
                    TimeInterval(oldestAcknowledgement) / 1_000 + renewalAge
            )
            guard now >= renewalDate else { return nil }
        }

        let attempt = LocalCLIReadinessMaintenanceAttempt(
            id: UUID(),
            authority: authority
        )
        inFlightAttempt = attempt
        return attempt
    }

    mutating func complete(
        _ attempt: LocalCLIReadinessMaintenanceAttempt,
        outcome: LocalCLIReadinessMaintenanceOutcome,
        at now: Date
    ) {
        guard inFlightAttempt == attempt else { return }
        inFlightAttempt = nil

        switch outcome {
        case .maintained, .noRuntime:
            retryFailureCount = 0
            retryAfter = nil
        case .leaseContended, .authorizationRevoked, .failed:
            retryFailureCount = min(retryFailureCount + 1, 63)
            retryAfter = now.addingTimeInterval(retryDelay(for: retryFailureCount))
        }
    }

    mutating func deactivate() {
        observedAuthority = nil
        observedTopology = nil
        retryFailureCount = 0
        retryAfter = nil
    }

    private func retryDelay(for failureCount: Int) -> TimeInterval {
        guard failureCount > 0 else { return 0 }
        let exponent = min(failureCount - 1, 20)
        let multiplier = pow(2, Double(exponent))
        return min(
            configuration.maximumRetryDelay,
            configuration.initialRetryDelay * multiplier
        )
    }
}

enum LocalCLIReadinessMaintenanceRunner {
    typealias Authorization = @Sendable () -> Bool
    typealias AuthorizationProvider = @MainActor @Sendable (
        AccountMutationLease
    ) -> Authorization?
    typealias Reload = @Sendable (
        @escaping Authorization
    ) async -> CodexReloadSummary

    @MainActor
    static func run(
        transaction: AccountActivationTransaction,
        authority: LocalCLIReadinessMaintenanceAuthority,
        makeAuthorization: AuthorizationProvider,
        reload: Reload
    ) async -> LocalCLIReadinessMaintenanceOutcome {
        let leasedOutcome: LocalCLIReadinessMaintenanceOutcome? =
            await transaction.withActivationLease(
                targetAccountId: authority.accountId,
                activationGeneration: authority.activationGeneration
            ) { lease in
                guard let authorization = makeAuthorization(lease),
                      authorization() else {
                    return .authorizationRevoked
                }
                let summary = await reload(authorization)
                guard authorization() else { return .authorizationRevoked }
                switch summary.outcome {
                case .allDiscoveredRuntimesAcknowledged:
                    return .maintained
                case .noLocalRuntime:
                    return .noRuntime
                case .restartRequiredOrFailed:
                    return .failed
                }
            }
        return leasedOutcome ?? .leaseContended
    }
}
