import Foundation
import Testing
@testable import CodexSwitch

@Suite("AppDelegate notifications")
struct AppDelegateNotificationTests {
    @Test("Codex app termination observer does not use ObjC selector callback")
    func codexAppTerminationObserverDoesNotUseObjCSelectorCallback() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )

        #expect(!source.contains("selector: #selector(codexAppDidTerminate"))
        #expect(!source.contains("@objc private func codexAppDidTerminate"))
        #expect(source.contains("handleCodexAppDidTerminate"))
        #expect(source.contains("queue: .main"))
        #expect(source.contains("scheduleDesktopPatchCheckIfNeeded(force: true)"))
    }

    @Test("Desktop patch monitor forces patch checks when installed Codex app changes")
    func desktopPatchMonitorForcesPatchChecksWhenInstalledCodexAppChanges() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )

        #expect(source.contains("lastDesktopPatchInstallationFingerprint"))
        #expect(source.contains("recordDesktopPatchInstallationFingerprintChange()"))
        #expect(source.contains("DesktopPatchManager.installationFingerprint()"))
        #expect(source.contains("let effectiveForce = force || installationChanged"))
        #expect(source.contains("ignoreCooldown: effectiveForce"))
        #expect(source.contains("ignorePermissionDeniedBackoff: effectiveForce"))
        #expect(source.contains("desktopInstallationWatcher.start"))
        #expect(source.contains("desktopUpdateCoordinator.checkNow"))
        #expect(source.contains("desktopUpdateCoordinator.desktopAppDidTerminate"))
    }

    @Test("VPS readiness identity remains independent from account-state identity")
    @MainActor
    func vpsReadinessIdentitySurvivesAccountStateIntegration() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let account = CodexAccount(
            email: "state-b@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "provider-b"
        )
        manager.accounts = [account]
        let readiness = LinuxDevboxStatus(
            state: .ready,
            summary: "ready",
            activeEmail: "readiness-a@example.com",
            activeProviderAccountId: "provider-a"
        )
        manager.linuxDevboxStatus = AppDelegate.vpsStatusPreservingReadinessIdentity(
            readiness,
            summary: "mirrored"
        )
        manager.applyLinuxDevboxAccountStates(
            [LinuxDevboxAccountState(
                email: account.email,
                providerAccountId: account.accountId,
                isActive: true,
                quotaSnapshot: nil,
                planType: "plus",
                lastRefreshed: nil,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: nil,
                subscriptionWillRenew: nil,
                hasActiveSubscription: true
            )],
            observedAt: now
        )

        #expect(manager.linuxDevboxStatus.activeEmail == "readiness-a@example.com")
        #expect(manager.vpsRuntimePresentation(for: account, now: now) == .unknown)
    }

    @Test("Active reauthentication requires exact stable provider identity")
    func activeReauthenticationRejectsSameEmailWithDifferentProviderID() {
        let original = CodexAccount(
            email: "same@example.com",
            accessToken: "old-access",
            refreshToken: "old-refresh",
            idToken: "old-id",
            accountId: "provider-a"
        )
        let replacement = CodexAccount(
            email: original.email,
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: "new-id",
            accountId: "provider-b"
        )

        #expect(!AppDelegate.reauthenticationPreservesStableProviderIdentity(
            original: original,
            observed: replacement
        ))
    }

    @Test("Duplicate active login proves runtime against pre-mutation credentials")
    func duplicateActiveLoginKeepsExistingRuntimeProofSource() {
        let original = CodexAccount(
            email: "same@example.com",
            accessToken: "old-access",
            refreshToken: "old-refresh",
            idToken: "old-id",
            accountId: "provider-a"
        )
        let imported = CodexAccount(
            email: original.email,
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: "new-id",
            accountId: original.accountId
        )

        let source = AppDelegate.activeCredentialMutationSource(
            existing: original,
            imported: imported
        )

        #expect(source.accessToken == original.accessToken)
        #expect(source.refreshToken == original.refreshToken)
        #expect(source.idToken == original.idToken)
    }

    @Test("Normal lifecycle does not schedule TCC mutation")
    func appDelegateDoesNotScheduleComputerUsePermissionMutation() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )

        #expect(!source.contains("ComputerUsePermissionRepair"))
        #expect(!source.contains("scheduleComputerUsePermissionRepair"))
        #expect(!source.contains("TCC.db"))
        #expect(!source.contains("killall"))
    }

    @Test("Config repair uses separate non-overlapping 15-minute maintenance")
    func configRepairIsNotCoupledToFiveSecondTimer() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )
        let timerStart = try #require(
            source.range(of: "iconUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5")
        )
        let timerEnd = try #require(
            source.range(of: "private func reconcileExternalAuthIfNeeded", range: timerStart.upperBound..<source.endIndex)
        )
        let timerBody = String(source[timerStart.lowerBound..<timerEnd.lowerBound])

        #expect(source.contains("configMaintenanceInterval: TimeInterval = 15 * 60"))
        #expect(source.contains("configMaintenanceTimer = Timer.scheduledTimer"))
        #expect(source.contains("guard configMaintenanceTask == nil else { return }"))
        #expect(source.contains("scheduleConfigMaintenanceIfNeeded(removeStaleCopies: true)"))
        #expect(!timerBody.contains("CodexConfigRepair.repairDefaultConfigIfNeeded"))
        #expect(!timerBody.contains("scheduleConfigMaintenanceIfNeeded"))
    }

    @Test("AppDelegate contains no Hermes integration")
    func appDelegateContainsNoHermesIntegration() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )

        #expect(!source.contains("HermesTarget"))
        #expect(!source.contains("syncHermesLocal"))
        #expect(!source.contains("HERMES_"))
    }

    @Test("Swap notification reports only present quota windows")
    func swapNotificationReportsWeeklyOnlyQuota() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let from = CodexAccount(
            email: "from@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "from"
        )
        let to = CodexAccount(
            email: "weekly@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "weekly",
            quotaSnapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: now,
                windows: [
                    QuotaWindow(
                        kind: .weekly,
                        durationSeconds: 604_800,
                        usedPercent: 25,
                        resetsAt: now.addingTimeInterval(3_600),
                        source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                    ),
                ]
            )
        )

        let body = NotificationManager.swapNotificationBody(from: from, to: to, now: now)

        #expect(body.contains("Weekly: 75% remaining"))
        #expect(body.contains("Next quota reset in 60m."))
        #expect(!body.contains("5hr"))
    }

    @Test("Swap notification does not present unknown diagnostics as capacity")
    func swapNotificationIgnoresUnknownDiagnosticWindows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let from = CodexAccount(
            email: "from@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "from"
        )
        let to = CodexAccount(
            email: "unknown@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "unknown",
            quotaSnapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: now,
                windows: [
                    QuotaWindow(
                        kind: .unknown,
                        durationSeconds: 86_400,
                        usedPercent: 0,
                        resetsAt: now.addingTimeInterval(86_400),
                        source: QuotaWindowSourceMetadata(rateLimit: .additional, slot: .secondary)
                    ),
                ]
            )
        )

        let body = NotificationManager.swapNotificationBody(from: from, to: to, now: now)

        #expect(body == "Quota windows are unavailable.")
    }

    @Test("Weekly-only presentation guards every five-hour ready line")
    func weeklyOnlyPresentationDoesNotClaimFiveHourReadiness() throws {
        let accountCard = try String(
            contentsOfFile: "Sources/CodexSwitch/Views/AccountCardView.swift",
            encoding: .utf8
        )
        let popover = try String(
            contentsOfFile: "Sources/CodexSwitch/Views/PopoverContentView.swift",
            encoding: .utf8
        )

        #expect(accountCard.contains("guard account.realQuotaSnapshot?.fiveHour != nil"))
        #expect(popover.contains("if let fiveHour = nextReset.account.realQuotaSnapshot?.fiveHour"))
        #expect(popover.contains("Text(\"Weekly window resets\")"))
    }

    @Test("Token refresh failure notifications are throttled per account")
    func tokenRefreshFailureNotificationsAreThrottledPerAccount() {
        let suiteName = "CodexSwitchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let account = CodexAccount(
            email: "needs-refresh@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "account"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(NotificationManager.shouldNotifyTokenRefreshFailed(
            account: account,
            now: now,
            userDefaults: defaults
        ))
        #expect(!NotificationManager.shouldNotifyTokenRefreshFailed(
            account: account,
            now: now.addingTimeInterval(60),
            userDefaults: defaults
        ))
        #expect(NotificationManager.shouldNotifyTokenRefreshFailed(
            account: account,
            now: now.addingTimeInterval(13 * 3600),
            userDefaults: defaults
        ))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "CodexSwitchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
