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
        let acknowledgementDate = Date(
            timeIntervalSince1970: TimeInterval(acknowledgedAtUnixMilliseconds) / 1_000
        )
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
            observedAt: acknowledgementDate,
            expiresAt: acknowledgementDate.addingTimeInterval(10),
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            runtimeBindings: [runtime.startupAcknowledgement.binding]
        )))
    }

    @Test("Evidence lifetime starts at the oldest acknowledgement")
    func evidenceUsesOldestAcknowledgementTime() {
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
        let oldest = Date(
            timeIntervalSince1970: TimeInterval(olderMilliseconds) / 1_000
        )
        #expect(evidence.observedAt == oldest)
        #expect(evidence.expiresAt == oldest.addingTimeInterval(10))
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

    @Test("An ACK older than five minutes cannot be reminted with a current process binding")
    func staleAcknowledgementCannotBeReminted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staleAcknowledgement = Int64(now.timeIntervalSince1970 * 1_000)
            - Int64(AccountActivationRuntimeEvidenceEvaluator.maximumAcknowledgementAge * 1_000)
            - 1
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
        #expect(decision == .denied(
            detail: .runtimeAcknowledgementIncomplete,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
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
        #expect(evidence.observedAt == Date(timeIntervalSince1970: 1_799_999_999))
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
