import Foundation
import Testing
@testable import CodexSwitch

@Suite("AccountManager Sync")
struct AccountManagerSyncTests {
    @Test("syncWithAuthJson promotes auth target immediately")
    @MainActor func syncPromotesAuthTarget() async {
        let defaults = isolatedDefaults()
        let manager = AccountManager(
            userDefaults: defaults,
            authAccountIdProvider: { "acc-target" },
            authFileWriter: { _ in }
        )

        let current = CodexAccount(email: "current@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc-current", isActive: true)
        let target = CodexAccount(email: "target@test.com", accessToken: "t2", refreshToken: "r2", idToken: "i2", accountId: "acc-target")
        manager.addAccount(current)
        manager.addAccount(target)
        manager.setActive(current.id)

        let changed = await manager.syncWithAuthJson()

        #expect(changed == target.id)
        #expect(manager.activeAccount?.id == target.id)
    }

    @Test("syncWithAuthJson returns nil when already in sync")
    @MainActor func syncReturnsNilWhenAlreadyInSync() async {
        let defaults = isolatedDefaults()
        let manager = AccountManager(
            userDefaults: defaults,
            authAccountIdProvider: { "acc-current" },
            authFileWriter: { _ in }
        )

        let current = CodexAccount(email: "current@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc-current", isActive: true)
        manager.addAccount(current)
        manager.setActive(current.id)

        let changed = await manager.syncWithAuthJson()

        #expect(changed == nil)
        #expect(manager.activeAccount?.id == current.id)
    }

    @Test("Restore prefers stored preference over auth.json — CodexSwitch state is authoritative")
    @MainActor func restorePrefersStored() async {
        let defaults = isolatedDefaults()
        let manager = AccountManager(
            userDefaults: defaults,
            authAccountIdProvider: { "acc-target" },
            authFileWriter: { _ in }
        )

        let current = CodexAccount(email: "current@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc-current")
        let target = CodexAccount(email: "target@test.com", accessToken: "t2", refreshToken: "r2", idToken: "i2", accountId: "acc-target")
        manager.addAccount(current)
        manager.addAccount(target)
        defaults.set(current.id.uuidString, forKey: "activeAccountId")

        await manager.restoreActiveAccount()

        // Stored preference wins — auth.json may be stale from a swap chain
        // before the app was killed. CodexSwitch re-writes auth.json to match.
        #expect(manager.activeAccount?.id == current.id)
    }

    @Test("Restore falls back to stored preference when no auth.json")
    @MainActor func restoreFallsBackToStored() async {
        let defaults = isolatedDefaults()
        let current = CodexAccount(email: "current@test.com", accessToken: "t1", refreshToken: "r1", idToken: "i1", accountId: "acc-current")
        let manager = AccountManager(
            userDefaults: defaults,
            authAccountIdProvider: { nil },
            authFileWriter: { _ in }
        )

        manager.addAccount(current)
        defaults.set(current.id.uuidString, forKey: "activeAccountId")

        await manager.restoreActiveAccount()

        #expect(manager.activeAccount?.id == current.id)
    }

    @Test("Quota updates record fetch time as last refreshed")
    @MainActor func quotaUpdatesRecordFetchTime() {
        let defaults = isolatedDefaults()
        let manager = AccountManager(userDefaults: defaults)
        let fetchedAt = Date(timeIntervalSince1970: 1_773_333_333)
        let account = CodexAccount(
            email: "current@test.com",
            accessToken: "t1",
            refreshToken: "r1",
            idToken: "i1",
            accountId: "acc-current"
        )
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: fetchedAt.addingTimeInterval(300)),
            weekly: QuotaWindow(usedPercent: 20, windowDurationMins: 10_080, resetsAt: fetchedAt.addingTimeInterval(10_000)),
            fetchedAt: fetchedAt
        )

        manager.addAccount(account)
        manager.updateQuota(for: account.id, snapshot: snapshot, planType: "plus")

        #expect(manager.accounts.first?.lastRefreshed == fetchedAt)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "CodexSwitchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
