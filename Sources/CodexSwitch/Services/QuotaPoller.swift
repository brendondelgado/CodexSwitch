import Foundation
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "QuotaPoller")

actor QuotaPoller {
    private let session: URLSession
    private var pollTasks: [UUID: Task<Void, Never>] = [:]

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Calculate poll interval based on remaining percent, scaled by user's poll multiplier.
    /// Active account polls every 5s for near-realtime UI (~500 byte response, negligible overhead).
    static func pollInterval(forRemainingPercent remaining: Double, isActive: Bool = false) -> TimeInterval {
        if isActive { return 5 }
        let base = QuotaUrgency(remainingPercent: remaining).pollInterval
        let raw = UserDefaults.standard.double(forKey: "pollMultiplier")
        let multiplier = raw > 0 ? max(0.5, min(2.0, raw)) : 1.0
        return base * multiplier
    }

    static func initialPollDelay(
        hasCachedSnapshot: Bool,
        randomDelay: TimeInterval = TimeInterval.random(in: 5...15)
    ) -> TimeInterval {
        _ = hasCachedSnapshot
        _ = randomDelay
        return 0
    }

    static func inactivePollInterval(
        for snapshot: QuotaSnapshot,
        now: Date = Date()
    ) -> TimeInterval {
        let fhReset = snapshot.fiveHour.resetsAt.timeIntervalSince(now)
        let wkReset = snapshot.weekly.resetsAt.timeIntervalSince(now)
        let bothWindowsFresh = snapshot.fiveHour.usedPercent == 0
            && snapshot.weekly.usedPercent == 0
            && fhReset > 0
            && wkReset > 0

        let interval: TimeInterval
        if bothWindowsFresh {
            // Freshly reset idle accounts look dead if we only revisit them every 5-10 minutes.
            // Keep them warm enough that the UI and swap logic see the countdown move.
            interval = 60
        } else if snapshot.fiveHour.isExhausted && fhReset > 0 {
            interval = fhReset + 2
        } else if snapshot.fiveHour.remainingPercent > 50 {
            interval = 600
        } else {
            interval = 300
        }

        let nearestReset = min(fhReset, wkReset)
        if nearestReset > 0 && nearestReset + 2 < interval {
            return nearestReset + 2
        }
        return interval
    }

    struct FetchResult: Sendable {
        let snapshot: QuotaSnapshot
        let planType: String
    }

    /// Fetch quota snapshot for a single account
    func fetchQuota(for account: CodexAccount) async throws -> FetchResult {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        logger.info("Fetching quota for accountId=\(account.accountId, privacy: .public) email=\(account.email, privacy: .private)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response (not HTTP) for \(account.email, privacy: .private)")
            throw PollerError.invalidResponse
        }

        logger.info("Quota API response: HTTP \(httpResponse.statusCode) for \(account.email, privacy: .private)")

        switch httpResponse.statusCode {
        case 200:
            let result = try UsageResponseParser.parse(data)
            logger.info("Quota parsed: 5h=\(String(format: "%.1f", result.snapshot.fiveHour.remainingPercent))% weekly=\(String(format: "%.1f", result.snapshot.weekly.remainingPercent))% plan=\(result.planType, privacy: .public)")
            return FetchResult(snapshot: result.snapshot, planType: result.planType)
        case 401:
            logger.warning("Token expired (401) for \(account.email, privacy: .private)")
            throw PollerError.tokenExpired
        case 429:
            logger.warning("Rate limited (429) for \(account.email, privacy: .private)")
            throw PollerError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            logger.error("HTTP \(httpResponse.statusCode) for \(account.email, privacy: .private): \(body.prefix(500), privacy: .private)")
            throw PollerError.httpError(httpResponse.statusCode)
        }
    }

    /// Start adaptive polling for an account, calling onUpdate with each new snapshot.
    /// Uses accountProvider to get current account state (fresh tokens after refresh).
    ///
    /// Polling strategy:
    /// - **Active account**: Polls at urgency-based intervals (10s-600s)
    /// - **Inactive accounts**: Sleeps until their reset time, then polls once to confirm reset
    /// - All accounts get an initial fetch on startup
    func startPolling(
        for accountId: UUID,
        accountProvider: @escaping @Sendable (UUID) async -> CodexAccount?,
        onUpdate: @escaping @Sendable (UUID, QuotaSnapshot, String) -> Void,
        onError: @escaping @Sendable (UUID, PollerError) -> Void
    ) {
        stopPolling(for: accountId)

        pollTasks[accountId] = Task {
            // First poll: fetch immediately so fresh/idle accounts get a real window snapshot
            // instead of looking inert until the next scheduled pass.
            let initialAccount = await accountProvider(accountId)
            let hasData = initialAccount?.quotaSnapshot != nil
            var interval = Self.initialPollDelay(hasCachedSnapshot: hasData)

            logger.info("Starting poll for \(accountId) — initial interval: \(String(format: "%.0f", interval))s, hasData: \(hasData)")

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }

                guard let currentAccount = await accountProvider(accountId) else {
                    logger.error("Account \(accountId) not found in provider — stopping poll")
                    onError(accountId, .invalidResponse)
                    return
                }

                do {
                    let result = try await self.fetchQuota(for: currentAccount)
                    onUpdate(accountId, result.snapshot, result.planType)

                    if currentAccount.isActive {
                        // Active account: poll at urgency-based intervals (capped at 30s)
                        interval = Self.pollInterval(
                            forRemainingPercent: result.snapshot.fiveHour.remainingPercent,
                            isActive: true
                        )
                    } else {
                        interval = Self.inactivePollInterval(
                            for: result.snapshot,
                            now: result.snapshot.fetchedAt
                        )
                    }

                    logger.info("Poll success for \(currentAccount.email, privacy: .private) [active=\(currentAccount.isActive)] — next in \(String(format: "%.0f", interval))s")
                } catch let error as PollerError {
                    logger.error("Poll error for \(currentAccount.email, privacy: .private): \(String(describing: error), privacy: .public)")
                    onError(accountId, error)
                    if case .tokenExpired = error { return }
                    interval = 60 // Back off on error
                } catch {
                    logger.error("Poll network error for \(currentAccount.email, privacy: .private): \(error.localizedDescription, privacy: .public)")
                    onError(accountId, .networkError(error.localizedDescription))
                    interval = 60
                }
            }
        }
    }

    func stopPolling(for accountId: UUID) {
        pollTasks[accountId]?.cancel()
        pollTasks[accountId] = nil
    }

    func stopAll() {
        for (_, task) in pollTasks { task.cancel() }
        pollTasks.removeAll()
    }
}

enum PollerError: Error, Sendable {
    case invalidResponse
    case tokenExpired
    case rateLimited
    case httpError(Int)
    case networkError(String)
}
