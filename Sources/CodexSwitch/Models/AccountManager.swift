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

    private let userDefaults: UserDefaults
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var configuredAccount: CodexAccount? {
        accounts.first(where: \.isActive)
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

    /// Restore only the configured selection after loading from storage.
    /// Credential persistence and runtime convergence are owned by AppDelegate's activation transaction.
    @discardableResult
    func restoreConfiguredAccount(
        observedProviderAccountId: String?
    ) -> ConfiguredAccountRecovery {
        let recovery = AccountActivationRecoveryCoordinator.configuredAccountRecovery(
            accounts: accounts,
            observedProviderAccountId: observedProviderAccountId
        )
        if case .recovered(let accountId) = recovery {
            setConfiguredAccount(accountId)
        } else {
            clearConfiguredAccount()
        }
        return recovery
    }

    /// One-shot startup hydration. It cannot overwrite an already configured in-memory store.
    @discardableResult
    func restorePersistedAccounts(_ persistedAccounts: [CodexAccount]) -> Bool {
        guard accounts.isEmpty else { return false }
        accounts = persistedAccounts
        return true
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

    @discardableResult
    func applyConfiguredCredentialMutation(
        _ account: CodexAccount,
        permit: AccountCredentialMutationPermit
    ) -> Bool {
        let targetAccountId = account.id
        guard permit.targetAccountId == targetAccountId,
              permit.authorizes(
                  state: activationState,
                  at: Date()
              ) else {
            return false
        }
        guard !accounts.contains(where: {
            $0.id != targetAccountId && $0.accountId == account.accountId
        }) else {
            return false
        }
        if let idx = accounts.firstIndex(where: { $0.id == targetAccountId }) {
            applyCredentialUpdate(account, at: idx)
            return true
        }
        accounts.append(account)
        return true
    }

    private func applyCredentialUpdate(_ account: CodexAccount, at index: Int) {
        accounts[index].email = account.email
        accounts[index].accountId = account.accountId
        accounts[index].accessToken = account.accessToken
        accounts[index].refreshToken = account.refreshToken
        accounts[index].idToken = account.idToken
        accounts[index].lastRefreshed = account.lastRefreshed ?? Date()
        accounts[index].rateLimitResetBank = account.rateLimitResetBank
            ?? accounts[index].rateLimitResetBank
        accounts[index].runtimeUnusableUntil = account.runtimeUnusableUntil
        accounts[index].runtimeUnusableReason = account.runtimeUnusableReason
        if accounts[index].quotaSnapshot?.hasExpiredExhaustedWindow() == true {
            accounts[index].quotaSnapshot = nil
        }
        if account.runtimeUnusableUntil == nil, account.runtimeUnusableReason == nil {
            pollingErrors[accounts[index].id] = nil
        }
    }

    func recordSwap(_ event: SwapEvent) {
        swapHistory.append(event)
    }
}
