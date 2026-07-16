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
        let view = AccountCardView(account: account, pollingError: nil, onReauthenticate: nil, onForceSwap: {
            didSwap = true
        })

        #expect(view.handlePrimaryClick())
        #expect(didSwap)
    }

    @Test("Primary click ignores the runtime-current account")
    @MainActor
    func primaryClickIgnoresRuntimeCurrentAccount() {
        let account = makeAccount(isActive: true)
        var didSwap = false
        let view = AccountCardView(
            account: account,
            isConfigured: true,
            isRuntimeCurrent: true,
            pollingError: nil,
            onReauthenticate: nil,
            onForceSwap: {
                didSwap = true
            }
        )

        #expect(!view.handlePrimaryClick())
        #expect(!didSwap)
    }

    @Test("Primary click retries a configured account whose runtime is not current")
    @MainActor
    func primaryClickRetriesConfiguredNonCurrentAccount() {
        let account = makeAccount(isActive: true)
        var didSwap = false
        let view = AccountCardView(
            account: account,
            isConfigured: true,
            isRuntimeCurrent: false,
            pollingError: nil,
            onReauthenticate: nil,
            onForceSwap: {
                didSwap = true
            }
        )

        #expect(view.handlePrimaryClick())
        #expect(didSwap)
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
            onReauthenticate: {
                didReauthenticate = true
            },
            onForceSwap: {
                didSwap = true
            }
        )

        #expect(view.requiresReauthentication)
        #expect(view.handlePrimaryClick())
        #expect(!didSwap)
        #expect(didReauthenticate)
    }

    @Test("Accessibility hint describes the same primary action")
    @MainActor
    func accessibilityHintMatchesPrimaryAction() {
        let account = makeAccount(isActive: false)

        #expect(AccountCardView(
            account: account,
            pollingError: nil,
            onReauthenticate: nil,
            onForceSwap: {}
        ).primaryActionAccessibilityHint == "Switch Mac to this account")

        #expect(AccountCardView(
            account: account,
            isConfigured: true,
            isRuntimeCurrent: false,
            pollingError: nil,
            onReauthenticate: nil,
            onForceSwap: {}
        ).primaryActionAccessibilityHint == "Retry Mac runtime activation")

        #expect(AccountCardView(
            account: account,
            isConfigured: true,
            isRuntimeCurrent: true,
            pollingError: nil,
            onReauthenticate: nil,
            onForceSwap: {}
        ).primaryActionAccessibilityHint == "Mac runtime is already using this account")

        #expect(AccountCardView(
            account: account,
            pollingError: "Token refresh failed (HTTP 401)",
            onReauthenticate: {},
            onForceSwap: {}
        ).primaryActionAccessibilityHint == "Reauthenticate this account")
    }
}
