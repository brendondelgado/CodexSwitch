import Foundation

actor QuotaPoller {
    private let session: URLSession
    private var pollTasks: [UUID: Task<Void, Never>] = [:]

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/api/codex/usage")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Calculate poll interval based on remaining percent
    static func pollInterval(forRemainingPercent remaining: Double) -> TimeInterval {
        QuotaUrgency(remainingPercent: remaining).pollInterval
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

    /// Start adaptive polling for an account, calling onUpdate with each new snapshot
    func startPolling(
        for account: CodexAccount,
        onUpdate: @escaping @Sendable (UUID, QuotaSnapshot) -> Void,
        onError: @escaping @Sendable (UUID, PollerError) -> Void
    ) {
        stopPolling(for: account.id)

        let accountId = account.id
        let initialInterval = Self.pollInterval(
            forRemainingPercent: account.quotaSnapshot?.fiveHour.remainingPercent ?? 100
        )

        pollTasks[accountId] = Task { [weak self] in
            var interval = initialInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }

                do {
                    let snapshot = try await self.fetchQuota(for: account)
                    onUpdate(accountId, snapshot)
                    interval = Self.pollInterval(
                        forRemainingPercent: snapshot.fiveHour.remainingPercent
                    )
                } catch let error as PollerError {
                    onError(accountId, error)
                    interval = 60 // Back off on error
                } catch {
                    onError(accountId, .networkError(error))
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
    case networkError(Error)
}
