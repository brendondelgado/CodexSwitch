import Foundation
import Testing
@testable import CodexSwitch

@Suite("Account host ownership presentation")
@MainActor
struct AccountHostOwnershipPresentationTests {
    @Test("Mac and VPS can report different runtime-current accounts")
    func simultaneousHostOwnershipIsVisible() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let mac = makeAccount(email: "mac@example.com", active: true)
        let vps = makeAccount(email: "vps@example.com")
        manager.accounts = [mac, vps]
        manager.publishActivationState(confirmedState(for: mac.id, at: now))
        manager.linuxDevboxStatus = readyStatus(
            activeEmail: vps.email,
            providerAccountId: vps.accountId
        )
        manager.applyLinuxDevboxAccountStates(
            [remoteState(email: vps.email, providerAccountId: vps.accountId, active: true)],
            observedAt: now
        )

        #expect(manager.runtimeCurrentAccount?.id == mac.id)
        #expect(manager.vpsRuntimePresentation(for: mac, now: now) == .notCurrent)
        #expect(manager.vpsRuntimePresentation(for: vps, now: now) == .current)
        let ownership = AccountCardView.hostOwnershipLabels(
            isConfigured: true,
            isRuntimeCurrent: true,
            vpsRuntimePresentation: .notCurrent
        )
        #expect(ownership.macConfigured == "Mac Configured")
        #expect(ownership.macRuntime == "Mac Runtime Current")
        #expect(ownership.vpsRuntime == "VPS Not Current")
        let vpsOwnership = AccountCardView.hostOwnershipLabels(
            isConfigured: false,
            isRuntimeCurrent: false,
            vpsRuntimePresentation: .current
        )
        #expect(vpsOwnership.macConfigured == "Mac Not Configured")
        #expect(vpsOwnership.macRuntime == "Mac Runtime Not Current")
        #expect(vpsOwnership.vpsRuntime == "VPS Runtime Current")
    }

    @Test("Stale or disconnected VPS evidence never remains current")
    func staleAndDisconnectedEvidenceFailClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let account = makeAccount(email: "remote@example.com")
        manager.accounts = [account]
        manager.linuxDevboxStatus = readyStatus(
            activeEmail: account.email,
            providerAccountId: account.accountId
        )
        manager.applyLinuxDevboxAccountStates(
            [remoteState(
                email: account.email,
                providerAccountId: account.accountId,
                active: true
            )],
            observedAt: now.addingTimeInterval(
                -AccountManager.vpsRuntimeEvidenceFreshnessInterval - 1
            )
        )

        #expect(manager.vpsRuntimePresentation(for: account, now: now) == .unknown)

        manager.linuxDevboxStatus = LinuxDevboxStatus(
            state: .failed,
            summary: "unreachable",
            activeEmail: nil
        )
        #expect(manager.vpsRuntimePresentation(for: account, now: now) == .disconnected)
    }

    @Test("Quota movement without explicit VPS active identity stays unknown")
    func quotaMovementDoesNotInferVPSOwnership() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let account = makeAccount(email: "quota@example.com")
        manager.accounts = [account]
        manager.linuxDevboxStatus = readyStatus(activeEmail: nil, providerAccountId: nil)
        manager.applyLinuxDevboxAccountStates(
            [remoteState(email: account.email, active: false, withQuota: true)],
            observedAt: now
        )

        #expect(manager.vpsRuntimePresentation(for: account, now: now) == .unknown)
    }

    @Test("Contradictory VPS status and account-state identity is unknown")
    func contradictoryRemoteIdentityFailsClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let account = makeAccount(email: "state-active@example.com")
        manager.accounts = [account]
        manager.linuxDevboxStatus = readyStatus(
            activeEmail: "status-active@example.com",
            providerAccountId: account.accountId
        )
        manager.applyLinuxDevboxAccountStates(
            [remoteState(
                email: account.email,
                providerAccountId: account.accountId,
                active: true
            )],
            observedAt: now
        )

        #expect(manager.vpsRuntimePresentation(for: account, now: now) == .unknown)
    }

    @Test("Missing VPS readiness identity cannot corroborate an active account state")
    func missingReadinessIdentityFailsClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let account = makeAccount(email: "state-active@example.com")
        manager.accounts = [account]
        manager.linuxDevboxStatus = readyStatus(activeEmail: nil, providerAccountId: nil)
        manager.applyLinuxDevboxAccountStates(
            [remoteState(
                email: account.email,
                providerAccountId: account.accountId,
                active: true
            )],
            observedAt: now
        )

        #expect(manager.vpsRuntimePresentation(for: account, now: now) == .unknown)
    }

    @Test("Readiness provider A plus account-state provider B remains unknown")
    func contradictoryProviderIdentityFailsClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let account = makeAccount(email: "state-active@example.com")
        manager.accounts = [account]
        manager.linuxDevboxStatus = readyStatus(
            activeEmail: account.email,
            providerAccountId: "provider-readiness-a"
        )
        manager.applyLinuxDevboxAccountStates(
            [remoteState(
                email: account.email,
                providerAccountId: "provider-state-b",
                active: true
            )],
            observedAt: now
        )

        #expect(manager.vpsRuntimePresentation(for: account, now: now) == .unknown)
    }

    @Test("Duplicate display emails cannot identify a VPS runtime owner")
    func duplicateEmailsFailClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let first = makeAccount(email: "duplicate@example.com")
        var second = makeAccount(email: "duplicate@example.com")
        second.accountId = "provider-duplicate-second"
        manager.accounts = [first, second]
        manager.linuxDevboxStatus = readyStatus(
            activeEmail: first.email,
            providerAccountId: first.accountId
        )
        manager.applyLinuxDevboxAccountStates(
            [remoteState(
                email: first.email,
                providerAccountId: first.accountId,
                active: true
            )],
            observedAt: now
        )

        #expect(manager.vpsRuntimePresentation(for: first, now: now) == .unknown)
        #expect(manager.vpsRuntimePresentation(for: second, now: now) == .unknown)
    }

    private func makeAccount(email: String, active: Bool = false) -> CodexAccount {
        CodexAccount(
            email: email,
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "provider-\(email)",
            isActive: active
        )
    }

    private func remoteState(
        email: String,
        providerAccountId: String? = nil,
        active: Bool,
        withQuota: Bool = false
    ) -> LinuxDevboxAccountState {
        LinuxDevboxAccountState(
            email: email,
            providerAccountId: providerAccountId ?? "provider-\(email)",
            isActive: active,
            quotaSnapshot: withQuota ? quotaSnapshot() : nil,
            planType: "plus",
            lastRefreshed: nil,
            subscriptionRenewsAt: nil,
            subscriptionExpiresAt: nil,
            subscriptionWillRenew: nil,
            hasActiveSubscription: true
        )
    }

    private func quotaSnapshot() -> QuotaSnapshot {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: 80,
                windowDurationMins: 300,
                resetsAt: now.addingTimeInterval(3_600)
            ),
            weekly: QuotaWindow(
                usedPercent: 50,
                windowDurationMins: 10_080,
                resetsAt: now.addingTimeInterval(86_400)
            ),
            fetchedAt: now
        )
    }

    private func readyStatus(
        activeEmail: String?,
        providerAccountId: String?
    ) -> LinuxDevboxStatus {
        LinuxDevboxStatus(
            state: .ready,
            summary: "fresh remote account state",
            activeEmail: activeEmail,
            activeProviderAccountId: providerAccountId
        )
    }

    private func confirmedState(for accountId: UUID, at now: Date) -> AccountActivationState {
        AccountActivationState(
            version: AccountActivationState.currentVersion,
            phase: .confirmed,
            activationGeneration: UUID(),
            configuredAccountId: accountId,
            runtimeCurrentAccountId: accountId,
            updatedAt: now,
            retryAttempt: 0,
            nextRetryAt: nil,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            detail: nil,
            runtimeEvidenceGeneration: UUID(),
            runtimeEvidenceObservedAt: .distantPast,
            runtimeEvidenceExpiresAt: .distantFuture
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "CodexSwitchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
