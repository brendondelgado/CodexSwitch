import Testing
import Foundation
@testable import CodexSwitch

@Suite("QuotaPoller")
struct QuotaPollerTests {
    private func fixture(named name: String) throws -> Data {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: testsDirectory.appendingPathComponent("Fixtures/Quota/\(name).json"))
    }

    @Test("Main Codex limit wins and legacy two-window payload is enumerated")
    func parseLegacyTwoWindowResponse() throws {
        let result = try UsageResponseParser.parse(try fixture(named: "legacy-two"))
        let fiveHour = try #require(result.snapshot.fiveHour)
        let weekly = try #require(result.snapshot.weekly)

        #expect(result.planType == "plus")
        #expect(result.snapshot.allowed == true)
        #expect(result.snapshot.limitReached == false)
        #expect(result.snapshot.windows.count == 2)
        #expect(fiveHour.usedPercent == 28)
        #expect(fiveHour.durationSeconds == 18_000)
        #expect(fiveHour.source.rateLimit == .main)
        #expect(fiveHour.source.slot == .primary)
        #expect(weekly.usedPercent == 5)
        #expect(weekly.durationSeconds == 604_800)
        #expect(weekly.source.rateLimit == .main)
        #expect(weekly.source.slot == .secondary)
        #expect(fiveHour.resetsAt == Date(timeIntervalSince1970: 1_741_860_000))
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_742_200_000))
    }

    @Test("Weekly window in primary slot stays weekly and missing five-hour stays absent")
    func parseWeeklyPrimary() throws {
        let result = try UsageResponseParser.parse(try fixture(named: "weekly-primary"))
        let weekly = try #require(result.snapshot.weekly)

        #expect(result.snapshot.windows.count == 1)
        #expect(result.snapshot.fiveHour == nil)
        #expect(weekly.kind == .weekly)
        #expect(weekly.usedPercent == 37)
        #expect(weekly.source.slot == .primary)
    }

    @Test("Weekly window in secondary slot is classified by duration")
    func parseWeeklySecondary() throws {
        let result = try UsageResponseParser.parse(try fixture(named: "weekly-secondary"))
        let fiveHour = try #require(result.snapshot.fiveHour)
        let weekly = try #require(result.snapshot.weekly)

        #expect(result.snapshot.windows.count == 2)
        #expect(fiveHour.source.slot == .primary)
        #expect(weekly.usedPercent == 41)
        #expect(weekly.source.slot == .secondary)
    }

    @Test("Zero-duration primary is ignored while valid weekly telemetry survives")
    func parseDisabledPrimaryWithWeekly() throws {
        let result = try UsageResponseParser.parse(try fixture(named: "disabled-primary-weekly"))
        let weekly = try #require(result.snapshot.weekly)

        #expect(result.snapshot.windows.count == 1)
        #expect(result.snapshot.fiveHour == nil)
        #expect(weekly.usedPercent == 16)
        #expect(weekly.source.slot == .secondary)
    }

    @Test("Spark before Codex does not steal Codex quota selection")
    func parseSparkBeforeCodex() throws {
        try assertCodexAdditionalSelection(fixtureName: "spark-before-codex")
    }

    @Test("Spark after Codex does not change Codex quota selection")
    func parseSparkAfterCodex() throws {
        try assertCodexAdditionalSelection(fixtureName: "spark-after-codex")
    }

    @Test("Bengalfox in limit name does not steal Codex quota selection")
    func parseBengalfoxNameCodexFeature() throws {
        try assertCodexAdditionalSelection(fixtureName: "bengalfox-name-codex-feature")
    }

    @Test("Spark and Bengalfox in metered feature alone exclude the candidate")
    func parseExcludedFamilyInMeteredFeatureOnly() throws {
        for meteredFeature in ["codex_spark", "codex_bengalfox"] {
            try assertCodexAdditionalSelection(
                meteredFeatureOnlyFixture(excludedFeature: meteredFeature),
                expectedMeteredFeature: "codex_standard"
            )
        }
    }

    @Test("Spark in limit name alone excludes the candidate")
    func parseSparkInLimitNameOnly() throws {
        try assertCodexAdditionalSelection(sparkLimitNameOnlyFixture())
    }

    @Test("Denied weekly quota remains a snapshot-level decision")
    func parseDeniedWeekly() throws {
        let result = try UsageResponseParser.parse(try fixture(named: "denied-weekly"))
        let weekly = try #require(result.snapshot.weekly)

        #expect(result.snapshot.allowed == false)
        #expect(result.snapshot.limitReached == true)
        #expect(result.snapshot.isDenied)
        #expect(weekly.kind == .weekly)
        #expect(weekly.hardLimitReached == false)
    }

    @Test("Allowed response with no valid windows reports telemetry unavailable")
    func parseAllowedNoWindows() throws {
        let data = try fixture(named: "allowed-no-windows")

        #expect(throws: UsageResponseParser.ParserError.placeholderRateLimitWindow) {
            try UsageResponseParser.parse(data)
        }
    }

    @Test("Unknown positive duration is preserved without semantic fabrication")
    func parseUnknownDuration() throws {
        let result = try UsageResponseParser.parse(try fixture(named: "unknown-duration"))
        let window = try #require(result.snapshot.windows.first)

        #expect(result.snapshot.windows.count == 1)
        #expect(result.snapshot.fiveHour == nil)
        #expect(result.snapshot.weekly == nil)
        #expect(window.kind == .unknown)
        #expect(window.durationSeconds == 86_400)
        #expect(window.usedPercent == 33)
    }

    @Test("Unknown main telemetry cannot hide a recognized additional Codex window")
    func parseUnknownMainWithRecognizedAdditionalWindow() throws {
        let result = try UsageResponseParser.parse(
            try fixture(named: "unknown-main-recognized-additional")
        )

        #expect(result.snapshot.weekly?.usedPercent == 19)
        #expect(result.snapshot.fiveHour == nil)
        #expect(result.snapshot.windows.filter { $0.kind == .unknown }.map(\.usedPercent) == [33])
    }

    @Test("Allowed rounded 100 percent usage is preserved exactly")
    func parseAllowedRoundedOneHundredPercent() throws {
        let result = try UsageResponseParser.parse(try fixture(named: "allowed-rounded-100"))
        let weekly = try #require(result.snapshot.weekly)

        #expect(result.snapshot.allowed == true)
        #expect(result.snapshot.limitReached == false)
        #expect(weekly.usedPercent == 100)
        #expect(weekly.remainingPercent == 0)
    }

    private func assertCodexAdditionalSelection(fixtureName: String) throws {
        try assertCodexAdditionalSelection(try fixture(named: fixtureName))
    }

    private func assertCodexAdditionalSelection(
        _ data: Data,
        expectedMeteredFeature: String = "codex"
    ) throws {
        let result = try UsageResponseParser.parse(data)
        let weekly = try #require(result.snapshot.weekly)

        #expect(result.snapshot.windows.count == 1)
        #expect(weekly.usedPercent == 27)
        #expect(weekly.source.rateLimit == .additional)
        #expect(weekly.source.slot == .primary)
        #expect(weekly.source.limitName == "GPT-5.5")
        #expect(weekly.source.meteredFeature == expectedMeteredFeature)
    }

    private func meteredFeatureOnlyFixture(excludedFeature: String) -> Data {
        Data("""
        {
          "plan_type": "pro",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 0,
              "limit_window_seconds": 0,
              "reset_after_seconds": 0,
              "reset_at": 1780464593
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3",
              "metered_feature": "\(excludedFeature)",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 91,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 410000,
                  "reset_at": 1780876593
                }
              }
            },
            {
              "limit_name": "GPT-5.5",
              "metered_feature": "codex_standard",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 27,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 420000,
                  "reset_at": 1780976593
                }
              }
            }
          ]
        }
        """.utf8)
    }

    private func sparkLimitNameOnlyFixture() -> Data {
        Data("""
        {
          "plan_type": "pro",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 0,
              "limit_window_seconds": 0,
              "reset_after_seconds": 0,
              "reset_at": 1780464593
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "codex",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 91,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 410000,
                  "reset_at": 1780876593
                }
              }
            },
            {
              "limit_name": "GPT-5.5",
              "metered_feature": "codex",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 27,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 420000,
                  "reset_at": 1780976593
                }
              }
            }
          ]
        }
        """.utf8)
    }

    @Test("Adaptive poll interval selection")
    func adaptiveIntervals() {
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 75) == 600)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 35) == 300)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 15) == 120)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 7) == 60)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 3) == 1)
    }

    @Test("Active account tightens poll interval near exhaustion")
    func activeIntervalsTightenNearExhaustion() {
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 75, isActive: true) == 5)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 10, isActive: true) == 2)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 7, isActive: true) == 2)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 5, isActive: true) == 2)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 3, isActive: true) == 2)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 2, isActive: true) == 1)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 1.6, isActive: true) == 1)
    }

    @Test("Snapshot polling follows the most constrained present window")
    func snapshotPollingUsesMostConstrainedWindow() {
        let now = Date()
        let snapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: now,
            windows: [
                QuotaWindow(
                    kind: .fiveHour,
                    durationSeconds: 18_000,
                    usedPercent: 20,
                    resetsAt: now.addingTimeInterval(18_000),
                    source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                ),
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 604_800,
                    usedPercent: 96,
                    resetsAt: now.addingTimeInterval(604_800),
                    source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .secondary)
                ),
            ]
        )

        #expect(QuotaPoller.pollInterval(for: snapshot, isActive: true) == 2)
    }

    @Test("Polling ignores unknown diagnostics and rejects unknown-only snapshots")
    func pollingUsesRecognizedPolicyWindowsOnly() {
        let now = Date()
        let diagnostic = QuotaWindow(
            kind: .unknown,
            durationSeconds: 86_400,
            usedPercent: 99,
            resetsAt: now.addingTimeInterval(86_400),
            source: QuotaWindowSourceMetadata(rateLimit: .additional, slot: .secondary)
        )
        let weekly = QuotaWindow(
            kind: .weekly,
            durationSeconds: 604_800,
            usedPercent: 20,
            resetsAt: now.addingTimeInterval(604_800),
            source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
        )
        let mixed = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: now,
            windows: [diagnostic, weekly]
        )
        let unknownOnly = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: now,
            windows: [diagnostic]
        )
        let deniedUnknownOnly = QuotaSnapshot(
            allowed: false,
            limitReached: true,
            fetchedAt: now,
            windows: [diagnostic]
        )

        #expect(QuotaPoller.pollInterval(for: mixed, isActive: true) == 5)
        #expect(QuotaPoller.accepts(mixed))
        #expect(!QuotaPoller.accepts(unknownOnly))
        #expect(QuotaPoller.accepts(deniedUnknownOnly))
    }

    @Test("Weekly-only inactive account retains plan-aware polling")
    func inactiveWeeklyOnlyAccountPollsNormally() {
        let now = Date()
        let snapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: now,
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 604_800,
                    usedPercent: 20,
                    resetsAt: now.addingTimeInterval(604_800),
                    source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                ),
            ]
        )
        let account = CodexAccount(
            email: "weekly@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "weekly",
            quotaSnapshot: snapshot,
            planType: "plus"
        )

        #expect(QuotaPoller.inactivePollInterval(for: account, snapshot: snapshot) == 15)
    }

    @Test("Inactive non-Pro exhausted account polls quickly for plan upgrades")
    func inactiveNonProExhaustedAccountPollsQuicklyForPlanUpgrades() {
        let future = Date().addingTimeInterval(18_000)
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: future, hardLimitReached: false),
            weekly: QuotaWindow(usedPercent: 94, windowDurationMins: 10080, resetsAt: future, hardLimitReached: false),
            fetchedAt: Date()
        )
        let account = CodexAccount(
            email: "upgrade@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "account",
            quotaSnapshot: snapshot,
            planType: "prolite",
            hasActiveSubscription: true
        )

        #expect(QuotaPoller.inactivePollInterval(for: account, snapshot: snapshot) == 5)
    }

    @Test("Inactive non-Pro usable account polls for plan upgrades")
    func inactiveNonProUsableAccountPollsForPlanUpgrades() {
        let future = Date().addingTimeInterval(18_000)
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: future, hardLimitReached: false),
            weekly: QuotaWindow(usedPercent: 20, windowDurationMins: 10080, resetsAt: future, hardLimitReached: false),
            fetchedAt: Date()
        )
        let account = CodexAccount(
            email: "upgrade@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "account",
            quotaSnapshot: snapshot,
            planType: "plus",
            hasActiveSubscription: true
        )

        #expect(QuotaPoller.inactivePollInterval(for: account, snapshot: snapshot) == 15)
    }

    @Test("Inactive Pro account polls within a minute for manual usage resets")
    func inactiveProAccountPollsWithinAMinuteForManualUsageResets() {
        let future = Date().addingTimeInterval(18_000)
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: future, hardLimitReached: false),
            weekly: QuotaWindow(usedPercent: 20, windowDurationMins: 10080, resetsAt: future, hardLimitReached: false),
            fetchedAt: Date()
        )
        let account = CodexAccount(
            email: "pro@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "account",
            quotaSnapshot: snapshot,
            planType: "pro",
            hasActiveSubscription: true
        )

        #expect(QuotaPoller.inactivePollInterval(for: account, snapshot: snapshot) == 60)
    }

    @Test("Inactive exhausted weekly-only Pro account does not poll every five seconds")
    func inactiveExhaustedWeeklyOnlyProUsesManualResetCadence() {
        let now = Date()
        let snapshot = QuotaSnapshot(
            allowed: false,
            limitReached: true,
            fetchedAt: now,
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 604_800,
                    usedPercent: 100,
                    resetsAt: now.addingTimeInterval(18_000),
                    source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                ),
            ]
        )
        let account = CodexAccount(
            email: "exhausted-pro@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "exhausted-pro",
            quotaSnapshot: snapshot,
            planType: "pro",
            hasActiveSubscription: true
        )

        #expect(QuotaPoller.inactivePollInterval(for: account, snapshot: snapshot) == 60)
    }
}
