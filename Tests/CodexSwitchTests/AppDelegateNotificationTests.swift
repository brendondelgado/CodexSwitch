import Foundation
import Testing
import UserNotifications
@testable import CodexSwitch

private final class ResetNotificationEnqueueHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [@Sendable (Error?) -> Void] = []

    func enqueue(
        _ request: UNNotificationRequest,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        lock.lock()
        completions.append(completion)
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return completions.count
    }

    func complete(at index: Int, error: Error?) {
        lock.lock()
        let completion = completions[index]
        lock.unlock()
        completion(error)
    }
}

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

    @Test("Reset expiration dedupe key uses stable account, exact expiration, and urgency")
    func resetExpirationDedupeKeyContract() throws {
        let expiration = Date(timeIntervalSince1970: 1_800_500_000.125)
        let advisoryKey = try #require(
            NotificationManager.resetExpirationNotificationDedupeKey(
                stableProviderAccountId: " provider-123 ",
                expiration: expiration,
                urgency: .advisory
            )
        )

        #expect(advisoryKey == NotificationManager.resetExpirationNotificationDedupeKey(
            stableProviderAccountId: "PROVIDER-123",
            expiration: expiration,
            urgency: .advisory
        ))
        #expect(advisoryKey != NotificationManager.resetExpirationNotificationDedupeKey(
            stableProviderAccountId: "provider-456",
            expiration: expiration,
            urgency: .advisory
        ))
        #expect(advisoryKey != NotificationManager.resetExpirationNotificationDedupeKey(
            stableProviderAccountId: "provider-123",
            expiration: expiration.addingTimeInterval(0.001),
            urgency: .advisory
        ))
        #expect(advisoryKey != NotificationManager.resetExpirationNotificationDedupeKey(
            stableProviderAccountId: "provider-123",
            expiration: expiration,
            urgency: .urgent
        ))
        #expect(NotificationManager.resetExpirationNotificationDedupeKey(
            stableProviderAccountId: "provider-123",
            expiration: expiration,
            urgency: .normal
        ) == nil)

        #expect(!NotificationManager.shouldNotifyResetExpiration(
            stableProviderAccountId: "provider-123",
            expiration: expiration,
            urgency: .advisory,
            alreadyNotifiedKeys: [advisoryKey]
        ))
        #expect(NotificationManager.shouldNotifyResetExpiration(
            stableProviderAccountId: "provider-123",
            expiration: expiration,
            urgency: .urgent,
            alreadyNotifiedKeys: [advisoryKey]
        ))
    }

    @Test("Reset expiration dedupe persists only after successful enqueue")
    func resetExpirationDedupePersistsAfterSuccess() {
        let suiteName = "CodexSwitchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let defaultsKey = "reset-test-success.\(UUID().uuidString)"
        let coordinator = RateLimitResetNotificationDedupeCoordinator(
            defaultsKey: defaultsKey,
            maximumPersistedKeys: 8
        )
        let harness = ResetNotificationEnqueueHarness()
        let dedupeKey = "reset-success"
        let request = UNNotificationRequest(
            identifier: dedupeKey,
            content: UNMutableNotificationContent(),
            trigger: nil
        )

        #expect(NotificationManager.enqueueResetExpirationNotification(
            request: request,
            dedupeKey: dedupeKey,
            userDefaults: defaults,
            coordinator: coordinator
        ) { request, completion in
            harness.enqueue(request, completion: completion)
        })
        #expect(defaults.stringArray(forKey: defaultsKey) == nil)
        #expect(!NotificationManager.enqueueResetExpirationNotification(
            request: request,
            dedupeKey: dedupeKey,
            userDefaults: defaults,
            coordinator: coordinator
        ) { request, completion in
            harness.enqueue(request, completion: completion)
        })
        #expect(harness.count() == 1)

        harness.complete(at: 0, error: nil)
        #expect(defaults.stringArray(forKey: defaultsKey) == [dedupeKey])
        #expect(!NotificationManager.enqueueResetExpirationNotification(
            request: request,
            dedupeKey: dedupeKey,
            userDefaults: defaults,
            coordinator: coordinator
        ) { request, completion in
            harness.enqueue(request, completion: completion)
        })
    }

    @Test("Failed reset expiration enqueue clears in-flight state and retries")
    func resetExpirationDedupeRetriesAfterFailure() {
        let suiteName = "CodexSwitchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let defaultsKey = "reset-test-retry.\(UUID().uuidString)"
        let coordinator = RateLimitResetNotificationDedupeCoordinator(
            defaultsKey: defaultsKey,
            maximumPersistedKeys: 8
        )
        let harness = ResetNotificationEnqueueHarness()
        let dedupeKey = "reset-retry"
        let request = UNNotificationRequest(
            identifier: dedupeKey,
            content: UNMutableNotificationContent(),
            trigger: nil
        )
        let enqueue: RateLimitResetNotificationDedupeCoordinator.Enqueue = {
            request, completion in
            harness.enqueue(request, completion: completion)
        }

        #expect(NotificationManager.enqueueResetExpirationNotification(
            request: request,
            dedupeKey: dedupeKey,
            userDefaults: defaults,
            coordinator: coordinator,
            enqueue: enqueue
        ))
        harness.complete(at: 0, error: NSError(domain: "test", code: 1))
        #expect(defaults.stringArray(forKey: defaultsKey) == nil)

        #expect(NotificationManager.enqueueResetExpirationNotification(
            request: request,
            dedupeKey: dedupeKey,
            userDefaults: defaults,
            coordinator: coordinator,
            enqueue: enqueue
        ))
        #expect(harness.count() == 2)
        harness.complete(at: 1, error: nil)
        #expect(defaults.stringArray(forKey: defaultsKey) == [dedupeKey])
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "CodexSwitchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
