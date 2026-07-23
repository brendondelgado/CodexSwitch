import Foundation
import Testing
@testable import CodexSwitch

private final class ReloadCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("Account activation reload transaction")
struct AppDelegateSwapCommitTests {
    @Test("Delayed external auth reads are discarded after a newer swap and replayed")
    func delayedExternalAuthReadUsesCurrentActivationContext() {
        let configuredAccountId = UUID()
        let activationGeneration = UUID()
        let captured = ExternalAuthObservationContext(
            configuredAccountId: configuredAccountId,
            swapGeneration: 7,
            activationGeneration: activationGeneration
        )
        let newerSwap = ExternalAuthObservationContext(
            configuredAccountId: configuredAccountId,
            swapGeneration: 8,
            activationGeneration: UUID()
        )

        #expect(!AppDelegate.externalAuthObservationIsCurrent(
            captured: captured,
            current: newerSwap
        ))
        #expect(AppDelegate.externalAuthObservationIsCurrent(
            captured: newerSwap,
            current: newerSwap
        ))

        for changed in [
            ExternalAuthObservationContext(
                configuredAccountId: UUID(),
                swapGeneration: captured.swapGeneration,
                activationGeneration: captured.activationGeneration
            ),
            ExternalAuthObservationContext(
                configuredAccountId: captured.configuredAccountId,
                swapGeneration: captured.swapGeneration + 1,
                activationGeneration: captured.activationGeneration
            ),
            ExternalAuthObservationContext(
                configuredAccountId: captured.configuredAccountId,
                swapGeneration: captured.swapGeneration,
                activationGeneration: UUID()
            ),
        ] {
            #expect(!AppDelegate.externalAuthObservationIsCurrent(
                captured: captured,
                current: changed
            ))
        }
    }

    @Test("Manual account switches do not require source runtime-current proof")
    func manualSwapUsesDurableSourceAuthorization() {
        #expect(!AccountCredentialMutationRuntimePolicy.requiresSourceRuntimeEvidence(
            route: .swap,
            reason: .manual
        ))
        #expect(AccountCredentialMutationRuntimePolicy.requiresSourceRuntimeEvidence(
            route: .swap,
            reason: .quotaExhausted
        ))
        #expect(AccountCredentialMutationRuntimePolicy.requiresSourceRuntimeEvidence(
            route: .tokenRefresh,
            reason: .manual
        ))
        #expect(AccountCredentialMutationRuntimePolicy.requiresSourceRuntimeEvidence(
            route: .activeReauthentication,
            reason: .manual
        ))
        #expect(AccountCredentialMutationRuntimePolicy.requiresSourceRuntimeEvidence(
            route: .planUpgrade,
            reason: .manual
        ))
        #expect(!AccountCredentialMutationRuntimePolicy.requiresSourceRuntimeEvidence(
            route: .firstActivation,
            reason: .manual
        ))
        #expect(!AccountCredentialMutationRuntimePolicy.requiresSourceRuntimeEvidence(
            route: .externalAuthObservation,
            reason: .manual
        ))
    }

    @Test("Launch repair requires exact durable file agreement")
    func launchRepairChecksBothConfiguredFiles() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )

        #expect(source.contains("stored.detail == .fileCommitFailed"))
        #expect(source.contains("Self.accountStoreMatches("))
        #expect(source.contains("Self.authFileMatches("))
        #expect(source.contains(".recoverFileCommitFailure("))
        #expect(source.contains("ACTIVATION_FILE_COMMIT_FAILURE_RECOVERED"))
    }

    @Test("Launch recovery preserves exhausted retries and requires a durable target")
    func launchRecoveryRequiresExactRecoverableTarget() {
        let target = UUID()
        let other = UUID()
        let exhausted = AccountActivationState.manualReview(
            targetAccountId: target,
            detail: .automaticRetryLimitReached,
            retryAttempt: 4,
            at: Date()
        )
        let durableReadback = AccountActivationState.manualReview(
            targetAccountId: target,
            detail: .durableConfigurationChanged,
            at: Date()
        )
        let unrelatedReview = AccountActivationState.manualReview(
            targetAccountId: target,
            detail: .configuredFilesInconsistent,
            retryAttempt: 4,
            at: Date()
        )

        #expect(AppDelegate.manualReviewLaunchRecoveryTarget(
            state: exhausted,
            configuredAccountId: target
        ) == nil)
        #expect(AppDelegate.manualReviewLaunchRecoveryTarget(
            state: durableReadback,
            configuredAccountId: target
        ) == target)
        #expect(AppDelegate.manualReviewLaunchRecoveryTarget(
            state: durableReadback,
            configuredAccountId: other
        ) == nil)
        #expect(AppDelegate.manualReviewLaunchRecoveryTarget(
            state: unrelatedReview,
            configuredAccountId: target
        ) == nil)
        #expect(AppDelegate.manualReviewLaunchRecoveryTarget(
            state: nil,
            configuredAccountId: target
        ) == nil)
        #expect(!AccountActivationDetail.automaticRetryLimitReached
            .allowsLaunchSameTargetRecovery)
        #expect(AccountActivationDetail.durableConfigurationChanged
            .allowsLaunchSameTargetRecovery)
    }

    @Test("Runtime topology recovery is one-shot and fully managed")
    func topologyRecoveryRequiresManagedChangedTopology() {
        let target = UUID()
        let exhausted = AccountActivationState.manualReview(
            targetAccountId: target,
            detail: .automaticRetryLimitReached,
            retryAttempt: 4,
            at: Date()
        )

        #expect(AppDelegate.retryExhaustedTopologyRecoveryTarget(
            state: exhausted,
            configuredAccountId: target,
            topologyIsFullyManaged: true,
            topologyChanged: true
        ) == target)
        #expect(AppDelegate.retryExhaustedTopologyRecoveryTarget(
            state: exhausted,
            configuredAccountId: target,
            topologyIsFullyManaged: false,
            topologyChanged: true
        ) == nil)
        #expect(AppDelegate.retryExhaustedTopologyRecoveryTarget(
            state: exhausted,
            configuredAccountId: target,
            topologyIsFullyManaged: true,
            topologyChanged: false
        ) == nil)
    }

    @Test("Launch waits for bridge installation before retry recovery")
    func launchRecoveryRunsAfterBridgeInstallation() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )
        let bridgeWait = try #require(source.range(of: "await desktopBridgeInstallation.value"))
        let recovery = try #require(
            source.range(of: "await recoverManualReviewActivationOnLaunch()")
        )

        #expect(bridgeWait.lowerBound < recovery.lowerBound)
    }

    @Test("No live runtime remains configured-only")
    func noRuntimeIsConfiguredOnly() {
        let completion = AccountActivationConvergenceEvaluator.completion(
            cliReload: CodexReloadSummary(
                discoveredRuntimeCount: 0,
                acknowledgedRuntimeCount: 0
            ),
            desktopReload: .noDesktopRuntime
        )

        #expect(completion.outcome == .configuredOnly)
        #expect(completion.discoveredRuntimeCount == 0)
        #expect(completion.acknowledgedRuntimeCount == 0)
    }

    @Test("Every admitted runtime must acknowledge before runtime-current")
    func allAdmittedRuntimesConverge() {
        let completion = AccountActivationConvergenceEvaluator.completion(
            cliReload: CodexReloadSummary(
                discoveredRuntimeCount: 2,
                acknowledgedRuntimeCount: 2
            ),
            desktopReload: .reloaded(
                method: "account/login/start",
                discoveredRuntimeCount: 1,
                acknowledgedRuntimeCount: 1
            )
        )

        #expect(completion.outcome == .runtimeCurrent)
        #expect(completion.discoveredRuntimeCount == 3)
        #expect(completion.acknowledgedRuntimeCount == 3)
        #expect(completion.detail == nil)
    }

    @Test("Partial CLI acknowledgement is degraded")
    func partialCLIConvergenceRequiresRestart() {
        let completion = AccountActivationConvergenceEvaluator.completion(
            cliReload: CodexReloadSummary(
                discoveredRuntimeCount: 2,
                acknowledgedRuntimeCount: 1
            ),
            desktopReload: .reloaded(
                method: "account/login/start",
                discoveredRuntimeCount: 1,
                acknowledgedRuntimeCount: 1
            )
        )

        #expect(completion.outcome == .restartRequired)
        #expect(completion.discoveredRuntimeCount == 3)
        #expect(completion.acknowledgedRuntimeCount == 2)
        #expect(completion.detail?.contains("cli_acknowledged_1_of_2") == true)
    }

    @Test("Failed desktop transaction cannot fall through to a later signal")
    func failedDesktopStopsBeforeCLIReload() async {
        let cliCalls = ReloadCallCounter()
        let transaction = AccountActivationReloadTransaction(
            desktopReload: { _ in
                .failed(
                    "strict_ack_timeout",
                    discoveredRuntimeCount: 3,
                    acknowledgedRuntimeCount: 2
                )
            },
            cliReload: {
                cliCalls.increment()
                return CodexReloadSummary(
                    discoveredRuntimeCount: 1,
                    acknowledgedRuntimeCount: 1
                )
            }
        )

        let result = await transaction.converge(
            account: makeAccount(),
            authorizeAfterDesktop: { true }
        )

        #expect(cliCalls.read() == 0)
        guard case .completed(let desktop, let completion) = result else {
            Issue.record("Expected a degraded completion")
            return
        }
        #expect(desktop == .failed(
            "strict_ack_timeout",
            discoveredRuntimeCount: 3,
            acknowledgedRuntimeCount: 2
        ))
        #expect(completion.outcome == .restartRequired)
        #expect(completion.discoveredRuntimeCount == 3)
        #expect(completion.acknowledgedRuntimeCount == 2)
    }

    @Test("Unsupported desktop transaction cannot be rescued by CLI signalling")
    func unsupportedDesktopStopsBeforeCLIReload() async {
        let cliCalls = ReloadCallCounter()
        let transaction = AccountActivationReloadTransaction(
            desktopReload: { _ in
                .unsupported(
                    discoveredRuntimeCount: 4,
                    acknowledgedRuntimeCount: 1
                )
            },
            cliReload: {
                cliCalls.increment()
                return CodexReloadSummary(
                    discoveredRuntimeCount: 1,
                    acknowledgedRuntimeCount: 1
                )
            }
        )

        let result = await transaction.converge(
            account: makeAccount(),
            authorizeAfterDesktop: { true }
        )

        #expect(cliCalls.read() == 0)
        guard case .completed(_, let completion) = result else {
            Issue.record("Expected a degraded completion")
            return
        }
        #expect(completion.outcome == .restartRequired)
        #expect(completion.discoveredRuntimeCount == 4)
        #expect(completion.acknowledgedRuntimeCount == 1)
        #expect(completion.detail?.contains("desktop_json_rpc_unsupported") == true)
    }

    @Test("Ownership loss after desktop await prevents the CLI effect")
    func postDesktopAuthorizationLossStopsBeforeCLIReload() async {
        let cliCalls = ReloadCallCounter()
        let transaction = AccountActivationReloadTransaction(
            desktopReload: { _ in
                .reloaded(
                    method: "account/login/start",
                    discoveredRuntimeCount: 1,
                    acknowledgedRuntimeCount: 1
                )
            },
            cliReload: {
                cliCalls.increment()
                return CodexReloadSummary(
                    discoveredRuntimeCount: 1,
                    acknowledgedRuntimeCount: 1
                )
            }
        )

        let result = await transaction.converge(
            account: makeAccount(),
            authorizeAfterDesktop: { false }
        )

        #expect(cliCalls.read() == 0)
        guard case .cancelledAfterDesktop(.reloaded) = result else {
            Issue.record("Expected cancellation after the desktop await")
            return
        }
    }

    @MainActor
    @Test("Runtime identity loss immediately before confirmation blocks persistence")
    func runtimeRevalidationStopsConfirmationPersistence() async {
        let accountId = UUID()
        let activationGeneration = UUID()
        let now = Date()
        let state = AccountActivationState.committedDegraded(
            targetAccountId: accountId,
            detail: .runtimeAcknowledgementIncomplete,
            activationGeneration: activationGeneration,
            retryAttempt: 0,
            nextRetryAt: now,
            at: now
        )
        let permit = AccountActivationEffectPermit(
            targetAccountId: accountId,
            activationGeneration: activationGeneration,
            requiredPhase: .committedDegraded,
            leaseGeneration: 1,
            runtimePermit: nil,
            leaseAuthorization: { true },
            durableStateProvider: { state }
        )
        let persistenceCalls = ReloadCallCounter()

        let result = await AccountActivationConfirmationTransaction().confirm(
            AccountActivationConfirmationOperations(
                verifyDurableFiles: { true },
                authorizeConfirmation: { permit },
                reauthorizeConfirmation: { _ in nil },
                persistConfirmation: { _ in
                    persistenceCalls.increment()
                    return state
                }
            )
        )

        #expect(result == .blocked(.runtimeRevalidation))
        #expect(persistenceCalls.read() == 0)
    }

    @Test("Auth readback verifies the complete token set")
    func authReadbackVerifiesCompleteTokenSet() throws {
        let account = makeAccount()
        let root = try makeSecureTestDirectoryURL(prefix: "codexswitch-app-delegate-auth")
        let url = root.appendingPathComponent("auth.json")
        defer { try? FileManager.default.removeItem(at: root) }

        try SwapEngine.writeAuthFile(for: account, path: url.path)
        #expect(AppDelegate.authFileMatches(account: account, atPath: url.path))

        var mismatch = account
        mismatch.refreshToken = "different-refresh-token"
        #expect(!AppDelegate.authFileMatches(account: mismatch, atPath: url.path))
    }

    private func makeAccount() -> CodexAccount {
        CodexAccount(
            email: "swap-contract@example.com",
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: "id-token",
            accountId: "account-id"
        )
    }
}
