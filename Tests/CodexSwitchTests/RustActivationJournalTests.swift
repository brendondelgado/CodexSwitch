import Foundation
import Testing
@testable import CodexSwitch

@Suite("Rust activation journal handoff")
struct RustActivationJournalTests {
    private let targetAccountId = "provider-target"
    private let fingerprint = String(repeating: "a", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_200_000)

    @Test("Matching terminal activation states permit Swift adoption")
    func terminalStatesAreReady() {
        for state in ["confirmed", "committed_degraded"] {
            #expect(disposition(state: state, updatedAt: now) == .ready)
        }
    }

    @Test("Fresh file-only and prepared states defer competing convergence")
    func inFlightStatesAreDeferred() {
        #expect(disposition(
            state: "file_only",
            updatedAt: now.addingTimeInterval(
                -RustActivationJournal.fileOnlyConvergenceGraceInterval + 1
            )
        ) == .deferred("Rust runtime convergence is still in flight"))
        #expect(disposition(
            state: "prepared",
            updatedAt: now.addingTimeInterval(-3_600)
        ) == .deferred("Rust activation is still committing credentials"))
    }

    @Test("An abandoned file-only activation becomes eligible for recovery")
    func staleFileOnlyIsReady() {
        #expect(disposition(
            state: "file_only",
            updatedAt: now.addingTimeInterval(
                -RustActivationJournal.fileOnlyConvergenceGraceInterval
            )
        ) == .ready)
    }

    @Test("Matching review and rollback states remain blocked")
    func failureStatesAreBlocked() {
        #expect(disposition(
            state: "manual_review",
            updatedAt: now
        ) == .blocked("Rust activation requires reconciliation"))
        #expect(disposition(
            state: "rolled_back",
            updatedAt: now
        ) == .blocked("Rust activation requires reconciliation"))
    }

    @Test("A journal for another credential generation cannot block adoption")
    func unrelatedJournalIsIgnored() {
        let otherTarget = record(
            state: "prepared",
            updatedAt: now,
            targetAccountId: "provider-other"
        )
        #expect(RustActivationJournal.handoffDisposition(
            record: otherTarget,
            targetProviderAccountId: targetAccountId,
            targetFingerprint: fingerprint,
            at: now
        ) == .ready)

        let otherFingerprint = record(
            state: "prepared",
            updatedAt: now,
            authFingerprint: String(repeating: "b", count: 64)
        )
        #expect(RustActivationJournal.handoffDisposition(
            record: otherFingerprint,
            targetProviderAccountId: targetAccountId,
            targetFingerprint: fingerprint,
            at: now
        ) == .ready)
    }

    private func disposition(
        state: String,
        updatedAt: Date
    ) -> RustActivationHandoffDisposition {
        RustActivationJournal.handoffDisposition(
            record: record(state: state, updatedAt: updatedAt),
            targetProviderAccountId: targetAccountId,
            targetFingerprint: fingerprint,
            at: now
        )
    }

    private func record(
        state: String,
        updatedAt: Date,
        targetAccountId: String? = nil,
        authFingerprint: String? = nil
    ) -> RustActivationJournalRecord {
        RustActivationJournalRecord(
            version: RustActivationJournal.currentVersion,
            state: state,
            targetAccountId: targetAccountId ?? self.targetAccountId,
            authFingerprint: authFingerprint ?? fingerprint,
            updatedAt: ISO8601DateFormatter().string(from: updatedAt)
        )
    }
}
