import Foundation

enum QuotaFreshnessPolicy {
    static let maximumSnapshotAge: TimeInterval = 15 * 60

    static func isFresh(fetchedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age <= maximumSnapshotAge
    }
}

enum QuotaWindowKind: String, Codable, Sendable, Equatable {
    case fiveHour
    case weekly
    case unknown

    static func classify(durationSeconds: Int) -> Self {
        switch durationSeconds {
        case 5 * 60 * 60:
            return .fiveHour
        case 7 * 24 * 60 * 60:
            return .weekly
        default:
            return .unknown
        }
    }
}

enum QuotaWindowRateLimitSource: String, Codable, Sendable, Equatable {
    case main
    case additional
    case legacy
    case unknown
}

enum QuotaWindowSlot: String, Codable, Sendable, Equatable {
    case primary
    case secondary
    case legacyFiveHour
    case legacyWeekly
    case unknown
}

struct QuotaWindowSourceMetadata: Codable, Sendable, Equatable {
    let rateLimit: QuotaWindowRateLimitSource
    let slot: QuotaWindowSlot
    let limitName: String?
    let meteredFeature: String?

    init(
        rateLimit: QuotaWindowRateLimitSource,
        slot: QuotaWindowSlot,
        limitName: String? = nil,
        meteredFeature: String? = nil
    ) {
        self.rateLimit = rateLimit
        self.slot = slot
        self.limitName = limitName
        self.meteredFeature = meteredFeature
    }
}

struct QuotaSnapshot: Codable, Sendable, Equatable {
    static let codingVersion = 2

    let allowed: Bool?
    let limitReached: Bool?
    let fetchedAt: Date
    let windows: [QuotaWindow]

    init(
        allowed: Bool?,
        limitReached: Bool?,
        fetchedAt: Date,
        windows: [QuotaWindow]
    ) {
        self.allowed = allowed
        self.limitReached = limitReached
        self.fetchedAt = fetchedAt
        self.windows = Self.validWindows(windows)
    }

    /// Migration-only constructor for callers that still own a rigid two-window model.
    init(fiveHour: QuotaWindow, weekly: QuotaWindow, fetchedAt: Date) {
        let migratedFiveHour = Self.migratedLegacyWindow(fiveHour, slot: .legacyFiveHour)
        let migratedWeekly = Self.migratedLegacyWindow(weekly, slot: .legacyWeekly)
        let migratedWindows = Self.validWindows([migratedFiveHour, migratedWeekly])
        let legacyLimitReached = migratedWindows.contains(where: \.hardLimitReached)

        allowed = legacyLimitReached ? false : nil
        limitReached = legacyLimitReached ? true : nil
        self.fetchedAt = fetchedAt
        windows = migratedWindows
    }

    /// Positive-duration windows with policy semantics. Unknown windows remain diagnostic-only.
    var policyWindows: [QuotaWindow] {
        windows.filter { $0.kind == .fiveHour || $0.kind == .weekly }
    }

    /// Migration conveniences. New policy code should operate on `policyWindows` and handle absence.
    var fiveHour: QuotaWindow? { policyWindows.first(where: { $0.kind == .fiveHour }) }
    var weekly: QuotaWindow? { policyWindows.first(where: { $0.kind == .weekly }) }

    var orderedWindows: [QuotaWindow] {
        Self.ordered(windows)
    }

    var orderedPolicyWindows: [QuotaWindow] {
        Self.ordered(policyWindows)
    }

    private static func ordered(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        windows.enumerated().sorted { lhs, rhs in
            let lhsRank = Self.sortRank(for: lhs.element.kind)
            let rhsRank = Self.sortRank(for: rhs.element.kind)
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }.map(\.element)
    }

    var isDenied: Bool {
        allowed == false || limitReached == true
    }

    var blockingWindows: [QuotaWindow] {
        if isDenied { return orderedPolicyWindows }
        return orderedPolicyWindows.filter(\.shouldAutoSwapAway)
    }

    var minimumRemainingPercent: Double? {
        if isDenied { return 0 }
        return policyWindows.map(\.effectiveRemainingPercent).min()
    }

    var mostUrgentWindow: QuotaWindow? {
        orderedPolicyWindows.min { lhs, rhs in
            lhs.effectiveRemainingPercent < rhs.effectiveRemainingPercent
        }
    }

    var needsSwap: Bool {
        isDenied || !blockingWindows.isEmpty
    }

    var isImmediatelyUsable: Bool {
        !isDenied && !policyWindows.isEmpty && blockingWindows.isEmpty
    }

    var nextRecoveryAt: Date? {
        blockingWindows.map(\.resetsAt).max()
    }

    var hasBackendUsagePlaceholder: Bool {
        policyWindows.contains(where: { $0.looksLikeBackendUsagePlaceholder(fetchedAt: fetchedAt) })
    }

    func isFresh(at now: Date) -> Bool {
        QuotaFreshnessPolicy.isFresh(fetchedAt: fetchedAt, now: now)
    }

    func hasExpiredExhaustedWindow(now: Date = Date()) -> Bool {
        policyWindows.contains(where: { $0.needsResetConfirmation(now: now) })
    }

    func hasStaleExpiredExhaustedWindow(
        now: Date = Date(),
        staleAfter: TimeInterval = QuotaFreshnessPolicy.maximumSnapshotAge
    ) -> Bool {
        policyWindows.contains(where: { $0.needsResetConfirmation(now: now, staleAfter: staleAfter) })
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case schemaVersion
        case allowed
        case limitReached
        case fetchedAt
        case windows
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case fiveHour
        case weekly
        case fetchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? container.decodeIfPresent(Int.self, forKey: .schemaVersion)

        if let version {
            guard version == Self.codingVersion else {
                throw DecodingError.dataCorruptedError(
                    forKey: container.contains(.version) ? .version : .schemaVersion,
                    in: container,
                    debugDescription: "Unsupported quota snapshot version \(version)"
                )
            }

            allowed = try container.decodeIfPresent(Bool.self, forKey: .allowed)
            limitReached = try container.decodeIfPresent(Bool.self, forKey: .limitReached)
            fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
            windows = Self.validWindows(
                try container.decode([QuotaWindow].self, forKey: .windows)
            )
            return
        }

        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyFiveHour = try legacy.decodeIfPresent(QuotaWindow.self, forKey: .fiveHour)
            .map { Self.migratedLegacyWindow($0, slot: .legacyFiveHour) }
        let legacyWeekly = try legacy.decodeIfPresent(QuotaWindow.self, forKey: .weekly)
            .map { Self.migratedLegacyWindow($0, slot: .legacyWeekly) }
        let decodedWindows = Self.validWindows([legacyFiveHour, legacyWeekly].compactMap { $0 })
        let legacyLimitReached = decodedWindows.contains(where: \.hardLimitReached)

        allowed = legacyLimitReached ? false : nil
        limitReached = legacyLimitReached ? true : nil
        fetchedAt = try legacy.decode(Date.self, forKey: .fetchedAt)
        windows = decodedWindows
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.codingVersion, forKey: .version)
        if let allowed {
            try container.encode(allowed, forKey: .allowed)
        } else {
            try container.encodeNil(forKey: .allowed)
        }
        if let limitReached {
            try container.encode(limitReached, forKey: .limitReached)
        } else {
            try container.encodeNil(forKey: .limitReached)
        }
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(Self.validWindows(windows), forKey: .windows)
    }

    private static func validWindows(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        var recognized: [QuotaWindowKind: QuotaWindow] = [:]
        var unknown: [QuotaWindow] = []

        for window in windows where window.durationSeconds > 0 {
            let normalized = window.with(
                kind: QuotaWindowKind.classify(durationSeconds: window.durationSeconds),
                source: window.source
            )
            guard normalized.kind != .unknown else {
                unknown.append(normalized)
                continue
            }
            if let existing = recognized[normalized.kind] {
                recognized[normalized.kind] = moreRestrictive(existing, normalized)
            } else {
                recognized[normalized.kind] = normalized
            }
        }

        return [recognized[.fiveHour], recognized[.weekly]].compactMap { $0 } + unknown
    }

    private static func migratedLegacyWindow(
        _ window: QuotaWindow,
        slot: QuotaWindowSlot
    ) -> QuotaWindow {
        window.with(
            kind: QuotaWindowKind.classify(durationSeconds: window.durationSeconds),
            source: QuotaWindowSourceMetadata(rateLimit: .legacy, slot: slot)
        )
    }

    private static func moreRestrictive(_ lhs: QuotaWindow, _ rhs: QuotaWindow) -> QuotaWindow {
        if lhs.hardLimitReached != rhs.hardLimitReached {
            return lhs.hardLimitReached ? lhs : rhs
        }
        if lhs.usedPercent != rhs.usedPercent {
            return lhs.usedPercent > rhs.usedPercent ? lhs : rhs
        }
        return lhs.resetsAt >= rhs.resetsAt ? lhs : rhs
    }

    private static func sortRank(for kind: QuotaWindowKind) -> Int {
        switch kind {
        case .fiveHour: 0
        case .weekly: 1
        case .unknown: 2
        }
    }
}

struct QuotaWindow: Codable, Sendable, Equatable {
    static let autoSwapThresholdPercent = 2.0

    let kind: QuotaWindowKind
    let durationSeconds: Int
    let usedPercent: Double
    let resetsAt: Date
    let source: QuotaWindowSourceMetadata

    /// Retained for legacy snapshots and callers. Parser-level denial belongs to QuotaSnapshot.
    let hardLimitReached: Bool

    init(
        kind: QuotaWindowKind,
        durationSeconds: Int,
        usedPercent: Double,
        resetsAt: Date,
        source: QuotaWindowSourceMetadata,
        hardLimitReached: Bool = false
    ) {
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.source = source
        self.hardLimitReached = hardLimitReached
    }

    /// Migration-only constructor for the v1 minute-based window representation.
    init(usedPercent: Double, windowDurationMins: Int, resetsAt: Date, hardLimitReached: Bool = false) {
        let durationSeconds = windowDurationMins * 60
        self.init(
            kind: QuotaWindowKind.classify(durationSeconds: durationSeconds),
            durationSeconds: durationSeconds,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            source: QuotaWindowSourceMetadata(rateLimit: .legacy, slot: .unknown),
            hardLimitReached: hardLimitReached
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case durationSeconds
        case windowDurationMins
        case usedPercent
        case resetsAt
        case source
        case hardLimitReached
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        resetsAt = try container.decode(Date.self, forKey: .resetsAt)
        hardLimitReached = try container.decodeIfPresent(Bool.self, forKey: .hardLimitReached) ?? false

        if let decodedDuration = try container.decodeIfPresent(Int.self, forKey: .durationSeconds) {
            durationSeconds = decodedDuration
            kind = QuotaWindowKind.classify(durationSeconds: decodedDuration)
            source = try container.decodeIfPresent(QuotaWindowSourceMetadata.self, forKey: .source)
                ?? QuotaWindowSourceMetadata(rateLimit: .unknown, slot: .unknown)
        } else {
            let windowDurationMins = try container.decode(Int.self, forKey: .windowDurationMins)
            durationSeconds = windowDurationMins * 60
            kind = QuotaWindowKind.classify(durationSeconds: durationSeconds)
            source = try container.decodeIfPresent(QuotaWindowSourceMetadata.self, forKey: .source)
                ?? QuotaWindowSourceMetadata(rateLimit: .legacy, slot: .unknown)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encode(resetsAt, forKey: .resetsAt)
        try container.encode(source, forKey: .source)
        try container.encode(hardLimitReached, forKey: .hardLimitReached)
    }

    var windowDurationMins: Int {
        guard durationSeconds > 0 else { return 0 }
        return (durationSeconds + 59) / 60
    }

    var remainingPercent: Double { max(0, 100 - usedPercent) }
    var effectiveRemainingPercent: Double { isExhausted ? 0 : remainingPercent }
    var timeUntilReset: TimeInterval { resetsAt.timeIntervalSinceNow }
    var isExhausted: Bool { hardLimitReached || remainingPercent < 1 }
    func needsResetConfirmation(now: Date = Date()) -> Bool {
        isExhausted && resetsAt <= now
    }
    func needsResetConfirmation(now: Date = Date(), staleAfter: TimeInterval) -> Bool {
        isExhausted && resetsAt <= now.addingTimeInterval(-staleAfter)
    }
    var shouldAutoSwapAway: Bool {
        hardLimitReached || remainingPercent < Self.autoSwapThresholdPercent
    }

    func looksLikeBackendUsagePlaceholder(fetchedAt: Date, tolerance: TimeInterval = 10) -> Bool {
        !hardLimitReached
            && usedPercent <= 0.0001
            && abs(resetsAt.timeIntervalSince(fetchedAt)) <= tolerance
    }

    func looksLikeUnstartedFiveHourWindow(
        referenceDate: Date = Date(),
        minimumRemainingPercent: Double = 98.5,
        resetWindowRatio: Double = 0.995
    ) -> Bool {
        let windowSeconds = TimeInterval(durationSeconds)
        guard !hardLimitReached, windowSeconds > 0 else { return false }
        return remainingPercent >= minimumRemainingPercent
            && resetsAt.timeIntervalSince(referenceDate) >= windowSeconds * resetWindowRatio
    }

    var urgency: QuotaUrgency { QuotaUrgency(remainingPercent: effectiveRemainingPercent) }

    fileprivate func with(kind: QuotaWindowKind, source: QuotaWindowSourceMetadata) -> Self {
        Self(
            kind: kind,
            durationSeconds: durationSeconds,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            source: source,
            hardLimitReached: hardLimitReached
        )
    }
}

/// Urgency levels ordered by increasing severity (Comparable uses declaration order).
enum QuotaUrgency: Sendable, Comparable {
    case relaxed     // >= 50%
    case moderate    // 20–50%
    case elevated    // 10–20%
    case high        // 7–10%
    case imminent    // 1–7% — agents can drain fast, poll every second
    case critical    // < 1% — about to hit the wall

    var pollInterval: TimeInterval {
        switch self {
        case .relaxed:  return 600
        case .moderate: return 300
        case .elevated: return 120
        case .high:     return 60
        case .imminent: return 1
        case .critical: return 1
        }
    }

    init(remainingPercent: Double) {
        switch remainingPercent {
        case 50...: self = .relaxed
        case 20..<50: self = .moderate
        case 10..<20: self = .elevated
        case 7..<10: self = .high
        case 1..<7: self = .imminent
        default: self = .critical
        }
    }
}
