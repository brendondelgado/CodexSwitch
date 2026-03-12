import Testing
import Foundation
@testable import CodexSwitch

@Suite("QuotaPoller")
struct QuotaPollerTests {
    @Test("Parse usage API response")
    func parseUsageResponse() throws {
        // The ChatGPT backend API returns rate limit data.
        // The exact format may vary — this tests our parser against the expected structure.
        // Fields based on Codex CLI binary analysis:
        //   rate_limit.primary_window.limit_window_seconds
        //   rate_limit.primary_window.reset_after_seconds
        //   additional_rate_limits[0].primary_window (weekly)
        let json = """
        {
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 8040,
                    "remaining_seconds": 8040,
                    "used_percent": 28.0
                }
            },
            "additional_rate_limits": [
                {
                    "metered_feature": "weekly",
                    "primary_window": {
                        "limit_window_seconds": 604800,
                        "reset_after_seconds": 345600,
                        "remaining_seconds": 345600,
                        "used_percent": 5.0
                    }
                }
            ]
        }
        """
        let snapshot = try UsageResponseParser.parse(json.data(using: .utf8)!)
        #expect(snapshot.fiveHour.usedPercent == 28.0)
        #expect(snapshot.fiveHour.windowDurationMins == 300)
        #expect(snapshot.weekly.usedPercent == 5.0)
        #expect(snapshot.weekly.windowDurationMins == 10080)
    }

    @Test("Parse usage response — fallback when used_percent missing")
    func parseFallback() throws {
        // If used_percent isn't in the response, estimate from reset_after / window
        let json = """
        {
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 9000
                }
            },
            "additional_rate_limits": []
        }
        """
        let snapshot = try UsageResponseParser.parse(json.data(using: .utf8)!)
        // 9000/18000 = 50% remaining → 50% used
        #expect(snapshot.fiveHour.usedPercent == 50.0)
        // No weekly data → default to 0% used
        #expect(snapshot.weekly.usedPercent == 0)
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
