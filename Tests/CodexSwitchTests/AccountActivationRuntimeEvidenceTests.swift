import Foundation
import Testing
@testable import CodexSwitch

@Suite("Mac activation runtime evidence")
struct AccountActivationRuntimeEvidenceTests {
    private let accountId = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
    private let auth = CodexAuthFileIdentity(
        canonicalPath: "/Users/me/.codex/auth.json",
        completeTokenFingerprint: String(repeating: "a", count: 64)
    )

    @Test("No live runtime is configured-only evidence, never confirmation")
    func noRuntimeDeniesConfirmation() {
        let decision = AccountActivationRuntimeEvidenceEvaluator.evaluate(
            cli: .init(runtimes: [], isComplete: true),
            desktop: .init(runtimes: [], isComplete: true),
            expectedAccountId: accountId,
            expectedAuthIdentity: auth,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000)
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
            observedAt: Date(timeIntervalSince1970: 1_800_000_000)
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
        let generation = UUID()
        let decision = AccountActivationRuntimeEvidenceEvaluator.evaluate(
            cli: .init(runtimes: [runtimeEvidence()], isComplete: true),
            desktop: .init(runtimes: [], isComplete: true),
            expectedAccountId: accountId,
            expectedAuthIdentity: auth,
            observedAt: now,
            lifetime: 10,
            generation: generation
        )

        #expect(decision == .confirmed(AccountActivationRuntimeEvidence(
            generation: generation,
            runtimeCurrentAccountId: accountId,
            observedAt: now,
            expiresAt: now.addingTimeInterval(10),
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1
        )))
    }

    private func runtimeEvidence() -> CodexLocalRuntimeEvidence {
        let identity = CodexSignalProcessIdentity(
            pid: 42,
            ownerUID: 501,
            executablePath: "/Users/me/.local/share/codexswitch/prepared-codex/codex",
            startSeconds: 1_000,
            startMicroseconds: 1
        )
        let process = CodexIdentityBoundProcess(
            identity: identity,
            kernelExecutableIdentity: CodexKernelExecutableIdentity(
                path: identity.executablePath
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
            requestNonce: "nonce-42",
            issuedAtUnixMilliseconds: 1_500_000
        )
        return CodexLocalRuntimeEvidence(
            observation: observation,
            startupAcknowledgement: CodexReloadAcknowledgement(
                binding: binding,
                acknowledgedAtUnixMilliseconds: 1_500_100,
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
