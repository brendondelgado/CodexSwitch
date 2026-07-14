import Foundation
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "QuotaPoller")

actor QuotaPoller {
    private let session: URLSession
    private var pollTasks: [UUID: Task<Void, Never>] = [:]

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let inactiveExhaustedPlanUpgradePollInterval: TimeInterval = 5
    private static let inactivePlanUpgradePollInterval: TimeInterval = 15
    private static let inactiveProManualResetPollInterval: TimeInterval = 60

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Calculate poll interval based on remaining percent, scaled by user's poll multiplier.
    /// Active account polls every 5s, then tightens to 2s/1s near exhaustion.
    static func pollInterval(forRemainingPercent remaining: Double, isActive: Bool = false) -> TimeInterval {
        if isActive {
            if remaining <= 2 { return 1 }
            if remaining <= 10 { return 2 }
            return 5
        }
        let base = QuotaUrgency(remainingPercent: remaining).pollInterval
        let raw = UserDefaults.standard.double(forKey: "pollMultiplier")
        let multiplier = raw > 0 ? max(0.5, min(2.0, raw)) : 1.0
        return base * multiplier
    }

    static func pollInterval(for snapshot: QuotaSnapshot, isActive: Bool) -> TimeInterval {
        guard let remaining = snapshot.minimumRemainingPercent else { return 60 }
        return pollInterval(forRemainingPercent: remaining, isActive: isActive)
    }

    static func accepts(_ snapshot: QuotaSnapshot) -> Bool {
        snapshot.isDenied || !snapshot.policyWindows.isEmpty
    }

    /// Inactive accounts normally sleep for minutes or until reset. Non-Pro accounts are
    /// a special case because a user can buy/upgrade a plan while CodexSwitch is running;
    /// poll them quickly enough that plan upgrades become visible without a restart. Pro
    /// accounts are capped at one minute so manual usage resets are detected live too.
    static func inactivePollInterval(for account: CodexAccount, snapshot: QuotaSnapshot) -> TimeInterval {
        guard let mostConstrained = snapshot.mostUrgentWindow else { return 60 }
        var interval: TimeInterval

        if snapshot.isDenied {
            interval = inactiveExhaustedPlanUpgradePollInterval
        } else if mostConstrained.isExhausted, mostConstrained.timeUntilReset > 0 {
            interval = mostConstrained.timeUntilReset + 2
        } else {
            interval = pollInterval(
                forRemainingPercent: mostConstrained.effectiveRemainingPercent,
                isActive: false
            )
        }

        let nearestReset = snapshot.policyWindows
            .map(\.timeUntilReset)
            .filter { $0 > 0 }
            .min()
        if let nearestReset, nearestReset + 2 < interval {
            interval = nearestReset + 2
        }

        guard account.planPriority < 4 else {
            if snapshot.isDenied || mostConstrained.isExhausted {
                let naturalResetWake = nearestReset.map { $0 + 2 }
                    ?? inactiveProManualResetPollInterval
                return min(naturalResetWake, inactiveProManualResetPollInterval)
            }
            return min(interval, inactiveProManualResetPollInterval)
        }
        if snapshot.needsSwap || snapshot.policyWindows.contains(where: \.isExhausted) {
            return min(interval, inactiveExhaustedPlanUpgradePollInterval)
        }
        return min(interval, inactivePlanUpgradePollInterval)
    }

    struct FetchResult: Sendable {
        let snapshot: QuotaSnapshot
        let planType: String
    }

    /// Fetch quota snapshot for a single account
    func fetchQuota(for account: CodexAccount) async throws -> FetchResult {
        await NetworkBackoffGuard.shared.waitIfNeeded(operation: "quota:\(account.email)")

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        logger.info("Fetching quota for accountId=\(account.accountId, privacy: .public) email=\(account.email, privacy: .private)")

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
                await NetworkBackoffGuard.shared.recordSuccess(operation: "quota:\(account.email)")
            } catch {
                let message = error.localizedDescription
                await NetworkBackoffGuard.shared.recordFailure(message, operation: "quota:\(account.email)")
                throw PollerError.networkError(message)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response (not HTTP) for \(account.email, privacy: .private)")
                throw PollerError.invalidResponse
            }

            logger.info("Quota API response: HTTP \(httpResponse.statusCode) for \(account.email, privacy: .private)")

            switch httpResponse.statusCode {
            case 200:
                let result: UsageResponseParser.ParseResult
                do {
                    result = try UsageResponseParser.parse(data)
                } catch UsageResponseParser.ParserError.placeholderRateLimitWindow {
                    logger.warning("Quota API returned a placeholder usage window for \(account.email, privacy: .private) attempt=\(attempt, privacy: .public)")
                    if attempt < maxAttempts {
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }
                    throw PollerError.usageUnavailable
                }
                guard Self.accepts(result.snapshot) else {
                    logger.warning("Quota API returned no usable windows for \(account.email, privacy: .private)")
                    throw PollerError.usageUnavailable
                }
                let windowSummary = result.snapshot.orderedPolicyWindows.map {
                    "\($0.kind.rawValue)=\(String(format: "%.1f", $0.effectiveRemainingPercent))%"
                }.joined(separator: " ")
                logger.info("Quota parsed: \(windowSummary, privacy: .public) denied=\(result.snapshot.isDenied) plan=\(result.planType, privacy: .public)")
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
        throw PollerError.usageUnavailable
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
            // First poll: fetch immediately when we already have account state.
            // Brand-new accounts use a small random delay to avoid burst traffic.
            let initialAccount = await accountProvider(accountId)
            let hasData = initialAccount?.quotaSnapshot != nil
            var interval: TimeInterval = hasData
                ? 0
                : TimeInterval.random(in: 5...15)

            logger.info("Starting poll for \(accountId) — initial interval: \(String(format: "%.0f", interval))s, hasData: \(hasData)")

            while !Task.isCancelled {
                if interval > 0 {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { return }
                }

                guard let currentAccount = await accountProvider(accountId) else {
                    logger.error("Account \(accountId) not found in provider — stopping poll")
                    onError(accountId, .invalidResponse)
                    return
                }
                guard !currentAccount.hasHardRuntimeBlock else {
                    logger.info("Account \(currentAccount.email, privacy: .private) has a hard runtime block — stopping poll until account state changes")
                    return
                }

                do {
                    let result = try await self.fetchQuota(for: currentAccount)
                    onUpdate(accountId, result.snapshot, result.planType)

                    if currentAccount.isActive {
                        interval = Self.pollInterval(for: result.snapshot, isActive: true)
                    } else {
                        interval = Self.inactivePollInterval(for: currentAccount, snapshot: result.snapshot)
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
    case usageUnavailable
    case httpError(Int)
    case networkError(String)
}
