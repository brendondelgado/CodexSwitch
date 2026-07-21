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

    private func makeResetBank(now: Date) -> RateLimitResetBank {
        RateLimitResetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [
                RateLimitResetCredit(
                    id: "credit-1",
                    resetType: "weekly",
                    status: "available",
                    grantedAt: now.addingTimeInterval(-3_600),
                    expiresAt: now.addingTimeInterval(2 * 86_400),
                    redeemedAt: nil,
                    title: nil,
                    description: nil
                ),
            ],
            fetchedAt: now
        )
    }

    private func makeRedeemableAccount(now: Date) -> CodexAccount {
        CodexAccount(
            email: "blocked-pro@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "blocked-pro",
            quotaSnapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: now,
                windows: [
                    QuotaWindow(
                        kind: .weekly,
                        durationSeconds: 604_800,
                        usedPercent: 100,
                        resetsAt: now.addingTimeInterval(86_400),
                        source: QuotaWindowSourceMetadata(
                            rateLimit: .main,
                            slot: .primary
                        )
                    ),
                ]
            ),
            planType: "pro",
            rateLimitResetBank: makeResetBank(now: now)
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

    @Test("Confirmed redemption invokes the account callback only for current eligible inventory")
    @MainActor
    func confirmedRedemptionRequiresVisibleEligibility() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = makeRedeemableAccount(now: now)
        var didRedeem = false
        let eligibleView = AccountCardView(
            account: account,
            rateLimitResetPresentation: .current(
                availableCount: 1,
                nextExpiration: now.addingTimeInterval(2 * 86_400)
            ),
            onRedeemReset: {
                didRedeem = true
            },
            onReauthenticate: nil,
            onForceSwap: nil
        )

        #expect(eligibleView.resetRedemptionActionPresentation(at: now).isEnabled)
        #expect(eligibleView.handleConfirmedResetRedemption(at: now))
        #expect(didRedeem)

        didRedeem = false
        let errorView = AccountCardView(
            account: account,
            rateLimitResetPresentation: .error(
                message: "Inventory request failed",
                lastKnownCount: 1
            ),
            onRedeemReset: {
                didRedeem = true
            },
            onReauthenticate: nil,
            onForceSwap: nil
        )

        let errorAction = errorView.resetRedemptionActionPresentation(at: now)
        #expect(!errorAction.isEnabled)
        #expect(errorAction.helpText == "Reset inventory error: Inventory request failed")
        #expect(!errorView.handleConfirmedResetRedemption(at: now))
        #expect(!didRedeem)

        let coordinatorBlockedView = AccountCardView(
            account: account,
            rateLimitResetPresentation: .current(
                availableCount: 1,
                nextExpiration: now.addingTimeInterval(2 * 86_400)
            ),
            rateLimitResetCoordinatorAuthorization: .blocked(
                "Another reset redemption is already in progress"
            ),
            onRedeemReset: {
                didRedeem = true
            },
            onReauthenticate: nil,
            onForceSwap: nil
        )
        let blockedAction = coordinatorBlockedView.resetRedemptionActionPresentation(at: now)
        #expect(!blockedAction.isEnabled)
        #expect(blockedAction.helpText == "Another reset redemption is already in progress")
        #expect(!coordinatorBlockedView.handleConfirmedResetRedemption(at: now))
        #expect(!didRedeem)
    }

    @Test("Redemption tooltip uses the policy's unavailable reason")
    @MainActor
    func redemptionTooltipUsesPolicyReason() {
        var usableAccount = makeAccount(isActive: false)
        let now = Date().addingTimeInterval(1)
        usableAccount.rateLimitResetBank = makeResetBank(now: now)
        let view = AccountCardView(
            account: usableAccount,
            rateLimitResetPresentation: .current(
                availableCount: 1,
                nextExpiration: now.addingTimeInterval(2 * 86_400)
            ),
            onRedeemReset: {},
            onReauthenticate: nil,
            onForceSwap: nil
        )

        let action = view.resetRedemptionActionPresentation(at: now)
        #expect(!action.isEnabled)
        #expect(action.helpText == RateLimitResetPolicy.manualRedemptionUnavailableReason(
            for: usableAccount,
            bank: usableAccount.rateLimitResetBank,
            now: now
        ))
        #expect(action.helpText == "This account still has usable quota")
    }
}
