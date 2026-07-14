import Foundation
import Testing
@testable import CodexSwitch

@Suite("External rate-limit reset hold and refresh policy")
struct ExternalRateLimitResetHoldStoreTests {
    @Test("Hold survives store recreation and contains no token material")
    func holdSurvivesStoreRecreation() throws {
        let storeURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let providerAccountId = "provider-account-1"
        let store = ExternalRateLimitResetHoldStore(
            url: storeURL,
            legacyUserDefaults: nil
        )

        let recorded = try #require(try store.record(
            providerAccountId: providerAccountId,
            observedAt: now,
            blockedUntil: now.addingTimeInterval(120)
        ))
        let restartedStore = ExternalRateLimitResetHoldStore(
            url: storeURL,
            legacyUserDefaults: nil
        )

        #expect(try restartedStore.activeHolds(
            at: now.addingTimeInterval(60)
        )[providerAccountId] == recorded)
        #expect(try restartedStore.activeHolds(
            at: now.addingTimeInterval(60)
        )["provider-account-2"] == nil)
        let data = try Data(contentsOf: storeURL)
        let storedJSON = try #require(String(data: data, encoding: .utf8))
        #expect(storedJSON.contains(providerAccountId))
        #expect(!storedJSON.localizedCaseInsensitiveContains("token"))
    }

    @Test("Expired holds are pruned from persistent storage")
    func expiredHoldsArePruned() throws {
        let storeURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ExternalRateLimitResetHoldStore(
            url: storeURL,
            legacyUserDefaults: nil
        )
        try #require(try store.record(
            providerAccountId: "provider-account-1",
            observedAt: now,
            blockedUntil: now.addingTimeInterval(120)
        ) != nil)

        #expect(try store.activeHolds(at: now.addingTimeInterval(120)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }

    @Test("Only newer usable quota evidence clears an active hold early")
    func quotaEvidenceGatesEarlyClear() throws {
        let storeURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let providerAccountId = "provider-account-1"
        let store = ExternalRateLimitResetHoldStore(
            url: storeURL,
            legacyUserDefaults: nil
        )
        try #require(try store.record(
            providerAccountId: providerAccountId,
            observedAt: observedAt,
            blockedUntil: observedAt.addingTimeInterval(120)
        ) != nil)

        let oldUsableEvidence = quotaSnapshot(fetchedAt: observedAt, usedPercent: 20)
        #expect(try store.clearIfQuotaRecovered(
            providerAccountId: providerAccountId,
            snapshot: oldUsableEvidence,
            at: observedAt.addingTimeInterval(10)
        ) == nil)

        let placeholderEvidence = backendPlaceholderSnapshot(
            fetchedAt: observedAt.addingTimeInterval(15)
        )
        #expect(try store.clearIfQuotaRecovered(
            providerAccountId: providerAccountId,
            snapshot: placeholderEvidence,
            at: observedAt.addingTimeInterval(16)
        ) == nil)

        let freshBlockedEvidence = quotaSnapshot(
            fetchedAt: observedAt.addingTimeInterval(20),
            usedPercent: 100
        )
        #expect(try store.clearIfQuotaRecovered(
            providerAccountId: providerAccountId,
            snapshot: freshBlockedEvidence,
            at: observedAt.addingTimeInterval(21)
        ) == nil)

        let freshUsableEvidence = quotaSnapshot(
            fetchedAt: observedAt.addingTimeInterval(30),
            usedPercent: 20
        )
        #expect(try store.clearIfQuotaRecovered(
            providerAccountId: providerAccountId,
            snapshot: freshUsableEvidence,
            at: observedAt.addingTimeInterval(31)
        ) != nil)
        #expect(try store.activeHolds(at: observedAt.addingTimeInterval(31)).isEmpty)
    }

    @Test("Corrupt secure hold state fails closed")
    func corruptStateIsRejected() throws {
        let storeURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ExternalRateLimitResetHoldStore(
            url: storeURL,
            legacyUserDefaults: nil
        )
        _ = try store.record(
            providerAccountId: "provider-account-1",
            observedAt: now,
            blockedUntil: now.addingTimeInterval(120)
        )
        try overwriteSecureTestFile(Data("not-json".utf8), atPath: storeURL.path)

        #expect(throws: ExternalRateLimitResetHoldStoreError.self) {
            try store.activeHolds(at: now.addingTimeInterval(30))
        }
        #expect(try Data(contentsOf: storeURL) == Data("not-json".utf8))
    }

    @Test("Secure-file readback failure is surfaced and recoverable after restart")
    func readbackFailureIsSurfaced() throws {
        let storeURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failingStore = ExternalRateLimitResetHoldStore(
            url: storeURL,
            legacyUserDefaults: nil,
            transactionTestHooks: .init(beforeReadback: {
                throw InjectedExternalHoldStoreFailure()
            })
        )

        #expect(throws: InjectedExternalHoldStoreFailure.self) {
            try failingStore.record(
                providerAccountId: "provider-account-1",
                observedAt: now,
                blockedUntil: now.addingTimeInterval(120)
            )
        }

        let restartedStore = ExternalRateLimitResetHoldStore(
            url: storeURL,
            legacyUserDefaults: nil
        )
        #expect(try restartedStore.activeHolds(
            at: now.addingTimeInterval(30)
        )["provider-account-1"] != nil)
    }

    @Test("Legacy UserDefaults holds migrate only after secure-file commit")
    func legacyHoldsMigrateToSecureStorage() throws {
        let storeURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let (suiteName, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hold = ExternalRateLimitResetHoldStore.Hold(
            observedAt: now,
            blockedUntil: now.addingTimeInterval(120)
        )
        let legacy = LegacyExternalResetHoldSnapshot(
            version: 1,
            holdsByProviderAccountId: ["provider-account-1": hold]
        )
        defaults.set(
            try JSONEncoder().encode(legacy),
            forKey: ExternalRateLimitResetHoldStore.defaultStorageKey
        )
        let store = ExternalRateLimitResetHoldStore(
            url: storeURL,
            legacyUserDefaults: defaults
        )

        #expect(try store.activeHolds(
            at: now.addingTimeInterval(30)
        )["provider-account-1"] == hold)
        #expect(FileManager.default.fileExists(atPath: storeURL.path))
        #expect(defaults.object(
            forKey: ExternalRateLimitResetHoldStore.defaultStorageKey
        ) == nil)
    }

    @Test("Inventory comparison ignores fetchedAt but observes semantic fields")
    func inventoryComparisonUsesSemanticFields() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let credit = resetCredit(id: "credit-1", status: "available", now: now)
        let previous = resetBank(
            availableCount: 1,
            totalEarnedCount: 2,
            credits: [credit],
            fetchedAt: now
        )
        let timestampOnlyRefresh = resetBank(
            availableCount: 1,
            totalEarnedCount: 2,
            credits: [credit],
            fetchedAt: now.addingTimeInterval(30)
        )

        #expect(!AppDelegate.rateLimitResetInventorySemanticallyChanged(
            previous: previous,
            refreshed: timestampOnlyRefresh
        ))
        #expect(AppDelegate.rateLimitResetInventorySemanticallyChanged(
            previous: nil,
            refreshed: timestampOnlyRefresh
        ))
        #expect(AppDelegate.rateLimitResetInventorySemanticallyChanged(
            previous: previous,
            refreshed: resetBank(
                availableCount: 0,
                totalEarnedCount: 2,
                credits: [credit],
                fetchedAt: now.addingTimeInterval(30)
            )
        ))
        #expect(AppDelegate.rateLimitResetInventorySemanticallyChanged(
            previous: previous,
            refreshed: resetBank(
                availableCount: 1,
                totalEarnedCount: 3,
                credits: [credit],
                fetchedAt: now.addingTimeInterval(30)
            )
        ))
        #expect(AppDelegate.rateLimitResetInventorySemanticallyChanged(
            previous: previous,
            refreshed: resetBank(
                availableCount: 1,
                totalEarnedCount: 2,
                credits: [resetCredit(id: "credit-1", status: "redeemed", now: now)],
                fetchedAt: now.addingTimeInterval(30)
            )
        ))
    }

    @Test("Background and redemption decisions use distinct freshness bounds")
    func resetBankFreshnessPolicy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bank = resetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [],
            fetchedAt: now.addingTimeInterval(-61)
        )

        #expect(AppDelegate.rateLimitResetBankIsFresh(
            bank,
            at: now,
            requiresDecisionEvidence: false
        ))
        #expect(!AppDelegate.rateLimitResetBankIsFresh(
            bank,
            at: now,
            requiresDecisionEvidence: true
        ))

        let decisionFreshBank = resetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [],
            fetchedAt: now.addingTimeInterval(-59)
        )
        #expect(AppDelegate.rateLimitResetBankIsFresh(
            decisionFreshBank,
            at: now,
            requiresDecisionEvidence: true
        ))

        let backgroundExpiredBank = resetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [],
            fetchedAt: now.addingTimeInterval(-300)
        )
        #expect(!AppDelegate.rateLimitResetBankIsFresh(
            backgroundExpiredBank,
            at: now,
            requiresDecisionEvidence: false
        ))
    }

    @Test("Any fresh blocked quota requires decision evidence")
    func blockedQuotaRequiresDecisionEvidence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usable = quotaSnapshot(fetchedAt: now, usedPercent: 20)
        let blocked = quotaSnapshot(fetchedAt: now, usedPercent: 100)
        let staleBlocked = quotaSnapshot(
            fetchedAt: now.addingTimeInterval(-(QuotaFreshnessPolicy.maximumSnapshotAge + 1)),
            usedPercent: 100
        )

        #expect(!AppDelegate.rateLimitResetQuotaRequiresDecisionEvidence(usable, at: now))
        #expect(AppDelegate.rateLimitResetQuotaRequiresDecisionEvidence(blocked, at: now))
        #expect(!AppDelegate.rateLimitResetQuotaRequiresDecisionEvidence(staleBlocked, at: now))
        #expect(!AppDelegate.rateLimitResetQuotaRequiresDecisionEvidence(nil, at: now))
    }

    @Test("Reset-bank telemetry is not credential material")
    func resetBankRefreshDoesNotSyncCredentials() {
        #expect(!AppDelegate.shouldSyncLinuxDevboxCredentials(for: "reset-bank-refresh"))
        #expect(!AppDelegate.shouldSyncLinuxDevboxCredentials(for: "queued-after-reset-bank-refresh"))
        #expect(AppDelegate.linuxDevboxCredentialSyncThrottleInterval(for: "reset-bank-refresh") == 10 * 60)
        #expect(AppDelegate.shouldSyncLinuxDevboxCredentials(for: "reset-consumed"))
        #expect(AppDelegate.shouldSyncLinuxDevboxCredentials(for: "queued-after-reset-consumed"))
        #expect(AppDelegate.linuxDevboxCredentialSyncThrottleInterval(for: "reset-consumed") == 60)
    }

    private func isolatedDefaults() -> (String, UserDefaults) {
        let suiteName = "CodexSwitchTests.ExternalResetHold.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }

    private func temporaryStoreURL() -> URL {
        makeSecureTestFileURL(
            prefix: "codexswitch-external-reset-holds",
            fileName: "external-rate-limit-reset-holds.json"
        )
    }

    private func quotaSnapshot(
        fetchedAt: Date,
        usedPercent: Double
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: fetchedAt,
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 7 * 24 * 60 * 60,
                    usedPercent: usedPercent,
                    resetsAt: fetchedAt.addingTimeInterval(24 * 60 * 60),
                    source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                ),
            ]
        )
    }

    private func backendPlaceholderSnapshot(fetchedAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: fetchedAt,
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 7 * 24 * 60 * 60,
                    usedPercent: 0,
                    resetsAt: fetchedAt,
                    source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                ),
            ]
        )
    }

    private func resetCredit(
        id: String,
        status: String,
        now: Date
    ) -> RateLimitResetCredit {
        RateLimitResetCredit(
            id: id,
            resetType: "weekly",
            status: status,
            grantedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(24 * 60 * 60),
            redeemedAt: status == "redeemed" ? now : nil,
            title: nil,
            description: nil
        )
    }

    private func resetBank(
        availableCount: Int,
        totalEarnedCount: Int,
        credits: [RateLimitResetCredit],
        fetchedAt: Date
    ) -> RateLimitResetBank {
        RateLimitResetBank(
            availableCount: availableCount,
            totalEarnedCount: totalEarnedCount,
            credits: credits,
            fetchedAt: fetchedAt
        )
    }
}

private struct LegacyExternalResetHoldSnapshot: Encodable {
    let version: Int
    let holdsByProviderAccountId: [String: ExternalRateLimitResetHoldStore.Hold]
}

private struct InjectedExternalHoldStoreFailure: Error {}
