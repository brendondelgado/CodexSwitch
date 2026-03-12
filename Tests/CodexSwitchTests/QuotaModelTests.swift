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
        #expect(QuotaUrgency(remainingPercent: 5) == .high)
        #expect(QuotaUrgency(remainingPercent: 4) == .critical)
        #expect(QuotaUrgency(remainingPercent: 0) == .critical)
    }

    @Test("QuotaUrgency poll intervals")
    func pollIntervals() {
        #expect(QuotaUrgency.relaxed.pollInterval == 600)
        #expect(QuotaUrgency.moderate.pollInterval == 300)
        #expect(QuotaUrgency.elevated.pollInterval == 120)
        #expect(QuotaUrgency.high.pollInterval == 60)
        #expect(QuotaUrgency.critical.pollInterval == 10)
    }

    @Test("QuotaWindow computed properties")
    func windowProperties() {
        let future = Date().addingTimeInterval(3600)
        let window = QuotaWindow(usedPercent: 28, windowDurationMins: 300, resetsAt: future)
        #expect(window.remainingPercent == 72)
        #expect(!window.isExhausted)
        #expect(window.urgency == .relaxed)

        let exhausted = QuotaWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: future)
        #expect(exhausted.remainingPercent == 0)
        #expect(exhausted.isExhausted)
        #expect(exhausted.urgency == .critical)
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
}
