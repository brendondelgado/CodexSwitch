import Foundation
import Testing
@testable import CodexSwitch

@Suite("Unmanaged runtime convergence")
struct UnmanagedRuntimeConvergenceTests {
    private func runtime(pid: Int32, startedAt seconds: UInt64) -> CodexUnmanagedRuntime {
        CodexUnmanagedRuntime(
            pid: pid,
            startSeconds: seconds,
            startMicroseconds: 0,
            host: "T3 Code (Alpha)",
            command: "codex app-server"
        )
    }

    @Test("Only unmanaged runtimes started before the credential write are warned")
    func warningsRequireRuntimeOlderThanCommittedCredentials() {
        let committedAt = Date(timeIntervalSince1970: 2_000)
        let warnings = AccountManager.unmanagedRuntimeWarnings(
            runtimes: [
                runtime(pid: 30, startedAt: 2_500),
                runtime(pid: 20, startedAt: 1_500),
                runtime(pid: 10, startedAt: 1_000),
            ],
            credentialsWrittenAt: committedAt
        )

        #expect(warnings.map(\.pid) == [10, 20])
        #expect(AccountManager.unmanagedRuntimeWarnings(
            runtimes: [runtime(pid: 10, startedAt: 1_000)],
            credentialsWrittenAt: nil
        ).isEmpty)
    }

    @Test("Published warnings refresh the UI only when they change")
    @MainActor func publishingWarningsIsIdempotent() {
        let manager = AccountManager()
        let revision = manager.uiRefreshRevision
        manager.publishUnmanagedRuntimeWarnings([runtime(pid: 81_444, startedAt: 1_000)])
        #expect(manager.unmanagedRuntimeWarnings.map(\.pid) == [81_444])
        #expect(manager.uiRefreshRevision == revision &+ 1)
        manager.publishUnmanagedRuntimeWarnings([runtime(pid: 81_444, startedAt: 1_000)])
        #expect(manager.uiRefreshRevision == revision &+ 1)
    }

    @Test("Identical automatic retry failures back off instead of repeating every five minutes")
    func identicalFailuresEscalateRetrySpacing() {
        let generation = UUID()
        let start = Date(timeIntervalSince1970: 10_000)
        let completion = AccountActivationRuntimeCompletion(
            outcome: .restartRequired,
            discoveredRuntimeCount: 2,
            acknowledgedRuntimeCount: 1,
            detail: "cli_acknowledged_0_of_1",
            blockers: []
        )
        let signature = ActivationRetryEscalation.signature(for: completion)
        var escalation = ActivationRetryEscalation()

        escalation.recordFailure(activationGeneration: generation, signature: signature, at: start)
        // A first failure keeps the journal cadence.
        #expect(escalation.permitsAutomaticRetry(activationGeneration: generation, at: start))

        escalation.recordFailure(activationGeneration: generation, signature: signature, at: start)
        #expect(!escalation.permitsAutomaticRetry(
            activationGeneration: generation,
            at: start.addingTimeInterval(9 * 60)
        ))
        #expect(escalation.permitsAutomaticRetry(
            activationGeneration: generation,
            at: start.addingTimeInterval(10 * 60)
        ))

        for _ in 0..<10 {
            escalation.recordFailure(activationGeneration: generation, signature: signature, at: start)
        }
        #expect(escalation.nextAutomaticRetryAt(activationGeneration: generation)
            == start.addingTimeInterval(ActivationRetryEscalation.maximumInterval))

        // Another activation generation is not gated by this history.
        #expect(escalation.permitsAutomaticRetry(activationGeneration: UUID(), at: start))
    }

    @Test("A changed failure outcome restores the normal retry cadence")
    func changedOutcomeResetsEscalation() {
        let generation = UUID()
        let start = Date(timeIntervalSince1970: 10_000)
        var escalation = ActivationRetryEscalation()
        escalation.recordFailure(activationGeneration: generation, signature: "a", at: start)
        escalation.recordFailure(activationGeneration: generation, signature: "a", at: start)
        #expect(!escalation.permitsAutomaticRetry(activationGeneration: generation, at: start))

        escalation.recordFailure(activationGeneration: generation, signature: "b", at: start)
        #expect(escalation.permitsAutomaticRetry(activationGeneration: generation, at: start))

        escalation.recordFailure(activationGeneration: generation, signature: "b", at: start)
        escalation.reset()
        #expect(escalation.permitsAutomaticRetry(activationGeneration: generation, at: start))
    }
}
