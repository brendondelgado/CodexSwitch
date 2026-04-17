import Foundation
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "WeeklyPrimer")

/// Sends a minimal Codex API request to idle accounts whose quota windows are at 100%,
/// starting their rolling timers so they begin counting down sooner.
///
/// Without priming, an idle account's timers don't start until first use — meaning
/// when you swap to it and deplete it, you wait the full window duration (5h or 7 days).
/// Priming starts the clock immediately so the window is partially elapsed by the time
/// you need that account.
///
/// Primes both windows with a single request (any Codex usage starts both timers):
/// - **Weekly**: prime when weekly remaining >= 99.5% (fresh/reset)
/// - **5-hour**: prime when 5h remaining >= 99.5% (fresh/reset)
actor WeeklyPrimer {
    private static let codexResponsesURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!

    private static let weeklyPersistKey = "primedAccountIds"

    /// Accounts that have been primed since their last weekly reset.
    /// Persisted to UserDefaults — weekly windows last 7 days.
    private var weeklyPrimedAccounts: Set<UUID>

    /// Tracks 5h priming by remembering WHEN we primed. An account can only
    /// be re-primed after 4+ hours (the timer needs to actually expire first).
    /// NOT persisted — 5h windows are short-lived, so in-memory is fine.
    private var fiveHourPrimedAt: [UUID: Date] = [:]

    private var lastErrorBody: String?

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        if let saved = UserDefaults.standard.stringArray(forKey: Self.weeklyPersistKey) {
            self.weeklyPrimedAccounts = Set(saved.compactMap { UUID(uuidString: $0) })
        } else {
            self.weeklyPrimedAccounts = []
        }
        // Clean up old persisted 5h state (no longer used)
        UserDefaults.standard.removeObject(forKey: "fiveHourPrimedAccountIds")
    }

    private func markWeeklyPrimed(_ id: UUID) {
        weeklyPrimedAccounts.insert(id)
        UserDefaults.standard.set(
            weeklyPrimedAccounts.map(\.uuidString),
            forKey: Self.weeklyPersistKey
        )
    }

    private func unmarkWeeklyPrimed(_ id: UUID) {
        weeklyPrimedAccounts.remove(id)
        UserDefaults.standard.set(
            weeklyPrimedAccounts.map(\.uuidString),
            forKey: Self.weeklyPersistKey
        )
    }

    private static let fiveHourCooldown: TimeInterval = 4 * 3600 // 4 hours

    private func isFiveHourPrimed(_ id: UUID) -> Bool {
        guard let primedAt = fiveHourPrimedAt[id] else { return false }
        // Only allow re-priming after the cooldown (the 5h window needs
        // time to actually expire and reset before priming again)
        return Date().timeIntervalSince(primedAt) < Self.fiveHourCooldown
    }

    private func markFiveHourPrimed(_ id: UUID) {
        fiveHourPrimedAt[id] = Date()
    }

    /// Check all accounts and prime any idle ones with full quota windows.
    /// A single API request starts both the 5-hour and weekly timers.
    /// Safe to call frequently — skips already-primed and active accounts.
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

            // Clear weekly primed state once usage drops below 99%
            if !weeklyFull { unmarkWeeklyPrimed(account.id) }

            // Determine if this account needs priming for either window
            let needsWeeklyPrime = weeklyFull && !weeklyPrimedAccounts.contains(account.id)
            // 5h: only prime once per ~4 hour cooldown
            let needsFiveHourPrime = fiveHourFull && !isFiveHourPrimed(account.id)

            guard needsWeeklyPrime || needsFiveHourPrime else { continue }

            // Get fresh account (tokens may have been refreshed since snapshot)
            guard let freshAccount = await accountProvider(account.id) else { continue }

            let windows = [needsWeeklyPrime ? "weekly" : nil, needsFiveHourPrime ? "5h" : nil]
                .compactMap { $0 }.joined(separator: "+")
            logger.info("Priming \(windows) timer(s) for \(freshAccount.email, privacy: .private)")

            do {
                try await sendMinimalRequest(for: freshAccount)
                if needsWeeklyPrime { markWeeklyPrimed(account.id) }
                if needsFiveHourPrime { markFiveHourPrimed(account.id) }
                onPrimed?(account.id)
                SwapLog.append(.debug("PRIMED email=\(freshAccount.email) windows=\(windows)"))
                logger.info("Successfully primed \(freshAccount.email, privacy: .private)")
            } catch PrimerError.tokenExpired {
                logger.warning("Token expired during priming for \(freshAccount.email, privacy: .private) — will retry after refresh")
            } catch {
                logger.error("Failed to prime \(freshAccount.email, privacy: .private): \(error.localizedDescription)")
                SwapLog.append(.debug("PRIME_FAILED email=\(freshAccount.email) windows=\(windows) error=\(error.localizedDescription) detail=\(lastErrorBody ?? "none")"))
            }
        }
    }

    /// Send a single minimal Codex API request using the account's tokens.
    /// This registers as Codex usage, starting the weekly rolling window.
    private func sendMinimalRequest(for account: CodexAccount) async throws {
        var request = URLRequest(url: Self.codexResponsesURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        // Minimal Responses API body — just enough to get GPT to respond
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
            "include": [] as [Any]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PrimerError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return // Success — usage registered
        case 401:
            throw PrimerError.tokenExpired
        case 429:
            // Rate limited — the request was received, which may still register usage.
            // Log but don't treat as failure.
            logger.warning("Rate limited (429) during priming for \(account.email, privacy: .private)")
            return
        default:
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            lastErrorBody = String(body.prefix(500))
            logger.error("Primer HTTP \(httpResponse.statusCode) for \(account.email, privacy: .private): \(body.prefix(500), privacy: .private)")
            throw PrimerError.httpError(httpResponse.statusCode)
        }
    }

    /// Clear priming state for an account (e.g., after resets and quota changes).
    func clearPrimedState(for accountId: UUID) {
        unmarkWeeklyPrimed(accountId)
        fiveHourPrimedAt.removeValue(forKey: accountId)
    }

    func clearAll() {
        weeklyPrimedAccounts.removeAll()
        fiveHourPrimedAt.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.weeklyPersistKey)
    }
}

private enum PrimerError: Error, LocalizedError {
    case invalidResponse
    case tokenExpired
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from Codex API"
        case .tokenExpired: return "Token expired"
        case .httpError(let code): return "HTTP \(code)"
        }
    }
}
