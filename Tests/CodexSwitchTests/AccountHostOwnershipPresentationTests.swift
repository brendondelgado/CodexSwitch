import Foundation
import Testing
@testable import CodexSwitch

@Suite("Pool target host convergence presentation")
@MainActor
struct AccountHostOwnershipPresentationTests {
    @Test("Authority target is highlighted before Mac adoption")
    func authorityTargetLeadsMacConvergence() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let mac = makeAccount(email: "mac-a@example.com", active: true)
        let authority = makeAccount(email: "authority-b@example.com")
        manager.accounts = [mac, authority]
        manager.publishActivationState(confirmedState(for: mac.id, at: now))
        manager.linuxDevboxStatus = readyStatus(
            activeEmail: authority.email,
            providerAccountId: authority.accountId
        )
        manager.publishPoolAuthorityObservation(try PoolAuthorityObservation(
            epoch: 9,
            phase: .stable,
            desiredProviderAccountId: authority.accountId,
            requestId: "99999999-9999-4999-8999-999999999999",
            reason: "manual",
            observedAt: now,
            updatedAt: now,
            previousProviderAccountId: mac.accountId,
            detail: nil
        ))

        #expect(manager.poolTargetAccount?.id == authority.id)
        #expect(manager.accounts.filter { manager.isPoolTarget($0) }.map(\.id)
            == [authority.id])
        #expect(manager.sortedAccounts.first?.id == authority.id)
        let convergence = manager.hostConvergencePresentation(
            forPoolTarget: authority,
            now: now
        )
        #expect(convergence.mac == .degraded)
        #expect(convergence.vps == .converged)
    }

    @Test("Stale or disconnected authority keeps target but fails host health closed")
    func staleAuthorityKeepsIdentityWithoutClaimingHealth() throws {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let now = observedAt.addingTimeInterval(
            PoolAuthorityObservation.maximumFreshnessAge + 1
        )
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let mac = makeAccount(email: "mac-a@example.com", active: true)
        let authority = makeAccount(email: "authority-b@example.com")
        manager.accounts = [mac, authority]
        manager.publishActivationState(confirmedState(for: mac.id, at: observedAt))
        manager.publishPoolAuthorityObservation(try PoolAuthorityObservation(
            epoch: 10,
            phase: .stable,
            desiredProviderAccountId: authority.accountId,
            requestId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            reason: "automatic",
            observedAt: observedAt,
            updatedAt: observedAt,
            previousProviderAccountId: mac.accountId,
            detail: nil
        ))
        manager.linuxDevboxStatus = readyStatus(
            activeEmail: authority.email,
            providerAccountId: authority.accountId
        )

        #expect(manager.isPoolTarget(authority))
        #expect(manager.hostConvergencePresentation(
            forPoolTarget: authority,
            now: now
        ).vps == .unknown)

        manager.linuxDevboxStatus = LinuxDevboxStatus(
            state: .failed,
            summary: "SSH disconnected",
            activeEmail: nil
        )
        #expect(manager.isPoolTarget(authority))
        #expect(manager.hostConvergencePresentation(
            forPoolTarget: authority,
            now: now
        ).vps == .unavailable)
    }

    @Test("Host mismatches remain health details for one pool target")
    func hostMismatchDoesNotCreateTwoPoolTargets() throws {
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
        try publishAuthority(
            manager: manager,
            target: target,
            previous: staleRuntime,
            now: now
        )

        #expect(manager.configuredAccount?.id == target.id)
        #expect(manager.runtimeCurrentAccount?.id == staleRuntime.id)
        #expect(manager.isPoolTarget(target))
        #expect(!manager.isPoolTarget(staleRuntime))
        #expect(manager.accounts.filter { manager.isPoolTarget($0) }.count == 1)

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
    func matchingHostEvidenceConvergesPoolTarget() throws {
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
        try publishAuthority(
            manager: manager,
            target: target,
            previous: target,
            now: now
        )

        let convergence = manager.hostConvergencePresentation(
            forPoolTarget: target,
            now: now
        )
        #expect(convergence == AccountHostConvergencePresentation(
            mac: .converged,
            vps: .converged
        ))
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

    private func publishAuthority(
        manager: AccountManager,
        target: CodexAccount,
        previous: CodexAccount,
        now: Date
    ) throws {
        manager.publishPoolAuthorityObservation(try PoolAuthorityObservation(
            epoch: 1,
            phase: .stable,
            desiredProviderAccountId: target.accountId,
            requestId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            reason: "test",
            observedAt: now,
            updatedAt: now,
            previousProviderAccountId: previous.accountId,
            detail: nil
        ))
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
