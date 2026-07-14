import Foundation

enum UsageResponseParser {
    enum ParserError: Error, Equatable {
        /// The backend allowed requests but exposed no usable quota telemetry.
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

    private struct SelectedRateLimit {
        let details: RateLimitDetails
        let source: QuotaWindowRateLimitSource
        let limitName: String?
        let meteredFeature: String?
    }

    static func parse(_ data: Data, fetchedAt: Date = Date()) throws -> ParseResult {
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)
        guard let selected = selectedRateLimit(from: response) else {
            throw ParserError.placeholderRateLimitWindow
        }

        var windows = mappedWindows(from: selected)
        if selected.source == .additional, let main = response.rateLimit {
            let mainDiagnostics = mappedWindows(from: SelectedRateLimit(
                details: main,
                source: .main,
                limitName: nil,
                meteredFeature: nil
            )).filter { $0.kind == .unknown }
            windows.append(contentsOf: mainDiagnostics)
        }
        let snapshot = QuotaSnapshot(
            allowed: selected.details.allowed,
            limitReached: selected.details.limitReached,
            fetchedAt: fetchedAt,
            windows: windows
        )

        guard !windows.isEmpty || snapshot.isDenied else {
            throw ParserError.placeholderRateLimitWindow
        }

        return ParseResult(snapshot: snapshot, planType: response.planType)
    }

    private static func selectedRateLimit(from response: UsageResponse) -> SelectedRateLimit? {
        if let main = response.rateLimit,
           hasRecognizedWindow(main) || isDenied(main) {
            return SelectedRateLimit(
                details: main,
                source: .main,
                limitName: nil,
                meteredFeature: nil
            )
        }

        let candidates = (response.additionalRateLimits ?? []).enumerated().compactMap { index, additional
            -> (rank: Int, index: Int, selected: SelectedRateLimit)? in
            guard let rank = codexMetadataRank(additional),
                  let details = additional.rateLimit,
                  hasPositiveWindow(details) || isDenied(details) else {
                return nil
            }
            return (
                rank,
                index,
                SelectedRateLimit(
                    details: details,
                    source: .additional,
                    limitName: additional.limitName,
                    meteredFeature: additional.meteredFeature
                )
            )
        }

        let policyCandidates = candidates.filter {
            hasRecognizedWindow($0.selected.details) || isDenied($0.selected.details)
        }
        if let selected = bestCandidate(policyCandidates) {
            return selected
        }

        if let main = response.rateLimit, hasPositiveWindow(main) {
            return SelectedRateLimit(
                details: main,
                source: .main,
                limitName: nil,
                meteredFeature: nil
            )
        }

        return bestCandidate(candidates)
    }

    private static func bestCandidate(
        _ candidates: [(rank: Int, index: Int, selected: SelectedRateLimit)]
    ) -> SelectedRateLimit? {
        candidates.min { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.index < rhs.index
        }?.selected
    }

    private static func hasPositiveWindow(_ details: RateLimitDetails) -> Bool {
        [details.primaryWindow, details.secondaryWindow]
            .compactMap { $0 }
            .contains(where: { $0.limitWindowSeconds > 0 })
    }

    private static func hasRecognizedWindow(_ details: RateLimitDetails) -> Bool {
        [details.primaryWindow, details.secondaryWindow]
            .compactMap { $0 }
            .contains {
                $0.limitWindowSeconds > 0
                    && QuotaWindowKind.classify(durationSeconds: $0.limitWindowSeconds) != .unknown
            }
    }

    private static func isDenied(_ details: RateLimitDetails) -> Bool {
        details.allowed == false || details.limitReached == true
    }

    private static func codexMetadataRank(_ additional: AdditionalRateLimit) -> Int? {
        let limitName = additional.limitName?.lowercased() ?? ""
        let meteredFeature = additional.meteredFeature?.lowercased() ?? ""
        let isExcludedModelFamily = limitName.contains("spark")
            || limitName.contains("bengalfox")
            || meteredFeature.contains("spark")
            || meteredFeature.contains("bengalfox")

        guard !isExcludedModelFamily else { return nil }
        if meteredFeature == "codex" { return 0 }
        if meteredFeature.contains("codex") { return 1 }
        if limitName.contains("codex") { return 2 }
        return nil
    }

    private static func mappedWindows(from selected: SelectedRateLimit) -> [QuotaWindow] {
        let candidates: [(WindowSnapshot?, QuotaWindowSlot)] = [
            (selected.details.primaryWindow, .primary),
            (selected.details.secondaryWindow, .secondary)
        ]

        return candidates.compactMap { window, slot in
            guard let window, window.limitWindowSeconds > 0 else { return nil }

            return QuotaWindow(
                kind: QuotaWindowKind.classify(durationSeconds: window.limitWindowSeconds),
                durationSeconds: window.limitWindowSeconds,
                usedPercent: window.usedPercent,
                resetsAt: Date(timeIntervalSince1970: TimeInterval(window.resetAt)),
                source: QuotaWindowSourceMetadata(
                    rateLimit: selected.source,
                    slot: slot,
                    limitName: selected.limitName,
                    meteredFeature: selected.meteredFeature
                )
            )
        }
    }
}
