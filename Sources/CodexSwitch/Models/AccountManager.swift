import Foundation
import Observation

struct LinuxDevboxAccountApplyResult: Equatable {
    let stateChanged: Bool
}

enum AccountCredentialUpsertResult: Equatable, Sendable {
    case inserted(UUID)
    case updated(UUID)
    case rejectedConfiguredAccount(UUID)
}

enum ConfiguredAccountRecovery: Equatable, Sendable {
    case recovered(UUID)
    case noConfiguredAccount
    case ambiguous
}

enum VPSRuntimeAccountPresentation: Equatable, Sendable {
    case current
    case notCurrent
    case unknown
    case disconnected
}

enum AccountHostConvergenceState: Equatable, Sendable {
    case converged
    case pending
    case degraded
    case unknown
    case unavailable
    case notConfigured
}

struct AccountHostConvergencePresentation: Equatable, Sendable {
    let mac: AccountHostConvergenceState
    let vps: AccountHostConvergenceState
}

@MainActor @Observable
final class AccountManager {
    var accounts: [CodexAccount] = []
    var swapHistory: [SwapEvent] = []
    var pollingErrors: [UUID: String] = [:]
    var linuxDevboxStatus: LinuxDevboxStatus = .notConfigured
    var linuxDevboxAccountStates: [LinuxDevboxAccountState] = []
    var linuxDevboxAccountStatesObservedAt: Date?
    var tokenSavingsSummary: CodexTokenSavingsSummary?
    var rateLimitResetPresentations: [UUID: RateLimitResetInventoryPresentation] = [:]
    var activationState: AccountActivationState?
    var activationNotice: String?
    var uiRefreshRevision: Int = 0
    private(set) var poolAuthorityObservation: PoolAuthorityObservation?
    private(set) var remoteAuthorityEndpointConfigured = false

    private let userDefaults: UserDefaults
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var configuredAccount: CodexAccount? {
        accounts.first(where: \.isActive)
    }

    var poolTargetAccount: CodexAccount? {
        if let providerAccountId = poolAuthorityObservation?
            .desiredProviderAccountId {
            let matches = accounts.filter {
                $0.normalizedProviderAccountId == providerAccountId
            }
            return matches.count == 1 ? matches[0] : nil
        }
        return remoteAuthorityEndpointConfigured ? nil : configuredAccount
    }

    func isPoolTarget(_ account: CodexAccount) -> Bool {
        poolTargetAccount?.id == account.id
    }

    func publishPoolAuthorityObservation(
        _ observation: PoolAuthorityObservation
    ) {
        guard poolAuthorityObservation.map({
            observation.epoch >= $0.epoch
        }) ?? true else {
            return
        }
        remoteAuthorityEndpointConfigured = true
        poolAuthorityObservation = observation
        uiRefreshRevision &+= 1
    }

    func publishRemoteAuthorityEndpointConfigured(_ configured: Bool) {
        guard remoteAuthorityEndpointConfigured != configured else { return }
        remoteAuthorityEndpointConfigured = configured
        uiRefreshRevision &+= 1
    }

    func clearPoolAuthorityObservation() {
        poolAuthorityObservation = nil
        uiRefreshRevision &+= 1
    }

    var runtimeCurrentAccount: CodexAccount? {
        guard let accountId = activationState?.runtimeCurrentAccountId,
              activationState?.runtimeIsCurrent(for: accountId) == true else {
            return nil
        }
        return accounts.first(where: { $0.id == accountId })
    }

    static let vpsRuntimeEvidenceFreshnessInterval =
        LinuxDevboxMonitor.activeRemoteAccountStatePollInterval * 4

    func vpsRuntimePresentation(
        for account: CodexAccount,
        now: Date = Date()
    ) -> VPSRuntimeAccountPresentation {
        guard linuxDevboxStatus.state == .ready else { return .disconnected }
        guard let observedAt = linuxDevboxAccountStatesObservedAt,
              now >= observedAt,
              now.timeIntervalSince(observedAt) <= Self.vpsRuntimeEvidenceFreshnessInterval else {
            return .unknown
        }
        let runtimeCurrent = linuxDevboxAccountStates.filter(\.isActive)
        guard runtimeCurrent.count == 1, let current = runtimeCurrent.first else {
            return .unknown
        }
        let localEmails = Dictionary(grouping: accounts) { $0.email.lowercased() }
        let remoteEmails = Dictionary(grouping: linuxDevboxAccountStates) {
            $0.email.lowercased()
        }
        guard localEmails.values.allSatisfy({ $0.count == 1 }),
              remoteEmails.values.allSatisfy({ $0.count == 1 }),
              let statusProviderId = Self.boundedRemoteProviderAccountId(
                  linuxDevboxStatus.activeProviderAccountId
              ),
              let currentProviderId = Self.boundedRemoteProviderAccountId(
                  current.providerAccountId
              ),
              statusProviderId == currentProviderId,
              linuxDevboxAccountStates.filter({
                  Self.boundedRemoteProviderAccountId($0.providerAccountId)
                    == currentProviderId
              }).count == 1,
              accounts.filter({ $0.accountId == currentProviderId }).count == 1,
              let statusActiveEmail = linuxDevboxStatus.activeEmail,
              statusActiveEmail.caseInsensitiveCompare(current.email) == .orderedSame else {
            return .unknown
        }
        return account.accountId == currentProviderId
            ? .current
            : .notCurrent
    }

    func hostConvergencePresentation(
        forPoolTarget account: CodexAccount,
        now: Date = Date()
    ) -> AccountHostConvergencePresentation {
        guard isPoolTarget(account) else {
            return AccountHostConvergencePresentation(mac: .unknown, vps: .unknown)
        }

        let mac: AccountHostConvergenceState
        if activationState?.runtimeIsCurrent(for: account.id, at: now) == true {
            mac = .converged
        } else if let activationState {
            if activationState.configuredAccountId != nil,
               activationState.configuredAccountId != account.id {
                mac = .degraded
            } else {
                switch activationState.phase {
                case .preparing:
                    mac = .pending
                case .committedDegraded, .manualReview, .confirmed:
                    mac = .degraded
                }
            }
        } else {
            mac = .pending
        }

        let vps: AccountHostConvergenceState
        if let authority = poolAuthorityObservation,
           authority.desiredProviderAccountId
            == account.normalizedProviderAccountId {
            switch linuxDevboxStatus.state {
            case .ready where authority.isFresh(at: now):
                let readyProvider = Self.boundedRemoteProviderAccountId(
                    linuxDevboxStatus.activeProviderAccountId
                )
                if readyProvider == authority.desiredProviderAccountId {
                    switch authority.phase {
                    case .stable:
                        vps = .converged
                    case .converging:
                        vps = .pending
                    case .degraded:
                        vps = .degraded
                    }
                } else if readyProvider == nil {
                    vps = .unknown
                } else {
                    vps = .degraded
                }
            case .notReady, .failed, .stale:
                vps = .unavailable
            case .ready, .checking, .notConfigured:
                vps = .unknown
            }
        } else {
            switch linuxDevboxStatus.state {
            case .notConfigured:
                vps = .notConfigured
            case .checking:
                vps = .pending
            case .notReady, .failed, .stale:
                vps = .unavailable
            case .ready:
                switch vpsRuntimePresentation(for: account, now: now) {
                case .current:
                    vps = .converged
                case .notCurrent:
                    vps = .degraded
                case .unknown:
                    vps = .unknown
                case .disconnected:
                    vps = .unavailable
                }
            }
        }

        return AccountHostConvergencePresentation(mac: mac, vps: vps)
    }

    private static func boundedRemoteProviderAccountId(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.lengthOfBytes(using: .utf8)
                <= LinuxDevboxMonitor.maximumRemoteProviderAccountIdBytes,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 32 && scalar.value != 127
              }) else {
            return nil
        }
        return value
    }

    func invalidateLinuxDevboxRuntimeEvidence() {
        linuxDevboxAccountStatesObservedAt = nil
    }

    func publishActivationState(_ state: AccountActivationState?) {
        activationState = state
        activationNotice = nil
    }

    func publishActivationNotice(_ notice: String?) {
        activationNotice = notice
    }

    func requestUIRefresh() {
        uiRefreshRevision &+= 1
    }

    func publishRateLimitResetPresentations(
        _ presentations: [UUID: RateLimitResetInventoryPresentation]
    ) {
        guard presentations != rateLimitResetPresentations else { return }
        rateLimitResetPresentations = presentations
    }

    var sortedAccounts: [CodexAccount] {
        let now = Date()
        return accounts.sorted { a, b in
            let aIsPoolTarget = isPoolTarget(a)
            let bIsPoolTarget = isPoolTarget(b)
            if aIsPoolTarget != bIsPoolTarget { return aIsPoolTarget }
            if a.isActive != b.isActive { return a.isActive }
            let aImmediatelyUsable = SwapEngine.isImmediatelyUsable(a, now: now)
            let bImmediatelyUsable = SwapEngine.isImmediatelyUsable(b, now: now)
            if aImmediatelyUsable != bImmediatelyUsable {
                return aImmediatelyUsable
            }
            let aScore = SwapEngine.score(a, now: now)
            let bScore = SwapEngine.score(b, now: now)
            if aScore != bScore { return aScore > bScore }
            let aReset = a.realQuotaSnapshot?.mostUrgentWindow?.timeUntilReset ?? .greatestFiniteMagnitude
            let bReset = b.realQuotaSnapshot?.mostUrgentWindow?.timeUntilReset ?? .greatestFiniteMagnitude
            return aReset < bReset
        }
    }

    func updateQuota(for accountId: UUID, snapshot: QuotaSnapshot, planType: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        if let current = accounts[idx].quotaSnapshot,
           snapshot.fetchedAt < current.fetchedAt {
            SwapLog.append(.debug(
                "STALE_QUOTA_IGNORED account=\(accounts[idx].email) current=\(Int(current.fetchedAt.timeIntervalSince1970)) candidate=\(Int(snapshot.fetchedAt.timeIntervalSince1970))"
            ))
            return
        }
        let hadReauthenticationBlock = accounts[idx].requiresReauthentication
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
        if !hadReauthenticationBlock {
            accounts[idx].runtimeUnusableUntil = nil
            accounts[idx].runtimeUnusableReason = nil
        }
        if Self.shouldClearStaleFiveHourPrimedMarker(
            primedAt: accounts[idx].fiveHourPrimedAt,
            snapshot: snapshot
        ) {
            accounts[idx].fiveHourPrimedAt = nil
            SwapLog.append(.debug("FIVE_HOUR_PRIME_MARKER_CLEARED account=\(accountId.uuidString) reason=backend_window_unstarted"))
        }
        if hadReauthenticationBlock {
            pollingErrors[accountId] = "Re-authentication required"
        } else {
            pollingErrors[accountId] = nil // Clear error on success
        }
    }

    private static func shouldClearStaleFiveHourPrimedMarker(
        primedAt: Date?,
        snapshot: QuotaSnapshot
    ) -> Bool {
        guard let primedAt else { return false }
        guard snapshot.fetchedAt >= primedAt else { return false }
        guard let fiveHour = snapshot.fiveHour else { return true }
        return fiveHour.looksLikeUnstartedFiveHourWindow(referenceDate: snapshot.fetchedAt)
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

    func updateRateLimitResetBank(for accountId: UUID, bank: RateLimitResetBank) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        guard (accounts[idx].rateLimitResetBank?.fetchedAt ?? .distantPast) <= bank.fetchedAt else { return }
        accounts[idx].rateLimitResetBank = bank
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

    func setConfiguredAccount(_ accountId: UUID) {
        for i in accounts.indices {
            accounts[i].isActive = (accounts[i].id == accountId)
        }
        // Persist across restarts
        userDefaults.set(accountId.uuidString, forKey: "activeAccountId")
    }

    func clearConfiguredAccount() {
        for index in accounts.indices {
            accounts[index].isActive = false
        }
        userDefaults.removeObject(forKey: "activeAccountId")
    }

    func accountId(matchingEmail email: String) -> UUID? {
        accounts.first(where: {
            $0.email.caseInsensitiveCompare(email) == .orderedSame
        })?.id
    }

    @discardableResult
    func applyLinuxDevboxAccountStates(
        _ states: [LinuxDevboxAccountState],
        observedAt: Date = Date()
    ) -> LinuxDevboxAccountApplyResult {
        let presentationStates = states.sorted {
            $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending
        }
        let stateChanged = presentationStates != linuxDevboxAccountStates
        linuxDevboxAccountStates = presentationStates
        linuxDevboxAccountStatesObservedAt = observedAt
        return LinuxDevboxAccountApplyResult(stateChanged: stateChanged)
    }

    /// One-shot startup hydration. It cannot overwrite an already configured in-memory store.
    @discardableResult
    func restorePersistedAccounts(_ persistedAccounts: [CodexAccount]) -> Bool {
        guard accounts.isEmpty else { return false }
        accounts = persistedAccounts
        return true
    }

    @discardableResult
    func adoptVerifiedExternalHandoff(
        _ persistedAccounts: [CodexAccount],
        targetAccountId: UUID
    ) -> Bool {
        guard persistedAccounts.filter(\.isActive).map(\.id) == [targetAccountId],
              persistedAccounts.contains(where: { $0.id == targetAccountId }) else {
            return false
        }
        accounts = persistedAccounts
        userDefaults.set(targetAccountId.uuidString, forKey: "activeAccountId")
        return true
    }

    @discardableResult
    func adoptVerifiedCommittedCredentialHandoff(
        _ persistedAccounts: [CodexAccount],
        expectedCredentialAuthority: [CodexAccount],
        targetAccountId: UUID
    ) -> Bool {
        guard let merged = Self.committedCredentialHandoffSnapshot(
            persistedAccounts,
            preservingTelemetryFrom: accounts,
            expectedCredentialAuthority: expectedCredentialAuthority,
            targetAccountId: targetAccountId
        ) else {
            return false
        }
        accounts = merged
        userDefaults.set(targetAccountId.uuidString, forKey: "activeAccountId")
        return true
    }

    nonisolated static func committedCredentialHandoffSnapshot(
        _ persistedAccounts: [CodexAccount],
        preservingTelemetryFrom currentAccounts: [CodexAccount],
        expectedCredentialAuthority: [CodexAccount],
        targetAccountId: UUID
    ) -> [CodexAccount]? {
        guard persistedAccounts.filter(\.isActive).map(\.id) == [targetAccountId],
              currentAccounts.count == expectedCredentialAuthority.count else {
            return nil
        }

        var currentById: [UUID: CodexAccount] = [:]
        var expectedById: [UUID: CodexAccount] = [:]
        var persistedIds: Set<UUID> = []
        for account in currentAccounts {
            guard currentById.updateValue(account, forKey: account.id) == nil else {
                return nil
            }
        }
        for account in expectedCredentialAuthority {
            guard expectedById.updateValue(account, forKey: account.id) == nil else {
                return nil
            }
        }
        for account in persistedAccounts {
            guard persistedIds.insert(account.id).inserted else { return nil }
        }

        let expectedIds = Set(expectedById.keys)
        guard Set(currentById.keys) == expectedIds else { return nil }
        let insertsTarget = !expectedIds.contains(targetAccountId)
        let committedIds = insertsTarget
            ? expectedIds.union([targetAccountId])
            : expectedIds
        guard persistedIds == committedIds else { return nil }

        return try? persistedAccounts.map { persisted in
            guard let expected = expectedById[persisted.id] else {
                guard insertsTarget, persisted.id == targetAccountId else {
                    throw CommittedCredentialHandoffError.credentialDrift
                }
                return persisted
            }
            guard let current = currentById[persisted.id],
                  current.accountId == expected.accountId,
                  current.accessToken == expected.accessToken,
                  current.refreshToken == expected.refreshToken,
                  current.idToken == expected.idToken,
                  current.isActive == expected.isActive else {
                throw CommittedCredentialHandoffError.credentialDrift
            }

            var merged = persisted
            if current.quotaSnapshot != expected.quotaSnapshot
                || current.planType != expected.planType
                || current.lastRefreshed != expected.lastRefreshed
                || current.subscriptionRenewsAt != expected.subscriptionRenewsAt
                || current.subscriptionExpiresAt != expected.subscriptionExpiresAt
                || current.subscriptionWillRenew != expected.subscriptionWillRenew
                || current.hasActiveSubscription != expected.hasActiveSubscription {
                merged.quotaSnapshot = current.quotaSnapshot
                merged.planType = current.planType
                merged.lastRefreshed = current.lastRefreshed
                merged.subscriptionRenewsAt = current.subscriptionRenewsAt
                merged.subscriptionExpiresAt = current.subscriptionExpiresAt
                merged.subscriptionWillRenew = current.subscriptionWillRenew
                merged.hasActiveSubscription = current.hasActiveSubscription
            }
            if current.fiveHourPrimedAt != expected.fiveHourPrimedAt {
                merged.fiveHourPrimedAt = current.fiveHourPrimedAt
            }
            if current.rateLimitResetBank != expected.rateLimitResetBank {
                merged.rateLimitResetBank = current.rateLimitResetBank
            }
            if current.runtimeUnusableUntil != expected.runtimeUnusableUntil
                || current.runtimeUnusableReason != expected.runtimeUnusableReason {
                merged.runtimeUnusableUntil = current.runtimeUnusableUntil
                merged.runtimeUnusableReason = current.runtimeUnusableReason
            }
            return merged
        }
    }

    /// Inserts a new identity only. Existing identities, including the configured one, are immutable here.
    @discardableResult
    func addAccount(_ account: CodexAccount) -> Bool {
        guard !accounts.contains(where: {
            $0.id == account.id || $0.accountId == account.accountId
        }) else {
            return false
        }
        var inserted = account
        inserted.isActive = false
        accounts.append(inserted)
        return true
    }

    @discardableResult
    func upsertInactiveAccount(_ imported: CodexAccount) -> AccountCredentialUpsertResult {
        let protectedAccountId = activationState?.configuredAccountId
        if imported.id == protectedAccountId {
            return .rejectedConfiguredAccount(imported.id)
        }
        guard let idx = accounts.firstIndex(where: {
            $0.id == imported.id
                || $0.accountId == imported.accountId
        }) else {
            var inactive = imported
            inactive.isActive = false
            accounts.append(inactive)
            return .inserted(inactive.id)
        }
        guard !accounts[idx].isActive,
              accounts[idx].id != protectedAccountId else {
            return .rejectedConfiguredAccount(accounts[idx].id)
        }
        applyCredentialUpdate(imported, at: idx)
        pollingErrors[accounts[idx].id] = nil
        return .updated(accounts[idx].id)
    }

    nonisolated static func configuredCredentialSnapshot(
        from accounts: [CodexAccount],
        applying account: CodexAccount,
        at date: Date = Date()
    ) -> [CodexAccount]? {
        let targetAccountId = account.id
        guard !accounts.contains(where: {
            $0.id != targetAccountId && $0.accountId == account.accountId
        }) else {
            return nil
        }
        var snapshot = accounts
        if let index = snapshot.firstIndex(where: { $0.id == targetAccountId }) {
            snapshot[index] = credentialUpdatedAccount(
                snapshot[index],
                from: account,
                at: date
            )
        } else {
            snapshot.append(account)
        }
        for index in snapshot.indices {
            snapshot[index].isActive = snapshot[index].id == targetAccountId
        }
        return snapshot
    }

    private func applyCredentialUpdate(_ account: CodexAccount, at index: Int) {
        accounts[index] = Self.credentialUpdatedAccount(
            accounts[index],
            from: account,
            at: Date()
        )
        if account.runtimeUnusableUntil == nil, account.runtimeUnusableReason == nil {
            pollingErrors[accounts[index].id] = nil
        }
    }

    nonisolated private static func credentialUpdatedAccount(
        _ existing: CodexAccount,
        from account: CodexAccount,
        at date: Date
    ) -> CodexAccount {
        var updated = existing
        updated.email = account.email
        updated.accountId = account.accountId
        updated.accessToken = account.accessToken
        updated.refreshToken = account.refreshToken
        updated.idToken = account.idToken
        updated.lastRefreshed = account.lastRefreshed ?? date
        updated.rateLimitResetBank = account.rateLimitResetBank
            ?? existing.rateLimitResetBank
        updated.runtimeUnusableUntil = account.runtimeUnusableUntil
        updated.runtimeUnusableReason = account.runtimeUnusableReason
        if updated.quotaSnapshot?.hasExpiredExhaustedWindow(now: date) == true {
            updated.quotaSnapshot = nil
        }
        return updated
    }

    private enum CommittedCredentialHandoffError: Error {
        case credentialDrift
    }

    func recordSwap(_ event: SwapEvent) {
        swapHistory.append(event)
    }
}
