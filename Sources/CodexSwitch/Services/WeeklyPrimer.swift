import Foundation
import os

private let weeklyPrimerLogger = Logger(subsystem: "com.codexswitch", category: "WeeklyPrimer")

/// Starts fresh rolling windows on idle accounts by sending a minimal Codex request.
///
/// Fresh accounts can look "full forever" until first real use. This primer nudges
/// those idle accounts once so their 5h and weekly windows actually start moving.
actor WeeklyPrimer {
    private static let codexResponsesURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    private static let weeklyPersistKey = "primedAccountIds"
    private static let fiveHourCooldown: TimeInterval = 4 * 3600

    private var weeklyPrimedAccounts: Set<UUID>
    private var fiveHourPrimedAt: [UUID: Date] = [:]
    private var currentlyPrimingAccounts: Set<UUID> = []
    private var lastErrorBody: String?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        if let saved = UserDefaults.standard.stringArray(forKey: Self.weeklyPersistKey) {
            self.weeklyPrimedAccounts = Set(saved.compactMap(UUID.init(uuidString:)))
        } else {
            self.weeklyPrimedAccounts = []
        }
        UserDefaults.standard.removeObject(forKey: "fiveHourPrimedAccountIds")
    }

    func primeIfNeeded(
        accounts: [CodexAccount],
        accountProvider: @escaping @Sendable (UUID) async -> CodexAccount?,
        onPrimed: (@Sendable (UUID) -> Void)? = nil
    ) async {
        for account in accounts {
            guard !account.isActive else { continue }
            guard let snapshot = account.quotaSnapshot else { continue }

            let weeklyFull = snapshot.weekly.remainingPercent >= 99.5
            let fiveHourFull = snapshot.fiveHour.remainingPercent >= 99.5

            if !weeklyFull {
                unmarkWeeklyPrimed(account.id)
            }

            let needsWeeklyPrime = weeklyFull && !weeklyPrimedAccounts.contains(account.id)
            let needsFiveHourPrime = fiveHourFull && !isFiveHourPrimed(account.id)
            guard needsWeeklyPrime || needsFiveHourPrime else { continue }
            guard !currentlyPrimingAccounts.contains(account.id) else { continue }

            currentlyPrimingAccounts.insert(account.id)
            defer { currentlyPrimingAccounts.remove(account.id) }

            guard let freshAccount = await accountProvider(account.id) else { continue }

            let windows = [needsWeeklyPrime ? "weekly" : nil, needsFiveHourPrime ? "5h" : nil]
                .compactMap { $0 }
                .joined(separator: "+")
            weeklyPrimerLogger.info("Priming \(windows, privacy: .public) timer(s) for \(freshAccount.email, privacy: .private)")

            do {
                try await sendMinimalRequest(for: freshAccount)
                if needsWeeklyPrime { markWeeklyPrimed(account.id) }
                if needsFiveHourPrime { markFiveHourPrimed(account.id) }
                onPrimed?(account.id)
                SwapLog.append(.debug("PRIMED email=\(freshAccount.email) windows=\(windows)"))
            } catch PrimerError.tokenExpired {
                weeklyPrimerLogger.warning("Token expired during priming for \(freshAccount.email, privacy: .private)")
            } catch {
                weeklyPrimerLogger.error("Failed to prime \(freshAccount.email, privacy: .private): \(error.localizedDescription, privacy: .public)")
                SwapLog.append(.debug("PRIME_FAILED email=\(freshAccount.email) windows=\(windows) error=\(error.localizedDescription) detail=\(lastErrorBody ?? "none")"))
            }
        }
    }

    func clearPrimedState(for accountId: UUID) {
        unmarkWeeklyPrimed(accountId)
        fiveHourPrimedAt.removeValue(forKey: accountId)
    }

    func clearAll() {
        weeklyPrimedAccounts.removeAll()
        fiveHourPrimedAt.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.weeklyPersistKey)
    }

    private func sendMinimalRequest(for account: CodexAccount) async throws {
        var request = URLRequest(url: Self.codexResponsesURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": "gpt-5.4",
            "instructions": "",
            "input": [
                ["role": "user", "content": [["type": "input_text", "text": "ok"]]]
            ],
            "tools": [] as [Any],
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "store": false,
            "stream": true,
            "include": [] as [Any],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PrimerError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return
        case 401:
            throw PrimerError.tokenExpired
        case 429:
            weeklyPrimerLogger.warning("Rate limited during priming for \(account.email, privacy: .private)")
            return
        default:
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            lastErrorBody = String(body.prefix(500))
            weeklyPrimerLogger.error("Primer HTTP \(httpResponse.statusCode) for \(account.email, privacy: .private): \(body.prefix(500), privacy: .private)")
            throw PrimerError.httpError(httpResponse.statusCode)
        }
    }

    private func markWeeklyPrimed(_ id: UUID) {
        weeklyPrimedAccounts.insert(id)
        UserDefaults.standard.set(weeklyPrimedAccounts.map(\.uuidString), forKey: Self.weeklyPersistKey)
    }

    private func unmarkWeeklyPrimed(_ id: UUID) {
        weeklyPrimedAccounts.remove(id)
        UserDefaults.standard.set(weeklyPrimedAccounts.map(\.uuidString), forKey: Self.weeklyPersistKey)
    }

    private func isFiveHourPrimed(_ id: UUID) -> Bool {
        guard let primedAt = fiveHourPrimedAt[id] else { return false }
        return Date().timeIntervalSince(primedAt) < Self.fiveHourCooldown
    }

    private func markFiveHourPrimed(_ id: UUID) {
        fiveHourPrimedAt[id] = Date()
    }
}

private enum PrimerError: Error, LocalizedError {
    case invalidResponse
    case tokenExpired
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Codex API"
        case .tokenExpired:
            return "Token expired"
        case .httpError(let code):
            return "HTTP \(code)"
        }
    }
}
