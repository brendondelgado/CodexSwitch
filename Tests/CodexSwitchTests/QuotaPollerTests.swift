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

    @Test("Parse rejects zero-length placeholder usage windows")
    func parseRejectsZeroLengthPlaceholderWindow() throws {
        let json = """
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
                    "metered_feature": "codex_bengalfox",
                    "rate_limit": {
                        "allowed": true,
                        "limit_reached": false,
                        "primary_window": {
                            "used_percent": 0,
                            "limit_window_seconds": 0,
                            "reset_after_seconds": 0,
                            "reset_at": 1780464593
                        }
                    }
                }
            ]
        }
        """

        #expect(throws: UsageResponseParser.ParserError.placeholderRateLimitWindow) {
            try UsageResponseParser.parse(json.data(using: .utf8)!)
        }
    }

    @Test("Parse falls back to valid additional rate limit")
    func parseFallsBackToValidAdditionalRateLimit() throws {
        let json = """
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
                    "limit_name": "GPT-5.5",
                    "metered_feature": "codex",
                    "rate_limit": {
                        "allowed": true,
                        "limit_reached": false,
                        "primary_window": {
                            "used_percent": 23,
                            "limit_window_seconds": 18000,
                            "reset_after_seconds": 12000,
                            "reset_at": 1780476593
                        }
                    }
                }
            ]
        }
        """

        let result = try UsageResponseParser.parse(json.data(using: .utf8)!)

        #expect(result.planType == "pro")
        #expect(result.snapshot.fiveHour.usedPercent == 23)
        #expect(result.snapshot.fiveHour.remainingPercent == 77)
    }

    @Test("Parse usage response marks primary window exhausted when backend says limit reached")
    func parseLimitReachedForcesAutoSwap() throws {
        let json = """
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": false,
                "limit_reached": true,
                "primary_window": {
                    "used_percent": 98.9,
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
        #expect(abs(result.snapshot.fiveHour.remainingPercent - 1.1) < 0.0001)
        #expect(result.snapshot.fiveHour.isExhausted)
        #expect(result.snapshot.fiveHour.shouldAutoSwapAway)
        #expect(!result.snapshot.weekly.isExhausted)
    }

    @Test("Parse usage response honors backend allowed despite rounded 100 percent")
    func parseAllowedOneHundredPercentDoesNotExhaust() throws {
        let json = """
        {
            "plan_type": "pro",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 0,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 15570,
                    "reset_at": 1779066308
                },
                "secondary_window": {
                    "used_percent": 100,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 92944,
                    "reset_at": 1779143682
                }
            }
        }
        """

        let result = try UsageResponseParser.parse(json.data(using: .utf8)!)
        #expect(result.planType == "pro")
        #expect(result.snapshot.weekly.usedPercent == 98)
        #expect(abs(result.snapshot.weekly.remainingPercent - 2) < 0.0001)
        #expect(!result.snapshot.weekly.isExhausted)
        #expect(!result.snapshot.weekly.shouldAutoSwapAway)
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

    @Test("Inactive Pro account keeps relaxed polling")
    func inactiveProAccountKeepsRelaxedPolling() {
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

        #expect(QuotaPoller.inactivePollInterval(for: account, snapshot: snapshot) == 600)
    }
}
