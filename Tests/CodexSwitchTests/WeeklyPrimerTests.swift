import Foundation
import Testing
@testable import CodexSwitch

@Suite("WeeklyPrimer")
struct WeeklyPrimerTests {
    @Test("Uses current Codex model for primer requests")
    func usesCurrentCodexModelForPrimerRequests() {
        #expect(WeeklyPrimer.defaultPrimerModel == "gpt-5.5")
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

    private func testAccount(
        id: UUID,
        fiveHourResetAfter: TimeInterval,
        fiveHourUsedPercent: Double = 0,
        weeklyUsedPercent: Double,
        weeklyResetAfter: TimeInterval = 6 * 24 * 3600,
        weeklyResetAt explicitWeeklyResetAt: Date? = nil
    ) -> CodexAccount {
        let now = Date()
        let weeklyResetAt = explicitWeeklyResetAt ?? now.addingTimeInterval(weeklyResetAfter)
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: fiveHourUsedPercent,
                windowDurationMins: 300,
                resetsAt: now.addingTimeInterval(fiveHourResetAfter),
                hardLimitReached: false
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
            quotaSnapshot: snapshot
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
