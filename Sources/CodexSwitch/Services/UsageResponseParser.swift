import Foundation

enum UsageResponseParser {
    /// Top-level response from GET /wham/usage
    struct UsageResponse: Decodable {
        let planType: String
        let rateLimit: RateLimitDetails?
        let additionalRateLimits: [AdditionalRateLimit]?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
        }
    }

    struct RateLimitDetails: Decodable {
        let allowed: Bool?
        let limitReached: Bool?
        let primaryWindow: WindowSnapshot?
        let secondaryWindow: WindowSnapshot?

        enum CodingKeys: String, CodingKey {
            case allowed
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct AdditionalRateLimit: Decodable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: RateLimitDetails?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }
    }

    struct WindowSnapshot: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Int
        let resetAfterSeconds: Int?
        let resetAt: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }

    struct ParseResult {
        let snapshot: QuotaSnapshot
        let planType: String
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ParseResult {
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)

        // primary_window = 5-hour window, secondary_window = weekly window
        let fiveHour = mapWindow(
            response.rateLimit?.primaryWindow,
            fallbackWindowMins: 300,
            now: now
        )

        let weekly = mapWindow(
            response.rateLimit?.secondaryWindow,
            fallbackWindowMins: 10080,
            now: now
        )

        let snapshot = QuotaSnapshot(fiveHour: fiveHour, weekly: weekly, fetchedAt: now)
        return ParseResult(snapshot: snapshot, planType: response.planType)
    }

    private static func mapWindow(
        _ window: WindowSnapshot?,
        fallbackWindowMins: Int,
        now: Date
    ) -> QuotaWindow {
        guard let window else {
            return QuotaWindow(
                usedPercent: 0,
                windowDurationMins: fallbackWindowMins,
                resetsAt: now.addingTimeInterval(TimeInterval(fallbackWindowMins * 60))
            )
        }

        let windowSeconds = window.limitWindowSeconds > 0
            ? window.limitWindowSeconds
            : fallbackWindowMins * 60

        let windowMins = window.limitWindowSeconds > 0
            ? (windowSeconds + 59) / 60
            : fallbackWindowMins

        let resetAt = Date(timeIntervalSince1970: TimeInterval(window.resetAt))
        let resetsAt: Date
        if let resetAfterSeconds = window.resetAfterSeconds, resetAfterSeconds > 0 {
            resetsAt = now.addingTimeInterval(TimeInterval(resetAfterSeconds))
        } else if resetAt > now {
            resetsAt = resetAt
        } else {
            // OpenAI sometimes reports a stale reset_at for a freshly reset window.
            // Keep the UI and poll scheduling moving by projecting a full window ahead.
            resetsAt = now.addingTimeInterval(TimeInterval(windowSeconds))
        }

        return QuotaWindow(
            usedPercent: max(0, min(100, Double(window.usedPercent))),
            windowDurationMins: windowMins,
            resetsAt: resetsAt
        )
    }
}
