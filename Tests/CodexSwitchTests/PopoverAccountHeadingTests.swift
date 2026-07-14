import Foundation
import Testing
@testable import CodexSwitch

@Suite("Popover account heading")
@MainActor
struct PopoverAccountHeadingTests {
    @Test("Fresh journaled evidence labels the Mac runtime current")
    func freshEvidenceIsMacRuntimeCurrent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accountId = UUID()

        #expect(PopoverContentView.accountHeading(
            activationState: confirmedState(accountId, observedAt: now),
            configuredAccountId: accountId,
            now: now
        ) == "Mac Runtime Current")
        #expect(StatusBarController.accountScopeLabel(
            configuredAccountId: accountId,
            runtimeCurrentAccountId: accountId
        ) == "Mac Configured; Mac Runtime Current")
    }

    @Test("Expired or missing evidence remains explicitly Mac configured")
    func missingEvidenceIsMacConfiguredOnly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accountId = UUID()

        #expect(PopoverContentView.accountHeading(
            activationState: confirmedState(
                accountId,
                observedAt: now.addingTimeInterval(-30)
            ),
            configuredAccountId: accountId,
            now: now
        ) == "Mac Configured Account")
        #expect(PopoverContentView.accountHeading(
            activationState: nil,
            configuredAccountId: accountId,
            now: now
        ) == "Mac Configured Account")
        #expect(StatusBarController.accountScopeLabel(
            configuredAccountId: accountId,
            runtimeCurrentAccountId: nil
        ) == "Mac Configured; Mac Runtime Not Current")
    }

    private func confirmedState(
        _ accountId: UUID,
        observedAt: Date
    ) -> AccountActivationState {
        AccountActivationState(
            version: AccountActivationState.currentVersion,
            phase: .confirmed,
            activationGeneration: UUID(),
            configuredAccountId: accountId,
            runtimeCurrentAccountId: accountId,
            updatedAt: observedAt,
            retryAttempt: 0,
            nextRetryAt: nil,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            detail: nil,
            runtimeEvidenceGeneration: UUID(),
            runtimeEvidenceObservedAt: observedAt,
            runtimeEvidenceExpiresAt: observedAt.addingTimeInterval(10)
        )
    }
}
