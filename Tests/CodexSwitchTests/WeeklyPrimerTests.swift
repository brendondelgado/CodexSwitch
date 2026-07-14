import Foundation
import Testing
@testable import CodexSwitch

@Suite("WeeklyPrimer")
struct WeeklyPrimerTests {
    @Test("Uses current Codex model for primer requests")
    func usesCurrentCodexModelForPrimerRequests() {
        #expect(WeeklyPrimer.defaultPrimerModel == "gpt-5.5")
    }

    @Test("Only HTTP 200 can confirm a primer request")
    func onlySuccessStatusCanPrime() {
        #expect(WeeklyPrimer.isAcceptedPrimerHTTPStatus(200))
        #expect(!WeeklyPrimer.isAcceptedPrimerHTTPStatus(202))
        #expect(!WeeklyPrimer.isAcceptedPrimerHTTPStatus(401))
        #expect(!WeeklyPrimer.isAcceptedPrimerHTTPStatus(429))
        #expect(!WeeklyPrimer.isAcceptedPrimerHTTPStatus(500))
    }

    @Test("Retries 5h priming when local marker did not start backend window")
    func retriesIneffectiveFiveHourPrimeMarker() async {
        let defaults = isolatedDefaults()
        let accountID = UUID()
        defaults.set(
            [accountID.uuidString: Date().addingTimeInterval(-11 * 60).timeIntervalSince1970],
            forKey: "fiveHourPrimedAtByAccountId"
        )

        let recorder = PrimerRequestRecorder()
        let primer = WeeklyPrimer(userDefaults: defaults) { account in
            await recorder.record(account.id)
        }
        let account = testAccount(
            id: accountID,
            fiveHourResetAfter: 4.999 * 3600,
            weeklyUsedPercent: 20
        )

        let primed = await primer.primeIfNeeded(accounts: [account]) { _ in account }

        #expect(primed == [
            WeeklyPrimer.PrimeResult(
                accountId: accountID,
                weeklyPrimed: false,
                fiveHourPrimed: true,
                fiveHourUnconfirmed: false
            )
        ])
        #expect(await recorder.recordedIDs() == [accountID])
    }

    @Test("Keeps 5h priming cooldown when backend window has started")
    func keepsCooldownWhenFiveHourWindowStarted() async {
        let defaults = isolatedDefaults()
        let accountID = UUID()
        defaults.set(
            [accountID.uuidString: Date().addingTimeInterval(-11 * 60).timeIntervalSince1970],
            forKey: "fiveHourPrimedAtByAccountId"
        )

        let recorder = PrimerRequestRecorder()
        let primer = WeeklyPrimer(userDefaults: defaults) { account in
            await recorder.record(account.id)
        }
        let account = testAccount(
            id: accountID,
            fiveHourResetAfter: 3 * 3600,
            weeklyUsedPercent: 20
        )

        let primed = await primer.primeIfNeeded(accounts: [account]) { _ in account }

        #expect(primed.isEmpty)
        #expect(await recorder.recordedIDs().isEmpty)
    }

    @Test("Primes weekly again when reset window changed")
    func primesWeeklyAgainWhenResetWindowChanged() async {
        let defaults = isolatedDefaults()
        let accountID = UUID()
        let oldResetAt = Date().addingTimeInterval(2 * 24 * 3600)
        defaults.set(
            [accountID.uuidString],
            forKey: "primedAccountIds"
        )
        defaults.set(
            [accountID.uuidString: oldResetAt.timeIntervalSince1970],
            forKey: "weeklyPrimedResetAtByAccountId"
        )
        defaults.set(
            [accountID.uuidString: Date().addingTimeInterval(-2 * 3600).timeIntervalSince1970],
            forKey: "fiveHourPrimedAtByAccountId"
        )

        let recorder = PrimerRequestRecorder()
        let primer = WeeklyPrimer(userDefaults: defaults) { account in
            await recorder.record(account.id)
        }
        let account = testAccount(
            id: accountID,
            fiveHourResetAfter: 3 * 3600,
            fiveHourUsedPercent: 10,
            weeklyUsedPercent: 0,
            weeklyResetAfter: 6 * 24 * 3600
        )

        let primed = await primer.primeIfNeeded(accounts: [account]) { _ in account }

        #expect(primed == [
            WeeklyPrimer.PrimeResult(
                accountId: accountID,
                weeklyPrimed: true,
                fiveHourPrimed: false,
                fiveHourUnconfirmed: false
            )
        ])
        #expect(await recorder.recordedIDs() == [accountID])
    }

    @Test("Keeps weekly primed state for same reset window")
    func keepsWeeklyPrimedStateForSameResetWindow() async {
        let defaults = isolatedDefaults()
        let accountID = UUID()
        let resetAt = Date().addingTimeInterval(6 * 24 * 3600)
        defaults.set(
            [accountID.uuidString: resetAt.timeIntervalSince1970],
            forKey: "weeklyPrimedResetAtByAccountId"
        )
        defaults.set(
            [accountID.uuidString: Date().addingTimeInterval(-2 * 3600).timeIntervalSince1970],
            forKey: "fiveHourPrimedAtByAccountId"
        )

        let recorder = PrimerRequestRecorder()
        let primer = WeeklyPrimer(userDefaults: defaults) { account in
            await recorder.record(account.id)
        }
        let account = testAccount(
            id: accountID,
            fiveHourResetAfter: 3 * 3600,
            fiveHourUsedPercent: 10,
            weeklyUsedPercent: 0,
            weeklyResetAt: resetAt
        )

        let primed = await primer.primeIfNeeded(accounts: [account]) { _ in account }

        #expect(primed.isEmpty)
        #expect(await recorder.recordedIDs().isEmpty)
    }

    @Test("Keeps weekly primed state when unstarted reset slides forward")
    func keepsWeeklyPrimedStateWhenUnstartedResetSlidesForward() async {
        let defaults = isolatedDefaults()
        let accountID = UUID()
        let resetAt = Date().addingTimeInterval(6 * 24 * 3600)
        defaults.set(
            [accountID.uuidString: resetAt.timeIntervalSince1970],
            forKey: "weeklyPrimedResetAtByAccountId"
        )
        defaults.set(
            [accountID.uuidString: Date().addingTimeInterval(-2 * 3600).timeIntervalSince1970],
            forKey: "fiveHourPrimedAtByAccountId"
        )

        let recorder = PrimerRequestRecorder()
        let primer = WeeklyPrimer(userDefaults: defaults) { account in
            await recorder.record(account.id)
        }
        let account = testAccount(
            id: accountID,
            fiveHourResetAfter: 3 * 3600,
            fiveHourUsedPercent: 10,
            weeklyUsedPercent: 0,
            weeklyResetAt: resetAt.addingTimeInterval(90 * 60)
        )

        let primed = await primer.primeIfNeeded(accounts: [account]) { _ in account }

        #expect(primed.isEmpty)
        #expect(await recorder.recordedIDs().isEmpty)
    }

    @Test("Reports observed started 5h window so account store can persist marker")
    func reportsObservedStartedFiveHourWindow() async {
        let defaults = isolatedDefaults()
        let accountID = UUID()

        let recorder = PrimerRequestRecorder()
        let primer = WeeklyPrimer(userDefaults: defaults) { account in
            await recorder.record(account.id)
        }
        let account = testAccount(
            id: accountID,
            fiveHourResetAfter: 4.75 * 3600,
            fiveHourUsedPercent: 1,
            weeklyUsedPercent: 20
        )

        let primed = await primer.primeIfNeeded(accounts: [account]) { _ in account }

        #expect(primed == [
            WeeklyPrimer.PrimeResult(
                accountId: accountID,
                weeklyPrimed: false,
                fiveHourPrimed: true,
                fiveHourUnconfirmed: false
            )
        ])
        #expect(await recorder.recordedIDs().isEmpty)
        let confirmed = await primer.persistedFiveHourPrimedAt()
        #expect(confirmed[accountID] != nil)
        if let observedAt = confirmed[accountID],
           let expectedStartedAt = account.quotaSnapshot?.fiveHour?.resetsAt.addingTimeInterval(-5 * 3600) {
            #expect(abs(observedAt.timeIntervalSince(expectedStartedAt)) < 1)
        }
    }

    @Test("Does not repeatedly report a running 5h window after cooldown")
    func doesNotRepeatObservedRunningFiveHourWindow() async {
        let defaults = isolatedDefaults()
        let accountID = UUID()
        defaults.set(
            [accountID.uuidString: Date().addingTimeInterval(-4.5 * 3600).timeIntervalSince1970],
            forKey: "fiveHourPrimedAtByAccountId"
        )

        let recorder = PrimerRequestRecorder()
        let primer = WeeklyPrimer(userDefaults: defaults) { account in
            await recorder.record(account.id)
        }
        let account = testAccount(
            id: accountID,
            fiveHourResetAfter: 20 * 60,
            fiveHourUsedPercent: 50,
            weeklyUsedPercent: 20
        )

        let first = await primer.primeIfNeeded(accounts: [account]) { _ in account }
        let second = await primer.primeIfNeeded(accounts: [account]) { _ in account }

        #expect(first.isEmpty)
        #expect(second.isEmpty)
        #expect(await recorder.recordedIDs().isEmpty)
    }

    @Test("Retries 5h priming when one-percent window still has full reset")
    func retriesFiveHourPrimingWhenOnePercentWindowStillHasFullReset() async {
        let defaults = isolatedDefaults()
        let accountID = UUID()
        defaults.set(
            [accountID.uuidString: Date().addingTimeInterval(-11 * 60).timeIntervalSince1970],
            forKey: "fiveHourPrimedAtByAccountId"
        )

        let recorder = PrimerRequestRecorder()
        let account = testAccount(
            id: accountID,
            fiveHourResetAfter: 5 * 3600,
            fiveHourUsedPercent: 1,
            weeklyUsedPercent: 20
        )
        let primer = WeeklyPrimer(
            userDefaults: defaults,
            requestSender: { account in
                await recorder.record(account.id)
            },
            quotaSnapshotFetcher: { _ in account.quotaSnapshot! },
            confirmationDelay: 0
        )

        let primed = await primer.primeIfNeeded(accounts: [account]) { _ in account }

        #expect(primed == [
            WeeklyPrimer.PrimeResult(
                accountId: accountID,
                weeklyPrimed: false,
                fiveHourPrimed: false,
                fiveHourUnconfirmed: true
            )
        ])
        #expect(await recorder.recordedIDs() == [accountID])
        let confirmed = await primer.persistedFiveHourPrimedAt()
        let attempted = await primer.persistedFiveHourPrimeAttemptedAt()
        #expect(confirmed[accountID] == nil)
        #expect(attempted[accountID] != nil)
    }

    @Test("Does not mark 5h primed until backend quota confirms window started")
    func doesNotMarkFiveHourPrimedUntilConfirmed() async {
        let defaults = isolatedDefaults()
        let accountID = UUID()

        let recorder = PrimerRequestRecorder()
        let account = testAccount(
            id: accountID,
            fiveHourResetAfter: 5 * 3600,
            weeklyUsedPercent: 20
        )
        let primer = WeeklyPrimer(
            userDefaults: defaults,
            requestSender: { account in
                await recorder.record(account.id)
            },
            quotaSnapshotFetcher: { _ in account.quotaSnapshot! },
            confirmationDelay: 0
        )

        let first = await primer.primeIfNeeded(accounts: [account]) { _ in account }
        let second = await primer.primeIfNeeded(accounts: [account]) { _ in account }

        #expect(first == [
            WeeklyPrimer.PrimeResult(
                accountId: accountID,
                weeklyPrimed: false,
                fiveHourPrimed: false,
                fiveHourUnconfirmed: true
            )
        ])
        #expect(second.isEmpty)
        #expect(await recorder.recordedIDs() == [accountID])
        let confirmed = await primer.persistedFiveHourPrimedAt()
        let attempted = await primer.persistedFiveHourPrimeAttemptedAt()
        #expect(confirmed[accountID] == nil)
        #expect(attempted[accountID] != nil)
    }

    @Test("Does not prime hard-limited full-looking 5h window")
    func doesNotPrimeHardLimitedFullLookingFiveHourWindow() async {
        let defaults = isolatedDefaults()
        let accountID = UUID()
        let recorder = PrimerRequestRecorder()
        let primer = WeeklyPrimer(userDefaults: defaults) { account in
            await recorder.record(account.id)
        }
        let account = testAccount(
            id: accountID,
            fiveHourResetAfter: 5 * 3600,
            fiveHourUsedPercent: 0,
            fiveHourHardLimitReached: true,
            weeklyUsedPercent: 20
        )

        let primed = await primer.primeIfNeeded(accounts: [account]) { _ in account }

        #expect(primed.isEmpty)
        #expect(await recorder.recordedIDs().isEmpty)
        #expect(await primer.persistedFiveHourPrimedAt() == [:])
        #expect(await primer.persistedFiveHourPrimeAttemptedAt() == [:])
    }

    @Test("Skips runtime-unusable accounts")
    func skipsRuntimeUnusableAccounts() async {
        let defaults = isolatedDefaults()
        let accountID = UUID()
        let recorder = PrimerRequestRecorder()
        let primer = WeeklyPrimer(userDefaults: defaults) { account in
            await recorder.record(account.id)
        }
        let account = testAccount(
            id: accountID,
            fiveHourResetAfter: 5 * 3600,
            weeklyUsedPercent: 20,
            runtimeUnusableUntil: Date().addingTimeInterval(30 * 24 * 3600),
            runtimeUnusableReason: "token_expired"
        )

        let primed = await primer.primeIfNeeded(accounts: [account]) { _ in account }

        #expect(primed.isEmpty)
        #expect(await recorder.recordedIDs().isEmpty)
        #expect(await primer.persistedFiveHourPrimedAt() == [:])
        #expect(await primer.persistedFiveHourPrimeAttemptedAt() == [:])
    }

    @Test("Weekly-only account primes weekly without five-hour tracking")
    func primesWeeklyOnlyAccount() async {
        let defaults = isolatedDefaults()
        let recorder = PrimerRequestRecorder()
        let now = Date()
        let account = CodexAccount(
            email: "weekly-only@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "weekly-only",
            quotaSnapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: now,
                windows: [
                    QuotaWindow(
                        kind: .weekly,
                        durationSeconds: 604_800,
                        usedPercent: 0,
                        resetsAt: now.addingTimeInterval(604_800),
                        source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                    ),
                ]
            )
        )
        let primer = WeeklyPrimer(userDefaults: defaults) { account in
            await recorder.record(account.id)
        }

        let results = await primer.primeIfNeeded(accounts: [account]) { _ in account }
        let repeated = await primer.primeIfNeeded(accounts: [account]) { _ in account }

        #expect(results == [
            WeeklyPrimer.PrimeResult(
                accountId: account.id,
                weeklyPrimed: true,
                fiveHourPrimed: false,
                fiveHourUnconfirmed: false
            )
        ])
        #expect(repeated.isEmpty)
        #expect(await recorder.recordedIDs() == [account.id])
        #expect(await primer.persistedFiveHourPrimedAt() == [:])
        #expect(await primer.persistedFiveHourPrimeAttemptedAt() == [:])
    }

    @Test("Weekly-only account with a running weekly window is not primed")
    func skipsRunningWeeklyOnlyWindow() async {
        let defaults = isolatedDefaults()
        let recorder = PrimerRequestRecorder()
        let now = Date()
        let account = CodexAccount(
            email: "weekly-running@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "weekly-running",
            quotaSnapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: now,
                windows: [
                    QuotaWindow(
                        kind: .weekly,
                        durationSeconds: 604_800,
                        usedPercent: 10,
                        resetsAt: now.addingTimeInterval(500_000),
                        source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                    ),
                ]
            )
        )
        let primer = WeeklyPrimer(userDefaults: defaults) { account in
            await recorder.record(account.id)
        }

        let results = await primer.primeIfNeeded(accounts: [account]) { _ in account }

        #expect(results.isEmpty)
        #expect(await recorder.recordedIDs().isEmpty)
    }

    @Test("Account becoming active is rechecked before primer usage")
    func rechecksInactiveStateBeforeSendingUsage() async {
        let defaults = isolatedDefaults()
        let recorder = PrimerRequestRecorder()
        let account = testAccount(
            id: UUID(),
            fiveHourResetAfter: 5 * 3600,
            weeklyUsedPercent: 20
        )
        let activeAccount: CodexAccount = {
            var active = account
            active.isActive = true
            return active
        }()
        let primer = WeeklyPrimer(userDefaults: defaults) { account in
            await recorder.record(account.id)
        }

        let results = await primer.primeIfNeeded(accounts: [account]) { _ in activeAccount }

        #expect(results.isEmpty)
        #expect(await recorder.recordedIDs().isEmpty)
        #expect(await primer.persistedFiveHourPrimeAttemptedAt() == [:])
    }

    private func testAccount(
        id: UUID,
        fiveHourResetAfter: TimeInterval,
        fiveHourUsedPercent: Double = 0,
        fiveHourHardLimitReached: Bool = false,
        weeklyUsedPercent: Double,
        weeklyResetAfter: TimeInterval = 6 * 24 * 3600,
        weeklyResetAt explicitWeeklyResetAt: Date? = nil,
        runtimeUnusableUntil: Date? = nil,
        runtimeUnusableReason: String? = nil
    ) -> CodexAccount {
        let now = Date()
        let weeklyResetAt = explicitWeeklyResetAt ?? now.addingTimeInterval(weeklyResetAfter)
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: fiveHourUsedPercent,
                windowDurationMins: 300,
                resetsAt: now.addingTimeInterval(fiveHourResetAfter),
                hardLimitReached: fiveHourHardLimitReached
            ),
            weekly: QuotaWindow(
                usedPercent: weeklyUsedPercent,
                windowDurationMins: 10_080,
                resetsAt: weeklyResetAt,
                hardLimitReached: false
            ),
            fetchedAt: now
        )

        return CodexAccount(
            id: id,
            email: "idle@test.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "acc-\(id.uuidString)",
            quotaSnapshot: snapshot,
            runtimeUnusableUntil: runtimeUnusableUntil,
            runtimeUnusableReason: runtimeUnusableReason
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "CodexSwitchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private actor PrimerRequestRecorder {
    private var ids: [UUID] = []

    func record(_ id: UUID) {
        ids.append(id)
    }

    func recordedIDs() -> [UUID] {
        ids
    }
}
