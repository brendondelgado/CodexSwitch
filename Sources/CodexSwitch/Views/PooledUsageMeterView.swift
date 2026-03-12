import SwiftUI

/// Shows aggregate usage across all accounts compared to a single Pro plan.
/// Uses TOTAL account count for cost/capacity calculations,
/// and reports how many are actually reporting data.
struct PooledUsageMeterView: View {
    let accounts: [CodexAccount]

    // Pro plan has ~6.7x the usage of Plus per window
    private static let proMultiplier = 6.7

    private var accountsWithData: [CodexAccount] {
        accounts.filter { $0.quotaSnapshot != nil }
    }

    private var usableAccounts: [CodexAccount] {
        accountsWithData.filter { account in
            guard let snap = account.quotaSnapshot else { return false }
            return !snap.fiveHour.isExhausted && !snap.weekly.isExhausted
        }
    }

    /// Count accounts where EITHER 5h or weekly is exhausted
    private var exhaustedCount: Int {
        accountsWithData.filter { account in
            guard let snap = account.quotaSnapshot else { return false }
            return snap.fiveHour.isExhausted || snap.weekly.isExhausted
        }.count
    }

    /// Pooled 5h remaining across all accounts with data
    private var pooled5h: PooledMetric {
        let withData = accountsWithData
        guard !withData.isEmpty else { return .empty(totalAccounts: accounts.count) }

        let totalRemaining = withData.reduce(0.0) { $0 + $1.quotaSnapshot!.fiveHour.remainingPercent }
        let totalCapacity = Double(accounts.count) * 100.0
        let pooledPercent = totalRemaining / totalCapacity * 100.0

        let proEquivalentRemaining = totalRemaining / Self.proMultiplier
        let proPercent = min(100, proEquivalentRemaining)

        let nextReset = withData.compactMap { $0.quotaSnapshot?.fiveHour.resetsAt }.min()

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

        let totalRemaining = withData.reduce(0.0) { $0 + $1.quotaSnapshot!.weekly.remainingPercent }
        let totalCapacity = Double(accounts.count) * 100.0
        let pooledPercent = totalRemaining / totalCapacity * 100.0

        let proEquivalentRemaining = totalRemaining / Self.proMultiplier
        let proPercent = min(100, proEquivalentRemaining)

        let nextReset = withData.compactMap { $0.quotaSnapshot?.weekly.resetsAt }.min()

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

    /// Estimated time until pooled 5h capacity runs out at current burn rate,
    /// factoring in accounts that will reset and add capacity back to the pool.
    private var estimatedTimeRemaining: String? {
        let withData = accountsWithData
        guard withData.count >= 2 else { return nil }

        // Calculate current aggregate burn rate (percent per second across all accounts)
        var totalBurnRatePerSec = 0.0
        for account in withData {
            let fh = account.quotaSnapshot!.fiveHour
            let elapsed = max(1, Double(fh.windowDurationMins * 60) - max(0, fh.timeUntilReset))
            let rate = fh.usedPercent / elapsed
            if rate > 0 { totalBurnRatePerSec += rate }
        }

        guard totalBurnRatePerSec > 0 else { return nil }

        // Current remaining percent across all accounts
        var poolRemaining = withData.reduce(0.0) { $0 + $1.quotaSnapshot!.fiveHour.remainingPercent }

        // Collect upcoming resets — each adds 100% back to the pool
        var resets: [(secondsFromNow: TimeInterval, accountEmail: String)] = []
        for account in withData {
            let fh = account.quotaSnapshot!.fiveHour
            let resetIn = fh.timeUntilReset
            if resetIn > 0 && resetIn < 86400 {
                resets.append((resetIn, account.email))
            }
        }
        resets.sort { $0.secondsFromNow < $1.secondsFromNow }

        // Simulate forward: burn down pool, add 100% at each reset
        var elapsedSec: TimeInterval = 0
        for reset in resets {
            let timeToReset = reset.secondsFromNow - elapsedSec
            let burnedByReset = totalBurnRatePerSec * timeToReset
            if burnedByReset >= poolRemaining {
                // Pool runs out before this reset
                let secondsToEmpty = poolRemaining / totalBurnRatePerSec
                let totalSeconds = elapsedSec + secondsToEmpty
                return formatTime(totalSeconds)
            }
            // Survive to this reset — subtract burn, add 100% back
            poolRemaining -= burnedByReset
            poolRemaining += 100.0
            elapsedSec = reset.secondsFromNow
        }

        // After all resets, how long does the remaining pool last?
        let remainingSeconds = poolRemaining / totalBurnRatePerSec
        let totalSeconds = elapsedSec + remainingSeconds

        return formatTime(totalSeconds)
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
        let lowWeeklyCount = accountsWithData.filter { ($0.quotaSnapshot?.weekly.remainingPercent ?? 100) < 30 }.count
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
                if let est = estimatedTimeRemaining {
                    HStack(spacing: 2) {
                        Image(systemName: "timer")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text(est)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .help("Estimated time until combined 5h pool runs out at current usage rate")
                }
            }

            // Time estimate explanation (inline, small)
            if estimatedTimeRemaining != nil {
                Text("Est. pool runway at current pace (includes upcoming resets)")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
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
        let total = accounts.count
        let monthlyCost = total * 20
        let capacityPct = Double(total) / Self.proMultiplier * 100
        let savings = 200 - monthlyCost

        return VStack(alignment: .leading, spacing: 2) {
            // Line 1: Your plan
            HStack(spacing: 4) {
                Image(systemName: "dollarsign.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                Text("Your pool: \(total) Plus accounts at $20/mo = $\(monthlyCost)/mo")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            // Line 2: Pro comparison
            HStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text("\(String(format: "%.0f", capacityPct))% the capacity of a single Pro plan ($200/mo)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 13)
            // Line 3: Savings (if any)
            if savings > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                    Text("Saving $\(savings)/mo vs Pro")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.green)
                }
                .padding(.leading, 13)
            }
        }
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
