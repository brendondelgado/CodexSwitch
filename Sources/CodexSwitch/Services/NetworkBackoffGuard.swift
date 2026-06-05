import Foundation

actor NetworkBackoffGuard {
    static let shared = NetworkBackoffGuard()

    private static let baseDelay: TimeInterval = 15
    private static let maxDelay: TimeInterval = 120

    private var transientFailureStreak = 0
    private var backoffUntil: Date?

    func waitIfNeeded(operation: String) async {
        guard let backoffUntil else { return }
        let remaining = backoffUntil.timeIntervalSinceNow
        guard remaining > 0 else { return }
        SwapLog.append(.debug("NETWORK_BACKOFF_WAIT operation=\(operation) seconds=\(Int(ceil(remaining)))"))
        try? await Task.sleep(for: .seconds(remaining))
    }

    func shouldDeferNonCriticalProbe(operation: String) -> Bool {
        guard let backoffUntil else { return false }
        let remaining = backoffUntil.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        SwapLog.append(.debug("NETWORK_BACKOFF_DEFER operation=\(operation) seconds=\(Int(ceil(remaining)))"))
        return true
    }

    func recordSuccess(operation: String) {
        guard transientFailureStreak > 0 || backoffUntil != nil else { return }
        transientFailureStreak = 0
        backoffUntil = nil
        SwapLog.append(.debug("NETWORK_BACKOFF_CLEARED operation=\(operation)"))
    }

    func recordFailure(_ message: String, operation: String) {
        guard Self.isTransientNetworkError(message) else { return }
        transientFailureStreak += 1
        let delay = Self.delay(forFailureStreak: transientFailureStreak)
        let candidate = Date().addingTimeInterval(delay)
        if let existing = backoffUntil, existing > candidate {
            SwapLog.append(.debug("NETWORK_BACKOFF_EXTANT operation=\(operation) seconds=\(Int(ceil(existing.timeIntervalSinceNow))) error=\(Self.sanitize(message))"))
            return
        }
        backoffUntil = candidate
        SwapLog.append(.debug("NETWORK_BACKOFF_ARMED operation=\(operation) streak=\(transientFailureStreak) seconds=\(Int(delay)) error=\(Self.sanitize(message))"))
    }

    nonisolated static func isTransientNetworkError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        let needles = [
            "tls error",
            "secure connection",
            "internet connection appears to be offline",
            "not connected to the internet",
            "network connection was lost",
            "connection reset",
            "reset by peer",
            "timed out",
            "operation timed out",
            "cannot connect to host",
            "could not connect",
            "cannot find host",
            "temporary failure",
            "network is unreachable",
            "software caused connection abort"
        ]
        return needles.contains { normalized.contains($0) }
    }

    nonisolated static func delay(forFailureStreak streak: Int) -> TimeInterval {
        let exponent = max(0, min(streak - 1, 3))
        return min(maxDelay, baseDelay * TimeInterval(1 << exponent))
    }

    private nonisolated static func sanitize(_ message: String) -> String {
        message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(160)
            .description
    }
}
