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

    /// Calculate poll interval based on remaining percent, scaled by user's poll multiplier
    static func pollInterval(forRemainingPercent remaining: Double) -> TimeInterval {
        let base = QuotaUrgency(remainingPercent: remaining).pollInterval
        let raw = UserDefaults.standard.double(forKey: "pollMultiplier")
        // UserDefaults.double returns 0.0 when unset — treat as default 1.0
        let multiplier = raw > 0 ? max(0.5, min(2.0, raw)) : 1.0
        return base * multiplier
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

        logger.info("Fetching quota for accountId=\(account.accountId, privacy: .public) email=\(account.email, privacy: .public)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response (not HTTP) for \(account.email, privacy: .public)")
            throw PollerError.invalidResponse
        }

        logger.info("Quota API response: HTTP \(httpResponse.statusCode) for \(account.email, privacy: .public)")

        switch httpResponse.statusCode {
        case 200:
            let result = try UsageResponseParser.parse(data)
            logger.info("Quota parsed: 5h=\(String(format: "%.1f", result.snapshot.fiveHour.remainingPercent))% weekly=\(String(format: "%.1f", result.snapshot.weekly.remainingPercent))% plan=\(result.planType, privacy: .public)")
            return FetchResult(snapshot: result.snapshot, planType: result.planType)
        case 401:
            logger.warning("Token expired (401) for \(account.email, privacy: .public)")
            throw PollerError.tokenExpired
        case 429:
            logger.warning("Rate limited (429) for \(account.email, privacy: .public)")
            throw PollerError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            logger.error("HTTP \(httpResponse.statusCode) for \(account.email, privacy: .public): \(body.prefix(500), privacy: .public)")
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
            // First poll: fetch immediately (small random delay to stagger multiple accounts)
            let initialAccount = await accountProvider(accountId)
            let hasData = initialAccount?.quotaSnapshot != nil
            var interval: TimeInterval = hasData
                ? Self.pollInterval(forRemainingPercent: initialAccount?.quotaSnapshot?.fiveHour.remainingPercent ?? 100)
                : TimeInterval.random(in: 5...15)

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
                        // Active account: poll at urgency-based intervals
                        interval = Self.pollInterval(
                            forRemainingPercent: result.snapshot.fiveHour.remainingPercent
                        )
                    } else {
                        // Inactive account: sleep until next reset, then recheck
                        let fhReset = result.snapshot.fiveHour.timeUntilReset
                        let wkReset = result.snapshot.weekly.timeUntilReset

                        if result.snapshot.fiveHour.isExhausted && fhReset > 0 {
                            // Exhausted — wake up 2s after 5h reset
                            interval = fhReset + 2
                            logger.info("Inactive \(currentAccount.email, privacy: .public) exhausted — sleeping \(String(format: "%.0f", interval))s until 5h reset")
                        } else if result.snapshot.fiveHour.remainingPercent > 50 {
                            // Plenty of quota — check again in 10 minutes
                            interval = 600
                        } else {
                            // Moderate quota — check every 5 minutes
                            interval = 300
                        }

                        // But never sleep longer than the nearest reset window
                        let nearestReset = min(fhReset, wkReset)
                        if nearestReset > 0 && nearestReset + 2 < interval {
                            interval = nearestReset + 2
                        }
                    }

                    logger.info("Poll success for \(currentAccount.email, privacy: .public) [active=\(currentAccount.isActive)] — next in \(String(format: "%.0f", interval))s")
                } catch let error as PollerError {
                    logger.error("Poll error for \(currentAccount.email, privacy: .public): \(String(describing: error), privacy: .public)")
                    onError(accountId, error)
                    if case .tokenExpired = error { return }
                    interval = 60 // Back off on error
                } catch {
                    logger.error("Poll network error for \(currentAccount.email, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
