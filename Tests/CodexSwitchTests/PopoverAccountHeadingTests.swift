import Foundation
import Testing
@testable import CodexSwitch

@Suite("Active account presentation")
@MainActor
struct PopoverAccountHeadingTests {
    @Test("Menubar follows the fresh pool target during Mac divergence")
    func menubarUsesPoolTargetInsteadOfConfiguredAccount() {
        let configured = account(email: "configured@example.com", isActive: true)
        let poolTarget = account(email: "target@example.com", isActive: false)
        let readModel = ActiveAccountReadModel(
            providerAccountId: poolTarget.accountId,
            epoch: 4,
            freshness: .current
        )

        let manager = AccountManager()
        manager.accounts = [configured, poolTarget]

        #expect(manager.logicalActiveAccount(using: readModel)?.id == poolTarget.id)
        #expect(StatusBarController.poolTargetScopeLabel(
            poolTargetAccountId: poolTarget.id,
            runtimeCurrentAccountId: configured.id
        ) == "Pool Target; Mac Runtime Not Current")
    }

    @Test("Menubar preserves stale authority and never invents a fallback")
    func menubarUsesOnlyAuthorityReadModel() {
        let configured = account(email: "configured@example.com", isActive: true)
        let staleTarget = account(email: "target@example.com", isActive: false)
        let manager = AccountManager()
        manager.accounts = [configured, staleTarget]

        #expect(manager.logicalActiveAccount(
            using: ActiveAccountReadModel(
                providerAccountId: staleTarget.accountId,
                epoch: 5,
                freshness: .stale
            )
        )?.id == staleTarget.id)
        #expect(manager.logicalActiveAccount(using: .unavailable) == nil)
        manager.accounts.append(staleTarget)
        #expect(manager.logicalActiveAccount(
            using: ActiveAccountReadModel(
                providerAccountId: staleTarget.accountId,
                epoch: 5,
                freshness: .current
            )
        ) == nil)
        #expect(StatusBarController.poolTargetScopeLabel(
            poolTargetAccountId: staleTarget.id,
            runtimeCurrentAccountId: configured.id,
            freshness: .stale
        ) == "Pool Target; Mac Runtime Not Current")
        #expect(AccountCardView.poolTargetLabel(for: .stale)
            == "Pool Target")
        #expect(PopoverContentView.poolTargetLabel(for: .stale)
            == "Pool Target")
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
