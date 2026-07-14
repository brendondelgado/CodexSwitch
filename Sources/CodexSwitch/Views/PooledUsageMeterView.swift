import SwiftUI

/// Shows aggregate usage across all accounts compared to a single Pro plan.
/// Uses plan-weighted Plus-equivalent capacity for cost/capacity calculations,
/// and reports how many are actually reporting data.
struct PooledUsageMeterView: View {
    let accounts: [CodexAccount]
    let tokenSavingsSummary: CodexTokenSavingsSummary?
    let rateLimitResetPresentations: [UUID: RateLimitResetInventoryPresentation]

    init(
        accounts: [CodexAccount],
        tokenSavingsSummary: CodexTokenSavingsSummary? = nil,
        rateLimitResetPresentations: [UUID: RateLimitResetInventoryPresentation] = [:]
    ) {
        self.accounts = accounts
        self.tokenSavingsSummary = tokenSavingsSummary
        self.rateLimitResetPresentations = rateLimitResetPresentations
    }

    private var capacitySummary: PooledCapacitySummary {
        PooledCapacitySummary(accounts: accounts)
    }

    private var accountsWithData: [CodexAccount] {
        accounts.filter { $0.realQuotaSnapshot != nil }
    }

    private var quotaStateSummary: PooledQuotaStateSummary {
        Self.stateSummary(for: accounts)
    }

    static func quotaState(for snapshot: QuotaSnapshot) -> PooledAccountQuotaState {
        if snapshot.isDenied { return .denied }
        if snapshot.windows.isEmpty { return .unknown }
        if snapshot.isImmediatelyUsable { return .usable }
        if !snapshot.blockingWindows.isEmpty { return .exhausted }
        return .unknown
    }

    static func stateSummary(for accounts: [CodexAccount]) -> PooledQuotaStateSummary {
        var deniedCount = 0
        var exhaustedCount = 0
        var unknownCount = 0
        var usableCount = 0
        var missingCount = 0

        for account in accounts {
            guard let snapshot = account.realQuotaSnapshot else {
                missingCount += 1
                continue
            }
            switch quotaState(for: snapshot) {
            case .denied: deniedCount += 1
            case .exhausted: exhaustedCount += 1
            case .unknown: unknownCount += 1
            case .usable: usableCount += 1
            }
        }

        return PooledQuotaStateSummary(
            deniedCount: deniedCount,
            exhaustedCount: exhaustedCount,
            unknownCount: unknownCount,
            usableCount: usableCount,
            missingCount: missingCount
        )
    }

    private var rateLimitResetSummary: PooledRateLimitResetPresentation {
        PooledRateLimitResetPresentation.summarize(
            accounts.compactMap { rateLimitResetPresentations[$0.id] }
        )
    }

    private static let bankedResetExpiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    /// Pooled 5h remaining across ALL accounts. Shows real 5h capacity even when
    /// weekly is exhausted — the weekly bar separately shows that constraint.
    private var pooled5h: PooledMetric {
        Self.metric(for: .fiveHour, accounts: accounts)
    }

    /// Pooled weekly remaining
    private var pooledWeekly: PooledMetric {
        Self.metric(for: .weekly, accounts: accounts)
    }

    static func metric(for kind: QuotaWindowKind, accounts: [CodexAccount]) -> PooledMetric {
        guard kind == .fiveHour || kind == .weekly else {
            return .empty(totalAccounts: accounts.count)
        }

        let reports = reportedWindows(for: kind, accounts: accounts)
        guard !reports.isEmpty else { return .empty(totalAccounts: accounts.count) }

        let totalRemaining = reports.reduce(0.0) { partial, report in
            return partial + report.window.effectiveRemainingPercent * multiplier(for: kind, account: report.account)
        }
        let totalCapacity = reports.reduce(0.0) { partial, report in
            partial + multiplier(for: kind, account: report.account) * 100.0
        }
        let pooledPercent = totalCapacity > 0 ? totalRemaining / totalCapacity * 100.0 : 0
        let proCapacity = multiplier(for: kind, planType: "pro") * 100.0
        let proPercent = proCapacity > 0 ? min(100, totalRemaining / proCapacity * 100.0) : 0

        return PooledMetric(
            pooledPercent: pooledPercent,
            totalRemaining: totalRemaining,
            totalCapacity: totalCapacity,
            proEquivalentPercent: proPercent,
            reportingCount: reports.count,
            totalCount: accounts.count,
            nextReset: reports.map(\.window.resetsAt).min()
        )
    }

    private static func reportedWindows(
        for kind: QuotaWindowKind,
        accounts: [CodexAccount]
    ) -> [ReportedQuotaWindow] {
        accounts.compactMap { account in
            guard let snapshot = account.realQuotaSnapshot,
                  !snapshot.isDenied,
                  let window = snapshot.windows.first(where: { $0.kind == kind }) else {
                return nil
            }
            return ReportedQuotaWindow(account: account, snapshot: snapshot, window: window)
        }
    }

    private static func multiplier(for kind: QuotaWindowKind, account: CodexAccount) -> Double {
        let capacity = CodexPlanCapacity.forAccount(account)
        return kind == .fiveHour ? capacity.fiveHourPlusMultiplier : capacity.weeklyPlusMultiplier
    }

    private static func multiplier(for kind: QuotaWindowKind, planType: String) -> Double {
        let capacity = CodexPlanCapacity.forPlanType(planType)
        return kind == .fiveHour ? capacity.fiveHourPlusMultiplier : capacity.weeklyPlusMultiplier
    }

    static func naturalWeeklyResetDate(accounts: [CodexAccount]) -> Date? {
        let recoveryDates = accounts.compactMap { account -> Date? in
            guard let snapshot = account.realQuotaSnapshot,
                  let weekly = snapshot.weekly,
                  snapshot.isDenied || weekly.shouldAutoSwapAway else {
                return nil
            }
            return weekly.resetsAt
        }
        guard !recoveryDates.isEmpty else { return nil }
        return recoveryDates.min()
    }

    static func runwayPresentation(
        accounts: [CodexAccount],
        now: Date = Date()
    ) -> PooledRunwayPresentation {
        let summary = stateSummary(for: accounts)
        if summary.usableCount == 0,
           let weeklyReset = naturalWeeklyResetDate(accounts: accounts),
           weeklyReset > now {
            return .weeklyRecovery(weeklyReset)
        }

        if summary.exhaustedCount > 0, summary.usableCount == 0 {
            return .unavailable
        }

        let estimates = [
            estimatedRunway(for: .fiveHour, accounts: accounts, now: now),
            estimatedRunway(for: .weekly, accounts: accounts, now: now),
        ].compactMap { $0 }
        guard let estimate = estimates.min() else { return .unavailable }
        return .estimate(estimate)
    }

    static func estimatedRunway(
        for kind: QuotaWindowKind,
        accounts: [CodexAccount],
        now: Date = Date()
    ) -> TimeInterval? {
        let reports = Self.reportedWindows(for: kind, accounts: accounts).filter {
            $0.snapshot.isImmediatelyUsable
        }
        guard !reports.isEmpty else { return nil }

        let burnPerSecond = reports.reduce(0.0) { partial, report in
            let multiplier = Self.multiplier(for: kind, account: report.account)
            let elapsed = max(
                60,
                Double(report.window.durationSeconds) - max(0, report.window.resetsAt.timeIntervalSince(now))
            )
            return partial + report.window.usedPercent * multiplier / elapsed
        }
        guard burnPerSecond > 0 else { return nil }

        let totalRemaining = reports.reduce(0.0) { partial, report in
            partial + report.window.effectiveRemainingPercent
                * Self.multiplier(for: kind, account: report.account)
        }
        return totalRemaining / burnPerSecond
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        if seconds > 86400 { return ">24h" }
        let hours = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        if hours > 0 { return "~\(hours)h \(mins)m" }
        return "~\(mins)m"
    }

    /// Compact status rows keep denial, natural exhaustion, and unknown data distinct.
    private var poolStatuses: [(icon: String, text: String, color: Color)] {
        let total = accounts.count
        let summary = quotaStateSummary
        var statuses: [(icon: String, text: String, color: Color)] = []

        if summary.deniedCount > 0 {
            let color: Color = summary.usableCount > 0 ? .orange : .red
            statuses.append((
                "hand.raised.fill",
                "\(summary.deniedCount) of \(total) account\(total == 1 ? "" : "s") denied by provider",
                color
            ))
        }

        if summary.exhaustedCount > 0 {
            if summary.usableCount <= 1 {
                statuses.append(("exclamationmark.triangle.fill",
                                 "\(summary.exhaustedCount) of \(total) accounts exhausted", .red))
            } else {
                statuses.append(("exclamationmark.triangle",
                                 "\(summary.exhaustedCount) of \(total) exhausted, \(summary.usableCount) still usable", .orange))
            }
        }

        if summary.unknownCount > 0 {
            statuses.append((
                "questionmark.circle",
                "\(summary.unknownCount) of \(total) quota state\(summary.unknownCount == 1 ? " is" : "s are") unknown",
                .secondary
            ))
        }

        if summary.missingCount > 0 {
            let pending = summary.missingCount
            statuses.append(("clock.fill", "\(pending) account\(pending == 1 ? "" : "s") still connecting - pool stats are partial", .orange))
        }

        if !statuses.isEmpty { return statuses }

        // All accounts reporting weekly capacity have very low weekly quota.
        let weeklyReports = Self.reportedWindows(for: .weekly, accounts: accounts)
        let lowWeeklyCount = weeklyReports.filter { $0.window.effectiveRemainingPercent < 30 }.count
        if !weeklyReports.isEmpty, lowWeeklyCount == weeklyReports.count {
            return [("exclamationmark.triangle",
                     "All \(weeklyReports.count) weekly reporters below 30%", .orange)]
        }

        // Everything healthy
        return [("checkmark.seal.fill",
                 "All \(total) accounts healthy", .green)]
    }

    private static func barColor(for percent: Double) -> Color {
        switch percent {
        case 50...: return .green
        case 20..<50: return .yellow
        case 5..<20: return .orange
        default: return .red
        }
    }

    var body: some View {
        if !accountsWithData.isEmpty {
            meterContent
        }
    }

    private var meterContent: some View {
        let fh = pooled5h
        let wk = pooledWeekly
        let now = Date()
        let runway = Self.runwayPresentation(accounts: accounts, now: now)
        let reporting = accountsWithData.count

        return VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.blue)
                if reporting < accounts.count {
                    Text("Pooled Usage (\(reporting)/\(accounts.count) reporting)")
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    Text("Pooled Usage - All \(accounts.count) Accounts")
                        .font(.system(size: 10, weight: .semibold))
                }
                Spacer()
                switch runway {
                case .weeklyRecovery(let resetAt):
                    HStack(spacing: 2) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                        Text(formatTime(resetAt.timeIntervalSince(now)))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                    .help("Time until earliest weekly reset restores capacity")
                case .estimate(let estimate):
                    HStack(spacing: 2) {
                        Image(systemName: "timer")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text(formatTime(estimate))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .help("Estimated time until combined pool runs out at current usage rate")
                case .unavailable:
                    EmptyView()
                }
            }

            // Context line
            switch runway {
            case .weeklyRecovery:
                Text("Reported weekly capacity is exhausted")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .padding(.leading, 16)
            case .estimate:
                Text("Est. pool runway at current pace")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 16)
            case .unavailable:
                EmptyView()
            }

            if fh.reportingCount > 0 {
                pooledBar(label: "5h pool", percent: fh.pooledPercent, proPercent: fh.proEquivalentPercent)
                    .help("\(fh.reportingCount) of \(fh.totalCount) accounts report a 5h window")
            }

            if wk.reportingCount > 0 {
                pooledBar(label: "Weekly", percent: wk.pooledPercent, proPercent: wk.proEquivalentPercent)
                    .help("\(wk.reportingCount) of \(wk.totalCount) accounts report a weekly window")
            }

            // Pool health statuses
            ForEach(Array(poolStatuses.enumerated()), id: \.offset) { _, status in
                HStack(spacing: 4) {
                    Image(systemName: status.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(status.color)
                    Text(status.text)
                        .font(.system(size: 9))
                        .foregroundStyle(status.color == .green ? .secondary : status.color)
                }
            }

            if rateLimitResetSummary.currentAvailableCount > 0
                || rateLimitResetSummary.hasIncompleteInventory {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.teal)
                    Text(rateLimitResetStatusText)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help("Reset inventory across the account pool")
            }

            costComparison(fiveHour: fh, weekly: wk)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.04))
    }

    private var rateLimitResetStatusText: String {
        Self.rateLimitResetStatusText(
            for: rateLimitResetSummary,
            nextExpirationText: rateLimitResetSummary.nextCurrentExpiration.map {
                Self.bankedResetExpiryFormatter.string(from: $0)
            }
        )
    }

    static func rateLimitResetStatusText(
        for summary: PooledRateLimitResetPresentation,
        nextExpirationText: String? = nil
    ) -> String {
        let count = summary.currentAvailableCount
        let noun = count == 1 ? "reset" : "resets"
        var parts = [summary.hasIncompleteInventory
            ? "\(count) current \(noun)"
            : "\(count) banked \(noun)"]

        if count > 0, let nextExpirationText {
            parts.append("next expires \(nextExpirationText)")
        }
        if summary.pendingAccountCount > 0 {
            parts.append("\(summary.pendingAccountCount) pending")
        }
        if summary.staleAccountCount > 0 {
            parts.append("\(summary.staleAccountCount) stale")
        }
        return parts.joined(separator: " • ")
    }

    private func costComparison(fiveHour: PooledMetric, weekly: PooledMetric) -> some View {
        let summary = capacitySummary
        let plusParts = reportedCapacityParts(fiveHour: fiveHour, weekly: weekly, relativeToPro: false)
        let proParts = reportedCapacityParts(fiveHour: fiveHour, weekly: weekly, relativeToPro: true)

        return VStack(alignment: .leading, spacing: 2) {
            // Line 1: Your plan
            HStack(spacing: 4) {
                Image(systemName: "dollarsign.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                Text("Your pool: \(summary.breakdownText) = $\(summary.totalMonthlyCostUSD)/mo")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if !plusParts.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Text("Vs single Plus: \(plusParts.joined(separator: " / "))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 13)
            }
            if !proParts.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Text("Vs Pro 20x: \(proParts.joined(separator: " / "))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 13)
            }
            if fiveHour.reportingCount > 0, let promoText = summary.promoText {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 8))
                        .foregroundStyle(.blue)
                    Text(promoText)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 13)
            }
            tokenSavingsComparison
        }
    }

    private func reportedCapacityParts(
        fiveHour: PooledMetric,
        weekly: PooledMetric,
        relativeToPro: Bool
    ) -> [String] {
        var parts: [String] = []
        if fiveHour.reportingCount > 0 {
            if relativeToPro {
                let proCapacity = CodexPlanCapacity.forPlanType("pro").fiveHourPlusMultiplier * 100
                let percent = proCapacity > 0 ? fiveHour.totalCapacity / proCapacity * 100 : 0
                parts.append("\(String(format: "%.0f", percent))% 5h")
            } else {
                parts.append("\(formatMultiplier(fiveHour.totalCapacity / 100))x 5h")
            }
        }
        if weekly.reportingCount > 0 {
            if relativeToPro {
                let proCapacity = CodexPlanCapacity.forPlanType("pro").weeklyPlusMultiplier * 100
                let percent = proCapacity > 0 ? weekly.totalCapacity / proCapacity * 100 : 0
                parts.append("\(String(format: "%.0f", percent))% weekly")
            } else {
                parts.append("\(formatMultiplier(weekly.totalCapacity / 100))x weekly")
            }
        }
        return parts
    }

    @ViewBuilder
    private var tokenSavingsComparison: some View {
        if let tokenSavingsSummary, tokenSavingsSummary.total.completionCount > 0 {
            let total = tokenSavingsSummary.total
            HStack(spacing: 4) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 8))
                    .foregroundStyle(.purple)
                Text("API value: \(formatCurrency(tokenSavingsSummary.apiValueUSD)) observed in logs (\(tokenSavingsSummary.coverageText), \(tokenSavingsWindowText(tokenSavingsSummary)))")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 13)

            HStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text("Tokens: \(formatCompactTokens(total.inputTokens)) in / \(formatCompactTokens(total.cachedInputTokens)) cached (\(tokenCacheHitText(total))) / \(formatCompactTokens(total.outputTokens)) out")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 13)

            HStack(spacing: 4) {
                Image(systemName: tokenSavingsSummary.savingsUSD >= 0 ? "checkmark.seal" : "info.circle")
                    .font(.system(size: 8))
                    .foregroundStyle(tokenSavingsSummary.savingsUSD >= 0 ? .green : .orange)
                Text(tokenSavingsText(tokenSavingsSummary))
                    .font(.system(size: 8))
                    .foregroundStyle(tokenSavingsSummary.savingsUSD >= 0 ? Color.secondary : Color.orange)
            }
            .padding(.leading, 13)

            if let reason = tokenSavingsSummary.remoteExcludedReason {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }
                .padding(.leading, 13)
            }
        }
    }

    private func formatMultiplier(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func formatCurrency(_ value: Double) -> String {
        if value >= 100 {
            return "$\(Int(value.rounded()))"
        }
        return String(format: "$%.2f", value)
    }

    private func formatCompactTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private func tokenCacheHitText(_ usage: CodexModelTokenUsage) -> String {
        guard usage.inputTokens > 0 else { return "0%" }
        return "\(Int((Double(usage.cachedInputTokens) / Double(usage.inputTokens) * 100).rounded()))%"
    }

    private func tokenSavingsText(_ summary: CodexTokenSavingsSummary) -> String {
        if summary.savingsUSD < 0 {
            return "Vs API: \(formatCurrency(summary.apiValueUSD)) observed so far vs $\(summary.subscriptionMonthlyCostUSD)/mo subscriptions"
        }
        if let multiple = summary.apiMultiple, multiple > 0 {
            return "Vs API: \(formatCurrency(summary.savingsUSD)) saved, \(String(format: "%.1f", multiple))x cheaper than GPT-5.5 API"
        }
        return "Vs API: \(formatCurrency(summary.savingsUSD)) net"
    }

    private func tokenSavingsWindowText(_ summary: CodexTokenSavingsSummary) -> String {
        let requestedDays = summary.localReport?.windowDays ?? summary.remoteReport?.windowDays ?? 30
        guard let firstEventAt = summary.firstEventAt else {
            return "≤\(requestedDays)d"
        }
        let observedDays = max(1, Int(ceil(Date().timeIntervalSince(firstEventAt) / 86_400)))
        return "\(min(observedDays, requestedDays))d observed"
    }

    @ViewBuilder
    private func pooledBar(label: String, percent: Double, proPercent: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.barColor(for: percent))
                        .frame(width: geo.size.width * CGFloat(max(0, min(100, percent))) / 100)

                    // Pro equivalent marker (orange line)
                    if proPercent < 100 {
                        Rectangle()
                            .fill(.orange.opacity(0.6))
                            .frame(width: 1.5)
                            .offset(x: geo.size.width * CGFloat(proPercent) / 100)
                    }
                }
            }
            .frame(height: 8)

            Text("\(Int(percent))%")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Self.barColor(for: percent))
                .frame(width: 28, alignment: .trailing)
        }
    }
}

private struct ReportedQuotaWindow {
    let account: CodexAccount
    let snapshot: QuotaSnapshot
    let window: QuotaWindow
}

enum PooledRunwayPresentation: Equatable {
    case weeklyRecovery(Date)
    case estimate(TimeInterval)
    case unavailable
}

enum PooledAccountQuotaState: Equatable {
    case usable
    case denied
    case exhausted
    case unknown
}

struct PooledQuotaStateSummary: Equatable {
    let deniedCount: Int
    let exhaustedCount: Int
    let unknownCount: Int
    let usableCount: Int
    let missingCount: Int
}

struct PooledMetric: Equatable {
    let pooledPercent: Double
    let totalRemaining: Double
    let totalCapacity: Double
    let proEquivalentPercent: Double
    let reportingCount: Int
    let totalCount: Int
    let nextReset: Date?

    static func empty(totalAccounts: Int) -> PooledMetric {
        PooledMetric(
            pooledPercent: 0,
            totalRemaining: 0,
            totalCapacity: 0,
            proEquivalentPercent: 0,
            reportingCount: 0,
            totalCount: totalAccounts,
            nextReset: nil
        )
    }
}
