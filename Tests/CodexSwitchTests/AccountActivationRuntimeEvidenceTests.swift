import Foundation
import Testing
@testable import CodexSwitch

@Suite("Mac activation runtime evidence")
struct AccountActivationRuntimeEvidenceTests {
    private let accountId = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
    private let auth = CodexAuthFileIdentity(
        canonicalPath: "/Users/me/.codex/auth.json",
        device: 8,
        inode: 12_001,
        accountID: "account-1",
        completeTokenFingerprint: String(repeating: "a", count: 64)
    )

    @Test("Activation renewal reuses exact identity-bound acknowledgements")
    func activationRenewalReusesIdentityBoundAcknowledgements() {
        #expect(!AccountActivationRuntimeEvidencePreflight.requiresFreshAcknowledgements)
    }

    @Test("Passive confirmation refresh is due before expiry and rejects other activation states")
    func passiveConfirmationRefreshEligibility() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = confirmationState(observedAt: now)
        #expect(AccountActivationConfirmationRefresh(
            state: state, configuredAccountId: accountId, at: now.addingTimeInterval(4)
        ) == nil)
        #expect(AccountActivationConfirmationRefresh(
            state: state, configuredAccountId: accountId, at: now.addingTimeInterval(5)
        ) != nil)
        #expect(AccountActivationConfirmationRefresh(
            state: state, configuredAccountId: accountId, at: now.addingTimeInterval(60)
        ) != nil)
        for invalid in [
            nil,
            AccountActivationState.preparing(targetAccountId: accountId, at: now),
            AccountActivationState.committedDegraded(
                targetAccountId: accountId, detail: .runtimeAcknowledgementIncomplete,
                activationGeneration: UUID(), retryAttempt: 0, nextRetryAt: now, at: now
            ),
            AccountActivationState.manualReview(
                targetAccountId: accountId, detail: .externalAuthConflict, at: now
            ),
        ] {
            #expect(AccountActivationConfirmationRefresh(
                state: invalid, configuredAccountId: accountId, at: now
            ) == nil)
        }
        #expect(AccountActivationConfirmationRefresh(
            state: state, configuredAccountId: UUID(), at: now.addingTimeInterval(60)
        ) == nil)
    }

    @Test("Failed passive refreshes are single-flight and retry at 30, then 60 seconds")
    func passiveConfirmationFailureBackoff() throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = confirmationState(observedAt: now.addingTimeInterval(-60))
        var schedule = AccountActivationConfirmationRefreshSchedule()
        var oldAttempt: AccountActivationConfirmationRefresh?
        for delay in [30.0, 60, 60, 60] {
            let pendingAttempt = schedule.begin(
                state: state, configuredAccountId: accountId, at: now
            )
            let attempt = try #require(pendingAttempt)
            #expect(schedule.begin(
                state: state, configuredAccountId: accountId, at: now.addingTimeInterval(600)
            ) == nil)
            if let oldAttempt {
                schedule.complete(oldAttempt, succeeded: true, at: now)
                #expect(schedule.begin(
                    state: state, configuredAccountId: accountId, at: now
                ) == nil)
            }
            schedule.complete(attempt, succeeded: false, at: now)
            #expect(schedule.begin(
                state: state, configuredAccountId: accountId,
                at: now.addingTimeInterval(delay - 0.001)
            ) == nil)
            oldAttempt = attempt
            now = now.addingTimeInterval(delay)
        }
        let changed = confirmationState(observedAt: now.addingTimeInterval(-60))
        #expect(schedule.begin(
            state: changed, configuredAccountId: accountId, at: now.addingTimeInterval(-1)
        ) != nil)
    }

    @Test("Passive confirmation cannot renew from a cached snapshot or missing current ACK proof")
    func passiveConfirmationRequiresNewCompleteBoundObservation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = confirmationState(observedAt: now.addingTimeInterval(-60))
        let refresh = try #require(AccountActivationConfirmationRefresh(
            state: state, configuredAccountId: accountId, at: now
        ))
        for snapshots in [
            snapshot([runtimeEvidence()], at: state.runtimeEvidenceObservedAt!),
            snapshot([], at: now),
            snapshot([runtimeEvidence()], at: now, desktopComplete: false),
            snapshot([runtimeEvidence(), runtimeEvidence()], at: now),
        ] {
            #expect(refresh.evidence(
                from: snapshots, authIdentity: auth, runtimeBindingIsCurrent: { _ in true }
            ) == nil)
        }
        #expect(refresh.evidence(
            from: snapshot([runtimeEvidence()], at: now),
            authIdentity: auth, runtimeBindingIsCurrent: { _ in false }
        ) == nil)
        let otherAuth = CodexAuthFileIdentity(
            canonicalPath: auth.canonicalPath, device: auth.device, inode: auth.inode,
            accountID: auth.accountID,
            completeTokenFingerprint: String(repeating: "b", count: 64)
        )
        #expect(refresh.evidence(
            from: snapshot([runtimeEvidence()], at: now),
            authIdentity: otherAuth, runtimeBindingIsCurrent: { _ in true }
        ) == nil)
    }

    @Test("Passive confirmation rejects generation, topology, auth and expiry drift before persistence")
    func passiveConfirmationPersistenceRevalidatesOriginalAuthority() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = confirmationState(observedAt: now.addingTimeInterval(-60))
        let refresh = try #require(AccountActivationConfirmationRefresh(
            state: state, configuredAccountId: accountId, at: now
        ))
        let snapshots = snapshot([runtimeEvidence()], at: now)
        let evidence = try #require(refresh.evidence(
            from: snapshots, authIdentity: auth, runtimeBindingIsCurrent: { _ in true }
        ))
        #expect(refresh.authorizesPersistence(
            of: evidence, state: state, snapshots: snapshots, authIdentity: auth,
            at: now, runtimeBindingIsCurrent: { _ in true }
        ))
        for changed in [
            confirmationState(observedAt: state.runtimeEvidenceObservedAt!),
            confirmationState(
                observedAt: now, activationGeneration: state.activationGeneration
            ),
            AccountActivationState.committedDegraded(
                targetAccountId: accountId, detail: .activeCredentialMutation,
                activationGeneration: state.activationGeneration,
                retryAttempt: 0, nextRetryAt: now, at: now
            ),
        ] {
            #expect(!refresh.authorizesPersistence(
                of: evidence, state: changed, snapshots: snapshots, authIdentity: auth,
                at: now, runtimeBindingIsCurrent: { _ in true }
            ))
        }
        for changed in [
            snapshot([runtimeEvidence(pid: 43)], at: now),
            snapshot([runtimeEvidence(), runtimeEvidence(pid: 43)], at: now),
            snapshot([runtimeEvidence()], at: now, desktopComplete: false),
        ] {
            #expect(!refresh.authorizesPersistence(
                of: evidence, state: state, snapshots: changed, authIdentity: auth,
                at: now, runtimeBindingIsCurrent: { _ in true }
            ))
        }
        #expect(!refresh.authorizesPersistence(
            of: evidence, state: state, snapshots: snapshots, authIdentity: auth,
            at: now, runtimeBindingIsCurrent: { _ in false }
        ))
        #expect(!refresh.authorizesPersistence(
            of: evidence, state: state, snapshots: snapshots, authIdentity: auth,
            at: evidence.expiresAt, runtimeBindingIsCurrent: { _ in true }
        ))
    }

    @Test("Expired same-generation confirmation recovers through the journal using existing ACKs")
    @MainActor
    func passiveConfirmationRefreshPersistsWithoutReload() async throws {
        let root = try makeSecureTestDirectoryURL(prefix: "codexswitch-passive-confirmation")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = AccountActivationCoordinator(url: root.appendingPathComponent("activation.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-60)
        let preparing = try await coordinator.beginPreparing(
            targetAccountId: accountId, kind: .manual, at: old
        )
        try await coordinator.markCommittedDegraded(
            targetAccountId: accountId, discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1, detail: .runtimeConfirmationPending, at: old
        )
        let state = try await coordinator.markConfirmed(
            targetAccountId: accountId,
            expectedActivationGeneration: preparing.activationGeneration,
            discoveredRuntimeCount: 1, acknowledgedRuntimeCount: 1,
            evidenceGeneration: UUID(), evidenceObservedAt: old,
            evidenceExpiresAt: old.addingTimeInterval(10), at: old
        )
        #expect(!state.runtimeIsCurrent(for: accountId, at: now))
        let refresh = try #require(AccountActivationConfirmationRefresh(
            state: state, configuredAccountId: accountId, at: now
        ))
        let snapshots = snapshot([runtimeEvidence()], at: now)
        let auth = self.auth
        let evidence = try #require(refresh.evidence(
            from: snapshots, authIdentity: auth, runtimeBindingIsCurrent: { _ in true }
        ))
        let renewed = try await coordinator.refreshConfirmedRuntimeEvidence(
            targetAccountId: accountId, expectedActivationGeneration: state.activationGeneration,
            evidence: evidence, at: now,
            authorizeEffect: { current in
                #expect(!Thread.isMainThread)
                return refresh.authorizesPersistence(
                    of: evidence, state: current, snapshots: snapshots, authIdentity: auth,
                    at: now, runtimeBindingIsCurrent: { _ in true }
                )
            }
        )
        #expect(renewed.runtimeIsCurrent(for: accountId, at: now))
        #expect(renewed.activationGeneration == state.activationGeneration)
        #expect(renewed.runtimeEvidenceGeneration != state.runtimeEvidenceGeneration)
        #expect(renewed.runtimeEvidenceExpiresAt == now.addingTimeInterval(30))
        #expect(AccountActivationCoordinator.runtimeEvidenceLifetime == 10)
        #expect(evidence.runtimeBindings == snapshots.cli.runtimes.map(\.startupAcknowledgement.binding))
        #expect(try await coordinator.load(at: now) == renewed)
        #expect(!refresh.matches(renewed))
        #expect(AccountActivationConfirmationRefresh(
            state: renewed, configuredAccountId: accountId, at: now
        ) == nil)
        #expect(AccountActivationConfirmationRefresh(
            state: renewed, configuredAccountId: accountId, at: now.addingTimeInterval(24.999)
        ) == nil)
        #expect(AccountActivationConfirmationRefresh(
            state: renewed, configuredAccountId: accountId, at: now.addingTimeInterval(25)
        ) != nil)
    }

    private func confirmationState(
        observedAt: Date,
        activationGeneration: UUID = UUID()
    ) -> AccountActivationState {
        AccountActivationState(
            version: AccountActivationState.currentVersion, phase: .confirmed,
            activationGeneration: activationGeneration,
            configuredAccountId: accountId, runtimeCurrentAccountId: accountId,
            updatedAt: observedAt, retryAttempt: 0, nextRetryAt: nil,
            discoveredRuntimeCount: 1, acknowledgedRuntimeCount: 1, detail: nil,
            runtimeEvidenceGeneration: UUID(), runtimeEvidenceObservedAt: observedAt,
            runtimeEvidenceExpiresAt: observedAt.addingTimeInterval(10), runtimeBlockers: nil
        )
    }

    private func snapshot(
        _ runtimes: [CodexLocalRuntimeEvidence],
        at date: Date,
        desktopComplete: Bool = true
    ) -> AccountActivationRuntimeSnapshotSet {
        AccountActivationRuntimeSnapshotSet(
            cli: .init(runtimes: runtimes, isComplete: true),
            desktop: .init(runtimes: [], isComplete: desktopComplete),
            observedAt: date
        )
    }

    @Test("No live runtime is configured-only evidence, never confirmation")
    func noRuntimeDeniesConfirmation() {
        let decision = AccountActivationRuntimeEvidenceEvaluator.evaluate(
            cli: .init(runtimes: [], isComplete: true),
            desktop: .init(runtimes: [], isComplete: true),
            expectedAccountId: accountId,
            expectedAuthIdentity: auth,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            runtimeBindingIsCurrent: { _ in true }
        )

        #expect(decision == .denied(
            detail: .noLocalRuntime,
            discoveredRuntimeCount: 0,
            acknowledgedRuntimeCount: 0
        ))
    }

    @Test("Incomplete discovery on either host path fails closed")
    func incompleteDesktopDiscoveryRejectsCompleteCLI() {
        let decision = AccountActivationRuntimeEvidenceEvaluator.evaluate(
            cli: .init(runtimes: [runtimeEvidence()], isComplete: true),
            desktop: .init(runtimes: [], isComplete: false),
            expectedAccountId: accountId,
            expectedAuthIdentity: auth,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            runtimeBindingIsCurrent: { _ in true }
        )

        #expect(decision == .denied(
            detail: .runtimeAcknowledgementIncomplete,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
    }

    @Test("A complete matching live runtime produces short-lived evidence")
    func matchingEvidenceConfirmsWithBoundedLifetime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let acknowledgedAtUnixMilliseconds: Int64 = 1_799_999_995_000
        let generation = UUID()
        let runtime = runtimeEvidence(
            acknowledgedAtUnixMilliseconds: acknowledgedAtUnixMilliseconds
        )
        let decision = AccountActivationRuntimeEvidenceEvaluator.evaluate(
            cli: .init(runtimes: [runtime], isComplete: true),
            desktop: .init(runtimes: [], isComplete: true),
            expectedAccountId: accountId,
            expectedAuthIdentity: auth,
            observedAt: now,
            lifetime: 10,
            generation: generation,
            runtimeBindingIsCurrent: { $0 == runtime.startupAcknowledgement.binding }
        )

        #expect(decision == .confirmed(AccountActivationRuntimeEvidence(
            generation: generation,
            runtimeCurrentAccountId: accountId,
            observedAt: now,
            expiresAt: now.addingTimeInterval(10),
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            runtimeBindings: [runtime.startupAcknowledgement.binding]
        )))
    }

    @Test("Passive revalidation renews evidence from the current observation")
    func evidenceUsesCurrentObservationTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let olderMilliseconds: Int64 = 1_799_999_994_000
        let runtimes = [
            runtimeEvidence(pid: 42, acknowledgedAtUnixMilliseconds: 1_799_999_998_000),
            runtimeEvidence(pid: 43, acknowledgedAtUnixMilliseconds: olderMilliseconds),
        ]

        let decision = AccountActivationRuntimeEvidenceEvaluator.evaluate(
            cli: .init(runtimes: runtimes, isComplete: true),
            desktop: .init(runtimes: [], isComplete: true),
            expectedAccountId: accountId,
            expectedAuthIdentity: auth,
            observedAt: now,
            lifetime: 10,
            runtimeBindingIsCurrent: { _ in true }
        )

        guard case .confirmed(let evidence) = decision else {
            Issue.record("Expected confirmed runtime evidence")
            return
        }
        #expect(evidence.observedAt == now)
        #expect(evidence.expiresAt == now.addingTimeInterval(10))
    }

    @Test("Historical ACKs require passive current-process evidence")
    func historicalAcknowledgementCannotMintEvidenceAlone() {
        let runtime = runtimeEvidence()
        var passiveChecks = 0

        let decision = AccountActivationRuntimeEvidenceEvaluator.evaluate(
            cli: .init(runtimes: [runtime], isComplete: true),
            desktop: .init(runtimes: [], isComplete: true),
            expectedAccountId: accountId,
            expectedAuthIdentity: auth,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            runtimeBindingIsCurrent: { _ in
                passiveChecks += 1
                return false
            }
        )

        #expect(passiveChecks == 1)
        #expect(decision == .denied(
            detail: .runtimeAcknowledgementIncomplete,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
    }

    @Test("An old ACK can renew evidence only for the exact current process and auth binding")
    func identityBoundAcknowledgementCanBeRevalidated() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staleAcknowledgement = Int64(now.timeIntervalSince1970 * 1_000)
            - (24 * 60 * 60 * 1_000)
        let runtime = runtimeEvidence(
            acknowledgedAtUnixMilliseconds: staleAcknowledgement
        )
        var passiveChecks = 0

        let decision = AccountActivationRuntimeEvidenceEvaluator.evaluate(
            cli: .init(runtimes: [runtime], isComplete: true),
            desktop: .init(runtimes: [], isComplete: true),
            expectedAccountId: accountId,
            expectedAuthIdentity: auth,
            observedAt: now,
            runtimeBindingIsCurrent: { binding in
                passiveChecks += 1
                return binding == runtime.startupAcknowledgement.binding
            }
        )

        #expect(passiveChecks == 1)
        guard case .confirmed(let evidence) = decision else {
            Issue.record("Expected identity-bound evidence to remain reusable")
            return
        }
        #expect(evidence.observedAt == now)
        #expect(evidence.runtimeBindings == [runtime.startupAcknowledgement.binding])
    }

    @Test("A running source renews its ACK before runtime authorization")
    func preflightRenewsStaleRunningSourceBeforeAuthorization() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = runtimeEvidence(
            acknowledgedAtUnixMilliseconds: 1_799_999_699_000
        )
        let renewed = runtimeEvidence(
            acknowledgedAtUnixMilliseconds: 1_799_999_999_000
        )
        let fixture = RuntimeEvidencePreflightFixture(runtime: stale)

        let decision = await AccountActivationRuntimeEvidencePreflight
            .renewAndEvaluate(
                expectedAccountId: accountId,
                expectedAuthIdentity: auth,
                renew: {
                    await fixture.renew(to: renewed)
                    return AccountActivationRuntimeRenewal(
                        cliReload: CodexReloadSummary(
                            discoveredRuntimeCount: 1,
                            acknowledgedRuntimeCount: 1
                        ),
                        desktopReload: .noDesktopRuntime
                    )
                },
                capture: {
                    let runtime = await fixture.capture()
                    return AccountActivationRuntimeSnapshotSet(
                        cli: .init(runtimes: [runtime], isComplete: true),
                        desktop: .init(runtimes: [], isComplete: true),
                        observedAt: now
                    )
                },
                runtimeBindingIsCurrent: {
                    $0 == renewed.startupAcknowledgement.binding
                }
            )

        guard case .confirmed(let evidence) = decision else {
            Issue.record("Expected renewed runtime authorization")
            return
        }
        #expect(await fixture.recordedEvents() == ["renew", "capture"])
        #expect(evidence.observedAt == now)
        #expect(evidence.expiresAt > now)
    }

    @Test("Incomplete renewal is denied before runtime artifact capture")
    func preflightRequiresCompleteRenewalBeforeCapture() async {
        let runtime = runtimeEvidence()
        let fixture = RuntimeEvidencePreflightFixture(runtime: runtime)

        let decision = await AccountActivationRuntimeEvidencePreflight
            .renewAndEvaluate(
                expectedAccountId: accountId,
                expectedAuthIdentity: auth,
                renew: {
                    await fixture.renew(to: runtime)
                    return AccountActivationRuntimeRenewal(
                        cliReload: CodexReloadSummary(
                            discoveredRuntimeCount: 2,
                            acknowledgedRuntimeCount: 1
                        ),
                        desktopReload: .noDesktopRuntime
                    )
                },
                capture: {
                    _ = await fixture.capture()
                    return nil
                },
                runtimeBindingIsCurrent: { _ in true }
            )

        #expect(decision == .denied(
            detail: .runtimeAcknowledgementIncomplete,
            discoveredRuntimeCount: 2,
            acknowledgedRuntimeCount: 1
        ))
        #expect(await fixture.recordedEvents() == ["renew"])
    }

    @Test("Desktop renewal failure or unsupported capability suppresses CLI signaling")
    func desktopRenewalFailureStopsBeforeCLI() async {
        for desktop in [
            DesktopReloadResult.failed(
                "strict failure",
                discoveredRuntimeCount: 3,
                acknowledgedRuntimeCount: 2
            ),
            DesktopReloadResult.unsupported(
                discoveredRuntimeCount: 4,
                acknowledgedRuntimeCount: 0
            ),
        ] {
            let fixture = RuntimeEvidencePreflightFixture(runtime: runtimeEvidence())
            let renewal = await AccountActivationRuntimeEvidencePreflight.performRenewal(
                desktopReload: { desktop },
                cliReload: {
                    await fixture.record("cli")
                    return CodexReloadSummary(
                        discoveredRuntimeCount: 1,
                        acknowledgedRuntimeCount: 1
                    )
                }
            )

            #expect(renewal.desktopReload == desktop)
            #expect(renewal.cliReload == CodexReloadSummary(
                discoveredRuntimeCount: 0,
                acknowledgedRuntimeCount: 0
            ))
            #expect(await fixture.recordedEvents().isEmpty)
        }
    }

    @Test("Confirmation revalidation requires the exact captured runtime topology")
    func runtimeTopologyRevalidationRejectsProcessReplacement() {
        let runtime = runtimeEvidence()
        let binding = runtime.startupAcknowledgement.binding
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let captured = AccountActivationRuntimeEvidence(
            generation: UUID(),
            runtimeCurrentAccountId: accountId,
            observedAt: now,
            expiresAt: now.addingTimeInterval(10),
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            runtimeBindings: [binding]
        )
        let replacementIdentity = CodexSignalProcessIdentity(
            pid: 43,
            ownerUID: binding.processIdentity.ownerUID,
            executablePath: binding.processIdentity.executablePath,
            startSeconds: binding.processIdentity.startSeconds + 1,
            startMicroseconds: binding.processIdentity.startMicroseconds
        )
        let replacementBinding = CodexReloadBinding(
            processIdentity: replacementIdentity,
            kernelExecutableIdentity: binding.kernelExecutableIdentity,
            runtimeKind: binding.runtimeKind,
            authFileIdentity: binding.authFileIdentity,
            requestNonce: "replacement",
            issuedAtUnixMilliseconds: binding.issuedAtUnixMilliseconds + 1
        )
        let replaced = AccountActivationRuntimeEvidence(
            generation: UUID(),
            runtimeCurrentAccountId: accountId,
            observedAt: now,
            expiresAt: now.addingTimeInterval(10),
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            runtimeBindings: [replacementBinding]
        )
        let renewedBinding = CodexReloadBinding(
            processIdentity: binding.processIdentity,
            kernelExecutableIdentity: binding.kernelExecutableIdentity,
            runtimeKind: binding.runtimeKind,
            authFileIdentity: binding.authFileIdentity,
            requestNonce: "renewed",
            issuedAtUnixMilliseconds: binding.issuedAtUnixMilliseconds + 1
        )
        let renewed = AccountActivationRuntimeEvidence(
            generation: UUID(),
            runtimeCurrentAccountId: accountId,
            observedAt: now,
            expiresAt: now.addingTimeInterval(10),
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            runtimeBindings: [renewedBinding]
        )
        let additionalRuntime = runtimeEvidence(pid: 44).startupAcknowledgement.binding
        let expanded = AccountActivationRuntimeEvidence(
            generation: UUID(),
            runtimeCurrentAccountId: accountId,
            observedAt: now,
            expiresAt: now.addingTimeInterval(10),
            discoveredRuntimeCount: 2,
            acknowledgedRuntimeCount: 2,
            runtimeBindings: [binding, additionalRuntime]
        )

        #expect(captured.hasSameRuntimeTopology(as: captured))
        #expect(captured.hasSameRuntimeTopology(as: renewed))
        #expect(!captured.hasSameRuntimeTopology(as: replaced))
        #expect(!captured.hasSameRuntimeTopology(as: expanded))
        #expect(captured.matchesRediscoveredRuntimeTopology(
            cli: .init(runtimes: [runtime], isComplete: true),
            desktop: .init(runtimes: [], isComplete: true)
        ))
        #expect(!captured.matchesRediscoveredRuntimeTopology(
            cli: .init(
                runtimes: [runtime, runtimeEvidence(pid: 44)],
                isComplete: true
            ),
            desktop: .init(runtimes: [], isComplete: true)
        ))
    }

    private func runtimeEvidence(
        pid: Int32 = 42,
        acknowledgedAtUnixMilliseconds: Int64 = 1_799_999_995_000
    ) -> CodexLocalRuntimeEvidence {
        let identity = CodexSignalProcessIdentity(
            pid: pid,
            ownerUID: 501,
            executablePath: "/Users/me/.local/share/codexswitch/prepared-codex/codex",
            startSeconds: 1_000,
            startMicroseconds: 1
        )
        let process = CodexIdentityBoundProcess(
            identity: identity,
            kernelExecutableIdentity: CodexKernelExecutableIdentity(
                canonicalPath: identity.executablePath,
                device: 7,
                inode: 10_000 + UInt64(pid)
            ),
            arguments: ["codex", "resume", "thread-42"]
        )
        let target = CodexRuntimeTarget(
            process: process,
            runtimeKind: .localInteractiveCLI
        )
        let observation = CodexRuntimeObservation(
            target: target,
            authFileIdentity: auth
        )
        let binding = CodexReloadBinding(
            processIdentity: identity,
            kernelExecutableIdentity: process.kernelExecutableIdentity,
            runtimeKind: .localInteractiveCLI,
            authFileIdentity: auth,
            requestNonce: "nonce-\(pid)",
            issuedAtUnixMilliseconds: acknowledgedAtUnixMilliseconds - 100
        )
        return CodexLocalRuntimeEvidence(
            observation: observation,
            startupAcknowledgement: CodexReloadAcknowledgement(
                binding: binding,
                acknowledgedAtUnixMilliseconds: acknowledgedAtUnixMilliseconds,
                loadedTokenFingerprint: auth.completeTokenFingerprint,
                activeTokenFingerprint: auth.completeTokenFingerprint,
                frontendNotified: false,
                frontendWriteCount: 0,
                authGeneration: 1,
                reconnectReady: true
            )
        )
    }
}

private actor RuntimeEvidencePreflightFixture {
    private var runtime: CodexLocalRuntimeEvidence
    private(set) var events: [String] = []

    init(runtime: CodexLocalRuntimeEvidence) {
        self.runtime = runtime
    }

    func renew(to runtime: CodexLocalRuntimeEvidence) {
        events.append("renew")
        self.runtime = runtime
    }

    func capture() -> CodexLocalRuntimeEvidence {
        events.append("capture")
        return runtime
    }

    func record(_ event: String) {
        events.append(event)
    }

    func recordedEvents() -> [String] {
        events
    }
}
