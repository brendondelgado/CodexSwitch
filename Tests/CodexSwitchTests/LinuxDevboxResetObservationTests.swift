import Foundation
import Testing
@testable import CodexSwitch

@Suite("VPS manual reset observations")
struct LinuxDevboxResetObservationTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let settings = LinuxDevboxMonitorSettings(
        enabled: true, host: "vps.example.com", user: "signul", sshKeyPath: "", port: 22
    )

    private func state(
        protocolVersion: Int = 1,
        blocked: Bool = false
    ) -> LinuxDevboxAccountState {
        .init(
            email: "fixture@example.com", providerAccountId: "provider-id", isActive: false,
            quotaSnapshot: nil, planType: "pro", lastRefreshed: nil,
            subscriptionRenewsAt: nil, subscriptionExpiresAt: nil,
            subscriptionWillRenew: nil, hasActiveSubscription: nil,
            resetAttemptStatus: .init(
                schemaVersion: 1, accountId: "provider-id", journalState: "observed",
                redemptionBlocked: blocked, attempts: []
            ),
            resetProtocolVersion: protocolVersion
        )
    }

    @Test("Reset compatibility survives runtime invalidation without authorizing runtime readiness")
    @MainActor
    func compatibilityAndRuntimeReadinessAreIndependent() {
        let manager = AccountManager()
        let status = LinuxDevboxStatus(
            state: .notReady, summary: "App-server has not acknowledged an auth reload"
        )
        manager.linuxDevboxStatus = status
        manager.linuxDevboxAccountStatesObservedAt = now
        manager.publishLinuxDevboxResetObservation(.init(
            states: [state()], settings: settings, observedAt: now
        ))
        manager.invalidateLinuxDevboxRuntimeEvidence()

        #expect(manager.linuxDevboxResetObservation?.authorization(
            for: "provider-id", settings: settings, now: now
        ).isAuthorized == true)
        #expect(manager.linuxDevboxAccountStatesObservedAt == nil)
        #expect(manager.linuxDevboxAccountStates.isEmpty)
        #expect(manager.linuxDevboxStatus == status)
        #expect(manager.accounts.isEmpty)
        #expect(manager.poolAuthorityObservation == nil)
        #expect(manager.activationState == nil)

        manager.publishLinuxDevboxResetObservation(nil)
        #expect(manager.linuxDevboxResetObservation == nil)
    }

    @Test("Reset compatibility is bound to the exact transport and current observation")
    func changedSettingsAndExpiredEvidenceFailClosed() {
        let observation = LinuxDevboxResetObservation(
            states: [state()], settings: settings, observedAt: now
        )
        let changedSettings = LinuxDevboxMonitorSettings(
            enabled: true, host: "other.example.com", user: "signul", sshKeyPath: "", port: 22
        )
        #expect(!observation.authorization(
            for: "provider-id", settings: changedSettings, now: now
        ).isAuthorized)
        #expect(!observation.authorization(
            for: "provider-id", settings: settings, now: now.addingTimeInterval(-1)
        ).isAuthorized)
        #expect(!observation.authorization(
            for: "provider-id", settings: settings,
            now: now.addingTimeInterval(LinuxDevboxMonitor.readinessEvidenceFreshnessInterval + 1)
        ).isAuthorized)
        #expect(!observation.authorization(
            for: "different-id", settings: settings, now: now
        ).isAuthorized)
    }

    @Test("Independent reset observations preserve journal, protocol, and identity guards")
    func unsafeResetStatesRemainBlocked() {
        for states in [[], [state(protocolVersion: 2)], [state(blocked: true)], [state(), state()]] {
            let observation = LinuxDevboxResetObservation(
                states: states, settings: settings, observedAt: now
            )
            #expect(!observation.authorization(
                for: "provider-id", settings: settings, now: now
            ).isAuthorized)
        }
    }

    @Test("The app refreshes reset observations before branching on runtime readiness")
    func appReadinessWiringKeepsObservationsSeparate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/CodexSwitch/App/AppDelegate.swift"
        ), encoding: .utf8)
        let readiness = try #require(source.components(
            separatedBy: "private func checkLinuxDevboxReadiness(force: Bool = false)"
        ).last)
        let beforeRuntimeBranch = try #require(readiness.components(separatedBy: "if readiness.ready {").first)
        #expect(beforeRuntimeBranch.contains("LinuxDevboxMonitor.fetchAccountStates("))
        #expect(beforeRuntimeBranch.contains("LinuxDevboxResetObservation("))
        #expect(beforeRuntimeBranch.contains("linuxDevboxReadinessTaskIsCurrent(taskContext)"))
        #expect(!beforeRuntimeBranch.contains("self.applyLinuxDevboxAccountStates("))
        #expect(source.contains("accountManager.linuxDevboxResetObservation?.authorization("))
    }
}
