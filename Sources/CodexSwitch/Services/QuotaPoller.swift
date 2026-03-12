import Foundation

actor QuotaPoller {
    private let session: URLSession
    private var pollTasks: [UUID: Task<Void, Never>] = [:]

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/api/codex/usage")!

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

    /// Fetch quota snapshot for a single account
    func fetchQuota(for account: CodexAccount) async throws -> QuotaSnapshot {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PollerError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try UsageResponseParser.parse(data)
        case 401:
            throw PollerError.tokenExpired
        case 429:
            throw PollerError.rateLimited
        default:
            throw PollerError.httpError(httpResponse.statusCode)
        }
    }

    /// Start adaptive polling for an account, calling onUpdate with each new snapshot.
    /// Uses accountProvider to get current account state (fresh tokens after refresh).
    func startPolling(
        for accountId: UUID,
        accountProvider: @escaping @Sendable (UUID) async -> CodexAccount?,
        onUpdate: @escaping @Sendable (UUID, QuotaSnapshot) -> Void,
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

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }

                guard let currentAccount = await accountProvider(accountId) else {
                    onError(accountId, .invalidResponse)
                    return
                }

                do {
                    let snapshot = try await self.fetchQuota(for: currentAccount)
                    onUpdate(accountId, snapshot)
                    interval = Self.pollInterval(
                        forRemainingPercent: snapshot.fiveHour.remainingPercent
                    )
                } catch let error as PollerError {
                    onError(accountId, error)
                    if case .tokenExpired = error { return }
                    interval = 60 // Back off on error
                } catch {
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
