import Foundation
import os

private let accountPersistenceLogger = Logger(
    subsystem: "com.codexswitch",
    category: "AccountPersistence"
)

enum AccountPersistenceCoordinatorError: Error, Equatable {
    case authorizationLost
}

actor AccountPersistenceCoordinator {
    typealias Load = @Sendable () throws -> [CodexAccount]
    typealias Save = @Sendable ([CodexAccount]) throws -> Void
    typealias DeleteAll = @Sendable () throws -> Void
    typealias Now = @Sendable () -> Date

    static let telemetryMinimumWriteInterval: TimeInterval = 60
    static let telemetryFreshnessHeartbeatInterval: TimeInterval = 5 * 60
    static let telemetryPersistenceInterval: Duration = .seconds(60)

    private struct PendingTelemetry: Sendable {
        let revision: UInt64
        let accounts: [CodexAccount]
        let firstQueuedAt: Date
        let updateCount: Int
    }

    private enum TelemetryWriteKind: String {
        case semantic
        case freshnessHeartbeat = "freshness-heartbeat"
        case forced
    }

    private let loadOperation: Load
    private let saveOperation: Save
    private let deleteAllOperation: DeleteAll
    private let telemetryDelay: Duration
    private let now: Now
    private var latestRevision: UInt64 = 0
    private var pendingTelemetry: PendingTelemetry?
    private var telemetryFlushTask: Task<Void, Never>?
    private var lastPersistedAccountsData: Data?
    private var lastPersistedSemanticData: Data?
    private var lastPersistenceAt: Date?
    private var lastTelemetryPersistenceAt: Date?

    init(
        store: KeychainStore,
        telemetryDelay: Duration = telemetryPersistenceInterval,
        now: @escaping Now = { Date() }
    ) {
        self.loadOperation = { try store.loadAll() }
        self.saveOperation = { try store.saveAll($0) }
        self.deleteAllOperation = { try store.deleteAll() }
        self.telemetryDelay = telemetryDelay
        self.now = now
    }

    init(
        telemetryDelay: Duration = telemetryPersistenceInterval,
        now: @escaping Now = { Date() },
        load: @escaping Load,
        save: @escaping Save,
        deleteAll: @escaping DeleteAll
    ) {
        self.loadOperation = load
        self.saveOperation = save
        self.deleteAllOperation = deleteAll
        self.telemetryDelay = telemetryDelay
        self.now = now
    }

    func loadAll() throws -> [CodexAccount] {
        let accounts = try loadOperation()
        recordSuccessfulPersistence(of: accounts, at: now(), isTelemetry: false)
        return accounts
    }

    func persistDurably(_ accounts: [CodexAccount], revision: UInt64) throws {
        try persistDurably(
            accounts,
            revision: revision,
            authorizeEffect: { true }
        )
    }

    func persistDurably(
        _ accounts: [CodexAccount],
        revision: UInt64,
        authorizeEffect: @Sendable () -> Bool
    ) throws {
        guard authorizeEffect() else {
            throw AccountPersistenceCoordinatorError.authorizationLost
        }
        guard revision >= latestRevision else { return }
        latestRevision = revision
        telemetryFlushTask?.cancel()
        telemetryFlushTask = nil
        if let pendingTelemetry, pendingTelemetry.revision <= revision {
            self.pendingTelemetry = nil
        }
        guard authorizeEffect() else {
            throw AccountPersistenceCoordinatorError.authorizationLost
        }
        try saveOperation(accounts)
        recordSuccessfulPersistence(of: accounts, at: now(), isTelemetry: false)
    }

    func deleteAllDurably(revision: UInt64) throws {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        telemetryFlushTask?.cancel()
        telemetryFlushTask = nil
        pendingTelemetry = nil
        try deleteAllOperation()
        recordSuccessfulPersistence(of: [], at: now(), isTelemetry: false)
    }

    func queueTelemetry(_ accounts: [CodexAccount], revision: UInt64) {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        let queuedAt = now()
        pendingTelemetry = PendingTelemetry(
            revision: revision,
            accounts: accounts,
            firstQueuedAt: pendingTelemetry?.firstQueuedAt ?? queuedAt,
            updateCount: (pendingTelemetry?.updateCount ?? 0) + 1
        )
        scheduleTelemetryFlushIfNeeded()
    }

    func flushTelemetryIfDue() throws -> Bool {
        telemetryFlushTask?.cancel()
        telemetryFlushTask = nil
        do {
            let persisted = try persistPendingTelemetry(force: false, at: now())
            scheduleTelemetryFlushIfNeeded()
            return persisted
        } catch {
            scheduleTelemetryFlushIfNeeded()
            throw error
        }
    }

    func flushTelemetry() throws {
        telemetryFlushTask?.cancel()
        telemetryFlushTask = nil
        do {
            _ = try persistPendingTelemetry(force: true, at: now())
        } catch {
            scheduleTelemetryFlushIfNeeded()
            throw error
        }
    }

    private func scheduleTelemetryFlushIfNeeded() {
        guard pendingTelemetry != nil, telemetryFlushTask == nil else { return }
        telemetryFlushTask = Task { [weak self, telemetryDelay] in
            do {
                try await Task.sleep(for: telemetryDelay)
            } catch {
                return
            }
            await self?.flushScheduledTelemetry()
        }
    }

    private func flushScheduledTelemetry() {
        telemetryFlushTask = nil
        do {
            _ = try persistPendingTelemetry(force: false, at: now())
            scheduleTelemetryFlushIfNeeded()
        } catch {
            accountPersistenceLogger.error(
                "Coalesced account telemetry persistence failed: \(error.localizedDescription, privacy: .public)"
            )
            SwapLog.append(.debug(
                "ACCOUNTS_PERSIST_FAILED context=telemetry-coalesced error=\(error.localizedDescription)"
            ))
            scheduleTelemetryFlushIfNeeded()
        }
    }

    private func persistPendingTelemetry(force: Bool, at date: Date) throws -> Bool {
        guard let pending = pendingTelemetry else { return false }

        let accountsData = Self.encodedAccounts(pending.accounts)
        let semanticData = Self.encodedSemanticAccounts(pending.accounts)
        if !force,
           let accountsData,
           accountsData == lastPersistedAccountsData {
            pendingTelemetry = nil
            return false
        }

        let writeKind: TelemetryWriteKind
        if force {
            writeKind = .forced
        } else {
            let queuedLongEnough = date.timeIntervalSince(pending.firstQueuedAt)
                >= Self.telemetryMinimumWriteInterval
            let cadenceAllowsWrite = lastTelemetryPersistenceAt.map {
                date.timeIntervalSince($0) >= Self.telemetryMinimumWriteInterval
            } ?? true
            guard queuedLongEnough, cadenceAllowsWrite else { return false }

            let semanticChanged: Bool
            if let semanticData, let lastPersistedSemanticData {
                semanticChanged = semanticData != lastPersistedSemanticData
            } else {
                semanticChanged = true
            }
            if semanticChanged {
                writeKind = .semantic
            } else {
                let heartbeatAnchor = lastPersistenceAt ?? pending.firstQueuedAt
                guard date.timeIntervalSince(heartbeatAnchor)
                    >= Self.telemetryFreshnessHeartbeatInterval else {
                    return false
                }
                writeKind = .freshnessHeartbeat
            }
        }

        pendingTelemetry = nil
        do {
            try saveOperation(pending.accounts)
            recordSuccessfulPersistence(
                of: pending.accounts,
                at: date,
                isTelemetry: true
            )
            SwapLog.append(.debug(
                "ACCOUNTS_PERSISTED context=telemetry-coalesced mode=\(writeKind.rawValue) revision=\(pending.revision) updates=\(pending.updateCount)"
            ))
            return true
        } catch {
            pendingTelemetry = pending
            throw error
        }
    }

    private func recordSuccessfulPersistence(
        of accounts: [CodexAccount],
        at date: Date,
        isTelemetry: Bool
    ) {
        lastPersistedAccountsData = Self.encodedAccounts(accounts)
        lastPersistedSemanticData = Self.encodedSemanticAccounts(accounts)
        lastPersistenceAt = date
        if isTelemetry {
            lastTelemetryPersistenceAt = date
        }
    }

    private static func encodedAccounts(_ accounts: [CodexAccount]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(accounts)
    }

    private static func encodedSemanticAccounts(_ accounts: [CodexAccount]) -> Data? {
        let freshnessAnchor = Date(timeIntervalSinceReferenceDate: 0)
        let normalized = accounts.map { account in
            var account = account
            if account.lastRefreshed != nil {
                account.lastRefreshed = freshnessAnchor
            }
            if let snapshot = account.quotaSnapshot {
                account.quotaSnapshot = QuotaSnapshot(
                    allowed: snapshot.allowed,
                    limitReached: snapshot.limitReached,
                    fetchedAt: freshnessAnchor,
                    windows: snapshot.windows
                )
            }
            if let bank = account.rateLimitResetBank {
                account.rateLimitResetBank = RateLimitResetBank(
                    availableCount: bank.availableCount,
                    totalEarnedCount: bank.totalEarnedCount,
                    credits: bank.credits,
                    fetchedAt: freshnessAnchor
                )
            }
            return account
        }
        return encodedAccounts(normalized)
    }
}
