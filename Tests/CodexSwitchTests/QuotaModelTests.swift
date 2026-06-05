import Testing
import Foundation
@testable import CodexSwitch

@Suite("Quota Models")
struct QuotaModelTests {
    @Test("QuotaUrgency thresholds")
    func urgencyThresholds() {
        #expect(QuotaUrgency(remainingPercent: 75) == .relaxed)
        #expect(QuotaUrgency(remainingPercent: 50) == .relaxed)
        #expect(QuotaUrgency(remainingPercent: 49) == .moderate)
        #expect(QuotaUrgency(remainingPercent: 20) == .moderate)
        #expect(QuotaUrgency(remainingPercent: 19) == .elevated)
        #expect(QuotaUrgency(remainingPercent: 10) == .elevated)
        #expect(QuotaUrgency(remainingPercent: 9) == .high)
        #expect(QuotaUrgency(remainingPercent: 7) == .high)
        #expect(QuotaUrgency(remainingPercent: 5) == .imminent)
        #expect(QuotaUrgency(remainingPercent: 1) == .imminent)
        #expect(QuotaUrgency(remainingPercent: 0.9) == .critical)
        #expect(QuotaUrgency(remainingPercent: 0) == .critical)
    }

    @Test("QuotaUrgency poll intervals")
    func pollIntervals() {
        #expect(QuotaUrgency.relaxed.pollInterval == 600)
        #expect(QuotaUrgency.moderate.pollInterval == 300)
        #expect(QuotaUrgency.elevated.pollInterval == 120)
        #expect(QuotaUrgency.high.pollInterval == 60)
        #expect(QuotaUrgency.imminent.pollInterval == 1)
        #expect(QuotaUrgency.critical.pollInterval == 1)
    }

    @Test("QuotaWindow computed properties")
    func windowProperties() {
        let future = Date().addingTimeInterval(3600)
        let window = QuotaWindow(usedPercent: 28, windowDurationMins: 300, resetsAt: future, hardLimitReached: false)
        #expect(window.remainingPercent == 72)
        #expect(!window.isExhausted)
        #expect(window.urgency == .relaxed)

        let exhausted = QuotaWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: future, hardLimitReached: false)
        #expect(exhausted.remainingPercent == 0)
        #expect(exhausted.isExhausted)
        #expect(exhausted.urgency == .critical)
    }

    @Test("Auto swap triggers when displayed quota reaches one percent")
    func autoSwapThreshold() {
        let future = Date().addingTimeInterval(3600)
        let fivePercent = QuotaWindow(usedPercent: 95, windowDurationMins: 300, resetsAt: future, hardLimitReached: false)
        let displayedAsOnePercentFromTruncation = QuotaWindow(usedPercent: 98.49, windowDurationMins: 300, resetsAt: future, hardLimitReached: false)
        let displayedAsOnePercent = QuotaWindow(usedPercent: 98.6, windowDurationMins: 300, resetsAt: future, hardLimitReached: false)
        let onePercent = QuotaWindow(usedPercent: 99, windowDurationMins: 300, resetsAt: future, hardLimitReached: false)
        let belowOnePercent = QuotaWindow(usedPercent: 99.2, windowDurationMins: 300, resetsAt: future, hardLimitReached: false)

        #expect(!fivePercent.shouldAutoSwapAway)
        #expect(displayedAsOnePercentFromTruncation.shouldAutoSwapAway)
        #expect(displayedAsOnePercent.shouldAutoSwapAway)
        #expect(onePercent.shouldAutoSwapAway)
        #expect(belowOnePercent.shouldAutoSwapAway)
    }

    @Test("Hard limit reached overrides percentage threshold")
    func hardLimitReachedOverridesThreshold() {
        let future = Date().addingTimeInterval(3600)
        let window = QuotaWindow(usedPercent: 98.9, windowDurationMins: 300, resetsAt: future, hardLimitReached: true)

        #expect(abs(window.remainingPercent - 1.1) < 0.0001)
        #expect(window.isExhausted)
        #expect(window.shouldAutoSwapAway)
    }

    @Test("Past exhausted reset needs fresh confirmation")
    func pastExhaustedResetNeedsFreshConfirmation() {
        let now = Date()
        let pastExhausted = QuotaWindow(
            usedPercent: 100,
            windowDurationMins: 300,
            resetsAt: now.addingTimeInterval(-60),
            hardLimitReached: true
        )
        let futureExhausted = QuotaWindow(
            usedPercent: 100,
            windowDurationMins: 300,
            resetsAt: now.addingTimeInterval(60),
            hardLimitReached: true
        )
        let pastHealthy = QuotaWindow(
            usedPercent: 20,
            windowDurationMins: 300,
            resetsAt: now.addingTimeInterval(-60),
            hardLimitReached: false
        )

        #expect(pastExhausted.needsResetConfirmation(now: now))
        #expect(pastExhausted.needsResetConfirmation(now: now, staleAfter: 30))
        #expect(!pastExhausted.needsResetConfirmation(now: now, staleAfter: 120))
        #expect(!futureExhausted.needsResetConfirmation(now: now))
        #expect(!pastHealthy.needsResetConfirmation(now: now))
    }

    @Test("Drain bar does not call expired reset timestamps reauth")
    @MainActor func drainBarExpiredResetCopyDoesNotSayReauth() {
        let now = Date(timeIntervalSince1970: 1_777_777_777)
        let past = now.addingTimeInterval(-60)

        #expect(DrainBarView.resetText(percent: 100, resetsAt: past, now: now) == "")
        #expect(DrainBarView.resetText(percent: 0, resetsAt: past, now: now) == "confirming reset")
        #expect(!DrainBarView.resetText(percent: 0, resetsAt: past, now: now).localizedCaseInsensitiveContains("reauth"))
    }

    @Test("Account card classifies token failures as login required only")
    @MainActor func accountCardAuthErrorClassification() {
        #expect(AccountCardView.needsReauthentication(for: "token_expired"))
        #expect(AccountCardView.needsReauthentication(for: "Token refresh failed (HTTP 401)"))
        #expect(AccountCardView.needsReauthentication(for: "unexpected status 401 Unauthorized"))
        #expect(AccountCardView.needsReauthentication(for: "Your authentication token has been invalidated."))
        #expect(!AccountCardView.needsReauthentication(for: "stale; confirming reset"))
        #expect(!AccountCardView.needsReauthentication(for: "reset needs confirmation"))
        #expect(!AccountCardView.needsReauthentication(for: nil))
    }

    @Test("AccountManager active account")
    @MainActor func activeAccount() {
        let manager = AccountManager()
        let a1 = CodexAccount(email: "a@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc1", isActive: true)
        let a2 = CodexAccount(email: "b@test.com", accessToken: "t2", refreshToken: "r2", idToken: "i2", accountId: "acc2", isActive: false)
        manager.addAccount(a1)
        manager.addAccount(a2)
        #expect(manager.activeAccount?.email == "a@test.com")
        manager.setActive(a2.id)
        #expect(manager.activeAccount?.email == "b@test.com")
    }

    @Test("AccountManager lightweight UI refresh revision")
    @MainActor func uiRefreshRevision() {
        let manager = AccountManager()
        #expect(manager.uiRefreshRevision == 0)
        manager.requestUIRefresh()
        #expect(manager.uiRefreshRevision == 1)
        manager.requestUIRefresh()
        #expect(manager.uiRefreshRevision == 2)
    }

    @Test("AccountManager deduplicates by accountId")
    @MainActor func deduplication() {
        let manager = AccountManager()
        let a1 = CodexAccount(email: "a@test.com", accessToken: "old", refreshToken: "r1", idToken: "i1", accountId: "same-id")
        let a2 = CodexAccount(email: "a@test.com", accessToken: "new", refreshToken: "r1", idToken: "i1", accountId: "same-id")
        manager.addAccount(a1)
        manager.addAccount(a2)
        #expect(manager.accounts.count == 1)
        #expect(manager.accounts[0].accessToken == "new")
    }

    @Test("AuthFile JSON decoding")
    func authFileDecoding() throws {
        let json = """
        {
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": null,
            "tokens": {
                "id_token": "idt",
                "access_token": "act",
                "refresh_token": "rft",
                "account_id": "acc-123"
            },
            "last_refresh": "2026-03-12T08:44:18.860111Z"
        }
        """
        let data = json.data(using: .utf8)!
        let authFile = try JSONDecoder().decode(AuthFile.self, from: data)
        #expect(authFile.authMode == "chatgpt")
        #expect(authFile.tokens.accessToken == "act")
        #expect(authFile.tokens.accountId == "acc-123")
    }


    @Test("Legacy quota snapshots decode without hardLimitReached")
    func legacyQuotaSnapshotDecoding() throws {
        let json = """
        {
          "fiveHour": {
            "usedPercent": 100,
            "windowDurationMins": 10080,
            "resetsAt": 799276275
          },
          "weekly": {
            "usedPercent": 0,
            "windowDurationMins": 10080,
            "resetsAt": 799653165.342368
          },
          "fetchedAt": 799048365.342368
        }
        """

        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.fiveHour.hardLimitReached == false)
        #expect(snapshot.weekly.hardLimitReached == false)
        #expect(snapshot.fiveHour.remainingPercent == 0)
    }
}
