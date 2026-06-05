import Foundation

struct CodexPlanCapacity: Equatable, Sendable {
    let label: String
    let monthlyCostUSD: Int
    let fiveHourPlusMultiplier: Double
    let weeklyPlusMultiplier: Double
    let countsTowardNominalPool: Bool

    static let plusFiveHourMultiplier = 1.0
    static let plusWeeklyMultiplier = 1.0
    static let pro5StandardMultiplier = 5.0
    static let pro5PromoMultiplier = 10.0
    static let pro20StandardMultiplier = 20.0
    static let pro20PromoFiveHourMultiplier = 25.0

    static let codexProPromoEndsAt: Date = {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 6
        components.day = 1
        return components.date!
    }()

    static func forAccount(_ account: CodexAccount, now: Date = Date()) -> CodexPlanCapacity {
        forPlanType(
            account.planType,
            hasActiveSubscription: account.hasActiveSubscription,
            now: now
        )
    }

    static func forPlanType(
        _ planType: String?,
        hasActiveSubscription: Bool? = nil,
        now: Date = Date()
    ) -> CodexPlanCapacity {
        let normalized = planType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "unknown"
        let promoActive = now < codexProPromoEndsAt

        switch normalized {
        case "pro":
            return CodexPlanCapacity(
                label: "Pro 20x",
                monthlyCostUSD: 200,
                fiveHourPlusMultiplier: promoActive ? pro20PromoFiveHourMultiplier : pro20StandardMultiplier,
                weeklyPlusMultiplier: pro20StandardMultiplier,
                countsTowardNominalPool: true
            )
        case "pro_lite", "prolite", "pro-lite", "pro lite":
            return CodexPlanCapacity(
                label: promoActive ? "Pro 5x promo" : "Pro 5x",
                monthlyCostUSD: 100,
                fiveHourPlusMultiplier: promoActive ? pro5PromoMultiplier : pro5StandardMultiplier,
                weeklyPlusMultiplier: promoActive ? pro5PromoMultiplier : pro5StandardMultiplier,
                countsTowardNominalPool: true
            )
        case "plus", "team", "business", "enterprise", "edu":
            return CodexPlanCapacity(
                label: "Plus",
                monthlyCostUSD: 20,
                fiveHourPlusMultiplier: plusFiveHourMultiplier,
                weeklyPlusMultiplier: plusWeeklyMultiplier,
                countsTowardNominalPool: true
            )
        case "free", "go", "free_workspace", "guest":
            return CodexPlanCapacity(
                label: normalized == "go" ? "Go" : "Free",
                monthlyCostUSD: normalized == "go" ? 8 : 0,
                fiveHourPlusMultiplier: 0,
                weeklyPlusMultiplier: 0,
                countsTowardNominalPool: false
            )
        default:
            if hasActiveSubscription == true {
                return CodexPlanCapacity(
                    label: "Paid",
                    monthlyCostUSD: 20,
                    fiveHourPlusMultiplier: plusFiveHourMultiplier,
                    weeklyPlusMultiplier: plusWeeklyMultiplier,
                    countsTowardNominalPool: true
                )
            }
            return CodexPlanCapacity(
                label: "Unknown",
                monthlyCostUSD: 0,
                fiveHourPlusMultiplier: 0,
                weeklyPlusMultiplier: 0,
                countsTowardNominalPool: false
            )
        }
    }
}

struct PooledCapacitySummary: Equatable, Sendable {
    let totalMonthlyCostUSD: Int
    let fiveHourPlusCapacity: Double
    let weeklyPlusCapacity: Double
    let nominalAccountCount: Int
    let excludedAccountCount: Int
    let breakdownText: String
    let promoText: String?

    init(accounts: [CodexAccount], now: Date = Date()) {
        var counts: [String: Int] = [:]
        var totalCost = 0
        var fiveHourCapacity = 0.0
        var weeklyCapacity = 0.0
        var nominalCount = 0
        var excludedCount = 0

        for account in accounts {
            let capacity = CodexPlanCapacity.forAccount(account, now: now)
            counts[capacity.label, default: 0] += 1
            totalCost += capacity.monthlyCostUSD
            fiveHourCapacity += capacity.fiveHourPlusMultiplier
            weeklyCapacity += capacity.weeklyPlusMultiplier
            if capacity.countsTowardNominalPool {
                nominalCount += 1
            } else {
                excludedCount += 1
            }
        }

        self.totalMonthlyCostUSD = totalCost
        self.fiveHourPlusCapacity = fiveHourCapacity
        self.weeklyPlusCapacity = weeklyCapacity
        self.nominalAccountCount = nominalCount
        self.excludedAccountCount = excludedCount
        self.breakdownText = Self.formatBreakdown(counts)
        self.promoText = now < CodexPlanCapacity.codexProPromoEndsAt
            ? "Promo through May 31: Pro 5x counts as 10x; Pro 20x 5h counts as 25x."
            : nil
    }

    private static func formatBreakdown(_ counts: [String: Int]) -> String {
        let order = ["Pro 20x", "Pro 5x promo", "Pro 5x", "Plus", "Paid", "Go", "Free", "Unknown"]
        let ordered = order.compactMap { label -> String? in
            guard let count = counts[label], count > 0 else { return nil }
            return "\(count) \(label)"
        }
        guard !ordered.isEmpty else { return "No accounts" }
        return ordered.joined(separator: " + ")
    }
}
