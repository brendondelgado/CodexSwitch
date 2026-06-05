import Foundation
import Testing
@testable import CodexSwitch

@Suite("Codex token economics")
struct CodexTokenEconomicsTests {
    @Test("GPT-5.5 API value bills cached input separately and does not double count reasoning")
    func gpt55APIValueUsesCachedInputDiscount() {
        let usage = CodexModelTokenUsage(
            model: "gpt-5.5",
            inputTokens: 176_034,
            cachedInputTokens: 173_952,
            outputTokens: 123,
            reasoningTokens: 22,
            completionCount: 1
        )

        let value = CodexAPIPricing.estimateAPIValue(for: usage)

        #expect(abs(value - 0.101076) < 0.000001, "Expected uncached input, cached input, and output only")
    }

    @Test("GPT-5.5 API value applies long-context pricing above 272K input tokens")
    func gpt55APIValueUsesLongContextPricing() {
        let usage = CodexModelTokenUsage(
            model: "gpt-5.5",
            inputTokens: 300_000,
            cachedInputTokens: 200_000,
            outputTokens: 10_000,
            reasoningTokens: 2_000,
            completionCount: 1,
            longContextInputTokens: 300_000,
            longContextCachedInputTokens: 200_000,
            longContextOutputTokens: 10_000
        )

        let value = CodexAPIPricing.estimateAPIValue(for: usage)

        #expect(abs(value - 1.65) < 0.000001, "Expected long-context input/cache/output rates")
    }

    @Test("Savings summary pools remote usage only when token hashes overlap")
    func savingsSummaryPoolsRemoteWhenTokenHashesOverlap() {
        let local = CodexTokenUsageReport(
            source: .mac,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            accountTokenHashPrefixes: ["aaa111", "bbb222"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 1_000_000,
                    cachedInputTokens: 800_000,
                    outputTokens: 10_000,
                    reasoningTokens: 1_000,
                    completionCount: 3
                )
            ]
        )
        let remote = CodexTokenUsageReport(
            source: .linuxDevbox,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            accountTokenHashPrefixes: ["bbb222", "ccc333"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 2_000_000,
                    cachedInputTokens: 1_500_000,
                    outputTokens: 20_000,
                    reasoningTokens: 2_000,
                    completionCount: 5
                )
            ]
        )

        let summary = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: local,
            remoteReport: remote,
            localTokenHashPrefixes: ["aaa111", "bbb222"]
        )

        #expect(summary.includesRemoteUsage)
        #expect(summary.total.completionCount == 8)
        #expect(summary.total.inputTokens == 3_000_000)
        #expect(summary.coverageText == "Mac + VPS")
    }

    @Test("Savings summary excludes remote usage when token hashes do not overlap")
    func savingsSummaryExcludesRemoteWithoutTokenMatch() {
        let local = CodexTokenUsageReport(
            source: .mac,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 1_000_000,
                    cachedInputTokens: 800_000,
                    outputTokens: 10_000,
                    reasoningTokens: 1_000,
                    completionCount: 3
                )
            ]
        )
        let remote = CodexTokenUsageReport(
            source: .linuxDevbox,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            accountTokenHashPrefixes: ["zzz999"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 2_000_000,
                    cachedInputTokens: 1_500_000,
                    outputTokens: 20_000,
                    reasoningTokens: 2_000,
                    completionCount: 5
                )
            ]
        )

        let summary = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: local,
            remoteReport: remote,
            localTokenHashPrefixes: ["aaa111"]
        )

        #expect(!summary.includesRemoteUsage)
        #expect(summary.total.completionCount == 3)
        #expect(summary.total.inputTokens == 1_000_000)
        #expect(summary.coverageText == "Mac only")
    }

    @Test("Savings summary keeps previous value when a refresh drops VPS data")
    func savingsSummaryKeepsPreviousWhenRemoteDropsOut() {
        let local = CodexTokenUsageReport(
            source: .mac,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_900_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 1_000_000,
                    cachedInputTokens: 900_000,
                    outputTokens: 10_000,
                    reasoningTokens: 0,
                    completionCount: 4
                )
            ]
        )
        let remote = CodexTokenUsageReport(
            source: .linuxDevbox,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_900_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 5_000_000,
                    cachedInputTokens: 4_500_000,
                    outputTokens: 50_000,
                    reasoningTokens: 0,
                    completionCount: 20
                )
            ]
        )
        let previous = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: local,
            remoteReport: remote,
            localTokenHashPrefixes: ["aaa111"]
        )
        let candidate = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: local,
            remoteReport: nil,
            localTokenHashPrefixes: ["aaa111"]
        )

        #expect(CodexTokenSavingsSummary.shouldKeepPreviousSummary(previous: previous, candidate: candidate))
    }

    @Test("Savings summary replaces stale high water when all sources are present")
    func savingsSummaryReplacesStaleHighWaterWithFreshCompleteCandidate() {
        let previousLocal = CodexTokenUsageReport(
            source: .mac,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_900_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 10_000_000,
                    cachedInputTokens: 9_000_000,
                    outputTokens: 100_000,
                    reasoningTokens: 0,
                    completionCount: 20
                )
            ]
        )
        let previousRemote = CodexTokenUsageReport(
            source: .linuxDevbox,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_900_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 10_000_000,
                    cachedInputTokens: 9_000_000,
                    outputTokens: 100_000,
                    reasoningTokens: 0,
                    completionCount: 20
                )
            ]
        )
        let candidateLocal = CodexTokenUsageReport(
            source: .mac,
            generatedAt: Date(timeIntervalSince1970: 1_900_043_201),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_900_000_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 1_000_000,
                    cachedInputTokens: 900_000,
                    outputTokens: 10_000,
                    reasoningTokens: 0,
                    completionCount: 2
                )
            ]
        )
        let candidateRemote = CodexTokenUsageReport(
            source: .linuxDevbox,
            generatedAt: Date(timeIntervalSince1970: 1_900_043_201),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_900_000_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 1_000_000,
                    cachedInputTokens: 900_000,
                    outputTokens: 10_000,
                    reasoningTokens: 0,
                    completionCount: 2
                )
            ]
        )
        let previous = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: previousLocal,
            remoteReport: previousRemote,
            localTokenHashPrefixes: ["aaa111"]
        )
        let candidate = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: candidateLocal,
            remoteReport: candidateRemote,
            localTokenHashPrefixes: ["aaa111"]
        )

        #expect(!CodexTokenSavingsSummary.shouldKeepPreviousSummary(previous: previous, candidate: candidate))
    }

    @Test("Savings summary keeps stale high water when fresh candidate is missing VPS")
    func savingsSummaryKeepsStaleHighWaterWhenFreshCandidateLosesSource() {
        let previousLocal = CodexTokenUsageReport(
            source: .mac,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_900_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 1_000_000,
                    cachedInputTokens: 900_000,
                    outputTokens: 10_000,
                    reasoningTokens: 0,
                    completionCount: 2
                )
            ]
        )
        let previousRemote = CodexTokenUsageReport(
            source: .linuxDevbox,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_900_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 10_000_000,
                    cachedInputTokens: 9_000_000,
                    outputTokens: 100_000,
                    reasoningTokens: 0,
                    completionCount: 20
                )
            ]
        )
        let candidateLocal = CodexTokenUsageReport(
            source: .mac,
            generatedAt: Date(timeIntervalSince1970: 1_900_043_201),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_900_000_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 1_000_000,
                    cachedInputTokens: 900_000,
                    outputTokens: 10_000,
                    reasoningTokens: 0,
                    completionCount: 2
                )
            ]
        )
        let previous = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: previousLocal,
            remoteReport: previousRemote,
            localTokenHashPrefixes: ["aaa111"]
        )
        let candidate = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: candidateLocal,
            remoteReport: nil,
            localTokenHashPrefixes: ["aaa111"]
        )

        #expect(CodexTokenSavingsSummary.shouldKeepPreviousSummary(previous: previous, candidate: candidate))
    }

    @Test("Savings summary accepts higher value even when a source drops")
    func savingsSummaryAcceptsHigherValueWhenRemoteDropsOut() {
        let previousLocal = CodexTokenUsageReport(
            source: .mac,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_900_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 1_000_000,
                    cachedInputTokens: 900_000,
                    outputTokens: 10_000,
                    reasoningTokens: 0,
                    completionCount: 40
                )
            ]
        )
        let previousRemote = CodexTokenUsageReport(
            source: .linuxDevbox,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_900_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 1_000_000,
                    cachedInputTokens: 900_000,
                    outputTokens: 10_000,
                    reasoningTokens: 0,
                    completionCount: 40
                )
            ]
        )
        let candidateLocal = CodexTokenUsageReport(
            source: .mac,
            generatedAt: Date(timeIntervalSince1970: 1_900_001_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_900_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 100_000_000,
                    cachedInputTokens: 95_000_000,
                    outputTokens: 500_000,
                    reasoningTokens: 100_000,
                    completionCount: 2
                )
            ]
        )
        let previous = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: previousLocal,
            remoteReport: previousRemote,
            localTokenHashPrefixes: ["aaa111"]
        )
        let candidate = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: candidateLocal,
            remoteReport: nil,
            localTokenHashPrefixes: ["aaa111"]
        )

        #expect(!CodexTokenSavingsSummary.shouldKeepPreviousSummary(previous: previous, candidate: candidate))
    }

    @Test("Savings summary accepts higher value when aggregate first event moves forward")
    func savingsSummaryAcceptsHigherValueWhenAggregateFirstEventMovesForward() {
        let previousReport = CodexTokenUsageReport(
            source: .linuxDevbox,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_000_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 10_000_000,
                    cachedInputTokens: 9_000_000,
                    outputTokens: 100_000,
                    reasoningTokens: 20_000,
                    completionCount: 100
                )
            ]
        )
        let candidateReport = CodexTokenUsageReport(
            source: .linuxDevbox,
            generatedAt: Date(timeIntervalSince1970: 1_900_001_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_900_000_500),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 2_000_000_000,
                    cachedInputTokens: 1_950_000_000,
                    outputTokens: 4_000_000,
                    reasoningTokens: 900_000,
                    completionCount: 1
                )
            ]
        )
        let previous = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: nil,
            remoteReport: previousReport,
            localTokenHashPrefixes: ["aaa111"]
        )
        let candidate = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: nil,
            remoteReport: candidateReport,
            localTokenHashPrefixes: ["aaa111"]
        )

        #expect(!CodexTokenSavingsSummary.shouldKeepPreviousSummary(previous: previous, candidate: candidate))
    }

    @Test("Savings summary keeps previous value when candidate goes backwards inside active window")
    func savingsSummaryKeepsPreviousWhenCandidateValueDrops() {
        let firstEvent = Date(timeIntervalSince1970: 1_899_900_000)
        let previousReport = CodexTokenUsageReport(
            source: .mac,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            firstEventAt: firstEvent,
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 2_000_000,
                    cachedInputTokens: 1_000_000,
                    outputTokens: 20_000,
                    reasoningTokens: 0,
                    completionCount: 8
                )
            ]
        )
        let candidateReport = CodexTokenUsageReport(
            source: .mac,
            generatedAt: Date(timeIntervalSince1970: 1_900_001_000),
            windowDays: 30,
            firstEventAt: firstEvent,
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 1_900_000,
                    cachedInputTokens: 1_000_000,
                    outputTokens: 20_000,
                    reasoningTokens: 0,
                    completionCount: 8
                )
            ]
        )
        let previous = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: previousReport,
            remoteReport: nil,
            localTokenHashPrefixes: ["aaa111"]
        )
        let candidate = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: candidateReport,
            remoteReport: nil,
            localTokenHashPrefixes: ["aaa111"]
        )

        #expect(CodexTokenSavingsSummary.shouldKeepPreviousSummary(previous: previous, candidate: candidate))
    }

    @Test("Savings summary allows aggregate parser to replace lower response counts with higher usage")
    func savingsSummaryAcceptsHigherValueWithLowerCompletionCount() {
        let previousReport = CodexTokenUsageReport(
            source: .linuxDevbox,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_900_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 2_000_000,
                    cachedInputTokens: 1_500_000,
                    outputTokens: 20_000,
                    reasoningTokens: 0,
                    completionCount: 100
                )
            ]
        )
        let candidateReport = CodexTokenUsageReport(
            source: .linuxDevbox,
            generatedAt: Date(timeIntervalSince1970: 1_900_001_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_900_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 69_263_147,
                    cachedInputTokens: 67_845_120,
                    outputTokens: 154_624,
                    reasoningTokens: 100_000,
                    completionCount: 1
                )
            ]
        )
        let previous = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: nil,
            remoteReport: previousReport,
            localTokenHashPrefixes: ["aaa111"]
        )
        let candidate = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: nil,
            remoteReport: candidateReport,
            localTokenHashPrefixes: ["aaa111"]
        )

        #expect(!CodexTokenSavingsSummary.shouldKeepPreviousSummary(previous: previous, candidate: candidate))
    }

    @Test("Savings store persists high water across app restarts")
    func savingsStoreKeepsPersistedHighWaterAcrossRestarts() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-token-savings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let previousReport = CodexTokenUsageReport(
            source: .mac,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_900_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 2_000_000,
                    cachedInputTokens: 1_000_000,
                    outputTokens: 20_000,
                    reasoningTokens: 0,
                    completionCount: 8
                )
            ]
        )
        let candidateReport = CodexTokenUsageReport(
            source: .mac,
            generatedAt: Date(timeIntervalSince1970: 1_900_001_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_900_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 1_900_000,
                    cachedInputTokens: 1_000_000,
                    outputTokens: 20_000,
                    reasoningTokens: 0,
                    completionCount: 8
                )
            ]
        )
        let previous = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: previousReport,
            remoteReport: nil,
            localTokenHashPrefixes: ["aaa111"]
        )
        let candidate = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: candidateReport,
            remoteReport: nil,
            localTokenHashPrefixes: ["aaa111"]
        )

        let firstStore = CodexTokenSavingsStore(storeURL: storeURL)
        firstStore.save(previous, now: Date(timeIntervalSince1970: 1_900_000_100))

        let restartedStore = CodexTokenSavingsStore(storeURL: storeURL)
        let stabilized = restartedStore.stabilizedSummary(current: nil, candidate: candidate)

        #expect(stabilized.keptPrevious)
        #expect(abs(stabilized.summary.apiValueUSD - previous.apiValueUSD) < 0.000001)
    }

    @Test("Savings store ignores stale parser-version high water")
    func savingsStoreIgnoresStaleParserVersionHighWater() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-token-savings-version-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let report = CodexTokenUsageReport(
            source: .mac,
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30,
            firstEventAt: Date(timeIntervalSince1970: 1_899_900_000),
            accountTokenHashPrefixes: ["aaa111"],
            models: [
                CodexModelTokenUsage(
                    model: "gpt-5.5",
                    inputTokens: 2_000_000,
                    cachedInputTokens: 1_000_000,
                    outputTokens: 20_000,
                    reasoningTokens: 0,
                    completionCount: 8
                )
            ]
        )
        let summary = CodexTokenSavingsSummary(
            subscriptionMonthlyCostUSD: 220,
            localReport: report,
            remoteReport: nil,
            localTokenHashPrefixes: ["aaa111"]
        )

        let store = CodexTokenSavingsStore(storeURL: storeURL)
        store.save(summary, now: Date(timeIntervalSince1970: 1_900_000_100))
        let currentJSON = try String(contentsOf: storeURL, encoding: .utf8)
        try currentJSON
            .replacingOccurrences(of: #""version" : 3"#, with: #""version" : 1"#)
            .write(to: storeURL, atomically: true, encoding: .utf8)

        #expect(CodexTokenSavingsStore(storeURL: storeURL).load() == nil)
    }

    @Test("Telemetry parser deduplicates repeated completion events")
    func telemetryParserDeduplicatesCompletionEvents() {
        let line = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=176034 output_token_count=123 cached_token_count=173952 reasoning_token_count=22 event.timestamp=2026-05-03T05:49:17.343Z conversation.id=019dcf51 app.version=0.128.0 user.account_id="df3c" user.email="brendon@example.com" model=gpt-5.5 slug=gpt-5.5
        """

        let report = CodexTelemetryLogParser.report(
            source: .mac,
            lines: [line, line],
            accountTokenHashPrefixes: ["hash1"],
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30
        )

        #expect(report.models.count == 1)
        #expect(report.total.completionCount == 1)
        #expect(report.total.inputTokens == 176_034)
        #expect(report.total.cachedInputTokens == 173_952)
        #expect(report.total.outputTokens == 123)
        #expect(report.total.reasoningTokens == 22)
    }

    @Test("Telemetry parser reads raw response.completed JSON usage rows")
    func telemetryParserReadsJSONUsageRows() {
        let line = """
        codexswitch_ts=1777777177 codexswitch_target=log {"type":"response.completed","sequence_number":99,"tool_usage":{"input_tokens":0,"output_tokens":0},"response":{"id":"resp_abc","model":"gpt-5.5","usage":{"input_tokens":217558,"input_tokens_details":{"cached_tokens":216448},"output_tokens":236,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":217794}}}
        """

        let report = CodexTelemetryLogParser.report(
            source: .mac,
            lines: [line],
            accountTokenHashPrefixes: ["hash1"],
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30
        )

        #expect(report.total.completionCount == 1)
        #expect(report.total.inputTokens == 217_558)
        #expect(report.total.cachedInputTokens == 216_448)
        #expect(report.total.outputTokens == 236)
        #expect(report.firstEventAt == Date(timeIntervalSince1970: 1_777_777_177))
    }

    @Test("Telemetry parser ignores tracing span braces before raw websocket JSON")
    func telemetryParserFindsJSONAfterTracingSpanBraces() {
        let line = """
        codexswitch_ts=1777789553 codexswitch_target=codex_api::endpoint::responses_websocket session_loop{thread_id=abc}:turn{model=gpt-5.5}: websocket event: {"type":"response.completed","response":{"id":"resp_abc","model":"gpt-5.5","usage":{"input_tokens":103594,"input_tokens_details":{"cached_tokens":102272},"output_tokens":508,"output_tokens_details":{"reasoning_tokens":210},"total_tokens":104102}}}
        """

        let report = CodexTelemetryLogParser.report(
            source: .linuxDevbox,
            lines: [line],
            accountTokenHashPrefixes: ["hash1"],
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30
        )

        #expect(report.total.completionCount == 1)
        #expect(report.total.inputTokens == 103_594)
        #expect(report.total.cachedInputTokens == 102_272)
        #expect(report.total.outputTokens == 508)
        #expect(report.total.reasoningTokens == 210)
    }

    @Test("Telemetry parser tracks long-context token buckets per event")
    func telemetryParserTracksLongContextBuckets() {
        let line = """
        codexswitch_ts=1777789666 codexswitch_target=log {"type":"response.completed","response":{"id":"resp_long","model":"gpt-5.5","usage":{"input_tokens":300001,"input_tokens_details":{"cached_tokens":250000},"output_tokens":1000,"output_tokens_details":{"reasoning_tokens":250},"total_tokens":301001}}}
        """

        let report = CodexTelemetryLogParser.report(
            source: .mac,
            lines: [line],
            accountTokenHashPrefixes: ["hash1"],
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30
        )

        #expect(report.total.longContextInputTokens == 300_001)
        #expect(report.total.longContextCachedInputTokens == 250_000)
        #expect(report.total.longContextOutputTokens == 1_000)
    }

    @Test("Telemetry parser reads Codex turn aggregate token usage")
    func telemetryParserReadsTurnAggregateUsage() {
        let line = """
        codexswitch_ts=1777797459 codexswitch_target=codex_api::endpoint::responses_websocket session_loop{thread_id=019ddf25}:turn{turn.id=019dec33 model=gpt-5.5 codex.turn.token_usage.input_tokens=69263147 codex.turn.token_usage.cached_input_tokens=67845120 codex.turn.token_usage.non_cached_input_tokens=1418027 codex.turn.token_usage.output_tokens=154624 codex.turn.token_usage.reasoning_output_tokens=100000 codex.turn.token_usage.total_tokens=69417771}: websocket event: {"type":"response.output_item.done"}
        """

        let report = CodexTelemetryLogParser.report(
            source: .linuxDevbox,
            lines: [line],
            accountTokenHashPrefixes: ["hash1"],
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30
        )

        #expect(report.total.completionCount == 1)
        #expect(report.total.inputTokens == 69_263_147)
        #expect(report.total.cachedInputTokens == 67_845_120)
        #expect(report.total.outputTokens == 154_624)
        #expect(report.total.reasoningTokens == 100_000)
        #expect(report.total.longContextInputTokens == 0, "Aggregate turn totals are not treated as one long-context request")
    }

    @Test("Telemetry parser prefers turn aggregate over response rows for the same turn")
    func telemetryParserDoesNotDoubleCountAggregatedTurnResponses() {
        let aggregateLine = """
        codexswitch_ts=1777797459 codexswitch_target=codex_otel.log_only session_loop{thread_id=019ddf25}:turn{turn.id=019dec33 model=gpt-5.5 codex.turn.token_usage.input_tokens=1000000 codex.turn.token_usage.cached_input_tokens=900000 codex.turn.token_usage.non_cached_input_tokens=100000 codex.turn.token_usage.output_tokens=10000 codex.turn.token_usage.reasoning_output_tokens=5000 codex.turn.token_usage.total_tokens=1010000}
        """
        let responseLine = """
        codexswitch_ts=1777797458 codexswitch_target=codex_api::endpoint::responses_websocket session_loop{thread_id=019ddf25}:turn{turn.id=019dec33 model=gpt-5.5}: websocket event: {"type":"response.completed","response":{"id":"resp_same_turn","model":"gpt-5.5","usage":{"input_tokens":200000,"input_tokens_details":{"cached_tokens":180000},"output_tokens":2000,"output_tokens_details":{"reasoning_tokens":1000},"total_tokens":202000}}}
        """

        let report = CodexTelemetryLogParser.report(
            source: .linuxDevbox,
            lines: [aggregateLine, responseLine],
            accountTokenHashPrefixes: ["hash1"],
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30
        )

        #expect(report.total.completionCount == 1)
        #expect(report.total.inputTokens == 1_000_000)
        #expect(report.total.cachedInputTokens == 900_000)
        #expect(report.total.outputTokens == 10_000)
    }

    @Test("Telemetry parser reads Codex session token_count totals")
    func telemetryParserReadsSessionTokenCountTotals() {
        let line = """
        codexswitch_session=019ddf25-8e5d-7d93-9006-54488876f0fa {"timestamp":"2026-05-03T08:45:29.656Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2064770545,"cached_input_tokens":2021302272,"output_tokens":4031283,"reasoning_output_tokens":929360,"total_tokens":2068801828},"last_token_usage":{"input_tokens":158051,"cached_input_tokens":157568,"output_tokens":80,"reasoning_output_tokens":7,"total_tokens":158131},"model_context_window":258400},"rate_limits":{"limit_id":"codex"}}}
        """

        let report = CodexTelemetryLogParser.report(
            source: .linuxDevbox,
            lines: [line],
            accountTokenHashPrefixes: ["hash1"],
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30
        )

        #expect(report.total.completionCount == 1)
        #expect(report.total.inputTokens == 2_064_770_545)
        #expect(report.total.cachedInputTokens == 2_021_302_272)
        #expect(report.total.outputTokens == 4_031_283)
        #expect(report.total.reasoningTokens == 929_360)
    }

    @Test("Session token_count reader preserves full session UUIDs")
    func sessionTokenCountReaderPreservesFullSessionUUIDs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexswitch-session-reader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let first = root.appendingPathComponent("rollout-2026-05-03T08-00-00-11111111-1111-1111-1111-aaaaaaaaaaaa.jsonl")
        let second = root.appendingPathComponent("rollout-2026-05-03T08-00-01-22222222-2222-2222-2222-aaaaaaaaaaaa.jsonl")
        try """
        {"timestamp":"2026-05-03T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":1050}},"model":"gpt-5.5"}}
        """.write(to: first, atomically: true, encoding: .utf8)
        try """
        {"timestamp":"2026-05-03T08:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":1600,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":2100}},"model":"gpt-5.5"}}
        """.write(to: second, atomically: true, encoding: .utf8)

        let lines = CodexTokenUsageReader.sessionTokenCountLines(root: root.path, cutoff: 0)
        let report = CodexTelemetryLogParser.report(
            source: .mac,
            lines: lines,
            accountTokenHashPrefixes: ["hash1"],
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30
        )

        #expect(lines.contains { $0.contains("codexswitch_session=11111111-1111-1111-1111-aaaaaaaaaaaa") })
        #expect(lines.contains { $0.contains("codexswitch_session=22222222-2222-2222-2222-aaaaaaaaaaaa") })
        #expect(report.total.completionCount == 2)
        #expect(report.total.inputTokens == 3_000)
        #expect(report.total.cachedInputTokens == 2_400)
        #expect(report.total.outputTokens == 150)
    }

    @Test("Session token_count reader ignores model strings inside message content")
    func sessionTokenCountReaderIgnoresMessageContentModels() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexswitch-session-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let session = root.appendingPathComponent("rollout-2026-05-13T08-00-00-33333333-3333-3333-3333-aaaaaaaaaaaa.jsonl")
        try """
        {"timestamp":"2026-05-13T08:00:00.000Z","type":"turn_context","payload":{"turn_id":"turn-1","model":"gpt-5.5","cwd":"/tmp"}}
        {"timestamp":"2026-05-13T08:00:01.000Z","type":"response_item","payload":{"type":"function_call_output","output":"not telemetry: {\\"model\\":\\"claude-opus-4-6\\",\\"input_tokens\\":999999,\\"output_tokens\\":999999}"}}
        {"timestamp":"2026-05-13T08:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":1600,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":2100}}}}
        """.write(to: session, atomically: true, encoding: .utf8)

        let lines = CodexTokenUsageReader.sessionTokenCountLines(root: root.path, cutoff: 0)
        let report = CodexTelemetryLogParser.report(
            source: .mac,
            lines: lines,
            accountTokenHashPrefixes: ["hash1"],
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30
        )

        #expect(lines.count == 1)
        #expect(lines[0].contains("codexswitch_model=gpt-5.5"))
        #expect(!lines[0].contains("claude-opus-4-6"))
        #expect(report.models.map(\.model) == ["gpt-5.5"])
        #expect(report.total.inputTokens == 2_000)
    }

    @Test("Telemetry parser prefers session total over turn aggregate for the same session")
    func telemetryParserDoesNotDoubleCountSessionTotalsAndTurnAggregates() {
        let sessionLine = """
        codexswitch_session=019ddf25 {"timestamp":"2026-05-03T08:45:29.656Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000000,"cached_input_tokens":1800000,"output_tokens":20000,"reasoning_output_tokens":5000,"total_tokens":2020000},"last_token_usage":{"input_tokens":1,"cached_input_tokens":1,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2},"model_context_window":258400}}}
        """
        let turnLine = """
        codexswitch_session=019ddf25 codexswitch_ts=1777797459 codexswitch_target=codex_api::endpoint::responses_websocket session_loop{thread_id=019ddf25}:turn{turn.id=019dec33 model=gpt-5.5 codex.turn.token_usage.input_tokens=1000000 codex.turn.token_usage.cached_input_tokens=900000 codex.turn.token_usage.non_cached_input_tokens=100000 codex.turn.token_usage.output_tokens=10000 codex.turn.token_usage.reasoning_output_tokens=5000 codex.turn.token_usage.total_tokens=1010000}
        """

        let report = CodexTelemetryLogParser.report(
            source: .linuxDevbox,
            lines: [sessionLine, turnLine],
            accountTokenHashPrefixes: ["hash1"],
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30
        )

        #expect(report.total.completionCount == 1)
        #expect(report.total.inputTokens == 2_000_000)
        #expect(report.total.cachedInputTokens == 1_800_000)
        #expect(report.total.outputTokens == 20_000)
    }

    @Test("Telemetry parser preserves long-context pricing when session totals supersede response rows")
    func telemetryParserKeepsLongContextPricingWithSessionTotals() {
        let sessionLine = """
        codexswitch_session=019ddf25 codexswitch_model=gpt-5.5 {"timestamp":"2026-05-03T08:45:29.656Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":400000,"cached_input_tokens":300000,"output_tokens":1000,"reasoning_output_tokens":100,"total_tokens":401000},"last_token_usage":{"input_tokens":1,"cached_input_tokens":1,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2},"model_context_window":258400}}}
        """
        let responseLine = """
        codexswitch_session=019ddf25 codexswitch_ts=1777777177 codexswitch_target=log {"type":"response.completed","response":{"id":"resp_long","model":"gpt-5.5","usage":{"input_tokens":300001,"input_tokens_details":{"cached_tokens":250000},"output_tokens":1000,"output_tokens_details":{"reasoning_tokens":50},"total_tokens":301001}}}
        """

        let report = CodexTelemetryLogParser.report(
            source: .linuxDevbox,
            lines: [sessionLine, responseLine],
            accountTokenHashPrefixes: ["hash1"],
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30
        )

        #expect(report.total.completionCount == 1)
        #expect(report.total.inputTokens == 400_000)
        #expect(report.total.cachedInputTokens == 300_000)
        #expect(report.total.longContextInputTokens == 300_001)
        #expect(report.total.longContextCachedInputTokens == 250_000)
        #expect(report.total.longContextOutputTokens == 1_000)
        #expect(report.apiValueUSD > 1.07)
    }

    @Test("Telemetry parser deduplicates otel and raw rows for the same response")
    func telemetryParserDeduplicatesOtelAndRawRows() {
        let rawLine = """
        codexswitch_ts=1777777177 codexswitch_target=log {"type":"response.completed","response":{"id":"resp_abc","model":"gpt-5.5","usage":{"input_tokens":217558,"input_tokens_details":{"cached_tokens":216448},"output_tokens":236,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":217794}}}
        """
        let otelLine = """
        codexswitch_ts=1777777177 codexswitch_target=codex_otel.log_only event.name="codex.sse_event" event.kind=response.completed input_token_count=217558 output_token_count=236 cached_token_count=216448 reasoning_token_count=0 event.timestamp=2026-05-03T02:59:37.669Z conversation.id=019dcf51 model=gpt-5.5 slug=gpt-5.5
        """

        let report = CodexTelemetryLogParser.report(
            source: .mac,
            lines: [rawLine, otelLine],
            accountTokenHashPrefixes: ["hash1"],
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            windowDays: 30
        )

        #expect(report.total.completionCount == 1)
        #expect(report.total.inputTokens == 217_558)
    }

    @Test("Account token fingerprints include refresh tokens so independent access refreshes still match")
    func tokenFingerprintsIncludeRefreshTokens() {
        let account = CodexAccount(
            email: "brendon@example.com",
            accessToken: "access-token-that-can-rotate",
            refreshToken: "stable-refresh-token",
            idToken: "",
            accountId: "acct"
        )

        let hashes = CodexTelemetryLogParser.tokenHashPrefixes(for: [account])

        #expect(hashes.contains(CodexTelemetryLogParser.tokenHashPrefix("access-token-that-can-rotate")))
        #expect(hashes.contains(CodexTelemetryLogParser.tokenHashPrefix("stable-refresh-token")))
    }
}
