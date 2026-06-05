import SwiftUI

/// Shows aggregate usage across all accounts compared to a single Pro plan.
/// Uses plan-weighted Plus-equivalent capacity for cost/capacity calculations,
/// and reports how many are actually reporting data.
struct PooledUsageMeterView: View {
    let accounts: [CodexAccount]
    let tokenSavingsSummary: CodexTokenSavingsSummary?

    private var capacitySummary: PooledCapacitySummary {
        PooledCapacitySummary(accounts: accounts)
    }

    private var accountsWithData: [CodexAccount] {
        accounts.filter { $0.realQuotaSnapshot != nil }
    }

    private var usableAccounts: [CodexAccount] {
        accountsWithData.filter { account in
            guard let snap = account.realQuotaSnapshot else { return false }
            return !snap.fiveHour.isExhausted && !snap.weekly.isExhausted
        }
    }

    /// Count accounts where EITHER 5h or weekly is exhausted
    private var exhaustedCount: Int {
        accountsWithData.filter { account in
            guard let snap = account.realQuotaSnapshot else { return false }
            return snap.fiveHour.isExhausted || snap.weekly.isExhausted
        }.count
    }

    /// Pooled 5h remaining across ALL accounts. Shows real 5h capacity even when
    /// weekly is exhausted — the weekly bar separately shows that constraint.
    private var pooled5h: PooledMetric {
        let withData = accountsWithData
        guard !withData.isEmpty else { return .empty(totalAccounts: accounts.count) }

        let totalRemaining = withData.reduce(0.0) { partial, account in
            let multiplier = CodexPlanCapacity.forAccount(account).fiveHourPlusMultiplier
            return partial + account.realQuotaSnapshot!.fiveHour.remainingPercent * multiplier
        }
        let totalCapacity = capacitySummary.fiveHourPlusCapacity * 100.0
        guard totalCapacity > 0 else { return .empty(totalAccounts: accounts.count) }
        let pooledPercent = totalRemaining / totalCapacity * 100.0

        let pro20Capacity = CodexPlanCapacity.forPlanType("pro").fiveHourPlusMultiplier * 100.0
        let proEquivalentRemaining = totalCapacity > 0 ? totalRemaining / pro20Capacity * 100.0 : 0
        let proPercent = min(100, proEquivalentRemaining)

        let nextReset = withData.compactMap { $0.realQuotaSnapshot?.fiveHour.resetsAt }.min()

        return PooledMetric(
            pooledPercent: pooledPercent,
            totalRemaining: totalRemaining,
            totalCapacity: totalCapacity,
            proEquivalentPercent: proPercent,
            reportingCount: withData.count,
            totalCount: accounts.count,
            nextReset: nextReset
        )
    }

    /// Pooled weekly remaining
    private var pooledWeekly: PooledMetric {
        let withData = accountsWithData
        guard !withData.isEmpty else { return .empty(totalAccounts: accounts.count) }

        let totalRemaining = withData.reduce(0.0) { partial, account in
            let multiplier = CodexPlanCapacity.forAccount(account).weeklyPlusMultiplier
            return partial + account.realQuotaSnapshot!.weekly.remainingPercent * multiplier
        }
        let totalCapacity = capacitySummary.weeklyPlusCapacity * 100.0
        guard totalCapacity > 0 else { return .empty(totalAccounts: accounts.count) }
        let pooledPercent = totalRemaining / totalCapacity * 100.0

        let pro20Capacity = CodexPlanCapacity.forPlanType("pro").weeklyPlusMultiplier * 100.0
        let proEquivalentRemaining = totalCapacity > 0 ? totalRemaining / pro20Capacity * 100.0 : 0
        let proPercent = min(100, proEquivalentRemaining)

        let nextReset = withData.compactMap { $0.realQuotaSnapshot?.weekly.resetsAt }.min()

        return PooledMetric(
            pooledPercent: pooledPercent,
            totalRemaining: totalRemaining,
            totalCapacity: totalCapacity,
            proEquivalentPercent: proPercent,
            reportingCount: withData.count,
            totalCount: accounts.count,
            nextReset: nextReset
        )
    }

    /// Time until nearest weekly reset (when capacity returns)
    private var nextWeeklyResetTime: String? {
        let nextReset = accountsWithData.compactMap { $0.realQuotaSnapshot?.weekly.resetsAt }.min()
        guard let reset = nextReset else { return nil }
        let seconds = reset.timeIntervalSinceNow
        guard seconds > 0 else { return nil }
        return formatTime(seconds)
    }

    /// Whether ALL accounts have weekly exhausted (pool is fully locked)
    private var allWeeklyExhausted: Bool {
        let withData = accountsWithData
        guard !withData.isEmpty else { return false }
        return withData.allSatisfy { $0.realQuotaSnapshot!.weekly.isExhausted }
    }

    /// Estimated time until usable pooled capacity runs out.
    /// Uses min(5h estimate, weekly estimate) — weekly is the hard ceiling since
    /// once weekly hits 0% on all accounts, 5h capacity is worthless.
    /// When all weekly is exhausted, returns nil (caller shows reset countdown instead).
    private var estimatedTimeRemaining: String? {
        let usable = accountsWithData.filter { !$0.realQuotaSnapshot!.weekly.isExhausted }
        guard !usable.isEmpty else { return nil }

        // --- Weekly ceiling ---
        let active = usable.first { $0.isActive } ?? usable.first!
        let activeWk = active.realQuotaSnapshot!.weekly
        let activeWeeklyMultiplier = CodexPlanCapacity.forAccount(active).weeklyPlusMultiplier
        let wkElapsed = max(60, Double(activeWk.windowDurationMins * 60) - max(0, activeWk.timeUntilReset))
        let wkBurnPerSec = activeWk.usedPercent * activeWeeklyMultiplier / wkElapsed

        let totalWeeklyRemaining = usable.reduce(0.0) { partial, account in
            let multiplier = CodexPlanCapacity.forAccount(account).weeklyPlusMultiplier
            return partial + account.realQuotaSnapshot!.weekly.remainingPercent * multiplier
        }
        let weeklyCeiling: TimeInterval = wkBurnPerSec > 0
            ? totalWeeklyRemaining / wkBurnPerSec
            : .greatestFiniteMagnitude

        // --- 5h estimate with reset simulation ---
        var fhBurnPerSec = 0.0
        for account in usable {
            let fh = account.realQuotaSnapshot!.fiveHour
            let multiplier = CodexPlanCapacity.forAccount(account).fiveHourPlusMultiplier
            let elapsed = max(60, Double(fh.windowDurationMins * 60) - max(0, fh.timeUntilReset))
            let rate = fh.usedPercent * multiplier / elapsed
            if rate > 0 { fhBurnPerSec += rate }
        }

        guard fhBurnPerSec > 0 || wkBurnPerSec > 0 else { return nil }

        var fhEstimate: TimeInterval = .greatestFiniteMagnitude
        if fhBurnPerSec > 0 {
            var poolRemaining = usable.reduce(0.0) { partial, account in
                let multiplier = CodexPlanCapacity.forAccount(account).fiveHourPlusMultiplier
                return partial + account.realQuotaSnapshot!.fiveHour.remainingPercent * multiplier
            }

            var resets: [(secondsFromNow: TimeInterval, restoredCapacity: Double)] = []
            for account in usable {
                let fh = account.realQuotaSnapshot!.fiveHour
                let resetIn = fh.timeUntilReset
                if resetIn > 0 && resetIn < 86400 {
                    let multiplier = CodexPlanCapacity.forAccount(account).fiveHourPlusMultiplier
                    resets.append((resetIn, multiplier * 100.0))
                }
            }
            resets.sort { $0.secondsFromNow < $1.secondsFromNow }

            var elapsedSec: TimeInterval = 0
            var foundEmpty = false
            for reset in resets {
                let timeToReset = reset.secondsFromNow - elapsedSec
                let burned = fhBurnPerSec * timeToReset
                if burned >= poolRemaining {
                    fhEstimate = elapsedSec + poolRemaining / fhBurnPerSec
                    foundEmpty = true
                    break
                }
                poolRemaining -= burned
                poolRemaining += reset.restoredCapacity
                elapsedSec = reset.secondsFromNow
            }
            if !foundEmpty {
                fhEstimate = elapsedSec + poolRemaining / fhBurnPerSec
            }
        }

        let estimate = min(fhEstimate, weeklyCeiling)
        guard estimate < .greatestFiniteMagnitude else { return nil }

        return formatTime(estimate)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        if seconds > 86400 { return ">24h" }
        let hours = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        if hours > 0 { return "~\(hours)h \(mins)m" }
        return "~\(mins)m"
    }

    /// Smart status line based on current pool state
    private var poolStatus: (icon: String, text: String, color: Color)? {
        let total = accounts.count
        let reporting = accountsWithData.count
        let usable = usableAccounts.count
        let exhausted = exhaustedCount

        // Not all accounts reporting yet
        if reporting < total {
            let pending = total - reporting
            return ("clock.fill", "\(pending) account\(pending == 1 ? "" : "s") still connecting — pool stats are partial", .orange)
        }

        // Accounts exhausted
        if exhausted > 0 {
            if usable <= 1 {
                return ("exclamationmark.triangle.fill",
                        "\(exhausted) of \(total) accounts exhausted — add more or wait for resets", .red)
            }
            return ("exclamationmark.triangle",
                    "\(exhausted) of \(total) accounts exhausted, \(usable) still usable", .orange)
        }

        // All accounts have very low weekly (< 30%)
        let lowWeeklyCount = accountsWithData.filter { ($0.realQuotaSnapshot?.weekly.remainingPercent ?? 100) < 30 }.count
        if lowWeeklyCount == total && total > 0 {
            return ("exclamationmark.triangle",
                    "All \(total) accounts below 30% weekly — consider adding an account", .orange)
        }

        // Everything healthy
        return ("checkmark.seal.fill",
                "All \(total) accounts healthy", .green)
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
        let estTime = estimatedTimeRemaining
        let weeklyLocked = allWeeklyExhausted
        let resetTime = nextWeeklyResetTime

        return VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.blue)
                if fh.reportingCount < fh.totalCount {
                    Text("Pooled Usage (\(fh.reportingCount)/\(fh.totalCount) reporting)")
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    Text("Pooled Usage — All \(fh.totalCount) Accounts")
                        .font(.system(size: 10, weight: .semibold))
                }
                Spacer()
                if let est = estTime {
                    HStack(spacing: 2) {
                        Image(systemName: "timer")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text(est)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .help("Estimated time until combined pool runs out at current usage rate")
                } else if weeklyLocked, let reset = resetTime {
                    HStack(spacing: 2) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                        Text(reset)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                    .help("Time until earliest weekly reset restores capacity")
                }
            }

            // Context line
            if estTime != nil {
                Text("Est. pool runway at current pace (includes upcoming resets)")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 16)
            } else if weeklyLocked {
                Text("Weekly exhausted on all accounts — 5h capacity locked until weekly resets")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .padding(.leading, 16)
            }

            // 5h pooled bar
            pooledBar(label: "5h pool", percent: fh.pooledPercent, proPercent: fh.proEquivalentPercent)

            // Weekly pooled bar
            pooledBar(label: "Weekly", percent: wk.pooledPercent, proPercent: wk.proEquivalentPercent)

            // Pool health status
            if let status = poolStatus {
                HStack(spacing: 4) {
                    Image(systemName: status.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(status.color)
                    Text(status.text)
                        .font(.system(size: 9))
                        .foregroundStyle(status.color == .green ? .secondary : status.color)
                }
            }

            // Cost comparison — broken into readable lines
            costComparison
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.04))
    }

    private var costComparison: some View {
        let summary = capacitySummary
        let pro20FiveHourPercent = summary.fiveHourPlusCapacity
            / CodexPlanCapacity.forPlanType("pro").fiveHourPlusMultiplier * 100
        let pro20WeeklyPercent = summary.weeklyPlusCapacity
            / CodexPlanCapacity.forPlanType("pro").weeklyPlusMultiplier * 100

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
            // Line 2: Plus comparison
            HStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text("Vs single Plus: \(formatMultiplier(summary.fiveHourPlusCapacity))x 5h / \(formatMultiplier(summary.weeklyPlusCapacity))x weekly")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 13)
            // Line 3: Pro comparison
            HStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text("Vs Pro 20x: \(String(format: "%.0f", pro20FiveHourPercent))% 5h / \(String(format: "%.0f", pro20WeeklyPercent))% weekly")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 13)
            if let promoText = summary.promoText {
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

private struct PooledMetric {
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
