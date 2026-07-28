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

    @Test("Menubar follows the fresh pool target during Mac divergence")
    func menubarUsesPoolTargetInsteadOfConfiguredAccount() {
        let configured = account(email: "configured@example.com", isActive: true)
        let poolTarget = account(email: "target@example.com", isActive: false)

        #expect(StatusBarController.displayAccount(
            configuredAccount: configured,
            poolTargetAccount: poolTarget,
            remoteAuthorityEndpointConfigured: true,
            authorityIsFresh: true
        )?.id == poolTarget.id)
        #expect(StatusBarController.poolTargetScopeLabel(
            poolTargetAccountId: poolTarget.id,
            runtimeCurrentAccountId: configured.id
        ) == "Pool Target; Mac Runtime Not Current")
    }

    @Test("Menubar never substitutes local quota for missing authority")
    func menubarFailsClosedWithoutFreshAuthority() {
        let configured = account(email: "configured@example.com", isActive: true)

        #expect(StatusBarController.displayAccount(
            configuredAccount: configured,
            poolTargetAccount: nil,
            remoteAuthorityEndpointConfigured: true,
            authorityIsFresh: false
        ) == nil)
        #expect(StatusBarController.displayAccount(
            configuredAccount: configured,
            poolTargetAccount: nil,
            remoteAuthorityEndpointConfigured: false,
            authorityIsFresh: false
        )?.id == configured.id)
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
            runtimeEvidenceExpiresAt: observedAt.addingTimeInterval(10),
            runtimeBlockers: nil
        )
    }

    private func account(email: String, isActive: Bool) -> CodexAccount {
        CodexAccount(
            email: email,
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: email,
            isActive: isActive
        )
    }
}
