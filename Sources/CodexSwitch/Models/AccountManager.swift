import Foundation
import Observation

struct LinuxDevboxAccountApplyResult: Equatable {
    let activeChangedId: UUID?
    let stateChanged: Bool
}

private struct LinuxDevboxComparableState: Equatable {
    let quotaSnapshot: LinuxDevboxComparableQuotaSnapshot?
    let planType: String?
    let subscriptionRenewsAt: Date?
    let subscriptionExpiresAt: Date?
    let subscriptionWillRenew: Bool?
    let hasActiveSubscription: Bool?
    let runtimeUnusableUntil: Date?
    let runtimeUnusableReason: String?
    let isActive: Bool
}

private struct LinuxDevboxComparableQuotaSnapshot: Equatable {
    let fiveHour: LinuxDevboxComparableQuotaWindow
    let weekly: LinuxDevboxComparableQuotaWindow
}

private struct LinuxDevboxComparableQuotaWindow: Equatable {
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: Date
    let hardLimitReached: Bool
}

@MainActor @Observable
final class AccountManager {
    var accounts: [CodexAccount] = []
    var swapHistory: [SwapEvent] = []
    var pollingErrors: [UUID: String] = [:]
    var linuxDevboxStatus: LinuxDevboxStatus = .notConfigured
    var tokenSavingsSummary: CodexTokenSavingsSummary?
    var uiRefreshRevision: Int = 0

    private let userDefaults: UserDefaults
    private let authAccountIdProvider: @Sendable () async -> String?
    private let authFileWriter: @Sendable (CodexAccount) throws -> Void

    init(
        userDefaults: UserDefaults = .standard,
        authAccountIdProvider: @escaping @Sendable () async -> String? = {
            await AccountManager.readAuthJsonAccountId()
        },
        authFileWriter: @escaping @Sendable (CodexAccount) throws -> Void = {
            try SwapEngine.writeAuthFile(for: $0)
        }
    ) {
        self.userDefaults = userDefaults
        self.authAccountIdProvider = authAccountIdProvider
        self.authFileWriter = authFileWriter
    }

    var activeAccount: CodexAccount? {
        accounts.first(where: \.isActive)
    }

    func requestUIRefresh() {
        uiRefreshRevision &+= 1
    }

    var sortedAccounts: [CodexAccount] {
        accounts.sorted { a, b in
            let aImmediatelyUsable = SwapEngine.isImmediatelyUsable(a)
            let bImmediatelyUsable = SwapEngine.isImmediatelyUsable(b)
            if aImmediatelyUsable != bImmediatelyUsable {
                return aImmediatelyUsable
            }
            if a.isActive != b.isActive { return a.isActive }
            let aScore = SwapEngine.score(a)
            let bScore = SwapEngine.score(b)
            if aScore != bScore { return aScore > bScore }
            let aReset = a.realQuotaSnapshot?.fiveHour.timeUntilReset ?? .greatestFiniteMagnitude
            let bReset = b.realQuotaSnapshot?.fiveHour.timeUntilReset ?? .greatestFiniteMagnitude
            return aReset < bReset
        }
    }

    func updateQuota(for accountId: UUID, snapshot: QuotaSnapshot, planType: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        guard !snapshot.hasBackendUsagePlaceholder else {
            accounts[idx].planType = planType
            accounts[idx].hasActiveSubscription = Self.planHasActiveSubscription(planType)
            if accounts[idx].quotaSnapshot?.hasBackendUsagePlaceholder == true {
                accounts[idx].quotaSnapshot = nil
                accounts[idx].lastRefreshed = nil
            }
            SwapLog.append(.debug("PLACEHOLDER_QUOTA_IGNORED source=mac account=\(accounts[idx].email) fetched=\(Int(snapshot.fetchedAt.timeIntervalSince1970))"))
            return
        }
        accounts[idx].quotaSnapshot = snapshot
        accounts[idx].planType = planType
        accounts[idx].hasActiveSubscription = Self.planHasActiveSubscription(planType)
        accounts[idx].lastRefreshed = snapshot.fetchedAt
        accounts[idx].runtimeUnusableUntil = nil
        accounts[idx].runtimeUnusableReason = nil
        if Self.shouldClearStaleFiveHourPrimedMarker(
            primedAt: accounts[idx].fiveHourPrimedAt,
            snapshot: snapshot
        ) {
            accounts[idx].fiveHourPrimedAt = nil
            SwapLog.append(.debug("FIVE_HOUR_PRIME_MARKER_CLEARED account=\(accountId.uuidString) reason=backend_window_unstarted"))
        }
        pollingErrors[accountId] = nil // Clear error on success
    }

    private static func shouldClearStaleFiveHourPrimedMarker(
        primedAt: Date?,
        snapshot: QuotaSnapshot
    ) -> Bool {
        guard let primedAt else { return false }
        guard snapshot.fetchedAt >= primedAt else { return false }
        let windowSeconds = TimeInterval(snapshot.fiveHour.windowDurationMins * 60)
        guard windowSeconds > 0 else { return false }
        let resetAfterFetch = snapshot.fiveHour.resetsAt.timeIntervalSince(snapshot.fetchedAt)
        return snapshot.fiveHour.remainingPercent >= 99.5
            && resetAfterFetch >= windowSeconds * 0.995
    }

    private static func planHasActiveSubscription(_ planType: String) -> Bool {
        let normalized = planType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "", "free", "free_workspace", "guest", "unknown":
            return false
        default:
            return true
        }
    }

    func updateSubscriptionInfo(for accountId: UUID, info: SubscriptionInfo) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        accounts[idx].planType = info.planType ?? accounts[idx].planType
        accounts[idx].subscriptionRenewsAt = info.renewsAt
        accounts[idx].subscriptionExpiresAt = info.expiresAt
        accounts[idx].subscriptionWillRenew = info.willRenew
        accounts[idx].hasActiveSubscription = info.hasActiveSubscription
    }

    func markFiveHourPrimed(for accountId: UUID, at date: Date = Date()) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        accounts[idx].fiveHourPrimedAt = date
    }

    func clearFiveHourPrimed(for accountId: UUID, reason: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        guard accounts[idx].fiveHourPrimedAt != nil else { return }
        accounts[idx].fiveHourPrimedAt = nil
        SwapLog.append(.debug("FIVE_HOUR_PRIME_MARKER_CLEARED account=\(accountId.uuidString) reason=\(reason)"))
    }

    func updatePollingError(for accountId: UUID, error: String) {
        pollingErrors[accountId] = error
    }

    func clearPollingError(for accountId: UUID) {
        pollingErrors[accountId] = nil
    }

    func markRuntimeUnusable(for accountId: UUID, reason: String, until: Date) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        accounts[idx].runtimeUnusableReason = reason
        accounts[idx].runtimeUnusableUntil = until
        if accounts[idx].requiresReauthentication {
            pollingErrors[accountId] = "Re-authentication required"
        }
    }

    func clearRuntimeUnusable(for accountId: UUID) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        accounts[idx].runtimeUnusableReason = nil
        accounts[idx].runtimeUnusableUntil = nil
    }

    func setActive(_ accountId: UUID) {
        for i in accounts.indices {
            accounts[i].isActive = (accounts[i].id == accountId)
        }
        // Persist across restarts
        userDefaults.set(accountId.uuidString, forKey: "activeAccountId")
    }

    @discardableResult
    func setActiveByEmail(_ email: String) -> UUID? {
        guard let match = accounts.first(where: {
            $0.email.caseInsensitiveCompare(email) == .orderedSame
        }) else {
            return nil
        }
        if activeAccount?.id == match.id {
            return nil
        }
        setActive(match.id)
        return match.id
    }

    @discardableResult
    func applyLinuxDevboxAccountStates(
        _ states: [LinuxDevboxAccountState],
        mirrorRemoteActive: Bool = true
    ) -> UUID? {
        applyLinuxDevboxAccountStatesWithResult(states, mirrorRemoteActive: mirrorRemoteActive).activeChangedId
    }

    @discardableResult
    func applyLinuxDevboxAccountStatesWithResult(
        _ states: [LinuxDevboxAccountState],
        mirrorRemoteActive: Bool = true
    ) -> LinuxDevboxAccountApplyResult {
        var stateChanged = false

        for state in states {
            guard let idx = accounts.firstIndex(where: {
                $0.email.caseInsensitiveCompare(state.email) == .orderedSame
            }) else {
                continue
            }
            let before = linuxDevboxComparableState(for: accounts[idx])
            let hadPollingError = pollingErrors[accounts[idx].id] != nil
            var ignoredPlaceholderQuota = false

            if let quotaSnapshot = state.quotaSnapshot {
                let currentFetchedAt = accounts[idx].realQuotaSnapshot?.fetchedAt
                if quotaSnapshot.hasBackendUsagePlaceholder {
                    ignoredPlaceholderQuota = true
                    if accounts[idx].quotaSnapshot?.hasBackendUsagePlaceholder == true {
                        accounts[idx].quotaSnapshot = nil
                        accounts[idx].lastRefreshed = nil
                    }
                    SwapLog.append(.debug("PLACEHOLDER_QUOTA_IGNORED source=linux-devbox account=\(accounts[idx].email) fetched=\(Int(quotaSnapshot.fetchedAt.timeIntervalSince1970))"))
                } else if currentFetchedAt == nil || quotaSnapshot.fetchedAt >= currentFetchedAt! {
                    accounts[idx].quotaSnapshot = quotaSnapshot
                    accounts[idx].lastRefreshed = state.lastRefreshed ?? quotaSnapshot.fetchedAt
                    pollingErrors[accounts[idx].id] = nil
                }
            }
            if let planType = state.planType {
                accounts[idx].planType = planType
            }
            if !ignoredPlaceholderQuota,
               let lastRefreshed = state.lastRefreshed,
               accounts[idx].lastRefreshed == nil || lastRefreshed >= accounts[idx].lastRefreshed! {
                accounts[idx].lastRefreshed = lastRefreshed
            }
            if let subscriptionRenewsAt = state.subscriptionRenewsAt {
                accounts[idx].subscriptionRenewsAt = subscriptionRenewsAt
            }
            if let subscriptionExpiresAt = state.subscriptionExpiresAt {
                accounts[idx].subscriptionExpiresAt = subscriptionExpiresAt
            }
            if let subscriptionWillRenew = state.subscriptionWillRenew {
                accounts[idx].subscriptionWillRenew = subscriptionWillRenew
            }
            if let hasActiveSubscription = state.hasActiveSubscription {
                accounts[idx].hasActiveSubscription = hasActiveSubscription
            }
            if let runtimeUnusableUntil = state.runtimeUnusableUntil,
               Self.shouldApplyRemoteRuntimeBlock(
                    local: accounts[idx],
                    remoteUntil: runtimeUnusableUntil,
                    remoteReason: state.runtimeUnusableReason,
                    remoteLastRefreshed: state.lastRefreshed
               ) {
                accounts[idx].runtimeUnusableUntil = runtimeUnusableUntil
                accounts[idx].runtimeUnusableReason = state.runtimeUnusableReason
            } else if state.runtimeUnusableUntil != nil {
                SwapLog.append(.debug("REMOTE_RUNTIME_BLOCK_IGNORED account=\(accounts[idx].email) reason=stale_remote_auth_state"))
            } else if state.quotaSnapshot != nil {
                accounts[idx].runtimeUnusableUntil = nil
                accounts[idx].runtimeUnusableReason = nil
            }
            if accounts[idx].requiresReauthentication {
                pollingErrors[accounts[idx].id] = "Re-authentication required"
            }

            if before != linuxDevboxComparableState(for: accounts[idx])
                || (hadPollingError && pollingErrors[accounts[idx].id] == nil) {
                stateChanged = true
            }
        }

        let activeChangedId = mirrorRemoteActive
            ? states.first(where: \.isActive).flatMap { setActiveByEmail($0.email) }
            : nil
        return LinuxDevboxAccountApplyResult(
            activeChangedId: activeChangedId,
            stateChanged: stateChanged || activeChangedId != nil
        )
    }

    static func shouldApplyRemoteRuntimeBlock(
        local: CodexAccount,
        remoteUntil: Date,
        remoteReason: String?,
        remoteLastRefreshed: Date?
    ) -> Bool {
        guard remoteUntil > Date() else { return true }
        guard Self.isAuthenticationRuntimeReason(remoteReason) else { return true }
        guard !local.requiresReauthentication,
              let localLastRefreshed = local.lastRefreshed else {
            return true
        }
        guard let remoteLastRefreshed else { return true }
        return remoteLastRefreshed >= localLastRefreshed.addingTimeInterval(-1)
    }

    private static func isAuthenticationRuntimeReason(_ reason: String?) -> Bool {
        guard let reason else { return false }
        let normalized = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return normalized.contains("token_expired")
            || normalized.contains("token_invalidated")
            || normalized.contains("refresh_token_reused")
            || normalized.contains("reauth")
            || normalized.contains("unauthorized")
            || normalized.contains("authentication")
    }

    private func linuxDevboxComparableState(for account: CodexAccount) -> LinuxDevboxComparableState {
        LinuxDevboxComparableState(
            quotaSnapshot: account.realQuotaSnapshot.map {
                LinuxDevboxComparableQuotaSnapshot(
                    fiveHour: LinuxDevboxComparableQuotaWindow(
                        usedPercent: $0.fiveHour.usedPercent,
                        windowDurationMins: $0.fiveHour.windowDurationMins,
                        resetsAt: $0.fiveHour.resetsAt,
                        hardLimitReached: $0.fiveHour.hardLimitReached
                    ),
                    weekly: LinuxDevboxComparableQuotaWindow(
                        usedPercent: $0.weekly.usedPercent,
                        windowDurationMins: $0.weekly.windowDurationMins,
                        resetsAt: $0.weekly.resetsAt,
                        hardLimitReached: $0.weekly.hardLimitReached
                    )
                )
            },
            planType: account.planType,
            subscriptionRenewsAt: account.subscriptionRenewsAt,
            subscriptionExpiresAt: account.subscriptionExpiresAt,
            subscriptionWillRenew: account.subscriptionWillRenew,
            hasActiveSubscription: account.hasActiveSubscription,
            runtimeUnusableUntil: account.runtimeUnusableUntil,
            runtimeUnusableReason: account.runtimeUnusableReason,
            isActive: account.isActive
        )
    }

    /// Restore the last active account after loading from Keychain.
    /// Priority: UserDefaults (CodexSwitch truth) → auth.json (CLI state) → first account.
    func restoreActiveAccount() async {
        if let stored = userDefaults.string(forKey: "activeAccountId"),
           let savedId = UUID(uuidString: stored),
           accounts.contains(where: { $0.id == savedId }) {
            setActive(savedId)
            if let active = activeAccount {
                try? authFileWriter(active)
            }
            return
        }

        if let authAccountId = await authAccountIdProvider(),
           let match = accounts.first(where: { $0.accountId == authAccountId }) {
            setActive(match.id)
            return
        }

        // 3. Last resort: first account
        if let first = accounts.first { setActive(first.id) }
    }

    /// Read the account_id from ~/.codex/auth.json using the shared AuthFile model.
    /// Runs on a detached task to avoid blocking MainActor with file I/O.
    private static func readAuthJsonAccountId() async -> String? {
        await Task.detached {
            let path = NSString("~/.codex/auth.json").expandingTildeInPath
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let authFile = try? JSONDecoder().decode(AuthFile.self, from: data) else {
                return nil
            }
            return authFile.tokens.accountId
        }.value
    }

    /// Sync active account with auth.json if it changed externally.
    /// Call periodically (e.g. every 5s) to detect CLI or manual changes.
    /// Returns the UUID of the newly active account if it changed, nil otherwise.
    @discardableResult
    func syncWithAuthJson() async -> UUID? {
        guard let authAccountId = await authAccountIdProvider() else { return nil }
        // Already in sync
        if activeAccount?.accountId == authAccountId { return nil }
        // Find matching account and switch
        if let match = accounts.first(where: { $0.accountId == authAccountId }) {
            setActive(match.id)
            return match.id
        }
        return nil
    }

    func addAccount(_ account: CodexAccount) {
        // Prevent duplicate by accountId (OpenAI account UUID)
        if let idx = accounts.firstIndex(where: { $0.accountId == account.accountId }) {
            accounts[idx].accessToken = account.accessToken
            accounts[idx].refreshToken = account.refreshToken
            accounts[idx].idToken = account.idToken
            accounts[idx].lastRefreshed = account.lastRefreshed
            accounts[idx].runtimeUnusableUntil = account.runtimeUnusableUntil
            accounts[idx].runtimeUnusableReason = account.runtimeUnusableReason
            if account.runtimeUnusableUntil == nil,
               account.runtimeUnusableReason == nil {
                pollingErrors[accounts[idx].id] = nil
            }
        } else {
            accounts.append(account)
        }
    }

    @discardableResult
    func refreshStoredTokens(from imported: CodexAccount) -> UUID? {
        guard let idx = accounts.firstIndex(where: {
            $0.accountId == imported.accountId || $0.email.caseInsensitiveCompare(imported.email) == .orderedSame
        }) else {
            return nil
        }
        let tokensChanged = accounts[idx].accessToken != imported.accessToken
            || accounts[idx].refreshToken != imported.refreshToken
            || accounts[idx].idToken != imported.idToken
            || accounts[idx].accountId != imported.accountId
        let hadRuntimeBlock = accounts[idx].runtimeUnusableUntil != nil
            || accounts[idx].runtimeUnusableReason != nil
            || pollingErrors[accounts[idx].id] != nil
        guard tokensChanged || hadRuntimeBlock else {
            return nil
        }

        accounts[idx].email = imported.email
        accounts[idx].accessToken = imported.accessToken
        accounts[idx].refreshToken = imported.refreshToken
        accounts[idx].idToken = imported.idToken
        accounts[idx].accountId = imported.accountId
        accounts[idx].lastRefreshed = imported.lastRefreshed ?? Date()
        accounts[idx].runtimeUnusableUntil = nil
        accounts[idx].runtimeUnusableReason = nil
        if accounts[idx].quotaSnapshot?.hasExpiredExhaustedWindow() == true {
            accounts[idx].quotaSnapshot = nil
        }
        pollingErrors[accounts[idx].id] = nil
        return accounts[idx].id
    }

    func recordSwap(_ event: SwapEvent) {
        swapHistory.append(event)
    }
}
