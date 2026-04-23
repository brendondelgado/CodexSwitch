import Foundation
import Testing
@testable import CodexSwitch

@Suite("Account card interactions")
struct AccountCardViewTests {
    private func makeAccount(isActive: Bool) -> CodexAccount {
        CodexAccount(
            id: UUID(),
            email: "tester@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "acct_123",
            quotaSnapshot: QuotaSnapshot(
                fiveHour: QuotaWindow(
                    usedPercent: 5,
                    windowDurationMins: 300,
                    resetsAt: Date().addingTimeInterval(18_000)
                ),
                weekly: QuotaWindow(
                    usedPercent: 10,
                    windowDurationMins: 10_080,
                    resetsAt: Date().addingTimeInterval(604_800)
                ),
                fetchedAt: Date()
            ),
            planType: "pro",
            lastRefreshed: Date(),
            isActive: isActive
        )
    }

    @Test("Primary click triggers a manual swap for inactive accounts")
    @MainActor
    func primaryClickTriggersSwap() {
        let account = makeAccount(isActive: false)
        var didSwap = false
        let view = AccountCardView(account: account, pollingError: nil, onForceSwap: {
            didSwap = true
        }, onReauthenticate: nil)

        #expect(view.handlePrimaryClick())
        #expect(didSwap)
    }

    @Test("Primary click ignores the active account")
    @MainActor
    func primaryClickIgnoresActiveAccount() {
        let account = makeAccount(isActive: true)
        var didSwap = false
        let view = AccountCardView(account: account, pollingError: nil, onForceSwap: {
            didSwap = true
        }, onReauthenticate: nil)

        #expect(!view.handlePrimaryClick())
        #expect(!didSwap)
    }

    @Test("Primary click triggers re-authentication for stale accounts")
    @MainActor
    func primaryClickTriggersReauthentication() {
        let account = makeAccount(isActive: false)
        var didSwap = false
        var didReauthenticate = false
        let view = AccountCardView(
            account: account,
            pollingError: "Re-authentication required — click Re-authenticate",
            onForceSwap: {
                didSwap = true
            },
            onReauthenticate: {
                didReauthenticate = true
            }
        )

        #expect(view.requiresReauthentication)
        #expect(view.handlePrimaryClick())
        #expect(!didSwap)
        #expect(didReauthenticate)
    }
}
