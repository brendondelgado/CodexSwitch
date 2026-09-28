import Foundation
import Testing
@testable import CodexSwitch

@Suite("Pool target host convergence presentation")
@MainActor
struct AccountHostOwnershipPresentationTests {
    @Test("Host mismatches remain health details for one pool target")
    func hostMismatchDoesNotCreateTwoPoolTargets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let target = makeAccount(email: "target@example.com", active: true)
        let staleRuntime = makeAccount(email: "stale-runtime@example.com")
        manager.accounts = [target, staleRuntime]
        manager.publishActivationState(confirmedState(for: staleRuntime.id, at: now))
        manager.linuxDevboxStatus = readyStatus(
            activeEmail: staleRuntime.email,
            providerAccountId: staleRuntime.accountId
        )
        manager.applyLinuxDevboxAccountStates(
            [remoteState(
                email: staleRuntime.email,
                providerAccountId: staleRuntime.accountId,
                active: true
            )],
            observedAt: now
        )

        #expect(manager.configuredAccount?.id == target.id)
        #expect(manager.runtimeCurrentAccount?.id == staleRuntime.id)
        #expect(manager.isConfigured(target))
        #expect(!manager.isConfigured(staleRuntime))
        #expect(manager.accounts.filter { manager.isConfigured($0) }.count == 1)
        #expect(manager.vpsRuntimePresentation(for: staleRuntime, now: now) == .current)

        let convergence = manager.hostConvergencePresentation(
            forPoolTarget: target,
            now: now
        )
        #expect(convergence.mac == .degraded)
        #expect(convergence.vps == .degraded)
        #expect(PopoverContentView.macConvergenceLabel(for: convergence.mac)
            == "Mac convergence degraded")
        #expect(PopoverContentView.vpsConvergenceLabel(for: convergence.vps)
            == "VPS convergence degraded")
    }

    @Test("Matching host evidence converges the configured pool target")
    func matchingHostEvidenceConvergesPoolTarget() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let target = makeAccount(email: "target@example.com", active: true)
        manager.accounts = [target]
        manager.publishActivationState(confirmedState(for: target.id, at: now))
        manager.linuxDevboxStatus = readyStatus(
            activeEmail: target.email,
            providerAccountId: target.accountId
        )
        manager.applyLinuxDevboxAccountStates(
            [remoteState(
                email: target.email,
                providerAccountId: target.accountId,
                active: true
            )],
            observedAt: now
        )

        let convergence = manager.hostConvergencePresentation(
            forPoolTarget: target,
            now: now
        )
        #expect(convergence == AccountHostConvergencePresentation(
            mac: .converged,
            vps: .converged
        ))
        #expect(PopoverContentView.macConvergenceLabel(for: convergence.mac)
            == "Mac converged")
        #expect(PopoverContentView.vpsConvergenceLabel(for: convergence.vps)
            == "VPS converged")
    }

    @Test("Stale or disconnected VPS evidence never remains current")
    func staleAndDisconnectedEvidenceFailClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let account = makeAccount(email: "remote@example.com", active: true)
        manager.accounts = [account]
        manager.publishActivationState(confirmedState(for: account.id, at: now))
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

        #expect(manager.hostConvergencePresentation(
            forPoolTarget: account,
            now: now
        ).vps == .unknown)

        manager.linuxDevboxStatus = LinuxDevboxStatus(
            state: .failed,
            summary: "unreachable",
            activeEmail: nil
        )
        #expect(manager.hostConvergencePresentation(
            forPoolTarget: account,
            now: now
        ).vps == .unavailable)
    }

    @Test("Quota movement without explicit VPS active identity stays unknown")
    func quotaMovementDoesNotInferVPSOwnership() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let account = makeAccount(email: "quota@example.com", active: true)
        manager.accounts = [account]
        manager.linuxDevboxStatus = readyStatus(activeEmail: nil, providerAccountId: nil)
        manager.applyLinuxDevboxAccountStates(
            [remoteState(email: account.email, active: false, withQuota: true)],
            observedAt: now
        )

        #expect(manager.hostConvergencePresentation(
            forPoolTarget: account,
            now: now
        ).vps == .unknown)
    }

    @Test("Contradictory VPS status and account-state identity is unknown")
    func contradictoryRemoteIdentityFailsClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let account = makeAccount(email: "state-active@example.com", active: true)
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

        #expect(manager.hostConvergencePresentation(
            forPoolTarget: account,
            now: now
        ).vps == .unknown)
    }

    @Test("Missing VPS readiness identity cannot corroborate an active account state")
    func missingReadinessIdentityFailsClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let account = makeAccount(email: "state-active@example.com", active: true)
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

        #expect(manager.hostConvergencePresentation(
            forPoolTarget: account,
            now: now
        ).vps == .unknown)
    }

    @Test("Readiness provider A plus account-state provider B remains unknown")
    func contradictoryProviderIdentityFailsClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let account = makeAccount(email: "state-active@example.com", active: true)
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

        #expect(manager.hostConvergencePresentation(
            forPoolTarget: account,
            now: now
        ).vps == .unknown)
    }

    @Test("Duplicate display emails cannot identify a VPS runtime owner")
    func duplicateEmailsFailClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let first = makeAccount(email: "duplicate@example.com", active: true)
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

        #expect(manager.hostConvergencePresentation(
            forPoolTarget: first,
            now: now
        ).vps == .unknown)
        #expect(!manager.isConfigured(second))
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
