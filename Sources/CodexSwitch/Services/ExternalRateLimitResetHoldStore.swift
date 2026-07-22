import Foundation

enum ExternalRateLimitResetHoldStoreError: Error, LocalizedError, Equatable {
    case corruptState(String)
    case readbackMismatch

    var errorDescription: String? {
        switch self {
        case .corruptState(let reason):
            "External reset hold state is corrupt: \(reason)"
        case .readbackMismatch:
            "External reset hold state did not match its secure-file readback"
        }
    }
}

struct ExternalRateLimitResetHoldStore {
    struct Hold: Codable, Equatable, Sendable {
        let observedAt: Date
        let blockedUntil: Date
    }

    private struct Snapshot: Codable, Equatable {
        let version: Int
        var holdsByProviderAccountId: [String: Hold]
    }

    private struct LoadedHolds {
        let values: [String: Hold]
        let migratedFromUserDefaults: Bool
    }

    static let defaultStorageKey = "externalRateLimitResetHolds.v1"
    static let defaultURL = URL(fileURLWithPath: NSString(
        string: "~/.codexswitch/external-rate-limit-reset-holds.json"
    ).expandingTildeInPath)

    let url: URL
    private let transaction: SecureAtomicFileTransaction
    private let legacyUserDefaults: UserDefaults?
    private let legacyStorageKey: String

    init(
        url: URL = Self.defaultURL,
        legacyUserDefaults: UserDefaults? = UserDefaults.standard,
        legacyStorageKey: String = Self.defaultStorageKey,
        transactionTestHooks: SecureAtomicFileTransaction.TestHooks = .init()
    ) {
        self.url = url
        self.transaction = SecureAtomicFileTransaction(
            path: url.path,
            subject: "external reset holds",
            testHooks: transactionTestHooks
        )
        self.legacyUserDefaults = legacyUserDefaults
        self.legacyStorageKey = legacyStorageKey
    }

    @discardableResult
    func record(
        providerAccountId: String,
        observedAt: Date,
        blockedUntil: Date
    ) throws -> Hold? {
        guard !providerAccountId.isEmpty, blockedUntil > observedAt else { return nil }

        return try withHolds { holds in
            _ = Self.pruneExpired(&holds, at: observedAt)
            let candidate = Hold(observedAt: observedAt, blockedUntil: blockedUntil)
            let effectiveHold: Hold
            if let existing = holds[providerAccountId], existing.blockedUntil > blockedUntil {
                effectiveHold = existing
            } else {
                effectiveHold = candidate
            }
            holds[providerAccountId] = effectiveHold
            return effectiveHold
        }
    }

    func activeHolds(at now: Date) throws -> [String: Hold] {
        try withHolds { holds in
            _ = Self.pruneExpired(&holds, at: now)
            return holds
        }
    }

    @discardableResult
    func clearIfQuotaRecovered(
        providerAccountId: String,
        snapshot: QuotaSnapshot,
        at now: Date
    ) throws -> Hold? {
        try withHolds { holds in
            _ = Self.pruneExpired(&holds, at: now)
            guard let hold = holds[providerAccountId],
                  snapshot.fetchedAt > hold.observedAt,
                  snapshot.isFresh(at: now),
                  !snapshot.hasBackendUsagePlaceholder,
                  snapshot.isImmediatelyUsable else {
                return nil
            }

            holds.removeValue(forKey: providerAccountId)
            return hold
        }
    }

    private func withHolds<T>(
        _ operation: (inout [String: Hold]) throws -> T
    ) throws -> T {
        let committed = try transaction.withExclusiveLock { lockedFile in
            let current = try lockedFile.read()
            let loaded = try loadHolds(secureData: current.bytes)
            var proposed = loaded.values
            let original = proposed
            let result = try operation(&proposed)

            if proposed != original || loaded.migratedFromUserDefaults {
                try persist(
                    proposed,
                    replacing: current,
                    using: lockedFile
                )
            }
            return (result, loaded.migratedFromUserDefaults)
        }

        if committed.1 {
            legacyUserDefaults?.removeObject(forKey: legacyStorageKey)
        }
        return committed.0
    }

    private func loadHolds(secureData: Data?) throws -> LoadedHolds {
        if let secureData {
            return LoadedHolds(
                values: try Self.decode(secureData),
                migratedFromUserDefaults: false
            )
        }

        guard let legacyUserDefaults,
              legacyUserDefaults.object(forKey: legacyStorageKey) != nil else {
            return LoadedHolds(values: [:], migratedFromUserDefaults: false)
        }
        guard let legacyData = legacyUserDefaults.data(forKey: legacyStorageKey) else {
            throw ExternalRateLimitResetHoldStoreError.corruptState(
                "legacy state is not encoded data"
            )
        }
        return LoadedHolds(
            values: try Self.decode(legacyData),
            migratedFromUserDefaults: true
        )
    }

    private func persist(
        _ holds: [String: Hold],
        replacing current: SecureAtomicFileTransaction.Snapshot,
        using lockedFile: SecureAtomicFileTransaction.LockedFile
    ) throws {
        guard !holds.isEmpty else {
            if current.bytes != nil {
                let readback = try lockedFile.remove(expectedGeneration: current.generation)
                guard readback.bytes == nil else {
                    throw ExternalRateLimitResetHoldStoreError.readbackMismatch
                }
            }
            return
        }

        let data = try Self.encode(holds)
        let readback = try lockedFile.replace(data, expectedGeneration: current.generation)
        guard try Self.decode(readback.bytes) == holds else {
            throw ExternalRateLimitResetHoldStoreError.readbackMismatch
        }
    }

    private static func decode(_ data: Data?) throws -> [String: Hold] {
        guard let data else { return [:] }
        let snapshot: Snapshot
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            throw ExternalRateLimitResetHoldStoreError.corruptState(
                "invalid JSON or schema"
            )
        }
        guard snapshot.version == 1 else {
            throw ExternalRateLimitResetHoldStoreError.corruptState(
                "unsupported version \(snapshot.version)"
            )
        }
        guard snapshot.holdsByProviderAccountId.allSatisfy({ providerAccountId, hold in
            !providerAccountId.isEmpty && hold.blockedUntil > hold.observedAt
        }) else {
            throw ExternalRateLimitResetHoldStoreError.corruptState(
                "invalid provider account key or hold interval"
            )
        }
        return snapshot.holdsByProviderAccountId
    }

    private static func encode(_ holds: [String: Hold]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Snapshot(version: 1, holdsByProviderAccountId: holds))
    }

    private static func pruneExpired(
        _ holds: inout [String: Hold],
        at now: Date
    ) -> Bool {
        let previousCount = holds.count
        holds = holds.filter { $0.value.blockedUntil > now }
        return holds.count != previousCount
    }
}

actor ExternalRateLimitResetHoldPersistence {
    private let store: ExternalRateLimitResetHoldStore

    init() {
        store = ExternalRateLimitResetHoldStore()
    }

    func activeHolds(
        at now: Date
    ) throws -> [String: ExternalRateLimitResetHoldStore.Hold] {
        try store.activeHolds(at: now)
    }

    func record(
        providerAccountId: String,
        observedAt: Date,
        blockedUntil: Date
    ) throws -> ExternalRateLimitResetHoldStore.Hold? {
        try store.record(
            providerAccountId: providerAccountId,
            observedAt: observedAt,
            blockedUntil: blockedUntil
        )
    }

    func clearIfQuotaRecovered(
        providerAccountId: String,
        snapshot: QuotaSnapshot,
        at now: Date
    ) throws -> ExternalRateLimitResetHoldStore.Hold? {
        try store.clearIfQuotaRecovered(
            providerAccountId: providerAccountId,
            snapshot: snapshot,
            at: now
        )
    }
}
