import Foundation

enum UsageResponseParser {
    struct UsageResponse: Decodable {
        let rateLimit: RateLimitInfo?
        let additionalRateLimits: [AdditionalRateLimit]?

        enum CodingKeys: String, CodingKey {
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
        }
    }

    struct RateLimitInfo: Decodable {
        let allowed: Bool?
        let limitReached: Bool?
        let primaryWindow: WindowInfo?

        enum CodingKeys: String, CodingKey {
            case allowed
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
        }
    }

    struct AdditionalRateLimit: Decodable {
        let meteredFeature: String?
        let primaryWindow: WindowInfo?

        enum CodingKeys: String, CodingKey {
            case meteredFeature = "metered_feature"
            case primaryWindow = "primary_window"
        }
    }

    struct WindowInfo: Decodable {
        let limitWindowSeconds: Int?
        let resetAfterSeconds: Int?
        let remainingSeconds: Int?
        let usedPercent: Double?

        enum CodingKeys: String, CodingKey {
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case remainingSeconds = "remaining_seconds"
            case usedPercent = "used_percent"
        }
    }

    static func parse(_ data: Data) throws -> QuotaSnapshot {
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)
        let now = Date()

        let fiveHour = parseWindow(
            response.rateLimit?.primaryWindow,
            fallbackWindowSeconds: 18000,
            now: now
        )

        let weeklyWindow = response.additionalRateLimits?
            .first(where: { $0.meteredFeature == "weekly" })?
            .primaryWindow

        let weekly = parseWindow(
            weeklyWindow,
            fallbackWindowSeconds: 604800,
            now: now
        )

        return QuotaSnapshot(fiveHour: fiveHour, weekly: weekly, fetchedAt: now)
    }

    private static func parseWindow(
        _ info: WindowInfo?,
        fallbackWindowSeconds: Int,
        now: Date
    ) -> QuotaWindow {
        guard let info else {
            return QuotaWindow(
                usedPercent: 0,
                windowDurationMins: fallbackWindowSeconds / 60,
                resetsAt: now.addingTimeInterval(TimeInterval(fallbackWindowSeconds))
            )
        }

        let windowSeconds = info.limitWindowSeconds ?? fallbackWindowSeconds
        let resetAfter = info.resetAfterSeconds ?? windowSeconds

        let usedPercent: Double
        if let explicit = info.usedPercent {
            usedPercent = explicit
        } else {
            // Estimate: if reset_after is close to window, we haven't used much
            let fractionRemaining = Double(resetAfter) / Double(windowSeconds)
            usedPercent = (1.0 - fractionRemaining) * 100.0
        }

        let resetsAt = now.addingTimeInterval(TimeInterval(resetAfter))

        return QuotaWindow(
            usedPercent: max(0, min(100, usedPercent)),
            windowDurationMins: windowSeconds / 60,
            resetsAt: resetsAt
        )
    }
}
