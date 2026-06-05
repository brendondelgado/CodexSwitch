import Foundation
import Testing
@testable import CodexSwitch

@Suite("Codex plan capacity")
struct CodexPlanCapacityTests {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        return components.date!
    }

    @Test("Pro 5x gets 10x Codex capacity during promo")
    func pro5GetsTenXDuringPromo() {
        let capacity = CodexPlanCapacity.forPlanType("prolite", now: date(2026, 5, 3))

        #expect(capacity.label == "Pro 5x promo")
        #expect(capacity.monthlyCostUSD == 100)
        #expect(capacity.fiveHourPlusMultiplier == 10)
        #expect(capacity.weeklyPlusMultiplier == 10)
    }

    @Test("Pro 5x returns to 5x after promo")
    func pro5ReturnsToFiveXAfterPromo() {
        let capacity = CodexPlanCapacity.forPlanType("prolite", now: date(2026, 6, 1))

        #expect(capacity.label == "Pro 5x")
        #expect(capacity.fiveHourPlusMultiplier == 5)
        #expect(capacity.weeklyPlusMultiplier == 5)
    }

    @Test("Pro 20x uses 25x five-hour and 20x weekly during promo")
    func pro20UsesPublishedPromotionalFiveHourCapacity() {
        let capacity = CodexPlanCapacity.forPlanType("pro", now: date(2026, 5, 3))

        #expect(capacity.label == "Pro 20x")
        #expect(capacity.monthlyCostUSD == 200)
        #expect(capacity.fiveHourPlusMultiplier == 25)
        #expect(capacity.weeklyPlusMultiplier == 20)
    }

    @Test("Pool summary weights plans by Plus-equivalent Codex capacity")
    func poolSummaryWeightsPlansByPlusEquivalentCodexCapacity() {
        let accounts = [
            account(email: "pro20@test.com", planType: "pro"),
            account(email: "pro5@test.com", planType: "prolite"),
            account(email: "plus1@test.com", planType: "plus"),
            account(email: "plus2@test.com", planType: "plus"),
            account(email: "free@test.com", planType: "free"),
        ]

        let summary = PooledCapacitySummary(accounts: accounts, now: date(2026, 5, 3))

        #expect(summary.totalMonthlyCostUSD == 340)
        #expect(summary.fiveHourPlusCapacity == 37)
        #expect(summary.weeklyPlusCapacity == 32)
        #expect(summary.nominalAccountCount == 4)
        #expect(summary.excludedAccountCount == 1)
        #expect(summary.breakdownText == "1 Pro 20x + 1 Pro 5x promo + 2 Plus + 1 Free")
        #expect(summary.promoText != nil)
    }

    private func account(email: String, planType: String) -> CodexAccount {
        CodexAccount(
            email: email,
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: email,
            planType: planType,
            hasActiveSubscription: planType != "free"
        )
    }
}
