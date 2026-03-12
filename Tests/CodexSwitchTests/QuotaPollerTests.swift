import Testing
import Foundation
@testable import CodexSwitch

@Suite("QuotaPoller")
struct QuotaPollerTests {
    @Test("Parse usage API response — real /wham/usage format")
    func parseUsageResponse() throws {
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
        let result = try UsageResponseParser.parse(json.data(using: .utf8)!)
        #expect(result.planType == "plus")
        #expect(result.snapshot.fiveHour.usedPercent == 28.0)
        #expect(result.snapshot.fiveHour.windowDurationMins == 300)
        #expect(result.snapshot.weekly.usedPercent == 5.0)
        #expect(result.snapshot.weekly.windowDurationMins == 10080)
        // reset_at should be converted from Unix timestamp
        #expect(result.snapshot.fiveHour.resetsAt == Date(timeIntervalSince1970: 1741860000))
        #expect(result.snapshot.weekly.resetsAt == Date(timeIntervalSince1970: 1742200000))
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

    @Test("Adaptive poll interval selection")
    func adaptiveIntervals() {
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 75) == 600)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 35) == 300)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 15) == 120)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 7) == 60)
        #expect(QuotaPoller.pollInterval(forRemainingPercent: 3) == 10)
    }
}
