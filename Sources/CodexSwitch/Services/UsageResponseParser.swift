import Foundation

enum UsageResponseParser {
    enum ParserError: Error, Equatable {
        case placeholderRateLimitWindow
    }

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

    static func parse(_ data: Data) throws -> ParseResult {
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)
        guard let rateLimit = selectedRateLimit(from: response) else {
            throw ParserError.placeholderRateLimitWindow
        }

        let hardLimitReached = rateLimit.limitReached == true
            || rateLimit.allowed == false
        let backendAllowsRequests = rateLimit.allowed == true
            && rateLimit.limitReached != true

        // primary_window = 5-hour window, secondary_window = weekly window
        let fiveHour = mapWindow(
            rateLimit.primaryWindow,
            fallbackWindowMins: 300,
            hardLimitReached: hardLimitReached,
            backendAllowsRequests: backendAllowsRequests
        )

        let weekly = mapWindow(
            rateLimit.secondaryWindow,
            fallbackWindowMins: 10080,
            hardLimitReached: false,
            backendAllowsRequests: backendAllowsRequests
        )

        let snapshot = QuotaSnapshot(fiveHour: fiveHour, weekly: weekly, fetchedAt: Date())
        return ParseResult(snapshot: snapshot, planType: response.planType)
    }

    private static func selectedRateLimit(from response: UsageResponse) -> RateLimitDetails? {
        if let rateLimit = response.rateLimit,
           isUsablePrimaryWindow(rateLimit.primaryWindow) {
            return rateLimit
        }
        if let additional = response.additionalRateLimits?
            .compactMap(\.rateLimit)
            .first(where: { isUsablePrimaryWindow($0.primaryWindow) }) {
            return additional
        }
        if response.rateLimit?.allowed == false || response.rateLimit?.limitReached == true {
            return response.rateLimit
        }
        return nil
    }

    private static func isUsablePrimaryWindow(_ window: WindowSnapshot?) -> Bool {
        guard let window else { return false }
        return window.limitWindowSeconds > 0
    }

    private static func mapWindow(
        _ window: WindowSnapshot?,
        fallbackWindowMins: Int,
        hardLimitReached: Bool,
        backendAllowsRequests: Bool
    ) -> QuotaWindow {
        guard let window else {
            return QuotaWindow(
                usedPercent: 0,
                windowDurationMins: fallbackWindowMins,
                resetsAt: Date().addingTimeInterval(TimeInterval(fallbackWindowMins * 60)),
                hardLimitReached: hardLimitReached
            )
        }

        let windowMins = window.limitWindowSeconds > 0
            ? (window.limitWindowSeconds + 59) / 60
            : fallbackWindowMins

        // reset_at is a Unix timestamp
        let resetsAt = Date(timeIntervalSince1970: TimeInterval(window.resetAt))

        var usedPercent = max(0, min(100, Double(window.usedPercent)))
        if backendAllowsRequests && !hardLimitReached && usedPercent >= 100 {
            usedPercent = 100 - QuotaWindow.autoSwapThresholdPercent
        }

        return QuotaWindow(
            usedPercent: usedPercent,
            windowDurationMins: windowMins,
            resetsAt: resetsAt,
            hardLimitReached: hardLimitReached
        )
    }
}
