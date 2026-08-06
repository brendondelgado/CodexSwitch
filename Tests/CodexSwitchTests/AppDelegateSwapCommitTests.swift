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

private final class ReloadPIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Set<Int32> = []

    func record(_ pids: Set<Int32>) {
        lock.lock()
        value = pids
        lock.unlock()
    }

    func read() -> Set<Int32> {
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
        #expect(!AccountCredentialMutationRuntimePolicy.requiresSourceRuntimeEvidence(
            route: .swap,
            reason: .poolAuthority
        ))
        #expect(!AccountCredentialMutationRuntimePolicy.requiresSourceRuntimeEvidence(
            route: .swap,
            reason: .terminalTokenRecovery
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

    @Test("Pool authority adoption is not vetoed by healthy local quota")
    func poolAuthorityAdoptionBypassesLocalCandidatePolicy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = CodexAccount(
            email: "source@example.com",
            accessToken: "source-access",
            refreshToken: "source-refresh",
            idToken: "source-id",
            accountId: "source-provider",
            quotaSnapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: now,
                windows: [QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 604_800,
                    usedPercent: 1,
                    resetsAt: now.addingTimeInterval(86_400),
                    source: QuotaWindowSourceMetadata(
                        rateLimit: .main,
                        slot: .primary
                    )
                )]
            ),
            isActive: true
        )
        let target = CodexAccount(
            email: "target@example.com",
            accessToken: "target-access",
            refreshToken: "target-refresh",
            idToken: "target-id",
            accountId: "target-provider",
            quotaSnapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: now,
                windows: [QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 604_800,
                    usedPercent: 20,
                    resetsAt: now.addingTimeInterval(86_400),
                    source: QuotaWindowSourceMetadata(
                        rateLimit: .main,
                        slot: .primary
                    )
                )]
            )
        )

        #expect(!source.needsQuotaRelief(at: now))
        #expect(AccountCredentialMutationPolicy.stillAllows(
            route: .swap,
            from: source,
            to: target,
            reason: .poolAuthority,
            accounts: [source, target],
            configuredAccount: source,
            now: now
        ))
        #expect(!AccountCredentialMutationPolicy.stillAllows(
            route: .swap,
            from: source,
            to: target,
            reason: .poolAuthority,
            accounts: [source, target],
            configuredAccount: target,
            now: now
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

    @Test("Launch recovery does not bypass legacy retry-limit migration")
    func launchRecoveryRequiresExactRecoverableTarget() {
        let target = UUID()
        let other = UUID()
        let legacyRetryLimit = AccountActivationState.manualReview(
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
            state: legacyRetryLimit,
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

    @Test("Launch retires the legacy bridge before retry recovery")
    func launchRecoveryRunsAfterBridgeRetirement() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )
        let bridgeWait = try #require(source.range(of: "await desktopNativeChildMigration.value"))
        let recovery = try #require(
            source.range(of: "await recoverManualReviewActivationOnLaunch()")
        )

        #expect(bridgeWait.lowerBound < recovery.lowerBound)
    }

    @Test("Runtime convergence inherits the cross-process activation lease")
    func runtimeConvergenceIsNotDetached() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )
        let start = try #require(source.range(
            of: "private func beginRuntimeConvergence("
        ))
        let end = try #require(source.range(
            of: "private func activationWorkIsCurrent(",
            range: start.upperBound..<source.endIndex
        ))
        let implementation = source[start.lowerBound..<end.lowerBound]

        #expect(implementation.contains(
            "let convergenceTask = Task(priority: .userInitiated)"
        ))
        #expect(!implementation.contains("Task.detached"))
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
            cliReload: { _ in
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
            cliReload: { _ in
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
            cliReload: { _ in
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

    @Test("Desktop runtime PIDs are excluded from interactive CLI discovery")
    func desktopRuntimeIsNotCountedAsCLI() async {
        let desktopPID: Int32 = 51_246
        let recorder = ReloadPIDRecorder()
        let transaction = AccountActivationReloadTransaction(
            desktopReload: { _ in
                .reloaded(
                    method: "account/login/start",
                    discoveredRuntimeCount: 1,
                    acknowledgedRuntimeCount: 1,
                    acknowledgedRuntimeBindings: [
                        desktopRuntimeBinding(pid: desktopPID),
                    ]
                )
            },
            cliReload: { excludedPIDs in
                recorder.record(excludedPIDs)
                return CodexReloadSummary(
                    discoveredRuntimeCount: 0,
                    acknowledgedRuntimeCount: 0
                )
            }
        )

        let result = await transaction.converge(
            account: makeAccount(),
            authorizeAfterDesktop: { true }
        )

        #expect(recorder.read() == [desktopPID])
        guard case .completed(_, let completion) = result else {
            Issue.record("Expected runtime convergence")
            return
        }
        #expect(completion.outcome == .runtimeCurrent)
        #expect(completion.discoveredRuntimeCount == 1)
        #expect(completion.acknowledgedRuntimeCount == 1)
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

    @Test("Final runtime topology rejection routes through durable retry backoff")
    func runtimeRevalidationFailureUsesCoordinator() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )
        let start = try #require(
            source.range(of: "case .blocked(.runtimeRevalidation):")
        )
        let end = try #require(
            source.range(
                of: "case .blocked(.journalPersistence):",
                range: start.upperBound..<source.endIndex
            )
        )
        let branch = source[start.lowerBound..<end.lowerBound]
        let helperStart = try #require(
            source.range(of: "private func persistRuntimeRevalidationFailure(")
        )
        let helperEnd = try #require(
            source.range(
                of: "private func finishSwapRuntimeConvergence(",
                range: helperStart.upperBound..<source.endIndex
            )
        )
        let helper = source[helperStart.lowerBound..<helperEnd.lowerBound]

        #expect(branch.contains("persistRuntimeRevalidationFailure("))
        #expect(helper.contains(".recordRuntimeRevalidationFailure("))
        #expect(helper.contains("expectedActivationGeneration: prepared"))
        #expect(helper.contains("operationAuthority?.authorizes()"))
        #expect(helper.contains("failurePermit.authorizes("))
        #expect(helper.contains("accountManager.publishActivationState(failed)"))
    }

    @Test("Auth readback verifies the complete token set")
    func authReadbackVerifiesCompleteTokenSet() throws {
        let account = makeAccount()
        let root = try makeSecureTestDirectoryURL(prefix: "codexswitch-app-delegate-auth")
        let url = root.appendingPathComponent("auth.json")
        defer { try? FileManager.default.removeItem(at: root) }

        try SwapEngine.writeAuthFile(for: account, path: url.path)
        let observation = AccountImporter.observeCurrentAccount(from: url.path)
        guard case .valid(let observed) = observation else {
            Issue.record("Expected a valid auth observation, got \(String(describing: observation))")
            return
        }
        #expect(AppDelegate.credentialsMatch(account, observed))
        #expect(AppDelegate.authFileMatches(account: account, atPath: url.path))

        var mismatch = account
        mismatch.refreshToken = "different-refresh-token"
        #expect(!AppDelegate.authFileMatches(account: mismatch, atPath: url.path))
    }

    @Test("External handoff rejects an auth-only target change")
    func externalHandoffRequiresTargetSelectedInStore() {
        let source = makeAccount(
            email: "source@example.com",
            accountId: "source-account",
            isActive: true
        )
        let target = makeAccount(
            email: "target@example.com",
            accountId: "target-account"
        )

        #expect(AppDelegate.verifiedExternalHandoffTarget(
            accounts: [source, target],
            authObservation: .valid(target)
        ) == nil)

        var inactiveSource = source
        inactiveSource.isActive = false
        var activeTarget = target
        activeTarget.isActive = true
        #expect(AppDelegate.verifiedExternalHandoffTarget(
            accounts: [inactiveSource, activeTarget],
            authObservation: .valid(target)
        )?.id == target.id)

        var mismatchedTarget = activeTarget
        mismatchedTarget.refreshToken = "unobserved-refresh-token"
        #expect(AppDelegate.verifiedExternalHandoffTarget(
            accounts: [inactiveSource, mismatchedTarget],
            authObservation: .valid(target)
        ) == nil)

        #expect(AppDelegate.verifiedExternalHandoffTarget(
            accounts: [source, activeTarget],
            authObservation: .valid(target)
        ) == nil)
    }

    private func makeAccount(
        email: String = "swap-contract@example.com",
        accountId: String = "account-id",
        isActive: Bool = false
    ) -> CodexAccount {
        CodexAccount(
            email: email,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: "id-token",
            accountId: accountId,
            isActive: isActive
        )
    }

    private func desktopRuntimeBinding(pid: Int32) -> CodexDesktopRuntimeSocketBinding {
        let path = "/Users/me/.local/share/codexswitch/runtime/codex"
        let identity = CodexSignalProcessIdentity(
            pid: pid,
            ownerUID: 501,
            executablePath: path,
            startSeconds: 1_000,
            startMicroseconds: 12
        )
        return CodexDesktopRuntimeSocketBinding(
            target: CodexRuntimeTarget(
                process: CodexIdentityBoundProcess(
                    identity: identity,
                    kernelExecutableIdentity: CodexKernelExecutableIdentity(
                        canonicalPath: path,
                        device: 7,
                        inode: 10_000 + UInt64(pid)
                    ),
                    arguments: [
                        path,
                        "app-server",
                        "--listen",
                        "ws://127.0.0.1:9223",
                    ]
                ),
                runtimeKind: .officialDesktopStdioChild
            ),
            port: 9223
        )
    }
}
