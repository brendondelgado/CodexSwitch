import Foundation
import Observation

struct LinuxDevboxAccountApplyResult: Equatable {
    let stateChanged: Bool
}

enum AccountCredentialUpsertResult: Equatable, Sendable {
    case inserted(UUID)
    case updated(UUID)
    case rejectedConfiguredAccount(UUID)
    case rejectedInvalidProviderIdentity(UUID)
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

/// Mac runtime state for the account whose credentials are committed on the
/// Mac (`~/.codex/auth.json`).
enum MacCredentialRuntimeState: Equatable, Sendable {
    case confirmed
    case activating
    case restartRequired
    case configuredOnly
    case manualReview
    case unconfirmed
}

/// The one read model behind every Mac presentation surface: menu-bar ring,
/// tooltip, popover header, cards, and the current-account section.
///
/// "Current" is the account whose credentials are committed on the Mac, which
/// is what local Codex runtimes draw from. The VPS pool target is shown
/// separately, and only when it differs from the current account or is not
/// freshly verified, so an exhausted previous account is never presented as
/// current after `auth.json` was committed to another account.
struct AccountDisplayReadModel: Equatable, Sendable {
    let currentAccountId: UUID?
    let currentEmail: String?
    let currentIsAmbiguous: Bool
    let macRuntime: MacCredentialRuntimeState
    let poolTargetAccountId: UUID?
    let poolTargetEmail: String?
    let poolTargetFreshness: ActiveAccountAuthorityFreshness
    let poolTargetObservedAt: Date?
    let unmanagedRuntimes: [CodexUnmanagedRuntime]
    let now: Date

    var showsPoolTargetSeparately: Bool {
        poolTargetFreshness != .current || poolTargetAccountId != currentAccountId
    }

    var poolTargetNote: String? {
        guard showsPoolTargetSeparately else { return nil }
        switch poolTargetFreshness {
        case .unavailable:
            return "VPS target unavailable"
        case .current:
            return "VPS target: \(poolTargetEmail ?? "unknown account")"
        case .stale:
            let name = poolTargetEmail ?? "unknown account"
            guard let poolTargetObservedAt else {
                return "VPS target: \(name) (stale)"
            }
            let age = now.timeIntervalSince(poolTargetObservedAt)
            if age > PoolAuthorityObservation.maximumFreshnessAge {
                return "VPS target: \(name) (stale \(Self.compactAge(age)))"
            }
            return "VPS target: \(name) (VPS not verified)"
        }
    }

    var unmanagedRuntimeWarning: String? {
        guard let first = unmanagedRuntimes.first else { return nil }
        let more = unmanagedRuntimes.count > 1
            ? " (+\(unmanagedRuntimes.count - 1) more)"
            : ""
        return "Unmanaged Codex runtime pid \(first.pid) (\(first.host): \(first.command)) "
            + "is still using the previous account — restart it to switch\(more)"
    }

    static func compactAge(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }
}

@MainActor @Observable
final class AccountManager {
    var accounts: [CodexAccount] = []
    var swapHistory: [SwapEvent] = []
    var pollingErrors: [UUID: String] = [:]
    var linuxDevboxStatus: LinuxDevboxStatus = .notConfigured
    var linuxDevboxAccountStates: [LinuxDevboxAccountState] = []
    var linuxDevboxAccountStatesObservedAt: Date?
    private(set) var linuxDevboxResetObservation: LinuxDevboxResetObservation?
    var tokenSavingsSummary: CodexTokenSavingsSummary?
    var rateLimitResetPresentations: [UUID: RateLimitResetInventoryPresentation] = [:]
    var activationState: AccountActivationState?
    var activationNotice: String?
    var uiRefreshRevision: Int = 0
    private(set) var poolAuthorityObservation: PoolAuthorityObservation?
    private(set) var unmanagedRuntimeWarnings: [CodexUnmanagedRuntime] = []
    private(set) var remoteAuthorityEndpointConfigured = false
    private var retainedPoolAuthorityObservation: PoolAuthorityObservation?
    private var linuxDevboxTelemetryObservedAtByProviderAccountId: [String: Date] = [:]

    private let userDefaults: UserDefaults
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var configuredAccount: CodexAccount? {
        accounts.first(where: \.isActive)
    }

    func activeAccountReadModel(at now: Date = Date()) -> ActiveAccountReadModel {
        if let poolAuthorityObservation {
            let observed = ActiveAccountReadModel(
                lastObservation: poolAuthorityObservation,
                now: now
            )
            guard observed.freshness == .current,
                  remoteAuthorityEndpointConfigured,
                  linuxDevboxStatus.state == .ready else {
                return ActiveAccountReadModel(
                    providerAccountId: poolAuthorityObservation.desiredProviderAccountId,
                    epoch: poolAuthorityObservation.epoch,
                    freshness: .stale
                )
            }
            return observed
        }
        guard let retainedPoolAuthorityObservation else { return .unavailable }
        return ActiveAccountReadModel(
            providerAccountId: retainedPoolAuthorityObservation.desiredProviderAccountId,
            epoch: retainedPoolAuthorityObservation.epoch,
            freshness: .stale
        )
    }

    /// The account whose credentials are committed on the Mac. Contradictory
    /// local active flags fail closed to no current account.
    var macCommittedAccount: CodexAccount? {
        let active = accounts.filter(\.isActive)
        return active.count == 1 ? active[0] : nil
    }

    func displayReadModel(at now: Date = Date()) -> AccountDisplayReadModel {
        let readModel = activeAccountReadModel(at: now)
        let current = macCommittedAccount
        let poolTarget = logicalActiveAccount(using: readModel)
        let observation = poolAuthorityObservation ?? retainedPoolAuthorityObservation
        return AccountDisplayReadModel(
            currentAccountId: current?.id,
            currentEmail: current?.email,
            currentIsAmbiguous: current == nil
                && accounts.filter(\.isActive).count > 1,
            macRuntime: current.map {
                Self.macCredentialRuntimeState(
                    activationState,
                    accountId: $0.id,
                    now: now
                )
            } ?? .unconfirmed,
            poolTargetAccountId: poolTarget?.id,
            poolTargetEmail: poolTarget?.email,
            poolTargetFreshness: readModel.freshness,
            poolTargetObservedAt: readModel.freshness == .unavailable
                ? nil
                : observation?.observedAt,
            unmanagedRuntimes: unmanagedRuntimeWarnings,
            now: now
        )
    }

    nonisolated static func macCredentialRuntimeState(
        _ state: AccountActivationState?,
        accountId: UUID,
        now: Date
    ) -> MacCredentialRuntimeState {
        guard let state, state.configuredAccountId == accountId else {
            return .unconfirmed
        }
        if state.runtimeIsCurrent(for: accountId, at: now) {
            return .confirmed
        }
        switch state.phase {
        case .preparing:
            return .activating
        case .committedDegraded where state.detail == .noLocalRuntime:
            return .configuredOnly
        case .committedDegraded:
            return .restartRequired
        case .manualReview:
            return .manualReview
        case .confirmed:
            return .unconfirmed
        }
    }

    func logicalActiveAccount(
        using readModel: ActiveAccountReadModel
    ) -> CodexAccount? {
        guard let providerAccountId = readModel.providerAccountId else { return nil }
        let matches = accounts.filter {
            $0.normalizedProviderAccountId == providerAccountId
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func logicalActiveAccount(at now: Date = Date()) -> CodexAccount? {
        logicalActiveAccount(using: activeAccountReadModel(at: now))
    }

    var poolTargetAccount: CodexAccount? {
        logicalActiveAccount()
    }

    func isPoolTarget(
        _ account: CodexAccount,
        using readModel: ActiveAccountReadModel
    ) -> Bool {
        logicalActiveAccount(using: readModel)?.id == account.id
    }

    func isPoolTarget(_ account: CodexAccount, at now: Date = Date()) -> Bool {
        isPoolTarget(account, using: activeAccountReadModel(at: now))
    }

    func publishPoolAuthorityObservation(
        _ observation: PoolAuthorityObservation
    ) {
        let existing = poolAuthorityObservation ?? retainedPoolAuthorityObservation
        guard Self.authorityObservationCanReplace(
            existing: existing,
            with: observation
        ) else {
            return
        }
        remoteAuthorityEndpointConfigured = true
        poolAuthorityObservation = observation
        retainedPoolAuthorityObservation = observation
        uiRefreshRevision &+= 1
    }

    func publishRemoteAuthorityEndpointConfigured(_ configured: Bool) {
        guard remoteAuthorityEndpointConfigured != configured else { return }
        remoteAuthorityEndpointConfigured = configured
        uiRefreshRevision &+= 1
    }

    func clearPoolAuthorityObservation() {
        if let poolAuthorityObservation {
            retainedPoolAuthorityObservation = poolAuthorityObservation
        }
        poolAuthorityObservation = nil
        uiRefreshRevision &+= 1
    }

    private static func authorityObservationCanReplace(
        existing: PoolAuthorityObservation?,
        with candidate: PoolAuthorityObservation
    ) -> Bool {
        guard let existing else { return true }
        guard candidate.epoch >= existing.epoch else { return false }
        guard candidate.epoch == existing.epoch else { return true }
        guard candidate.desiredProviderAccountId
            == existing.desiredProviderAccountId,
              candidate.updatedAt >= existing.updatedAt else {
            return false
        }
        return candidate.updatedAt != existing.updatedAt
            || candidate.observedAt >= existing.observedAt
    }

    var runtimeCurrentAccount: CodexAccount? {
        guard let accountId = activationState?.runtimeCurrentAccountId,
              activationState?.runtimeIsCurrent(for: accountId) == true else {
            return nil
        }
        return accounts.first(where: { $0.id == accountId })
    }

    static let vpsRuntimeEvidenceFreshnessInterval =
        LinuxDevboxMonitor.readinessEvidenceFreshnessInterval

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

    func vpsReauthenticationNotice(
        for account: CodexAccount,
        now: Date = Date()
    ) -> String? {
        guard linuxDevboxStatus.state == .ready,
              let observedAt = linuxDevboxAccountStatesObservedAt,
              LinuxDevboxStatus.accountMirrorIsFresh(
                  observedAt: observedAt,
                  now: now,
                  maximumAge: Self.vpsRuntimeEvidenceFreshnessInterval
              ),
              let providerAccountId = account.normalizedProviderAccountId,
              accounts.filter({
                  $0.normalizedProviderAccountId == providerAccountId
              }).count == 1 else {
            return nil
        }

        let matchingStates = linuxDevboxAccountStates.filter {
            Self.canonicalRemoteProviderAccountId($0.providerAccountId)
                == providerAccountId
        }
        guard matchingStates.count == 1,
              let state = matchingStates.first,
              Self.hasValidRemoteRuntimeBlockState(state, now: now),
              CodexAccount.requiresReauthentication(
                  runtimeUnusableUntil: state.runtimeUnusableUntil,
                  runtimeUnusableReason: state.runtimeUnusableReason,
                  at: now
              ) else {
            return nil
        }
        return "VPS authentication requires reauthentication"
    }

    func hostConvergencePresentation(
        forPoolTarget account: CodexAccount,
        now: Date = Date()
    ) -> AccountHostConvergencePresentation {
        guard isPoolTarget(account, at: now) else {
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

    func publishLinuxDevboxResetObservation(_ observation: LinuxDevboxResetObservation?) {
        guard observation != linuxDevboxResetObservation else { return }
        linuxDevboxResetObservation = observation
    }

    func publishActivationState(_ state: AccountActivationState?) {
        activationState = state
        activationNotice = nil
    }

    func publishUnmanagedRuntimeWarnings(_ warnings: [CodexUnmanagedRuntime]) {
        guard warnings != unmanagedRuntimeWarnings else { return }
        unmanagedRuntimeWarnings = warnings
        uiRefreshRevision &+= 1
    }

    /// Unmanaged runtimes that started before `~/.codex/auth.json` was last
    /// written have not loaded the committed credentials. Runtimes started
    /// afterwards read the committed file at startup and need no warning.
    nonisolated static func unmanagedRuntimeWarnings(
        runtimes: [CodexUnmanagedRuntime],
        credentialsWrittenAt: Date?
    ) -> [CodexUnmanagedRuntime] {
        guard let credentialsWrittenAt else { return [] }
        return runtimes
            .filter { $0.startedAt < credentialsWrittenAt }
            .sorted { $0.pid < $1.pid }
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
        return sortedAccounts(using: displayReadModel(at: now), now: now)
    }

    func sortedAccounts(
        using displayModel: AccountDisplayReadModel,
        now: Date
    ) -> [CodexAccount] {
        sortedAccounts(currentAccountId: displayModel.currentAccountId, now: now)
    }

    func sortedAccounts(
        currentAccountId: UUID?,
        now: Date
    ) -> [CodexAccount] {
        return accounts.sorted { a, b in
            // Display tiers stay fixed even when a higher plan is unavailable.
            if a.planPriority != b.planPriority { return a.planPriority > b.planPriority }
            let aIsCurrent = currentAccountId != nil && a.id == currentAccountId
            let bIsCurrent = currentAccountId != nil && b.id == currentAccountId
            if aIsCurrent != bIsCurrent { return aIsCurrent }
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

    @discardableResult
    func updateQuota(
        forProviderAccountId providerAccountId: String,
        snapshot: QuotaSnapshot,
        planType: String
    ) -> UUID? {
        guard let idx = uniqueAccountIndex(forProviderAccountId: providerAccountId) else {
            return nil
        }
        let accountId = accounts[idx].id
        updateQuota(for: accountId, snapshot: snapshot, planType: planType)
        return accountId
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

    @discardableResult
    func updateRateLimitResetBank(
        forProviderAccountId providerAccountId: String,
        bank: RateLimitResetBank
    ) -> UUID? {
        guard bank.isStructurallyValidPersistenceObservation,
              let idx = uniqueAccountIndex(forProviderAccountId: providerAccountId) else {
            return nil
        }
        let retained = accounts[idx].rateLimitResetBank
        let preferred = RateLimitResetInventoryPersistencePolicy.newestValidBank(
            observed: bank,
            retained: retained
        )
        if preferred != retained {
            accounts[idx].rateLimitResetBank = preferred
        }
        return accounts[idx].id
    }

    func account(matchingProviderAccountId providerAccountId: String) -> CodexAccount? {
        guard let idx = uniqueAccountIndex(forProviderAccountId: providerAccountId) else {
            return nil
        }
        return accounts[idx]
    }

    private func uniqueAccountIndex(forProviderAccountId providerAccountId: String) -> Int? {
        guard let normalized = CodexAccount.normalizedProviderAccountId(providerAccountId) else {
            return nil
        }
        let matches = accounts.indices.filter {
            accounts[$0].normalizedProviderAccountId == normalized
        }
        return matches.count == 1 ? matches[0] : nil
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
        let telemetryChanged = projectAuthoritativeLinuxDevboxTelemetry(
            from: states,
            observedAt: observedAt
        )
        let stateChanged = presentationStates != linuxDevboxAccountStates
            || telemetryChanged
        linuxDevboxAccountStates = presentationStates
        linuxDevboxAccountStatesObservedAt = observedAt
        return LinuxDevboxAccountApplyResult(stateChanged: stateChanged)
    }

    /// Projects fresh VPS-owned telemetry without adopting remote credentials or selection state.
    @discardableResult
    func projectAuthoritativeLinuxDevboxTelemetry(
        from states: [LinuxDevboxAccountState],
        observedAt: Date,
        now: Date = Date()
    ) -> Bool {
        guard QuotaFreshnessPolicy.isFresh(fetchedAt: observedAt, now: now) else {
            return false
        }

        let remoteIdentities = states.map {
            Self.canonicalRemoteProviderAccountId($0.providerAccountId)
        }
        guard remoteIdentities.allSatisfy({ $0 != nil }) else { return false }
        let providerAccountIds = remoteIdentities.compactMap { $0 }
        guard Set(providerAccountIds).count == providerAccountIds.count else { return false }

        let localIdentities = accounts.map(\.normalizedProviderAccountId)
        guard localIdentities.allSatisfy({ $0 != nil }) else { return false }
        let localProviderAccountIds = localIdentities.compactMap { $0 }
        guard Set(localProviderAccountIds).count == localProviderAccountIds.count else {
            return false
        }
        let localIndexByProviderAccountId = Dictionary(
            uniqueKeysWithValues: zip(localProviderAccountIds, accounts.indices)
        )

        var projectedAccounts = accounts
        var projectedObservationDates = linuxDevboxTelemetryObservedAtByProviderAccountId
        var changed = false

        for (state, providerAccountId) in zip(states, providerAccountIds) {
            guard let index = localIndexByProviderAccountId[providerAccountId] else {
                continue
            }

            let current = projectedAccounts[index]
            var projected = current
            let advancesAccountObservation = observedAt
                > (projectedObservationDates[providerAccountId] ?? .distantPast)
            let acceptsNonResetTelemetry = advancesAccountObservation
                && Self.isValidAuthoritativeNonResetTelemetry(
                    state,
                    observedAt: observedAt,
                    now: now
                )

            if let quota = state.quotaSnapshot,
               acceptsNonResetTelemetry,
               quota.fetchedAt > (current.quotaSnapshot?.fetchedAt ?? .distantPast) {
                projected.quotaSnapshot = quota
                projected.lastRefreshed = max(
                    projected.lastRefreshed ?? .distantPast,
                    quota.fetchedAt
                )
            }

            if Self.hasSubscriptionTelemetry(state),
               acceptsNonResetTelemetry,
               let telemetryRefreshedAt = state.lastRefreshed,
               telemetryRefreshedAt > (current.lastRefreshed ?? .distantPast) {
                projected.planType = state.planType
                projected.subscriptionRenewsAt = state.subscriptionRenewsAt
                projected.subscriptionExpiresAt = state.subscriptionExpiresAt
                projected.subscriptionWillRenew = state.subscriptionWillRenew
                projected.hasActiveSubscription = state.hasActiveSubscription
                projected.lastRefreshed = max(
                    projected.lastRefreshed ?? .distantPast,
                    telemetryRefreshedAt
                )
            }

            if let bank = state.rateLimitResetBank,
               bank.fetchedAt <= observedAt,
               let preferredBank = RateLimitResetInventoryPersistencePolicy.newestValidBank(
                   observed: bank,
                   retained: current.rateLimitResetBank
               ),
               preferredBank != current.rateLimitResetBank {
                projected.rateLimitResetBank = preferredBank
            }

            if acceptsNonResetTelemetry {
                projected.runtimeUnusableUntil = state.runtimeUnusableUntil
                projected.runtimeUnusableReason = state.runtimeUnusableReason
            }

            if Self.telemetryDiffers(projected, from: current) {
                projectedAccounts[index] = projected
                changed = true
            }
            if advancesAccountObservation {
                projectedObservationDates[providerAccountId] = observedAt
            }
        }

        if changed {
            accounts = projectedAccounts
        }
        linuxDevboxTelemetryObservedAtByProviderAccountId = projectedObservationDates
        return changed
    }

    private static func canonicalRemoteProviderAccountId(_ value: String?) -> String? {
        guard let bounded = boundedRemoteProviderAccountId(value) else { return nil }
        let normalized = bounded
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func isValidAuthoritativeQuota(
        _ quota: QuotaSnapshot,
        observedAt: Date,
        now: Date
    ) -> Bool {
        quota.fetchedAt <= observedAt
            && quota.isFresh(at: now)
            && !quota.hasExpiredPolicyWindow(at: now)
            && !quota.hasBackendUsagePlaceholder
            && !quota.hasInvalidPolicyEvidence
            && (quota.isDenied || !quota.policyWindows.isEmpty)
    }

    private static func isValidAuthoritativeNonResetTelemetry(
        _ state: LinuxDevboxAccountState,
        observedAt: Date,
        now: Date
    ) -> Bool {
        if let quota = state.quotaSnapshot,
           !isValidAuthoritativeQuota(quota, observedAt: observedAt, now: now) {
            return false
        }
        if hasSubscriptionTelemetry(state),
           !hasValidAuthoritativeSubscriptionTelemetry(
               state,
               observedAt: observedAt,
               now: now
           ) {
            return false
        }
        return hasValidRemoteRuntimeBlockState(state, now: now)
    }

    private static func hasValidAuthoritativeSubscriptionTelemetry(
        _ state: LinuxDevboxAccountState,
        observedAt: Date,
        now: Date
    ) -> Bool {
        guard let refreshedAt = state.lastRefreshed else { return false }
        return refreshedAt <= observedAt
            && QuotaFreshnessPolicy.isFresh(fetchedAt: refreshedAt, now: now)
            && (state.planType.map {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? true)
            && [state.subscriptionRenewsAt, state.subscriptionExpiresAt]
                .compactMap { $0 }
                .allSatisfy { $0.timeIntervalSinceReferenceDate.isFinite }
    }

    private static func hasValidRemoteRuntimeBlockState(
        _ state: LinuxDevboxAccountState,
        now: Date
    ) -> Bool {
        switch (state.runtimeUnusableUntil, state.runtimeUnusableReason) {
        case (nil, nil):
            return true
        case let (until?, reason?):
            let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return until > now
                && until.timeIntervalSinceReferenceDate.isFinite
                && !normalizedReason.isEmpty
                && normalizedReason.lengthOfBytes(using: .utf8) <= 256
                && normalizedReason.unicodeScalars.allSatisfy({
                    $0.value >= 32 && $0.value != 127
                })
        default:
            return false
        }
    }

    private static func hasSubscriptionTelemetry(_ state: LinuxDevboxAccountState) -> Bool {
        state.planType != nil
            || state.subscriptionRenewsAt != nil
            || state.subscriptionExpiresAt != nil
            || state.subscriptionWillRenew != nil
            || state.hasActiveSubscription != nil
    }

    private static func telemetryDiffers(
        _ projected: CodexAccount,
        from current: CodexAccount
    ) -> Bool {
        projected.quotaSnapshot != current.quotaSnapshot
            || projected.planType != current.planType
            || projected.lastRefreshed != current.lastRefreshed
            || projected.subscriptionRenewsAt != current.subscriptionRenewsAt
            || projected.subscriptionExpiresAt != current.subscriptionExpiresAt
            || projected.subscriptionWillRenew != current.subscriptionWillRenew
            || projected.hasActiveSubscription != current.hasActiveSubscription
            || projected.rateLimitResetBank != current.rateLimitResetBank
            || projected.runtimeUnusableUntil != current.runtimeUnusableUntil
            || projected.runtimeUnusableReason != current.runtimeUnusableReason
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
              persistedAccounts.contains(where: { $0.id == targetAccountId }),
              let reconciled = RateLimitResetInventoryPersistencePolicy.reconciling(
                  persistedAccounts,
                  preservingFrom: accounts
              ) else {
            return false
        }
        accounts = reconciled
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

        guard let merged = try? persistedAccounts.map({ persisted in
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
            let inMemoryBank = RateLimitResetInventoryPersistencePolicy.newestValidBank(
                observed: current.rateLimitResetBank,
                retained: expected.rateLimitResetBank
            )
            merged.rateLimitResetBank = RateLimitResetInventoryPersistencePolicy.newestValidBank(
                observed: inMemoryBank,
                retained: persisted.rateLimitResetBank
            )
            if current.runtimeUnusableUntil != expected.runtimeUnusableUntil
                || current.runtimeUnusableReason != expected.runtimeUnusableReason {
                merged.runtimeUnusableUntil = current.runtimeUnusableUntil
                merged.runtimeUnusableReason = current.runtimeUnusableReason
            }
            return merged
        }) else {
            return nil
        }
        return merged
    }

    /// Inserts a new identity only. Existing identities, including the configured one, are immutable here.
    @discardableResult
    func addAccount(_ account: CodexAccount) -> Bool {
        guard let providerAccountId = account.normalizedProviderAccountId,
              !accounts.contains(where: {
            $0.id == account.id || $0.normalizedProviderAccountId == providerAccountId
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
        guard let importedProviderAccountId = imported.normalizedProviderAccountId else {
            return .rejectedInvalidProviderIdentity(imported.id)
        }
        guard let idx = accounts.firstIndex(where: {
            $0.id == imported.id
                || $0.normalizedProviderAccountId == importedProviderAccountId
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
        guard let providerAccountId = account.normalizedProviderAccountId,
              !accounts.contains(where: {
            $0.id != targetAccountId
                && $0.normalizedProviderAccountId == providerAccountId
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
        updated.rateLimitResetBank = RateLimitResetInventoryPersistencePolicy.newestValidBank(
            observed: account.rateLimitResetBank,
            retained: existing.rateLimitResetBank
        )
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
