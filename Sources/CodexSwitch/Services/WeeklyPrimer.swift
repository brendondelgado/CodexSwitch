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
/// Primes either reported window with a single request (Codex usage starts its timer):
/// - **Weekly**: prime when weekly remaining >= 99.5% (fresh/reset)
/// - **5-hour**: prime when 5h remaining >= 99.5% (fresh/reset)
actor WeeklyPrimer {
    static let defaultPrimerModel = "gpt-5.5"

    nonisolated static func isAcceptedPrimerHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 200
    }

    private static let codexResponsesURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!

    private static let weeklyPersistKey = "primedAccountIds"
    private static let weeklyResetPersistKey = "weeklyPrimedResetAtByAccountId"
    // Legacy compatibility only. Keep reading these keys during the collection migration.
    private static let legacyFiveHourPersistKey = "fiveHourPrimedAtByAccountId"
    private static let legacyFiveHourAttemptPersistKey = "fiveHourPrimeAttemptedAtByAccountId"

    /// Accounts that have been primed since their last weekly reset.
    /// Persisted to UserDefaults — weekly windows last 7 days.
    private var weeklyPrimedAccounts: Set<UUID>
    private var weeklyPrimedResetAt: [UUID: Date] = [:]

    /// Tracks 5h priming by remembering WHEN we primed. An account can only
    /// be re-primed after 4+ hours, and the timestamps are persisted so app
    /// restarts do not re-prime the same accounts immediately.
    private var fiveHourPrimedAt: [UUID: Date] = [:]
    private var fiveHourPrimeAttemptedAt: [UUID: Date] = [:]
    private var weeklyPrimingInFlight: Set<UUID> = []
    private var fiveHourPrimingInFlight: Set<UUID> = []

    private var lastErrorBody: String?

    private let session: URLSession
    private let userDefaults: UserDefaults
    private let requestSender: (@Sendable (CodexAccount) async throws -> Void)?
    private let quotaSnapshotFetcher: (@Sendable (CodexAccount) async throws -> QuotaSnapshot)?
    private let confirmationDelay: TimeInterval

    struct PrimeResult: Equatable, Sendable {
        let accountId: UUID
        let weeklyPrimed: Bool
        let fiveHourPrimed: Bool
        let fiveHourUnconfirmed: Bool
    }

    init(
        session: URLSession = .shared,
        userDefaults: UserDefaults = .standard,
        requestSender: (@Sendable (CodexAccount) async throws -> Void)? = nil,
        quotaSnapshotFetcher: (@Sendable (CodexAccount) async throws -> QuotaSnapshot)? = nil,
        confirmationDelay: TimeInterval = 2
    ) {
        self.session = session
        self.userDefaults = userDefaults
        self.requestSender = requestSender
        self.quotaSnapshotFetcher = quotaSnapshotFetcher
        self.confirmationDelay = confirmationDelay
        if let saved = userDefaults.stringArray(forKey: Self.weeklyPersistKey) {
            self.weeklyPrimedAccounts = Set(saved.compactMap { UUID(uuidString: $0) })
        } else {
            self.weeklyPrimedAccounts = []
        }
        if let saved = userDefaults.dictionary(forKey: Self.weeklyResetPersistKey) as? [String: TimeInterval] {
            self.weeklyPrimedResetAt = saved.reduce(into: [:]) { result, item in
                if let id = UUID(uuidString: item.key) {
                    result[id] = Date(timeIntervalSince1970: item.value)
                }
            }
        }
        if let saved = userDefaults.dictionary(forKey: Self.legacyFiveHourPersistKey) as? [String: TimeInterval] {
            self.fiveHourPrimedAt = saved.reduce(into: [:]) { result, item in
                if let id = UUID(uuidString: item.key) {
                    result[id] = Date(timeIntervalSince1970: item.value)
                }
            }
        }
        if let saved = userDefaults.dictionary(forKey: Self.legacyFiveHourAttemptPersistKey) as? [String: TimeInterval] {
            self.fiveHourPrimeAttemptedAt = saved.reduce(into: [:]) { result, item in
                if let id = UUID(uuidString: item.key) {
                    result[id] = Date(timeIntervalSince1970: item.value)
                }
            }
        }
        // Clean up old persisted 5h string-array state.
        userDefaults.removeObject(forKey: "fiveHourPrimedAccountIds")
    }

    private func markWeeklyPrimed(_ id: UUID, resetAt: Date) {
        weeklyPrimedAccounts.insert(id)
        weeklyPrimedResetAt[id] = resetAt
        userDefaults.set(
            weeklyPrimedAccounts.map(\.uuidString),
            forKey: Self.weeklyPersistKey
        )
        persistWeeklyPrimedResetAt()
    }

    private func unmarkWeeklyPrimed(_ id: UUID) {
        weeklyPrimedAccounts.remove(id)
        weeklyPrimedResetAt.removeValue(forKey: id)
        userDefaults.set(
            weeklyPrimedAccounts.map(\.uuidString),
            forKey: Self.weeklyPersistKey
        )
        persistWeeklyPrimedResetAt()
    }

    private func persistWeeklyPrimedResetAt() {
        let encoded = weeklyPrimedResetAt.reduce(into: [String: TimeInterval]()) { result, item in
            result[item.key.uuidString] = item.value.timeIntervalSince1970
        }
        userDefaults.set(encoded, forKey: Self.weeklyResetPersistKey)
    }

    private func isWeeklyPrimed(_ id: UUID, weekly: QuotaWindow) -> Bool {
        guard let primedResetAt = weeklyPrimedResetAt[id] else {
            return false
        }

        let windowSeconds = TimeInterval(weekly.durationSeconds)
        let resetTolerance = max(15 * 60, windowSeconds * 0.10)
        let sameResetWindow = abs(primedResetAt.timeIntervalSince(weekly.resetsAt)) < resetTolerance
        if !sameResetWindow {
            SwapLog.append(.debug(
                "WEEKLY_PRIME_RESET_CHANGED account=\(id.uuidString) old=\(Int(primedResetAt.timeIntervalSince1970)) new=\(Int(weekly.resetsAt.timeIntervalSince1970))"
            ))
        }
        return sameResetWindow
    }

    private static let fiveHourCooldown: TimeInterval = 4 * 3600 // 4 hours
    private static let ineffectiveFiveHourRetryCooldown: TimeInterval = 10 * 60
    private static let unstartedFiveHourWindowRatio = 0.995

    private func isFiveHourPrimed(_ id: UUID, window: QuotaWindow) -> Bool {
        guard let primedAt = fiveHourPrimedAt[id] else { return false }
        let age = Date().timeIntervalSince(primedAt)
        guard age < Self.fiveHourCooldown else { return false }
        if age >= Self.ineffectiveFiveHourRetryCooldown,
           fiveHourWindowStillLooksUnstarted(window) {
            let resetMinutes = max(0, Int(window.timeUntilReset / 60))
            logger.warning("5h prime marker still has full backend window after \(Int(age / 60))m; allowing retry")
            SwapLog.append(.debug("PRIME_STALE_RETRY account=\(id.uuidString) reset_mins=\(resetMinutes) age_mins=\(Int(age / 60))"))
            fiveHourPrimedAt.removeValue(forKey: id)
            persistFiveHourPrimedAt()
            return false
        }
        // Only allow re-priming after the cooldown unless the backend window
        // still looks unstarted after the retry grace period.
        return true
    }

    private func shouldThrottleFiveHourAttempt(_ id: UUID) -> Bool {
        guard let attemptedAt = fiveHourPrimeAttemptedAt[id] else { return false }
        return Date().timeIntervalSince(attemptedAt) < Self.ineffectiveFiveHourRetryCooldown
    }

    private func fiveHourWindowStillLooksUnstarted(_ window: QuotaWindow) -> Bool {
        window.looksLikeUnstartedFiveHourWindow(resetWindowRatio: Self.unstartedFiveHourWindowRatio)
    }

    func persistedFiveHourPrimedAt() -> [UUID: Date] {
        fiveHourPrimedAt.filter { Date().timeIntervalSince($0.value) < Self.fiveHourCooldown }
    }

    func persistedFiveHourPrimeAttemptedAt() -> [UUID: Date] {
        fiveHourPrimeAttemptedAt.filter {
            Date().timeIntervalSince($0.value) < Self.ineffectiveFiveHourRetryCooldown
        }
    }

    private func markFiveHourPrimed(_ id: UUID, at date: Date = Date()) {
        fiveHourPrimedAt[id] = date
        fiveHourPrimeAttemptedAt.removeValue(forKey: id)
        persistFiveHourPrimedAt()
        persistFiveHourPrimeAttemptedAt()
    }

    private func estimatedFiveHourStartedAt(from window: QuotaWindow, fallback: Date = Date()) -> Date {
        let windowSeconds = TimeInterval(window.durationSeconds)
        guard windowSeconds > 0 else { return fallback }
        let estimated = window.resetsAt.addingTimeInterval(-windowSeconds)
        return min(estimated, fallback)
    }

    private func persistFiveHourPrimedAt() {
        let encoded = fiveHourPrimedAt.reduce(into: [String: TimeInterval]()) { result, item in
            result[item.key.uuidString] = item.value.timeIntervalSince1970
        }
        userDefaults.set(encoded, forKey: Self.legacyFiveHourPersistKey)
    }

    private func markFiveHourPrimeAttempted(_ id: UUID) {
        fiveHourPrimeAttemptedAt[id] = Date()
        persistFiveHourPrimeAttemptedAt()
    }

    private func persistFiveHourPrimeAttemptedAt() {
        let encoded = fiveHourPrimeAttemptedAt.reduce(into: [String: TimeInterval]()) { result, item in
            result[item.key.uuidString] = item.value.timeIntervalSince1970
        }
        userDefaults.set(encoded, forKey: Self.legacyFiveHourAttemptPersistKey)
    }

    private func clearLegacyFiveHourTracking(_ id: UUID) {
        let removedPrimed = fiveHourPrimedAt.removeValue(forKey: id) != nil
        let removedAttempt = fiveHourPrimeAttemptedAt.removeValue(forKey: id) != nil
        guard removedPrimed || removedAttempt else { return }
        persistFiveHourPrimedAt()
        persistFiveHourPrimeAttemptedAt()
    }

    /// Check all accounts with a recognized window and prime idle full windows.
    /// Five-hour tracking and confirmation only run when that window is present.
    /// Safe to call frequently — skips already-primed and active accounts.
    func primeIfNeeded(
        accounts: [CodexAccount],
        accountProvider: @escaping @Sendable (UUID) async -> CodexAccount?
    ) async -> [PrimeResult] {
        var primeResults: [PrimeResult] = []

        for account in accounts {
            guard !account.isActive else { continue }
            guard !account.hasHardRuntimeBlock else { continue }
            guard let snapshot = account.realQuotaSnapshot,
                  !snapshot.isDenied,
                  !snapshot.policyWindows.isEmpty else { continue }

            let weekly = snapshot.weekly
            let fiveHour = snapshot.fiveHour
            if fiveHour == nil {
                clearLegacyFiveHourTracking(account.id)
            }
            let weeklyFull = weekly.map { !$0.isExhausted && $0.remainingPercent >= 99.5 } ?? false
            let fiveHourLooksUnstarted = fiveHour.map(fiveHourWindowStillLooksUnstarted) ?? false
            let fiveHourAlreadyStarted = fiveHour.map {
                !$0.isExhausted && !fiveHourLooksUnstarted
            } ?? false
            var observedFiveHourPrimed = false

            if fiveHourAlreadyStarted,
               let fiveHour,
               fiveHourPrimedAt[account.id] == nil {
                markFiveHourPrimed(
                    account.id,
                    at: estimatedFiveHourStartedAt(from: fiveHour)
                )
                observedFiveHourPrimed = true
            }

            // Clear weekly primed state once usage drops below 99%
            if weekly != nil, !weeklyFull { unmarkWeeklyPrimed(account.id) }

            // Determine if this account needs priming for either window
            let needsWeeklyPrime = weekly.map {
                weeklyFull
                    && !isWeeklyPrimed(account.id, weekly: $0)
                    && !weeklyPrimingInFlight.contains(account.id)
            } ?? false
            // 5h: only prime once per ~4 hour cooldown
            let needsFiveHourPrime = fiveHour.map {
                fiveHourLooksUnstarted
                    && !fiveHourPrimingInFlight.contains(account.id)
                    && !isFiveHourPrimed(account.id, window: $0)
                    && !shouldThrottleFiveHourAttempt(account.id)
            } ?? false

            guard needsWeeklyPrime || needsFiveHourPrime else {
                if observedFiveHourPrimed {
                    primeResults.append(PrimeResult(
                        accountId: account.id,
                        weeklyPrimed: false,
                        fiveHourPrimed: true,
                        fiveHourUnconfirmed: false
                    ))
                    SwapLog.append(.debug("PRIME_OBSERVED_STARTED email=\(account.email) windows=5h"))
                }
                continue
            }
            if needsWeeklyPrime { weeklyPrimingInFlight.insert(account.id) }
            if needsFiveHourPrime { fiveHourPrimingInFlight.insert(account.id) }
            defer {
                weeklyPrimingInFlight.remove(account.id)
                fiveHourPrimingInFlight.remove(account.id)
            }

            // Get fresh account (tokens may have been refreshed since snapshot)
            guard let freshAccount = await accountProvider(account.id) else { continue }
            guard !freshAccount.isActive,
                  !freshAccount.hasHardRuntimeBlock,
                  let freshSnapshot = freshAccount.realQuotaSnapshot,
                  !freshSnapshot.isDenied else { continue }
            let freshWeekly = freshSnapshot.weekly
            let freshFiveHour = freshSnapshot.fiveHour
            guard !needsWeeklyPrime || freshWeekly.map({
                !$0.isExhausted && $0.remainingPercent >= 99.5
            }) == true else { continue }
            guard !needsFiveHourPrime || freshFiveHour.map({
                fiveHourWindowStillLooksUnstarted($0)
            }) == true else { continue }

            let windows = [needsWeeklyPrime ? "weekly" : nil, needsFiveHourPrime ? "5h" : nil]
                .compactMap { $0 }.joined(separator: "+")
            logger.info("Priming \(windows) timer(s) for \(freshAccount.email, privacy: .private)")

            do {
                try await sendMinimalRequest(for: freshAccount)
                var weeklyPrimed = false
                var fiveHourPrimed = observedFiveHourPrimed
                var fiveHourUnconfirmed = false
                if needsWeeklyPrime, let freshWeekly {
                    markWeeklyPrimed(account.id, resetAt: freshWeekly.resetsAt)
                }
                weeklyPrimed = needsWeeklyPrime
                if needsFiveHourPrime {
                    markFiveHourPrimeAttempted(account.id)
                    if await confirmFiveHourPrimeStarted(for: freshAccount, previousSnapshot: snapshot) {
                        markFiveHourPrimed(account.id)
                        fiveHourPrimed = true
                    } else {
                        fiveHourUnconfirmed = true
                        SwapLog.append(.debug("PRIME_UNCONFIRMED email=\(freshAccount.email) windows=5h"))
                    }
                }
                primeResults.append(PrimeResult(
                    accountId: account.id,
                    weeklyPrimed: weeklyPrimed,
                    fiveHourPrimed: fiveHourPrimed,
                    fiveHourUnconfirmed: fiveHourUnconfirmed
                ))
                SwapLog.append(.debug(
                    "PRIME_REQUEST_ACCEPTED email=\(freshAccount.email) windows=\(windows) weekly_confirmed=\(weeklyPrimed) five_hour_confirmed=\(fiveHourPrimed)"
                ))
                logger.info("Primer request accepted for \(freshAccount.email, privacy: .private)")
            } catch PrimerError.tokenExpired {
                logger.warning("Token expired during priming for \(freshAccount.email, privacy: .private) — will retry after refresh")
            } catch {
                logger.error("Failed to prime \(freshAccount.email, privacy: .private): \(error.localizedDescription)")
                SwapLog.append(.debug("PRIME_FAILED email=\(freshAccount.email) windows=\(windows) error=\(error.localizedDescription) detail=\(lastErrorBody ?? "none")"))
            }
        }

        return primeResults
    }

    private func confirmFiveHourPrimeStarted(
        for account: CodexAccount,
        previousSnapshot: QuotaSnapshot
    ) async -> Bool {
        guard quotaSnapshotFetcher != nil || requestSender == nil else {
            return true
        }

        if confirmationDelay > 0 {
            try? await Task.sleep(for: .seconds(confirmationDelay))
        }

        do {
            let snapshot: QuotaSnapshot
            if let quotaSnapshotFetcher {
                snapshot = try await quotaSnapshotFetcher(account)
            } else {
                snapshot = try await fetchQuotaSnapshot(for: account)
            }
            guard let fiveHour = snapshot.fiveHour else { return false }
            return !fiveHourWindowStillLooksUnstarted(fiveHour)
        } catch {
            SwapLog.append(.debug("PRIME_CONFIRM_FAILED email=\(account.email) error=\(error.localizedDescription)"))
            guard let fiveHour = previousSnapshot.fiveHour else { return false }
            return !fiveHourWindowStillLooksUnstarted(fiveHour)
        }
    }

    /// Send a single minimal Codex API request using the account's tokens.
    /// This registers as Codex usage, starting the weekly rolling window.
    private func sendMinimalRequest(for account: CodexAccount) async throws {
        if let requestSender {
            try await requestSender(account)
            return
        }

        await NetworkBackoffGuard.shared.waitIfNeeded(operation: "primer:\(account.email)")

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
            "model": Self.defaultPrimerModel,
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let message = error.localizedDescription
            await NetworkBackoffGuard.shared.recordFailure(message, operation: "primer:\(account.email)")
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PrimerError.invalidResponse
        }

        switch httpResponse.statusCode {
        case let statusCode where Self.isAcceptedPrimerHTTPStatus(statusCode):
            await NetworkBackoffGuard.shared.recordSuccess(operation: "primer:\(account.email)")
            return // Success — usage registered
        case 401:
            await NetworkBackoffGuard.shared.recordFailure(
                "HTTP 401",
                operation: "primer:\(account.email)"
            )
            throw PrimerError.tokenExpired
        default:
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            lastErrorBody = String(body.prefix(500))
            await NetworkBackoffGuard.shared.recordFailure(
                "HTTP \(httpResponse.statusCode)",
                operation: "primer:\(account.email)"
            )
            logger.error("Primer HTTP \(httpResponse.statusCode) for \(account.email, privacy: .private): \(body.prefix(500), privacy: .private)")
            throw PrimerError.httpError(httpResponse.statusCode)
        }
    }

    private func fetchQuotaSnapshot(for account: CodexAccount) async throws -> QuotaSnapshot {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PrimerError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw PrimerError.httpError(httpResponse.statusCode)
        }
        return try UsageResponseParser.parse(data).snapshot
    }

    /// Clear priming state for an account (e.g., after resets and quota changes).
    func clearPrimedState(for accountId: UUID) {
        unmarkWeeklyPrimed(accountId)
        fiveHourPrimedAt.removeValue(forKey: accountId)
        fiveHourPrimeAttemptedAt.removeValue(forKey: accountId)
        persistFiveHourPrimedAt()
        persistFiveHourPrimeAttemptedAt()
    }

    func clearAll() {
        weeklyPrimedAccounts.removeAll()
        weeklyPrimedResetAt.removeAll()
        fiveHourPrimedAt.removeAll()
        fiveHourPrimeAttemptedAt.removeAll()
        userDefaults.removeObject(forKey: Self.weeklyPersistKey)
        userDefaults.removeObject(forKey: Self.weeklyResetPersistKey)
        userDefaults.removeObject(forKey: Self.legacyFiveHourPersistKey)
        userDefaults.removeObject(forKey: Self.legacyFiveHourAttemptPersistKey)
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
