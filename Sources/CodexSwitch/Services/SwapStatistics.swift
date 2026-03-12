import Foundation

enum SwapStatistics {
    private static let logDir = NSString("~/.codexswitch/logs").expandingTildeInPath

    struct Stats {
        let swapsToday: Int
        let swapsThisWeek: Int
        let swapsThisMonth: Int
        let averageSwapsPerDay: Double
        let mostSwappedFromEmail: String?
        let mostSwappedToEmail: String?
        let totalAccounts: Int
    }

    /// Parse all log files and compute swap statistics.
    static func compute(accountCount: Int) -> Stats {
        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -7, to: now)!
        let monthStart = calendar.date(byAdding: .day, value: -30, to: now)!

        var swapsToday = 0
        var swapsThisWeek = 0
        var swapsThisMonth = 0
        var fromCounts: [String: Int] = [:]
        var toCounts: [String: Int] = [:]
        var earliestSwap: Date?
        var totalSwaps = 0

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logDir) else {
            return Stats(swapsToday: 0, swapsThisWeek: 0, swapsThisMonth: 0,
                         averageSwapsPerDay: 0, mostSwappedFromEmail: nil,
                         mostSwappedToEmail: nil, totalAccounts: accountCount)
        }

        for file in files where file.hasPrefix("codexswitch-") && file.hasSuffix(".log") {
            let path = "\(logDir)/\(file)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

            for line in content.components(separatedBy: "\n") where line.contains("SWAP_TRIGGERED") {
                // Parse timestamp: [2026-03-12T15:30:00.123Z]
                guard let closeBracket = line.firstIndex(of: "]"),
                      line.first == "[" else { continue }
                let timestampStr = String(line[line.index(after: line.startIndex)..<closeBracket])
                guard let timestamp = isoFormatter.date(from: timestampStr) else { continue }

                totalSwaps += 1

                if earliestSwap == nil || timestamp < earliestSwap! {
                    earliestSwap = timestamp
                }

                if timestamp >= todayStart { swapsToday += 1 }
                if timestamp >= weekStart { swapsThisWeek += 1 }
                if timestamp >= monthStart { swapsThisMonth += 1 }

                // Parse from= and to=
                if let fromRange = line.range(of: "from="),
                   let toRange = line.range(of: " to=") {
                    let fromEmail = String(line[fromRange.upperBound..<toRange.lowerBound])
                    fromCounts[fromEmail, default: 0] += 1
                }
                if let toRange = line.range(of: " to="),
                   let reasonRange = line.range(of: " reason=") {
                    let toEmail = String(line[toRange.upperBound..<reasonRange.lowerBound])
                    toCounts[toEmail, default: 0] += 1
                }
            }
        }

        let daysSinceFirst: Double
        if let earliest = earliestSwap {
            daysSinceFirst = max(1, now.timeIntervalSince(earliest) / 86400)
        } else {
            daysSinceFirst = 1
        }

        return Stats(
            swapsToday: swapsToday,
            swapsThisWeek: swapsThisWeek,
            swapsThisMonth: swapsThisMonth,
            averageSwapsPerDay: Double(totalSwaps) / daysSinceFirst,
            mostSwappedFromEmail: fromCounts.max(by: { $0.value < $1.value })?.key,
            mostSwappedToEmail: toCounts.max(by: { $0.value < $1.value })?.key,
            totalAccounts: accountCount
        )
    }

    /// Generate a recommendation based on swap patterns.
    static func recommendation(from stats: Stats) -> String? {
        // High swap frequency with few accounts → suggest adding more
        if stats.averageSwapsPerDay > 8 && stats.totalAccounts < 6 {
            return "High swap rate (\(String(format: "%.0f", stats.averageSwapsPerDay))/day avg). Adding another account could reduce interruptions."
        }

        // Very low swap frequency with many accounts → could save money
        if stats.averageSwapsPerDay < 1 && stats.totalAccounts > 3 && stats.swapsThisWeek < 3 {
            return "Low usage (\(stats.swapsThisWeek) swaps/week). You could save $\(20 * (stats.totalAccounts - 3))/mo by dropping \(stats.totalAccounts - 3) account\(stats.totalAccounts - 3 == 1 ? "" : "s")."
        }

        // One account getting exhausted way more than others
        if let mostFrom = stats.mostSwappedFromEmail, stats.swapsThisWeek > 5 {
            let prefix = mostFrom.components(separatedBy: "@").first ?? mostFrom
            return "\(prefix)@... exhausts most often. Consider using it less for heavy sessions."
        }

        return nil
    }
}
