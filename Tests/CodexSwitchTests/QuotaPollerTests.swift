import Testing
import Foundation
@testable import CodexSwitch

@Suite("QuotaPoller")
struct QuotaPollerTests {
    @Test("Parse usage API response — real /wham/usage format")
    func parseUsageResponse() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Matches the actual Codex backend API format:
        // primary_window = 5-hour window, secondary_window = weekly
        // reset_at is a Unix timestamp
        let json = """
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 28,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 8040,
                    "reset_at": 1741860000
                },
                "secondary_window": {
                    "used_percent": 5,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 345600,
                    "reset_at": 1742200000
                }
            }
        }
        """
        let result = try UsageResponseParser.parse(
            json.data(using: .utf8)!,
            now: now
        )
        #expect(result.planType == "plus")
        #expect(result.snapshot.fiveHour.usedPercent == 28.0)
        #expect(result.snapshot.fiveHour.windowDurationMins == 300)
        #expect(result.snapshot.weekly.usedPercent == 5.0)
        #expect(result.snapshot.weekly.windowDurationMins == 10080)
        // Prefer the relative countdown because stale reset_at values can lag behind reality.
        #expect(result.snapshot.fiveHour.resetsAt == now.addingTimeInterval(8040))
        #expect(result.snapshot.weekly.resetsAt == now.addingTimeInterval(345_600))
    }

    @Test("Parse usage response — no secondary window defaults to 0%")
    func parseNoSecondary() throws {
        let json = """
        {
            "plan_type": "pro",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 42,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 0,
                    "reset_at": 1741860000
                }
            }
        }
        """
        let result = try UsageResponseParser.parse(json.data(using: .utf8)!)
        #expect(result.planType == "pro")
        #expect(result.snapshot.fiveHour.usedPercent == 42.0)
        // No secondary window → default 0% used
        #expect(result.snapshot.weekly.usedPercent == 0)
        #expect(result.snapshot.weekly.windowDurationMins == 10080)
    }

    @Test("Parse usage response with additional rate limits")
    func parseAdditionalLimits() throws {
        let json = """
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 10,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 16000,
                    "reset_at": 1741860000
                },
                "secondary_window": {
                    "used_percent": 3,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 500000,
                    "reset_at": 1742200000
                }
            },
            "additional_rate_limits": [
                {
                    "limit_name": "codex_other",
                    "metered_feature": "codex_other",
                    "rate_limit": {
                        "allowed": true,
                        "limit_reached": false,
                        "primary_window": {
                            "used_percent": 70,
                            "limit_window_seconds": 900,
                            "reset_after_seconds": 0,
                            "reset_at": 1741860000
                        }
                    }
                }
            ]
        }
        """
        let result = try UsageResponseParser.parse(json.data(using: .utf8)!)
        // Primary/secondary windows should still parse correctly
        #expect(result.snapshot.fiveHour.usedPercent == 10.0)
        #expect(result.snapshot.weekly.usedPercent == 3.0)
    }

    @Test("Parser prefers reset_after_seconds when reset_at is stale")
    func parsePrefersRelativeResetTimer() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 10,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 90,
                    "reset_at": 1700000000
                }
            }
        }
        """

        let result = try UsageResponseParser.parse(
            json.data(using: .utf8)!,
            now: now
        )

        #expect(result.snapshot.fiveHour.resetsAt == now.addingTimeInterval(90))
    }

    @Test("Fresh windows synthesize a forward reset when the API returns a stale reset_at")
    func parseFreshWindowWithStaleResetAt() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        {
            "plan_type": "pro",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 0,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 0,
                    "reset_at": 1700000000
                },
                "secondary_window": {
                    "used_percent": 0,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 0,
                    "reset_at": 1700000000
                }
            }
        }
        """

        let result = try UsageResponseParser.parse(
            json.data(using: .utf8)!,
            now: now
        )

        #expect(result.snapshot.fiveHour.resetsAt == now.addingTimeInterval(18_000))
        #expect(result.snapshot.weekly.resetsAt == now.addingTimeInterval(604_800))
    }

    @Test("Adaptive poll interval selection")
    func adaptiveIntervals() {
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 75) == 600)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 35) == 300)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 15) == 120)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 7) == 60)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 3) == 1)
    }

    @Test("All accounts refresh immediately on startup")
    func accountsRefreshImmediatelyOnStartup() {
        #expect(QuotaPoller.initialPollDelay(hasCachedSnapshot: true, randomDelay: 9) == 0)
        #expect(QuotaPoller.initialPollDelay(hasCachedSnapshot: false, randomDelay: 9) == 0)
    }

    @Test("Fresh zero-usage inactive windows keep polling every minute")
    func freshInactiveWindowsRefreshEveryMinute() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: 0,
                windowDurationMins: 300,
                resetsAt: now.addingTimeInterval(18_000)
            ),
            weekly: QuotaWindow(
                usedPercent: 0,
                windowDurationMins: 10_080,
                resetsAt: now.addingTimeInterval(604_800)
            ),
            fetchedAt: now
        )

        #expect(QuotaPoller.inactivePollInterval(for: snapshot, now: now) == 60)
    }
}
