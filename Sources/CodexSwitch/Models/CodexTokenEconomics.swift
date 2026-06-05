import Foundation

enum CodexTokenUsageSource: String, Codable, Equatable, Sendable {
    case mac
    case linuxDevbox

    var label: String {
        switch self {
        case .mac: return "Mac"
        case .linuxDevbox: return "VPS"
        }
    }
}

struct CodexModelTokenUsage: Codable, Equatable, Sendable {
    let model: String
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int
    var completionCount: Int
    var longContextInputTokens: Int = 0
    var longContextCachedInputTokens: Int = 0
    var longContextOutputTokens: Int = 0

    static func empty(model: String = "unknown") -> CodexModelTokenUsage {
        CodexModelTokenUsage(
            model: model,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            completionCount: 0,
            longContextInputTokens: 0,
            longContextCachedInputTokens: 0,
            longContextOutputTokens: 0
        )
    }

    mutating func add(_ other: CodexModelTokenUsage) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        outputTokens += other.outputTokens
        reasoningTokens += other.reasoningTokens
        completionCount += other.completionCount
        longContextInputTokens += other.longContextInputTokens
        longContextCachedInputTokens += other.longContextCachedInputTokens
        longContextOutputTokens += other.longContextOutputTokens
    }
}

struct CodexTokenUsageReport: Codable, Equatable, Sendable {
    let source: CodexTokenUsageSource
    let generatedAt: Date
    let windowDays: Int
    var firstEventAt: Date? = nil
    let accountTokenHashPrefixes: [String]
    let models: [CodexModelTokenUsage]

    var total: CodexModelTokenUsage {
        models.reduce(.empty(model: "all")) { partial, usage in
            var next = partial
            next.add(usage)
            return next
        }
    }

    var apiValueUSD: Double {
        models.reduce(0) { $0 + CodexAPIPricing.estimateAPIValue(for: $1) }
    }
}

struct CodexAPIPricing: Equatable, Sendable {
    let inputPerMillionUSD: Double
    let cachedInputPerMillionUSD: Double
    let outputPerMillionUSD: Double
    let longContextInputPerMillionUSD: Double
    let longContextCachedInputPerMillionUSD: Double
    let longContextOutputPerMillionUSD: Double

    init(
        inputPerMillionUSD: Double,
        cachedInputPerMillionUSD: Double,
        outputPerMillionUSD: Double,
        longContextInputPerMillionUSD: Double? = nil,
        longContextCachedInputPerMillionUSD: Double? = nil,
        longContextOutputPerMillionUSD: Double? = nil
    ) {
        self.inputPerMillionUSD = inputPerMillionUSD
        self.cachedInputPerMillionUSD = cachedInputPerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
        self.longContextInputPerMillionUSD = longContextInputPerMillionUSD ?? inputPerMillionUSD
        self.longContextCachedInputPerMillionUSD = longContextCachedInputPerMillionUSD ?? cachedInputPerMillionUSD
        self.longContextOutputPerMillionUSD = longContextOutputPerMillionUSD ?? outputPerMillionUSD
    }

    static func pricing(for model: String) -> CodexAPIPricing {
        switch model.lowercased() {
        case "gpt-5.5":
            return CodexAPIPricing(
                inputPerMillionUSD: 5.00,
                cachedInputPerMillionUSD: 0.50,
                outputPerMillionUSD: 30.00,
                longContextInputPerMillionUSD: 10.00,
                longContextCachedInputPerMillionUSD: 1.00,
                longContextOutputPerMillionUSD: 45.00
            )
        case "gpt-5.4":
            return CodexAPIPricing(
                inputPerMillionUSD: 2.50,
                cachedInputPerMillionUSD: 0.25,
                outputPerMillionUSD: 15.00,
                longContextInputPerMillionUSD: 5.00,
                longContextCachedInputPerMillionUSD: 0.50,
                longContextOutputPerMillionUSD: 22.50
            )
        case "gpt-5.4-mini", "gpt-5.4 mini":
            return CodexAPIPricing(inputPerMillionUSD: 0.75, cachedInputPerMillionUSD: 0.075, outputPerMillionUSD: 4.50)
        case "gpt-5.3-codex", "gpt-5.2":
            return CodexAPIPricing(inputPerMillionUSD: 1.75, cachedInputPerMillionUSD: 0.175, outputPerMillionUSD: 14.00)
        default:
            return CodexAPIPricing(inputPerMillionUSD: 5.00, cachedInputPerMillionUSD: 0.50, outputPerMillionUSD: 30.00)
        }
    }

    static func estimateAPIValue(for usage: CodexModelTokenUsage) -> Double {
        let pricing = pricing(for: usage.model)
        let longContextCached = min(usage.longContextCachedInputTokens, usage.longContextInputTokens)
        let longContextUncached = max(0, usage.longContextInputTokens - longContextCached)
        let longContextOutput = min(usage.longContextOutputTokens, usage.outputTokens)
        let shortInput = max(0, usage.inputTokens - usage.longContextInputTokens)
        let shortCached = min(max(0, usage.cachedInputTokens - longContextCached), shortInput)
        let shortUncached = max(0, shortInput - shortCached)
        let shortOutput = max(0, usage.outputTokens - longContextOutput)
        return (Double(shortUncached) * pricing.inputPerMillionUSD
            + Double(shortCached) * pricing.cachedInputPerMillionUSD
            + Double(shortOutput) * pricing.outputPerMillionUSD
            + Double(longContextUncached) * pricing.longContextInputPerMillionUSD
            + Double(longContextCached) * pricing.longContextCachedInputPerMillionUSD
            + Double(longContextOutput) * pricing.longContextOutputPerMillionUSD) / 1_000_000
    }
}

struct CodexTokenSavingsSummary: Codable, Equatable, Sendable {
    let subscriptionMonthlyCostUSD: Int
    let localReport: CodexTokenUsageReport?
    let remoteReport: CodexTokenUsageReport?
    let localTokenHashPrefixes: Set<String>

    init(
        subscriptionMonthlyCostUSD: Int,
        localReport: CodexTokenUsageReport?,
        remoteReport: CodexTokenUsageReport?,
        localTokenHashPrefixes: [String]
    ) {
        self.subscriptionMonthlyCostUSD = subscriptionMonthlyCostUSD
        self.localReport = localReport
        self.remoteReport = remoteReport
        self.localTokenHashPrefixes = Set(localTokenHashPrefixes)
    }

    var includesRemoteUsage: Bool {
        guard let remoteReport else { return false }
        return !Set(remoteReport.accountTokenHashPrefixes).isDisjoint(with: localTokenHashPrefixes)
    }

    var includedReports: [CodexTokenUsageReport] {
        var reports: [CodexTokenUsageReport] = []
        if let localReport { reports.append(localReport) }
        if includesRemoteUsage, let remoteReport { reports.append(remoteReport) }
        return reports
    }

    var includedSources: Set<CodexTokenUsageSource> {
        Set(includedReports.map(\.source))
    }

    var latestGeneratedAt: Date? {
        includedReports.map(\.generatedAt).max()
    }

    var total: CodexModelTokenUsage {
        includedReports.reduce(.empty(model: "all")) { partial, report in
            var next = partial
            next.add(report.total)
            return next
        }
    }

    var apiValueUSD: Double {
        includedReports.reduce(0) { $0 + $1.apiValueUSD }
    }

    var firstEventAt: Date? {
        includedReports.compactMap(\.firstEventAt).min()
    }

    var savingsUSD: Double {
        apiValueUSD - Double(subscriptionMonthlyCostUSD)
    }

    var apiMultiple: Double? {
        guard subscriptionMonthlyCostUSD > 0 else { return nil }
        return apiValueUSD / Double(subscriptionMonthlyCostUSD)
    }

    var coverageText: String {
        if includesRemoteUsage { return "Mac + VPS" }
        return localReport == nil ? "No token data yet" : "Mac only"
    }

    var remoteExcludedReason: String? {
        guard remoteReport != nil, !includesRemoteUsage else { return nil }
        return "VPS credential fingerprints do not match this Mac pool"
    }

    static func shouldKeepPreviousSummary(
        previous: CodexTokenSavingsSummary,
        candidate: CodexTokenSavingsSummary,
        now: Date = Date()
    ) -> Bool {
        let previousSources = Set(previous.includedReports.map(\.source))
        let candidateSources = Set(candidate.includedReports.map(\.source))
        if let previousGeneratedAt = previous.latestGeneratedAt,
           let candidateGeneratedAt = candidate.latestGeneratedAt,
           !candidateSources.isEmpty,
           candidateSources.isSuperset(of: previousSources),
           candidateGeneratedAt.timeIntervalSince(previousGeneratedAt) >= 12 * 60 * 60 {
            return false
        }

        if !candidateSources.isSuperset(of: previousSources),
           candidate.apiValueUSD + 0.01 < previous.apiValueUSD {
            return true
        }

        if candidate.total.completionCount < previous.total.completionCount,
           candidate.apiValueUSD + 0.01 < previous.apiValueUSD {
            return true
        }

        if let previousFirst = previous.firstEventAt,
           let candidateFirst = candidate.firstEventAt,
           candidateFirst.timeIntervalSince(previousFirst) > 120 {
            if candidate.apiValueUSD + 0.01 >= previous.apiValueUSD {
                return false
            }
            let requestedDays = candidate.localReport?.windowDays ?? candidate.remoteReport?.windowDays ?? previous.localReport?.windowDays ?? previous.remoteReport?.windowDays ?? 30
            let previousAge = now.timeIntervalSince(previousFirst)
            if previousAge >= Double(requestedDays) * 86_400 {
                return false
            }
            return true
        }

        return candidate.apiValueUSD + 0.01 < previous.apiValueUSD
    }
}
