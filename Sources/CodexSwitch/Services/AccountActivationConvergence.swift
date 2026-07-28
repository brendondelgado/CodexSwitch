import Foundation

enum AccountActivationRuntimeOutcome: Equatable, Sendable {
    case runtimeCurrent
    case configuredOnly
    case restartRequired
}

struct AccountActivationRuntimeCompletion: Equatable, Sendable {
    let outcome: AccountActivationRuntimeOutcome
    let discoveredRuntimeCount: Int
    let acknowledgedRuntimeCount: Int
    let detail: String?
    let blockers: Set<CodexRuntimeDiscoveryBlocker>
}

enum AccountActivationConvergenceEvaluator {
    static func completion(
        cliReload: CodexReloadSummary,
        desktopReload: DesktopReloadResult
    ) -> AccountActivationRuntimeCompletion {
        let desktopCounts: (discovered: Int, acknowledged: Int)
        var divergenceDetails: [String] = []

        switch cliReload.outcome {
        case .noLocalRuntime, .allDiscoveredRuntimesAcknowledged:
            break
        case .restartRequiredOrFailed:
            if cliReload.operationFailed {
                divergenceDetails.append("cli_discovery_or_reload_failed")
            } else {
                divergenceDetails.append(
                    "cli_acknowledged_\(cliReload.acknowledgedRuntimeCount)_of_\(cliReload.discoveredRuntimeCount)"
                )
            }
        }
        if !cliReload.blockers.isEmpty {
            let blockerSummary = cliReload.blockers
                .sorted {
                    $0.pid == $1.pid
                        ? $0.reason.rawValue < $1.reason.rawValue
                        : $0.pid < $1.pid
                }
                .map { "pid_\($0.pid)_\($0.reason.rawValue)" }
                .joined(separator: ";")
            divergenceDetails.append("cli_blockers_\(blockerSummary)")
        }

        switch desktopReload {
        case .reloaded(_, let discovered, let acknowledged, _):
            desktopCounts = (discovered, acknowledged)
            if discovered <= 0 || acknowledged != discovered {
                divergenceDetails.append(
                    "desktop_acknowledged_\(acknowledged)_of_\(discovered)"
                )
            }
        case .noDesktopRuntime:
            desktopCounts = (0, 0)
        case .unsupported(let discovered, let acknowledged):
            desktopCounts = (discovered, acknowledged)
            divergenceDetails.append("desktop_json_rpc_unsupported")
        case .failed(let reason, let discovered, let acknowledged):
            desktopCounts = (discovered, acknowledged)
            divergenceDetails.append("desktop_json_rpc_failed_\(reason)")
        }

        let discoveredRuntimeCount = cliReload.discoveredRuntimeCount
            + desktopCounts.discovered
        let acknowledgedRuntimeCount = cliReload.acknowledgedRuntimeCount
            + desktopCounts.acknowledged
        let outcome: AccountActivationRuntimeOutcome
        if !divergenceDetails.isEmpty {
            outcome = .restartRequired
        } else if discoveredRuntimeCount == 0 {
            outcome = .configuredOnly
        } else {
            outcome = .runtimeCurrent
        }

        return AccountActivationRuntimeCompletion(
            outcome: outcome,
            discoveredRuntimeCount: discoveredRuntimeCount,
            acknowledgedRuntimeCount: acknowledgedRuntimeCount,
            detail: divergenceDetails.isEmpty ? nil : divergenceDetails.joined(separator: ","),
            blockers: cliReload.blockers
        )
    }
}

enum AccountActivationReloadTransactionResult: Equatable, Sendable {
    case cancelledAfterDesktop(DesktopReloadResult)
    case completed(
        desktopReload: DesktopReloadResult,
        completion: AccountActivationRuntimeCompletion
    )
}

struct AccountActivationReloadTransaction: Sendable {
    typealias DesktopReload = @Sendable (CodexAccount) async -> DesktopReloadResult
    typealias CLIReload = @Sendable (Set<Int32>) -> CodexReloadSummary

    private let desktopReload: DesktopReload
    private let cliReload: CLIReload

    init(
        desktopReload: @escaping DesktopReload = { account in
            await DesktopRuntimeReloadClient().reloadAuth(account: account)
        },
        cliReload: @escaping CLIReload = { excludedRuntimePIDs in
            SwapEngine.signalCodexReload(
                excludingRuntimePIDs: excludedRuntimePIDs
            )
        }
    ) {
        self.desktopReload = desktopReload
        self.cliReload = cliReload
    }

    func converge(
        account: CodexAccount,
        authorizeAfterDesktop: @Sendable () async -> Bool
    ) async -> AccountActivationReloadTransactionResult {
        let desktopResult = await desktopReload(account)
        guard !Task.isCancelled, await authorizeAfterDesktop() else {
            return .cancelledAfterDesktop(desktopResult)
        }

        let cliResult: CodexReloadSummary
        switch desktopResult {
        case .reloaded, .noDesktopRuntime:
            cliResult = cliReload(desktopResult.acknowledgedRuntimePIDs)
        case .unsupported, .failed:
            cliResult = CodexReloadSummary(
                discoveredRuntimeCount: 0,
                acknowledgedRuntimeCount: 0
            )
        }
        return .completed(
            desktopReload: desktopResult,
            completion: AccountActivationConvergenceEvaluator.completion(
                cliReload: cliResult,
                desktopReload: desktopResult
            )
        )
    }
}

enum AccountActivationConfirmationFailureStage: Equatable, Sendable {
    case durableReadback
    case authorization
    case runtimeRevalidation
    case journalPersistence
}

enum AccountActivationConfirmationResult: Equatable, Sendable {
    case confirmed(AccountActivationState)
    case blocked(AccountActivationConfirmationFailureStage)
}

@MainActor
struct AccountActivationConfirmationOperations {
    let verifyDurableFiles: @MainActor @Sendable () async -> Bool
    let authorizeConfirmation: @MainActor @Sendable () async -> AccountActivationEffectPermit?
    let reauthorizeConfirmation: @MainActor @Sendable (
        AccountActivationEffectPermit
    ) async -> AccountActivationEffectPermit?
    let persistConfirmation: @MainActor @Sendable (
        AccountActivationEffectPermit
    ) async -> AccountActivationState?

    init(
        verifyDurableFiles: @escaping @MainActor @Sendable () async -> Bool,
        authorizeConfirmation: @escaping @MainActor @Sendable () async
            -> AccountActivationEffectPermit?,
        reauthorizeConfirmation: @escaping @MainActor @Sendable (
            AccountActivationEffectPermit
        ) async -> AccountActivationEffectPermit? = { $0 },
        persistConfirmation: @escaping @MainActor @Sendable (
            AccountActivationEffectPermit
        ) async -> AccountActivationState?
    ) {
        self.verifyDurableFiles = verifyDurableFiles
        self.authorizeConfirmation = authorizeConfirmation
        self.reauthorizeConfirmation = reauthorizeConfirmation
        self.persistConfirmation = persistConfirmation
    }
}

struct AccountActivationConfirmationTransaction: Sendable {
    @MainActor
    func confirm(
        _ operations: AccountActivationConfirmationOperations
    ) async -> AccountActivationConfirmationResult {
        guard await operations.verifyDurableFiles() else {
            return .blocked(.durableReadback)
        }
        guard let permit = await operations.authorizeConfirmation(),
              permit.isCurrentlyAuthorized() else {
            return .blocked(.authorization)
        }
        guard let revalidatedPermit = await operations.reauthorizeConfirmation(permit),
              revalidatedPermit.isCurrentlyAuthorized() else {
            return .blocked(.runtimeRevalidation)
        }
        guard let confirmed = await operations.persistConfirmation(revalidatedPermit) else {
            return .blocked(.journalPersistence)
        }
        return .confirmed(confirmed)
    }
}
