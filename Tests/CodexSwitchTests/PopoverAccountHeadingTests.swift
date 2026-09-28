import Foundation
import Testing
@testable import CodexSwitch

@Suite("Active account presentation")
@MainActor
struct PopoverAccountHeadingTests {
    @Test("Menubar follows the Mac-committed account and names a differing pool target")
    func menubarUsesCommittedAccountAndNamesPoolTarget() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let configured = account(email: "configured@example.com", isActive: true)
        let poolTarget = account(email: "target@example.com", isActive: false)
        let manager = AccountManager()
        manager.accounts = [configured, poolTarget]
        manager.linuxDevboxStatus = LinuxDevboxStatus(
            state: .ready,
            summary: "Ready",
            activeEmail: poolTarget.email,
            activeProviderAccountId: poolTarget.accountId
        )
        manager.publishPoolAuthorityObservation(try PoolAuthorityObservation(
            epoch: 4,
            phase: .stable,
            desiredProviderAccountId: poolTarget.accountId,
            requestId: "44444444-4444-4444-8444-444444444444",
            reason: "manual",
            observedAt: now,
            updatedAt: now,
            previousProviderAccountId: configured.accountId,
            detail: nil
        ))

        let display = manager.displayReadModel(at: now)
        #expect(manager.logicalActiveAccount(at: now)?.id == poolTarget.id)
        #expect(display.currentAccountId == configured.id)
        #expect(display.poolTargetAccountId == poolTarget.id)
        #expect(StatusBarController.currentScopeLabel(for: display)
            == "Current: configured@example.com; Mac runtime unconfirmed; VPS target: target@example.com")
    }

    @Test("Missing or contradictory Mac credentials never invent a current account")
    func missingOrAmbiguousCommittedAccountFailsClosed() {
        let first = account(email: "first@example.com", isActive: true)
        let second = account(email: "second@example.com", isActive: true)
        let manager = AccountManager()
        manager.accounts = [first, second]

        let ambiguous = manager.displayReadModel()
        #expect(ambiguous.currentAccountId == nil)
        #expect(ambiguous.currentIsAmbiguous)
        #expect(PopoverContentView.missingCurrentAccountLabel(for: ambiguous)
            == "Mac committed account is ambiguous")

        manager.accounts = [account(email: "idle@example.com", isActive: false)]
        let none = manager.displayReadModel()
        #expect(none.currentAccountId == nil)
        #expect(!none.currentIsAmbiguous)
        #expect(PopoverContentView.missingCurrentAccountLabel(for: none)
            == "No account committed on this Mac")
        #expect(AccountCardView.currentLabel == "Current")
        #expect(PopoverContentView.currentAccountLabel == "Current (Mac)")
    }

    @Test("Stale ages are compact")
    func staleAgesAreCompact() {
        #expect(AccountDisplayReadModel.compactAge(45) == "45s")
        #expect(AccountDisplayReadModel.compactAge(12 * 60) == "12m")
        #expect(AccountDisplayReadModel.compactAge(9 * 3_600 + 59) == "9h")
        #expect(AccountDisplayReadModel.compactAge(3 * 86_400) == "3d")
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
