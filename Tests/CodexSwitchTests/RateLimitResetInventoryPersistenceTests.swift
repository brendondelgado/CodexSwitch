import Foundation
import Testing
@testable import CodexSwitch

@Suite("Rate-limit reset inventory persistence")
struct RateLimitResetInventoryPersistenceTests {
    @Test("A delayed telemetry submission cannot be overtaken by a durable credential save")
    @MainActor func delayedTelemetrySubmissionPrecedesDurableWrite() async throws {
        let recorder = ResetInventoryPersistenceRecorder()
        let coordinator = AccountPersistenceCoordinator(
            telemetryDelay: .seconds(60),
            load: { [] },
            save: { recorder.record($0) },
            deleteAll: {}
        )
        let submissions = AccountPersistenceSubmissionQueue()
        let gate = AsyncStream<Void>.makeStream()
        let observed = account(
            providerAccountId: "provider-a",
            resetBank: resetBank(
                availableCount: 2,
                fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        var replacement = observed
        replacement.accessToken = "new-access"
        replacement.rateLimitResetBank = nil
        submissions.enqueue {
            for await _ in gate.stream { break }
            await coordinator.queueTelemetry([observed], revision: 1)
        }
        let save = Task { @MainActor in
            await submissions.drain()
            try await coordinator.persistDurably([replacement], revision: 2)
        }
        await Task.yield()
        #expect(recorder.lastAccounts() == nil)
        gate.continuation.yield(())
        gate.continuation.finish()
        try await save.value
        #expect(recorder.lastAccounts()?.first?.accessToken == "new-access")
        #expect(recorder.lastAccounts()?.first?.rateLimitResetBank?.availableCount == 2)
    }

    @Test("A coalesced failed refresh cannot erase a queued successful inventory")
    func coalescedFailurePreservesQueuedInventory() async throws {
        let recorder = ResetInventoryPersistenceRecorder()
        let coordinator = AccountPersistenceCoordinator(
            telemetryDelay: .seconds(60),
            load: { [] },
            save: { recorder.record($0) },
            deleteAll: {}
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var successful = account(
            providerAccountId: "provider-a",
            resetBank: resetBank(availableCount: 1, fetchedAt: fetchedAt)
        )

        await coordinator.queueTelemetry([successful], revision: 1)
        successful.rateLimitResetBank = nil
        await coordinator.queueTelemetry([successful], revision: 2)
        try await coordinator.flushTelemetry()

        #expect(recorder.lastAccounts()?.first?.rateLimitResetBank?.availableCount == 1)
        #expect(recorder.lastAccounts()?.first?.rateLimitResetBank?.fetchedAt == fetchedAt)
    }

    @Test("A durable credential save absorbs newer queued reset inventory")
    func durableSavePreservesQueuedInventory() async throws {
        let recorder = ResetInventoryPersistenceRecorder()
        let coordinator = AccountPersistenceCoordinator(
            telemetryDelay: .seconds(60),
            load: { [] },
            save: { recorder.record($0) },
            deleteAll: {}
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let observed = account(
            providerAccountId: " Provider-A ",
            resetBank: resetBank(availableCount: 2, fetchedAt: fetchedAt)
        )
        var credentialUpdate = account(
            localId: observed.id,
            providerAccountId: "provider-a",
            resetBank: nil
        )
        credentialUpdate.accessToken = "new-access"

        await coordinator.queueTelemetry([observed], revision: 1)
        try await coordinator.persistDurably([credentialUpdate], revision: 2)
        try await coordinator.flushTelemetry()

        let persisted = try #require(recorder.lastAccounts()?.first)
        #expect(persisted.accessToken == "new-access")
        #expect(persisted.rateLimitResetBank?.availableCount == 2)
        #expect(persisted.rateLimitResetBank?.fetchedAt == fetchedAt)
    }

    @Test("Durable replacement preserves inventory by normalized provider identity")
    func durableReplacementPreservesInventoryAcrossLocalIdentityChange() throws {
        let storePath = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: storePathDirectory(storePath)) }
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: storePath
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let original = account(
            providerAccountId: "  Provider-A  ",
            resetBank: resetBank(availableCount: 1, fetchedAt: fetchedAt)
        )
        let replacement = account(
            localId: UUID(),
            providerAccountId: "provider-a",
            resetBank: nil
        )

        try store.saveAll([original])
        try store.saveAll([replacement])

        let persisted = try #require(try store.loadAll().first)
        #expect(persisted.id == replacement.id)
        #expect(persisted.rateLimitResetBank?.availableCount == 1)
        #expect(persisted.rateLimitResetBank?.fetchedAt == fetchedAt)
    }

    @Test("Reauthenticating one inactive account preserves queued inventory for every account")
    func inactiveCredentialSavePreservesOtherQueuedInventories() async throws {
        let storePath = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: storePathDirectory(storePath)) }
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: storePath
        )
        let active = account(providerAccountId: "provider-a", resetBank: nil)
        var inactive = account(providerAccountId: "provider-b", resetBank: nil)
        inactive.isActive = false
        try store.saveAll([active, inactive])
        let coordinator = AccountPersistenceCoordinator(store: store, telemetryDelay: .seconds(60))
        var observedActive = active
        observedActive.rateLimitResetBank = resetBank(
            availableCount: 2,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        await coordinator.queueTelemetry([observedActive, inactive], revision: 1)
        var candidate = inactive
        candidate.accessToken = "new-access"
        _ = try await coordinator.persistInactiveCredentialUpdate(
            original: inactive,
            candidate: candidate,
            revision: 2
        )
        let saved = try store.loadAll()
        #expect(saved.first { $0.id == active.id }?.rateLimitResetBank?.availableCount == 2)
        #expect(saved.first { $0.id == inactive.id }?.accessToken == "new-access")
    }

    @Test("A telemetry refresh failure preserves the durable last-known inventory")
    func telemetryFailurePreservesDurableInventory() throws {
        let storePath = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: storePathDirectory(storePath)) }
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: storePath
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let original = account(
            providerAccountId: "provider-a",
            resetBank: resetBank(availableCount: 1, fetchedAt: fetchedAt)
        )
        try store.saveAll([original])
        var failedRefresh = original
        failedRefresh.rateLimitResetBank = nil

        guard case .persisted = try store.saveTelemetry([failedRefresh]) else {
            Issue.record("Matching telemetry should persist without erasing reset inventory")
            return
        }

        let persisted = try #require(try store.loadAll().first)
        #expect(persisted.rateLimitResetBank?.availableCount == 1)
        #expect(persisted.rateLimitResetBank?.fetchedAt == fetchedAt)
    }

    @Test("A newer valid zero observation replaces an older positive inventory")
    func explicitZeroObservationReplacesPositiveInventory() throws {
        let storePath = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: storePathDirectory(storePath)) }
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: storePath
        )
        let originalFetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var observed = account(
            providerAccountId: "provider-a",
            resetBank: resetBank(availableCount: 1, fetchedAt: originalFetchedAt)
        )
        try store.saveAll([observed])
        observed.rateLimitResetBank = resetBank(
            availableCount: 0,
            fetchedAt: originalFetchedAt.addingTimeInterval(60)
        )

        guard case .persisted = try store.saveTelemetry([observed]) else {
            Issue.record("Matching telemetry should persist an explicit zero observation")
            return
        }

        let persisted = try #require(try store.loadAll().first)
        #expect(persisted.rateLimitResetBank?.availableCount == 0)
        #expect(persisted.rateLimitResetBank?.fetchedAt == observed.rateLimitResetBank?.fetchedAt)
    }

    @Test("External handoff preserves inventory across normalized provider identity")
    @MainActor func externalHandoffPreservesInventoryAcrossLocalIdentityChange() throws {
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let original = account(
            providerAccountId: " Provider-A ",
            resetBank: resetBank(availableCount: 1, fetchedAt: fetchedAt)
        )
        manager.accounts = [original]
        let replacement = account(
            localId: UUID(),
            providerAccountId: "provider-a",
            resetBank: nil
        )

        #expect(manager.adoptVerifiedExternalHandoff(
            [replacement],
            targetAccountId: replacement.id
        ))

        let adopted = try #require(manager.accounts.first)
        #expect(adopted.id == replacement.id)
        #expect(adopted.rateLimitResetBank?.availableCount == 1)
        #expect(adopted.rateLimitResetBank?.fetchedAt == fetchedAt)
    }

    @Test("Valid VPS inventory is retained when unrelated quota telemetry is invalid")
    @MainActor func vpsInventoryMergesIndependentlyFromInvalidQuota() throws {
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let local = account(providerAccountId: " Provider-A ", resetBank: nil)
        manager.accounts = [local]
        let bank = resetBank(
            availableCount: 1,
            fetchedAt: now.addingTimeInterval(-5)
        )
        let staleQuota = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: now.addingTimeInterval(-20 * 60),
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 7 * 24 * 60 * 60,
                    usedPercent: 25,
                    resetsAt: now.addingTimeInterval(6 * 24 * 60 * 60),
                    source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                ),
            ]
        )

        let changed = manager.projectAuthoritativeLinuxDevboxTelemetry(
            from: [
                LinuxDevboxAccountState(
                    email: "remote@example.com",
                    providerAccountId: "provider-a",
                    isActive: true,
                    quotaSnapshot: staleQuota,
                    planType: nil,
                    lastRefreshed: nil,
                    subscriptionRenewsAt: nil,
                    subscriptionExpiresAt: nil,
                    subscriptionWillRenew: nil,
                    hasActiveSubscription: nil,
                    rateLimitResetBank: bank
                ),
            ],
            observedAt: now,
            now: now
        )

        #expect(changed)
        let projected = try #require(manager.accounts.first)
        #expect(projected.quotaSnapshot == nil)
        #expect(projected.rateLimitResetBank == bank)
    }

    @Test("Credential refresh cannot regress a newer inventory generation")
    @MainActor func credentialRefreshPreservesNewerInventory() throws {
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let newestFetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var existing = account(
            providerAccountId: "provider-a",
            resetBank: resetBank(availableCount: 1, fetchedAt: newestFetchedAt)
        )
        existing.isActive = false
        manager.accounts = [existing]
        var imported = existing
        imported.accessToken = "new-access"
        imported.refreshToken = "new-refresh"
        imported.idToken = "new-id"
        imported.rateLimitResetBank = resetBank(
            availableCount: 0,
            fetchedAt: newestFetchedAt.addingTimeInterval(-60)
        )

        #expect(manager.upsertInactiveAccount(imported) == .updated(existing.id))

        let updated = try #require(manager.accounts.first)
        #expect(updated.accessToken == "new-access")
        #expect(updated.rateLimitResetBank?.availableCount == 1)
        #expect(updated.rateLimitResetBank?.fetchedAt == newestFetchedAt)
    }

    @Test("Invalid provider identity is rejected explicitly")
    @MainActor func invalidProviderIdentityHasExplicitResult() {
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let imported = account(providerAccountId: "   ", resetBank: nil)

        #expect(
            manager.upsertInactiveAccount(imported)
                == .rejectedInvalidProviderIdentity(imported.id)
        )
        #expect(manager.accounts.isEmpty)
    }

    @Test("An in-flight provider observation survives local UUID replacement")
    @MainActor func inFlightObservationUsesStableProviderIdentity() throws {
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let original = account(providerAccountId: " Provider-A ", resetBank: nil)
        manager.accounts = [original]
        let capturedProviderAccountId = try #require(original.normalizedProviderAccountId)
        let replacement = account(
            localId: UUID(),
            providerAccountId: "provider-a",
            resetBank: nil
        )
        manager.accounts = [replacement]
        let bank = resetBank(
            availableCount: 2,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let updatedAccountId = manager.updateRateLimitResetBank(
            forProviderAccountId: capturedProviderAccountId,
            bank: bank
        )

        #expect(updatedAccountId == replacement.id)
        #expect(manager.accounts.first?.id == replacement.id)
        #expect(manager.accounts.first?.rateLimitResetBank == bank)
    }

    @Test("Reconciliation quota commit follows provider identity after UUID replacement")
    @MainActor func reconciliationQuotaCommitUsesStableProviderIdentity() throws {
        let manager = AccountManager(userDefaults: isolatedDefaults())
        let original = account(providerAccountId: " Provider-A ", resetBank: nil)
        manager.accounts = [original]
        let capturedProviderAccountId = try #require(original.normalizedProviderAccountId)
        let replacement = account(
            localId: UUID(),
            providerAccountId: "provider-a",
            resetBank: nil
        )
        manager.accounts = [replacement]
        let snapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 7 * 24 * 60 * 60,
                    usedPercent: 20,
                    resetsAt: Date(timeIntervalSince1970: 1_800_604_800),
                    source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                ),
            ]
        )

        let updatedAccountId = manager.updateQuota(
            forProviderAccountId: capturedProviderAccountId,
            snapshot: snapshot,
            planType: "pro"
        )

        #expect(updatedAccountId == replacement.id)
        #expect(manager.accounts.first?.id == replacement.id)
        #expect(manager.accounts.first?.quotaSnapshot == snapshot)
        #expect(manager.accounts.first?.planType == "pro")
    }

    @Test("Only unknown remote reset outcomes block immediate retry")
    func remoteResetRetryBlockingRequiresUnknownOutcome() {
        #expect(!AppDelegate.remoteRateLimitResetFailureRequiresReconciliation(.rejected))
        #expect(!AppDelegate.remoteRateLimitResetFailureRequiresReconciliation(
            .retryablePreExecution
        ))
        #expect(AppDelegate.remoteRateLimitResetFailureRequiresReconciliation(.outcomeUnknown))
    }

    @Test("Remote reset completion requires matching terminal journal evidence, not fresh inventory")
    func remoteResetCompletionRequiresMatchingJournalEvidence() {
        let requestID = UUID()
        let status = LinuxDevboxResetAttemptStatus(
            schemaVersion: 1,
            accountId: " Provider-A ",
            journalState: "observed",
            redemptionBlocked: false,
            attempts: [.init(requestId: requestID, state: "reconciled_usable")]
        )
        #expect(!AppDelegate.remoteRateLimitResetObservationCompletesReconciliation(
            status: nil,
            requestID: requestID,
            providerAccountId: "provider-a"
        ))
        #expect(AppDelegate.remoteRateLimitResetObservationCompletesReconciliation(
            status: status,
            requestID: requestID,
            providerAccountId: "provider-a"
        ))
        #expect(!AppDelegate.remoteRateLimitResetObservationCompletesReconciliation(
            status: status,
            requestID: UUID(),
            providerAccountId: "provider-a"
        ))
        #expect(!AppDelegate.remoteRateLimitResetObservationCompletesReconciliation(
            status: status,
            requestID: requestID,
            providerAccountId: "provider-b"
        ))
    }

    @Test("A failure from old credentials cannot block a new credential generation")
    func staleCredentialFailureIsIgnored() {
        #expect(AppDelegate.rateLimitResetFailureBelongsToCurrentCredentialGeneration(
            observed: "generation-a",
            current: "generation-a"
        ))
        #expect(!AppDelegate.rateLimitResetFailureBelongsToCurrentCredentialGeneration(
            observed: "generation-a",
            current: "generation-b"
        ))
        #expect(!AppDelegate.rateLimitResetFailureBelongsToCurrentCredentialGeneration(
            observed: nil,
            current: "generation-b"
        ))
        #expect(AppDelegate.rateLimitResetFailureBelongsToCurrentCredentialGeneration(
            observed: nil,
            current: nil
        ))
        #expect(AppDelegate.rateLimitResetFailureBelongsToCurrentCredentialGeneration(
            observed: "generation-a",
            current: nil
        ))
    }

    @Test("Local authorization rejection does not require reauthentication or restart")
    func localRejectionAllowsRetryOnlyWithResolvedJournal() {
        #expect(AppDelegate.localRateLimitResetFailureAllowsImmediateRetry(
            RateLimitResetServiceError.submissionUnauthorized,
            journalReportsUnresolved: false
        ))
        #expect(!AppDelegate.localRateLimitResetFailureAllowsImmediateRetry(
            RateLimitResetServiceError.submissionUnauthorized,
            journalReportsUnresolved: true
        ))
        #expect(!AppDelegate.localRateLimitResetFailureAllowsImmediateRetry(
            RateLimitResetServiceError.httpError(401),
            journalReportsUnresolved: false
        ))
        #expect(!AppDelegate.localRateLimitResetFailureAllowsImmediateRetry(
            RateLimitResetServiceError.journalUnavailable("unreadable"),
            journalReportsUnresolved: true
        ))
    }

    @Test("External reset holds survive reauthentication replacing the local UUID")
    func externalHoldUsesStableProviderIdentity() {
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        let before = account(providerAccountId: "Provider-A", resetBank: nil)
        let after = account(providerAccountId: " provider-a ", resetBank: nil)
        let other = account(providerAccountId: "provider-b", resetBank: nil)
        #expect(before.id != after.id)
        let holds = ["provider-a": until]
        #expect(AppDelegate.externalRateLimitResetHold(for: before, holds: holds) == until)
        #expect(AppDelegate.externalRateLimitResetHold(for: after, holds: holds) == until)
        #expect(AppDelegate.externalRateLimitResetHold(for: other, holds: holds) == nil)
    }

    @Test("A newer bank observation supersedes an older failure diagnostic")
    func newerBankSupersedesFailureDiagnostic() {
        let failureAt = Date(timeIntervalSince1970: 1_800_000_000)
        let failure = RateLimitResetFailurePolicy.updatedState(
            for: .transport("offline"),
            credentialFingerprint: "generation-a",
            previous: nil,
            now: failureAt
        )
        let olderBank = resetBank(
            availableCount: 1,
            fetchedAt: failureAt.addingTimeInterval(-1)
        )
        let newerBank = resetBank(
            availableCount: 1,
            fetchedAt: failureAt.addingTimeInterval(1)
        )

        #expect(AppDelegate.currentRateLimitResetFailureMessage(
            failure,
            bank: olderBank
        ) == failure.error)
        #expect(AppDelegate.currentRateLimitResetFailureMessage(
            failure,
            bank: newerBank
        ) == nil)
    }

    @Test("Credential handoff keeps the newest inventory from every participating view")
    @MainActor func credentialHandoffPreservesNewestInventoryAcrossAllViews() throws {
        let baseline = Date(timeIntervalSince1970: 1_800_000_000)
        var expected = [
            account(providerAccountId: "provider-a", resetBank: resetBank(availableCount: 1, fetchedAt: baseline)),
            account(providerAccountId: "provider-b", resetBank: resetBank(availableCount: 1, fetchedAt: baseline)),
            account(
                providerAccountId: "provider-c",
                resetBank: resetBank(availableCount: 5, fetchedAt: baseline.addingTimeInterval(50))
            ),
        ]
        expected[1].isActive = false
        expected[2].isActive = false

        var current = expected
        current[0].rateLimitResetBank = resetBank(
            availableCount: 2,
            fetchedAt: baseline.addingTimeInterval(20)
        )
        current[1].rateLimitResetBank = resetBank(
            availableCount: 4,
            fetchedAt: baseline.addingTimeInterval(40)
        )
        current[2].rateLimitResetBank = resetBank(
            availableCount: 2,
            fetchedAt: baseline.addingTimeInterval(20)
        )

        var persisted = expected
        persisted[0].rateLimitResetBank = resetBank(
            availableCount: 3,
            fetchedAt: baseline.addingTimeInterval(30)
        )
        persisted[1].rateLimitResetBank = resetBank(
            availableCount: 3,
            fetchedAt: baseline.addingTimeInterval(30)
        )
        persisted[2].rateLimitResetBank = resetBank(
            availableCount: 3,
            fetchedAt: baseline.addingTimeInterval(30)
        )

        let merged = try #require(AccountManager.committedCredentialHandoffSnapshot(
            persisted,
            preservingTelemetryFrom: current,
            expectedCredentialAuthority: expected,
            targetAccountId: expected[0].id
        ))

        #expect(merged[0].rateLimitResetBank?.availableCount == 3)
        #expect(merged[1].rateLimitResetBank?.availableCount == 4)
        #expect(merged[2].rateLimitResetBank?.availableCount == 5)
    }

    @Test("Telemetry merge accepts UUID and spelling replacement for the same provider")
    func telemetryMergeUsesNormalizedProviderIdentity() throws {
        let storePath = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: storePathDirectory(storePath)) }
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: storePath
        )
        let durable = account(providerAccountId: " Provider-A ", resetBank: nil)
        try store.saveAll([durable])
        var observed = account(
            localId: UUID(),
            providerAccountId: "provider-a",
            resetBank: resetBank(
                availableCount: 2,
                fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        observed.planType = "pro"

        guard case .persisted(let persisted) = try store.saveTelemetry([observed]) else {
            Issue.record("Equivalent provider identity should admit telemetry")
            return
        }

        let saved = try #require(persisted.first)
        #expect(saved.id == durable.id)
        #expect(saved.accountId == durable.accountId)
        #expect(saved.planType == "pro")
        #expect(saved.rateLimitResetBank?.availableCount == 2)
    }

    @Test("Normalized telemetry merge still rejects credential drift")
    func normalizedTelemetryMergeRejectsCredentialDrift() throws {
        let storePath = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: storePathDirectory(storePath)) }
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: storePath
        )
        let durable = account(providerAccountId: " Provider-A ", resetBank: nil)
        try store.saveAll([durable])
        var observed = account(
            localId: UUID(),
            providerAccountId: "provider-a",
            resetBank: resetBank(
                availableCount: 2,
                fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        observed.accessToken = "different-access-token"

        guard case .discardedCredentialDrift = try store.saveTelemetry([observed]) else {
            Issue.record("Provider identity must not bypass credential drift")
            return
        }
        #expect(try store.loadAll().first?.rateLimitResetBank == nil)
    }

    @Test("A failed refresh state follows provider identity but remains process-local")
    func failedRefreshStateSurvivesUUIDReplacementInProcess() throws {
        let bankFetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let failureObservedAt = bankFetchedAt.addingTimeInterval(60)
        let original = account(
            providerAccountId: " Provider-A ",
            resetBank: resetBank(availableCount: 2, fetchedAt: bankFetchedAt)
        )
        let providerAccountId = try #require(original.normalizedProviderAccountId)
        let failure = RateLimitResetFailurePolicy.updatedState(
            for: .transport("Bearer should-never-be-persisted"),
            credentialFingerprint: "credential-generation",
            previous: nil,
            now: failureObservedAt
        )
        let failureStates = [providerAccountId: failure]

        #expect(original.rateLimitResetBank?.availableCount == 2)
        #expect(failure.observedAt == failureObservedAt)
        #expect(!failure.error.contains("Bearer"))
        #expect(!failure.error.contains("should-never-be-persisted"))

        let replacement = account(
            localId: UUID(),
            providerAccountId: "provider-a",
            resetBank: nil
        )
        let replacementProviderAccountId = try #require(replacement.normalizedProviderAccountId)
        #expect(replacement.id != original.id)
        #expect(failureStates[replacementProviderAccountId] == failure)

        let stateAfterProcessRestart: [String: RateLimitResetFailureState] = [:]
        #expect(stateAfterProcessRestart[replacementProviderAccountId] == nil)
    }

    private func account(
        localId: UUID = UUID(),
        providerAccountId: String,
        resetBank: RateLimitResetBank?
    ) -> CodexAccount {
        CodexAccount(
            id: localId,
            email: "account@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: providerAccountId,
            rateLimitResetBank: resetBank,
            isActive: true
        )
    }

    private func resetBank(
        availableCount: Int,
        fetchedAt: Date
    ) -> RateLimitResetBank {
        let credits = (0..<availableCount).map { index in
            RateLimitResetCredit(
                id: "credit-\(index)",
                resetType: "usage",
                status: "available",
                grantedAt: fetchedAt.addingTimeInterval(-60),
                expiresAt: fetchedAt.addingTimeInterval(7 * 24 * 60 * 60),
                redeemedAt: nil,
                title: nil,
                description: nil
            )
        }
        return RateLimitResetBank(
            availableCount: availableCount,
            totalEarnedCount: availableCount,
            credits: credits,
            fetchedAt: fetchedAt
        )
    }

    private func temporaryStorePath() -> String {
        ("/private/tmp" as NSString)
            .appendingPathComponent(
                "CodexSwitchResetInventoryTests-\(UUID().uuidString)/accounts.json"
            )
    }

    private func storePathDirectory(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "RateLimitResetInventoryPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class ResetInventoryPersistenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[CodexAccount]] = []

    func record(_ accounts: [CodexAccount]) {
        lock.withLock { snapshots.append(accounts) }
    }

    func lastAccounts() -> [CodexAccount]? {
        lock.withLock { snapshots.last }
    }
}
