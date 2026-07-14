import Testing
import Foundation
@testable import CodexSwitch

@Suite("Quota Models")
struct QuotaModelTests {
    private func fixture(named name: String) throws -> Data {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: testsDirectory.appendingPathComponent("Fixtures/Quota/\(name).json"))
    }

    @Test("QuotaUrgency thresholds")
    func urgencyThresholds() {
        #expect(QuotaUrgency(remainingPercent: 75) == .relaxed)
        #expect(QuotaUrgency(remainingPercent: 50) == .relaxed)
        #expect(QuotaUrgency(remainingPercent: 49) == .moderate)
        #expect(QuotaUrgency(remainingPercent: 20) == .moderate)
        #expect(QuotaUrgency(remainingPercent: 19) == .elevated)
        #expect(QuotaUrgency(remainingPercent: 10) == .elevated)
        #expect(QuotaUrgency(remainingPercent: 9) == .high)
        #expect(QuotaUrgency(remainingPercent: 7) == .high)
        #expect(QuotaUrgency(remainingPercent: 5) == .imminent)
        #expect(QuotaUrgency(remainingPercent: 1) == .imminent)
        #expect(QuotaUrgency(remainingPercent: 0.9) == .critical)
        #expect(QuotaUrgency(remainingPercent: 0) == .critical)
    }

    @Test("QuotaUrgency poll intervals")
    func pollIntervals() {
        #expect(QuotaUrgency.relaxed.pollInterval == 600)
        #expect(QuotaUrgency.moderate.pollInterval == 300)
        #expect(QuotaUrgency.elevated.pollInterval == 120)
        #expect(QuotaUrgency.high.pollInterval == 60)
        #expect(QuotaUrgency.imminent.pollInterval == 1)
        #expect(QuotaUrgency.critical.pollInterval == 1)
    }

    @Test("QuotaWindow computed properties")
    func windowProperties() {
        let future = Date().addingTimeInterval(3600)
        let window = QuotaWindow(usedPercent: 28, windowDurationMins: 300, resetsAt: future, hardLimitReached: false)
        #expect(window.remainingPercent == 72)
        #expect(!window.isExhausted)
        #expect(window.urgency == .relaxed)

        let exhausted = QuotaWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: future, hardLimitReached: false)
        #expect(exhausted.remainingPercent == 0)
        #expect(exhausted.isExhausted)
        #expect(exhausted.urgency == .critical)
    }

    @Test("Unstarted 5h detection accepts one-percent usage when reset is still full")
    func unstartedFiveHourDetectionAcceptsOnePercentUsage() {
        let fetchedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let onePercentFullReset = QuotaWindow(
            usedPercent: 1,
            windowDurationMins: 300,
            resetsAt: fetchedAt.addingTimeInterval(300 * 60),
            hardLimitReached: false
        )
        let onePercentStarted = QuotaWindow(
            usedPercent: 1,
            windowDurationMins: 300,
            resetsAt: fetchedAt.addingTimeInterval(4.75 * 3600),
            hardLimitReached: false
        )
        let hardLimitedFullReset = QuotaWindow(
            usedPercent: 1,
            windowDurationMins: 300,
            resetsAt: fetchedAt.addingTimeInterval(300 * 60),
            hardLimitReached: true
        )

        #expect(onePercentFullReset.looksLikeUnstartedFiveHourWindow(referenceDate: fetchedAt))
        #expect(!onePercentStarted.looksLikeUnstartedFiveHourWindow(referenceDate: fetchedAt))
        #expect(!hardLimitedFullReset.looksLikeUnstartedFiveHourWindow(referenceDate: fetchedAt))
    }

    @Test("Auto swap triggers when displayed quota reaches one percent")
    func autoSwapThreshold() {
        let future = Date().addingTimeInterval(3600)
        let fivePercent = QuotaWindow(usedPercent: 95, windowDurationMins: 300, resetsAt: future, hardLimitReached: false)
        let displayedAsOnePercentFromTruncation = QuotaWindow(usedPercent: 98.49, windowDurationMins: 300, resetsAt: future, hardLimitReached: false)
        let displayedAsOnePercent = QuotaWindow(usedPercent: 98.6, windowDurationMins: 300, resetsAt: future, hardLimitReached: false)
        let onePercent = QuotaWindow(usedPercent: 99, windowDurationMins: 300, resetsAt: future, hardLimitReached: false)
        let belowOnePercent = QuotaWindow(usedPercent: 99.2, windowDurationMins: 300, resetsAt: future, hardLimitReached: false)

        #expect(!fivePercent.shouldAutoSwapAway)
        #expect(displayedAsOnePercentFromTruncation.shouldAutoSwapAway)
        #expect(displayedAsOnePercent.shouldAutoSwapAway)
        #expect(onePercent.shouldAutoSwapAway)
        #expect(belowOnePercent.shouldAutoSwapAway)
    }

    @Test("Hard limit reached overrides percentage threshold")
    func hardLimitReachedOverridesThreshold() {
        let future = Date().addingTimeInterval(3600)
        let window = QuotaWindow(usedPercent: 98.9, windowDurationMins: 300, resetsAt: future, hardLimitReached: true)

        #expect(abs(window.remainingPercent - 1.1) < 0.0001)
        #expect(window.effectiveRemainingPercent == 0)
        #expect(window.isExhausted)
        #expect(window.shouldAutoSwapAway)
        #expect(window.urgency == .critical)
    }

    @Test("Hard limit with zero visible usage displays exhausted")
    func hardLimitWithZeroUsageDisplaysExhausted() {
        let future = Date().addingTimeInterval(3600)
        let window = QuotaWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: future, hardLimitReached: true)

        #expect(window.remainingPercent == 100)
        #expect(window.effectiveRemainingPercent == 0)
        #expect(window.isExhausted)
        #expect(window.shouldAutoSwapAway)
        #expect(window.urgency == .critical)
    }

    @Test("Snapshot policy ignores unknown diagnostic windows")
    func snapshotPolicyIgnoresUnknownDiagnostics() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let weekly = QuotaWindow(
            kind: .weekly,
            durationSeconds: 604_800,
            usedPercent: 30,
            resetsAt: fetchedAt.addingTimeInterval(400_000),
            source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
        )
        let unknownBlocking = QuotaWindow(
            kind: .unknown,
            durationSeconds: 86_400,
            usedPercent: 99,
            resetsAt: fetchedAt.addingTimeInterval(20_000),
            source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .secondary)
        )
        let snapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: fetchedAt,
            windows: [unknownBlocking, weekly]
        )

        #expect(snapshot.orderedWindows.map(\.kind) == [.weekly, .unknown])
        #expect(snapshot.orderedPolicyWindows == [weekly])
        #expect(snapshot.blockingWindows.isEmpty)
        #expect(snapshot.minimumRemainingPercent == 70)
        #expect(snapshot.mostUrgentWindow == weekly)
        #expect(!snapshot.needsSwap)
        #expect(snapshot.isImmediatelyUsable)
        #expect(snapshot.nextRecoveryAt == nil)
        #expect(snapshot.fiveHour == nil)
    }

    @Test("Weekly-only healthy snapshot is immediately usable")
    func weeklyOnlySnapshotIsImmediatelyUsable() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let weekly = QuotaWindow(
            kind: .weekly,
            durationSeconds: 604_800,
            usedPercent: 30,
            resetsAt: fetchedAt.addingTimeInterval(400_000),
            source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
        )
        let snapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: fetchedAt,
            windows: [weekly]
        )

        #expect(snapshot.minimumRemainingPercent == 70)
        #expect(snapshot.mostUrgentWindow == weekly)
        #expect(snapshot.blockingWindows.isEmpty)
        #expect(!snapshot.needsSwap)
        #expect(snapshot.isImmediatelyUsable)
        #expect(snapshot.nextRecoveryAt == nil)
    }

    @Test("Recovery waits for every blocking window on the account")
    func recoveryWaitsForEveryBlockingWindow() {
        let fetchedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let earlier = QuotaWindow(
            kind: .fiveHour,
            durationSeconds: 18_000,
            usedPercent: 100,
            resetsAt: fetchedAt.addingTimeInterval(1_000),
            source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
        )
        let later = QuotaWindow(
            kind: .weekly,
            durationSeconds: 604_800,
            usedPercent: 100,
            resetsAt: fetchedAt.addingTimeInterval(9_000),
            source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .secondary)
        )
        let snapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: fetchedAt,
            windows: [earlier, later]
        )

        #expect(snapshot.nextRecoveryAt == later.resetsAt)
    }

    @Test("Global denial blocks all present windows without fabricating telemetry")
    func globalDenialBlocksPresentWindows() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let fiveHour = QuotaWindow(
            kind: .fiveHour,
            durationSeconds: 18_000,
            usedPercent: 10,
            resetsAt: fetchedAt.addingTimeInterval(10_000),
            source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .secondary)
        )
        let weekly = QuotaWindow(
            kind: .weekly,
            durationSeconds: 604_800,
            usedPercent: 20,
            resetsAt: fetchedAt.addingTimeInterval(400_000),
            source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
        )
        let denied = QuotaSnapshot(
            allowed: false,
            limitReached: true,
            fetchedAt: fetchedAt,
            windows: [weekly, fiveHour]
        )
        let deniedWithoutTelemetry = QuotaSnapshot(
            allowed: false,
            limitReached: true,
            fetchedAt: fetchedAt,
            windows: []
        )

        #expect(denied.blockingWindows == [fiveHour, weekly])
        #expect(denied.minimumRemainingPercent == 0)
        #expect(denied.needsSwap)
        #expect(!denied.isImmediatelyUsable)
        #expect(denied.nextRecoveryAt == weekly.resetsAt)
        #expect(deniedWithoutTelemetry.blockingWindows.isEmpty)
        #expect(deniedWithoutTelemetry.minimumRemainingPercent == 0)
        #expect(deniedWithoutTelemetry.mostUrgentWindow == nil)
        #expect(deniedWithoutTelemetry.needsSwap)
        #expect(!deniedWithoutTelemetry.isImmediatelyUsable)
        #expect(deniedWithoutTelemetry.nextRecoveryAt == nil)
    }

    @Test("Placeholder detection checks every present window")
    func placeholderDetectionChecksEveryWindow() {
        let fetchedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let weeklyPlaceholder = QuotaWindow(
            kind: .weekly,
            durationSeconds: 604_800,
            usedPercent: 0,
            resetsAt: fetchedAt,
            source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
        )
        let snapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: fetchedAt,
            windows: [weeklyPlaceholder]
        )

        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.hasBackendUsagePlaceholder)
    }

    @Test("Past exhausted reset needs fresh confirmation")
    func pastExhaustedResetNeedsFreshConfirmation() {
        let now = Date()
        let pastExhausted = QuotaWindow(
            usedPercent: 100,
            windowDurationMins: 300,
            resetsAt: now.addingTimeInterval(-60),
            hardLimitReached: true
        )
        let futureExhausted = QuotaWindow(
            usedPercent: 100,
            windowDurationMins: 300,
            resetsAt: now.addingTimeInterval(60),
            hardLimitReached: true
        )
        let pastHealthy = QuotaWindow(
            usedPercent: 20,
            windowDurationMins: 300,
            resetsAt: now.addingTimeInterval(-60),
            hardLimitReached: false
        )

        #expect(pastExhausted.needsResetConfirmation(now: now))
        #expect(pastExhausted.needsResetConfirmation(now: now, staleAfter: 30))
        #expect(!pastExhausted.needsResetConfirmation(now: now, staleAfter: 120))
        #expect(!futureExhausted.needsResetConfirmation(now: now))
        #expect(!pastHealthy.needsResetConfirmation(now: now))
    }

    @Test("Drain bar does not call expired reset timestamps reauth")
    @MainActor func drainBarExpiredResetCopyDoesNotSayReauth() {
        let now = Date(timeIntervalSince1970: 1_777_777_777)
        let past = now.addingTimeInterval(-60)

        #expect(DrainBarView.resetText(percent: 100, resetsAt: past, now: now) == "")
        #expect(DrainBarView.resetText(percent: 0, resetsAt: past, now: now) == "confirming reset")
        #expect(!DrainBarView.resetText(percent: 0, resetsAt: past, now: now).localizedCaseInsensitiveContains("reauth"))
    }

    @Test("Account card classifies token failures as login required only")
    @MainActor func accountCardAuthErrorClassification() {
        #expect(AccountCardView.needsReauthentication(for: "token_expired"))
        #expect(AccountCardView.needsReauthentication(for: "Token refresh failed (HTTP 401)"))
        #expect(AccountCardView.needsReauthentication(for: "unexpected status 401 Unauthorized"))
        #expect(AccountCardView.needsReauthentication(for: "Your authentication token has been invalidated."))
        #expect(!AccountCardView.needsReauthentication(for: "stale; confirming reset"))
        #expect(!AccountCardView.needsReauthentication(for: "reset needs confirmation"))
        #expect(!AccountCardView.needsReauthentication(for: nil))
    }

    @Test("AccountManager active account")
    @MainActor func configuredAccountSelection() {
        let manager = AccountManager()
        let a1 = CodexAccount(email: "a@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc1", isActive: true)
        let a2 = CodexAccount(email: "b@test.com", accessToken: "t2", refreshToken: "r2", idToken: "i2", accountId: "acc2", isActive: false)
        #expect(manager.addAccount(a1))
        #expect(manager.addAccount(a2))
        #expect(manager.configuredAccount == nil)
        manager.setConfiguredAccount(a1.id)
        #expect(manager.configuredAccount?.email == "a@test.com")
        manager.setConfiguredAccount(a2.id)
        #expect(manager.configuredAccount?.email == "b@test.com")
    }

    @Test("AccountManager lightweight UI refresh revision")
    @MainActor func uiRefreshRevision() {
        let manager = AccountManager()
        #expect(manager.uiRefreshRevision == 0)
        manager.requestUIRefresh()
        #expect(manager.uiRefreshRevision == 1)
        manager.requestUIRefresh()
        #expect(manager.uiRefreshRevision == 2)
    }

    @Test("AccountManager rejects duplicate additions by accountId")
    @MainActor func deduplication() {
        let manager = AccountManager()
        let a1 = CodexAccount(email: "a@test.com", accessToken: "old", refreshToken: "r1", idToken: "i1", accountId: "same-id")
        let a2 = CodexAccount(email: "a@test.com", accessToken: "new", refreshToken: "r1", idToken: "i1", accountId: "same-id")
        #expect(manager.addAccount(a1))
        #expect(!manager.addAccount(a2))
        #expect(manager.accounts.count == 1)
        #expect(manager.accounts[0].id == a1.id)
        #expect(manager.accounts[0].accessToken == "old")
        #expect(!manager.accounts[0].isActive)
    }

    @Test("AuthFile JSON decoding")
    func authFileDecoding() throws {
        let json = """
        {
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": null,
            "tokens": {
                "id_token": "idt",
                "access_token": "act",
                "refresh_token": "rft",
                "account_id": "acc-123"
            },
            "last_refresh": "2026-03-12T08:44:18.860111Z"
        }
        """
        let data = json.data(using: .utf8)!
        let authFile = try JSONDecoder().decode(AuthFile.self, from: data)
        #expect(authFile.authMode == "chatgpt")
        #expect(authFile.tokens.accessToken == "act")
        #expect(authFile.tokens.accountId == "acc-123")
    }


    @Test("Legacy v1 quota snapshots migrate through the explicit v2 writer")
    func legacyQuotaSnapshotRoundTrip() throws {
        let snapshot = try JSONDecoder().decode(
            QuotaSnapshot.self,
            from: fixture(named: "snapshot-v1")
        )
        let fiveHour = try #require(snapshot.fiveHour)
        let weekly = try #require(snapshot.weekly)

        #expect(snapshot.allowed == nil)
        #expect(snapshot.limitReached == nil)
        #expect(snapshot.windows.count == 2)
        #expect(fiveHour.kind == .fiveHour)
        #expect(fiveHour.source.rateLimit == .legacy)
        #expect(fiveHour.source.slot == .legacyFiveHour)
        #expect(fiveHour.hardLimitReached == false)
        #expect(weekly.kind == .weekly)
        #expect(weekly.source.slot == .legacyWeekly)
        #expect(weekly.hardLimitReached == false)

        let encoded = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["version"] as? Int == QuotaSnapshot.codingVersion)
        #expect(object["fiveHour"] == nil)
        #expect(object["weekly"] == nil)

        let migrated = try JSONDecoder().decode(QuotaSnapshot.self, from: encoded)
        #expect(migrated == snapshot)
    }

    @Test("V2 weekly-only quota snapshot round-trips without fabricated windows")
    func versionTwoQuotaSnapshotRoundTrip() throws {
        let snapshot = try JSONDecoder().decode(
            QuotaSnapshot.self,
            from: fixture(named: "snapshot-v2")
        )
        let weekly = try #require(snapshot.weekly)

        #expect(snapshot.allowed == true)
        #expect(snapshot.limitReached == false)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.fiveHour == nil)
        #expect(weekly.durationSeconds == 604_800)
        #expect(weekly.source.rateLimit == .additional)
        #expect(weekly.source.slot == .primary)
        #expect(weekly.source.limitName == "GPT-5.5")
        #expect(weekly.source.meteredFeature == "codex")

        let encoded = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let windows = try #require(object["windows"] as? [[String: Any]])
        #expect(object["version"] as? Int == QuotaSnapshot.codingVersion)
        #expect(windows.count == 1)
        #expect(windows[0]["durationSeconds"] as? Int == 604_800)
        #expect(windows[0]["windowDurationMins"] == nil)

        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: encoded)
        #expect(decoded == snapshot)
    }

    @Test("Legacy field names cannot override the observed window duration")
    func legacyMislabeledWeeklyWindowMigratesAsWeekly() throws {
        let data = Data(
            """
            {
              "fetchedAt": 1000,
              "fiveHour": {"usedPercent":6,"windowDurationMins":10080,"resetsAt":2000,"hardLimitReached":false},
              "weekly": {"usedPercent":0,"windowDurationMins":10080,"resetsAt":3000,"hardLimitReached":false}
            }
            """.utf8
        )

        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: data)

        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.weekly?.usedPercent == 6)
        #expect(snapshot.weekly?.source.slot == .legacyFiveHour)
    }

    @Test("V2 kind-duration contradictions normalize by duration")
    func versionTwoKindDurationMismatchNormalizesByDuration() throws {
        let snapshot = try JSONDecoder().decode(
            QuotaSnapshot.self,
            from: fixture(named: "snapshot-v2-kind-duration-mismatch")
        )

        #expect(snapshot.fiveHour?.usedPercent == 23)
        #expect(snapshot.weekly?.usedPercent == 19)
        #expect(snapshot.windows.filter { $0.kind == .unknown }.map(\.usedPercent) == [41])
    }

    @Test("Unknown-only telemetry is retained for diagnostics but cannot drive policy")
    func unknownOnlyTelemetryIsDiagnostic() {
        let fetchedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let diagnostic = QuotaWindow(
            kind: .unknown,
            durationSeconds: 86_400,
            usedPercent: 100,
            resetsAt: fetchedAt.addingTimeInterval(86_400),
            source: QuotaWindowSourceMetadata(rateLimit: .additional, slot: .secondary)
        )
        let snapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: fetchedAt,
            windows: [diagnostic]
        )

        #expect(snapshot.windows == [diagnostic])
        #expect(snapshot.policyWindows.isEmpty)
        #expect(snapshot.blockingWindows.isEmpty)
        #expect(snapshot.minimumRemainingPercent == nil)
        #expect(snapshot.mostUrgentWindow == nil)
        #expect(!snapshot.needsSwap)
        #expect(!snapshot.isImmediatelyUsable)
        #expect(snapshot.nextRecoveryAt == nil)
    }

    @Test("Nonpositive windows are filtered by direct init and v2 write")
    func directInitAndWriteFilterNonpositiveWindows() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let zero = QuotaWindow(
            kind: .unknown,
            durationSeconds: 0,
            usedPercent: 100,
            resetsAt: fetchedAt,
            source: QuotaWindowSourceMetadata(rateLimit: .unknown, slot: .unknown)
        )
        let negative = QuotaWindow(
            kind: .unknown,
            durationSeconds: -1,
            usedPercent: 100,
            resetsAt: fetchedAt,
            source: QuotaWindowSourceMetadata(rateLimit: .unknown, slot: .unknown)
        )
        let weekly = QuotaWindow(
            kind: .weekly,
            durationSeconds: 604_800,
            usedPercent: 20,
            resetsAt: fetchedAt.addingTimeInterval(604_800),
            source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
        )
        let snapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: fetchedAt,
            windows: [zero, weekly, negative]
        )

        #expect(snapshot.windows == [weekly])
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let windows = try #require(object["windows"] as? [[String: Any]])
        #expect(windows.count == 1)
        #expect(windows.allSatisfy { ($0["durationSeconds"] as? Int ?? 0) > 0 })
    }

    @Test("V2 and legacy decode both filter nonpositive windows")
    func decodeFiltersNonpositiveWindowsAcrossSchemas() throws {
        let v2 = Data(
            """
            {
              "version": 2,
              "allowed": true,
              "limitReached": false,
              "fetchedAt": 1000,
              "windows": [
                {"kind":"fiveHour","durationSeconds":0,"usedPercent":100,"resetsAt":2000},
                {"kind":"weekly","durationSeconds":604800,"usedPercent":20,"resetsAt":3000}
              ]
            }
            """.utf8
        )
        let legacy = Data(
            """
            {
              "fetchedAt": 1000,
              "fiveHour": {"usedPercent":100,"windowDurationMins":0,"resetsAt":2000,"hardLimitReached":true},
              "weekly": {"usedPercent":20,"windowDurationMins":10080,"resetsAt":3000,"hardLimitReached":false}
            }
            """.utf8
        )

        let decodedV2 = try JSONDecoder().decode(QuotaSnapshot.self, from: v2)
        let decodedLegacy = try JSONDecoder().decode(QuotaSnapshot.self, from: legacy)

        #expect(decodedV2.windows.count == 1)
        #expect(decodedV2.fiveHour == nil)
        #expect(decodedV2.weekly?.durationSeconds == 604_800)
        #expect(decodedLegacy.windows.count == 1)
        #expect(decodedLegacy.fiveHour == nil)
        #expect(decodedLegacy.weekly?.durationSeconds == 604_800)
        #expect(!decodedLegacy.isDenied)
    }
}
