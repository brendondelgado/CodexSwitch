import SwiftUI

struct SwapStatsView: View {
    let accountCount: Int

    @State private var stats: SwapStatistics.Stats?

    var body: some View {
        if let s = stats {
            statsContent(s)
        }
    }

    private func statsContent(_ s: SwapStatistics.Stats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 10))
                    .foregroundStyle(.purple)
                Text("Swap Activity")
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Text("\(String(format: "%.1f", s.averageSwapsPerDay))/day avg")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                statBadge(label: "Today", value: s.swapsToday)
                statBadge(label: "7 days", value: s.swapsThisWeek)
                statBadge(label: "30 days", value: s.swapsThisMonth)
            }

            if let rec = SwapStatistics.recommendation(from: s) {
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                    Text(rec)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.purple.opacity(0.04))
        .task {
            let count = accountCount
            let result = await Task.detached {
                SwapStatistics.compute(accountCount: count)
            }.value
            stats = result
        }
    }

    @ViewBuilder
    private func statBadge(label: String, value: Int) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(value > 0 ? .primary : .tertiary)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
