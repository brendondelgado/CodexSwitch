import Foundation
import Security
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "AccountStore")

/// File-based account storage at ~/.codexswitch/accounts.json (600 permissions).
/// Migrates from legacy Keychain on first load.
struct KeychainStore: Sendable {
    struct TestHooks: Sendable {
        enum LegacyReadResult: Sendable {
            case missing
            case data(Data)
            case invalidType
            case failure(OSStatus)
        }

        struct LegacyCredentials: Sendable {
            let read: @Sendable () throws -> LegacyReadResult
            let delete: @Sendable () throws -> Void

            init(
                data: Data,
                delete: @escaping @Sendable () throws -> Void
            ) {
                self.read = { .data(data) }
                self.delete = delete
            }

            init(
                read: @escaping @Sendable () throws -> LegacyReadResult,
                delete: @escaping @Sendable () throws -> Void
            ) {
                self.read = read
                self.delete = delete
            }
        }

        var beforeGenerationCheck: (@Sendable () throws -> Void)? = nil
        var beforeReadback: (@Sendable () throws -> Void)? = nil
        var legacyCredentials: LegacyCredentials? = nil
    }

    private typealias StoreGeneration = SecureAtomicFileTransaction.Generation

    private struct StoreSnapshot {
        let accounts: [CodexAccount]
        let bytes: Data?
        let generation: StoreGeneration

        static let missing = StoreSnapshot(
            accounts: [],
            bytes: nil,
            generation: .missing
        )
    }

    let service: String
    private let storePath: String
    private let fileTransaction: SecureAtomicFileTransaction
    private let testHooks: TestHooks
    private static let allAccountsKey = "all-accounts"
    private static let nilUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    private static let defaultStorePath: String = {
        let dir = NSString("~/.codexswitch").expandingTildeInPath
        return (dir as NSString).appendingPathComponent("accounts.json")
    }()
    private static let defaultStoreDir: String = {
        NSString("~/.codexswitch").expandingTildeInPath
    }()

    init(
        service: String = "com.codexswitch.accounts",
        storePath: String? = nil,
        testHooks: TestHooks = TestHooks()
    ) {
        self.service = service
        let expanded = NSString(string: storePath ?? Self.defaultStorePath).expandingTildeInPath
        self.storePath = expanded
        self.testHooks = testHooks
        self.fileTransaction = SecureAtomicFileTransaction(
            path: expanded,
            subject: "store",
            testHooks: .init(
                beforeGenerationCheck: testHooks.beforeGenerationCheck,
                beforeReadback: testHooks.beforeReadback
            )
        )
    }

    func save(_ account: CodexAccount) throws {
        try withExclusiveLock { lockedFile in
            let snapshot = try loadSnapshotOrMigrate(lockedFile: lockedFile)
            var accounts = snapshot.accounts
            // Deduplicate by accountId (OpenAI account UUID), not local id.
            if let index = accounts.firstIndex(where: { $0.accountId == account.accountId }) {
                accounts[index] = account
            } else {
                accounts.append(account)
            }
            _ = try commit(
                accounts,
                expectedGeneration: snapshot.generation,
                lockedFile: lockedFile
            )
        }
    }

    func loadAll() throws -> [CodexAccount] {
        try withExclusiveLock { lockedFile in
            try loadSnapshotOrMigrate(lockedFile: lockedFile).accounts
        }
    }

    func delete(_ accountId: UUID) throws {
        try withExclusiveLock { lockedFile in
            let snapshot = try readSnapshot(lockedFile: lockedFile, allowMissing: true)
            if snapshot.bytes != nil {
                let remaining = snapshot.accounts.filter { $0.id != accountId }
                if remaining.isEmpty {
                    try deleteStore(
                        expectedGeneration: snapshot.generation,
                        lockedFile: lockedFile
                    )
                    try deleteLegacyKeychainItem()
                } else {
                    _ = try commit(
                        remaining,
                        expectedGeneration: snapshot.generation,
                        lockedFile: lockedFile
                    )
                    try deleteLegacyKeychainItem()
                }
                return
            }

            guard let legacyAccounts = try decodedLegacyAccounts(),
                  legacyAccounts.contains(where: { $0.id == accountId }) else {
                return
            }

            let remaining = legacyAccounts.filter { $0.id != accountId }
            if remaining.isEmpty {
                try deleteStore(
                    expectedGeneration: snapshot.generation,
                    lockedFile: lockedFile
                )
            } else {
                _ = try commit(
                    remaining,
                    expectedGeneration: snapshot.generation,
                    lockedFile: lockedFile
                )
            }
            try deleteLegacyKeychainItem()
        }
    }

    func deleteAll() throws {
        try withExclusiveLock { lockedFile in
            let snapshot = try readSnapshot(lockedFile: lockedFile, allowMissing: true)
            try deleteStore(
                expectedGeneration: snapshot.generation,
                lockedFile: lockedFile
            )
            try deleteLegacyKeychainItem()
        }
    }

    func saveAll(_ accounts: [CodexAccount]) throws {
        try withExclusiveLock { lockedFile in
            let snapshot = try readSnapshot(lockedFile: lockedFile, allowMissing: true)
            _ = try commit(
                accounts,
                expectedGeneration: snapshot.generation,
                lockedFile: lockedFile
            )
        }
    }

    private func withExclusiveLock<T>(
        _ operation: (SecureAtomicFileTransaction.LockedFile) throws -> T
    ) throws -> T {
        do {
            return try fileTransaction.withExclusiveLock(operation)
        } catch let error as SecureAtomicFileError {
            throw Self.keychainError(from: error)
        }
    }

    private func loadSnapshotOrMigrate(
        lockedFile: SecureAtomicFileTransaction.LockedFile
    ) throws -> StoreSnapshot {
        let snapshot = try readSnapshot(lockedFile: lockedFile, allowMissing: true)
        guard snapshot.bytes == nil else {
            return snapshot
        }

        guard let accounts = try decodedLegacyAccounts() else {
            return snapshot
        }

        logger.info("Migrating \(accounts.count) accounts from Keychain to file store")

        let committed = try commit(
            accounts,
            expectedGeneration: snapshot.generation,
            lockedFile: lockedFile
        )
        // Delete legacy credentials only after durable commit and readback proof.
        try deleteLegacyKeychainItem()
        return committed
    }

    private func decodedLegacyAccounts() throws -> [CodexAccount]? {
        guard let data = try legacyCredentialData() else {
            return nil
        }

        let accounts = Self.removingPlaceholderQuotaSnapshots(
            try Self.accountDecoder.decode([CodexAccount].self, from: data)
        )
        try Self.validate(accounts)
        return accounts
    }

    private func readSnapshot(
        lockedFile: SecureAtomicFileTransaction.LockedFile,
        allowMissing: Bool
    ) throws -> StoreSnapshot {
        let raw = try lockedFile.read(allowMissing: allowMissing)
        guard let data = raw.bytes else { return .missing }
        let accounts = Self.removingPlaceholderQuotaSnapshots(
            try Self.accountDecoder.decode([CodexAccount].self, from: data)
        )
        try Self.validate(accounts)

        return StoreSnapshot(
            accounts: accounts,
            bytes: data,
            generation: raw.generation
        )
    }

    private func commit(
        _ proposedAccounts: [CodexAccount],
        expectedGeneration: StoreGeneration,
        lockedFile: SecureAtomicFileTransaction.LockedFile
    ) throws -> StoreSnapshot {
        let accounts = Self.removingPlaceholderQuotaSnapshots(proposedAccounts)
        try Self.validate(accounts)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(accounts)
        let rawReadback = try lockedFile.replace(data, expectedGeneration: expectedGeneration)
        guard rawReadback.bytes == data else {
            throw KeychainError.readbackMismatch(path: storePath)
        }
        let decoded = Self.removingPlaceholderQuotaSnapshots(
            try Self.accountDecoder.decode([CodexAccount].self, from: data)
        )
        try Self.validate(decoded)
        return StoreSnapshot(
            accounts: decoded,
            bytes: data,
            generation: rawReadback.generation
        )
    }

    private func deleteStore(
        expectedGeneration: StoreGeneration,
        lockedFile: SecureAtomicFileTransaction.LockedFile
    ) throws {
        let readback = try lockedFile.remove(expectedGeneration: expectedGeneration)
        guard readback == .missing else {
            throw KeychainError.readbackMismatch(path: storePath)
        }
    }

    private func legacyKeychainQuery(returnData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.allAccountsKey,
        ]
        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    private func legacyCredentialData() throws -> Data? {
        let readResult: TestHooks.LegacyReadResult
        if let injected = testHooks.legacyCredentials {
            readResult = try injected.read()
        } else {
            let query = legacyKeychainQuery(returnData: true)
            var rawResult: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &rawResult)
            if status == errSecItemNotFound {
                readResult = .missing
            } else if status != errSecSuccess {
                readResult = .failure(status)
            } else if let data = rawResult as? Data {
                readResult = .data(data)
            } else {
                readResult = .invalidType
            }
        }

        switch readResult {
        case .missing:
            return nil
        case .data(let data):
            return data
        case .invalidType:
            throw KeychainError.invalidLegacyCredentialResult
        case .failure(let status):
            throw KeychainError.loadFailed(status)
        }
    }

    private func deleteLegacyKeychainItem() throws {
        if let injected = testHooks.legacyCredentials {
            try injected.delete()
            return
        }

        let status = SecItemDelete(legacyKeychainQuery(returnData: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    private static func keychainError(from error: SecureAtomicFileError) -> KeychainError {
        switch error {
        case .lockFailed(let path, let operation, let code):
            return .lockFailed(path: path, operation: operation, code: code)
        case .operationFailed(let path, let operation, let code):
            return .fileOperationFailed(path: path, operation: operation, code: code)
        case .unsafePath(let path, let reason):
            return .unsafePath(path: path, reason: reason)
        case .staleGeneration(let expected, let actual):
            return .staleGeneration(expected: expected, actual: actual)
        case .readbackMismatch(let path):
            return .readbackMismatch(path: path)
        }
    }

    private static func validate(_ accounts: [CodexAccount]) throws {
        var accountIds = Set<String>()
        var localIds = Set<UUID>()

        for account in accounts {
            let accountId = account.accountId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !accountId.isEmpty else {
                throw KeychainError.missingAccountId
            }
            guard account.id != Self.nilUUID, localIds.insert(account.id).inserted else {
                if account.id == Self.nilUUID {
                    throw KeychainError.missingLocalId
                }
                throw KeychainError.duplicateLocalId(account.id)
            }
            guard accountIds.insert(accountId).inserted else {
                throw KeychainError.duplicateAccountId(accountId)
            }
        }

        let activeCount = accounts.lazy.filter(\.isActive).count
        guard accounts.isEmpty || activeCount == 1 else {
            throw KeychainError.invalidActiveAccountCount(activeCount)
        }
    }

    private static let accountDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: timestamp)
            }
            let string = try container.decode(String.self)
            if let timestamp = Double(string), timestamp.isFinite {
                return Date(timeIntervalSince1970: timestamp)
            }
            if let date = Self.decodeISO8601Date(string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected Apple reference timestamp, Unix timestamp string, or ISO-8601 date string"
            )
        }
        return decoder
    }()

    private static func decodeISO8601Date(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }

        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        return internet.date(from: string)
    }

    private static func removingPlaceholderQuotaSnapshots(_ accounts: [CodexAccount]) -> [CodexAccount] {
        accounts.map { account in
            guard account.quotaSnapshot?.hasBackendUsagePlaceholder == true else {
                return account
            }
            var cleaned = account
            cleaned.quotaSnapshot = nil
            cleaned.lastRefreshed = nil
            return cleaned
        }
    }
}

enum KeychainError: Error, Equatable, LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
    case duplicateAccountId(String)
    case duplicateLocalId(UUID)
    case missingAccountId
    case missingLocalId
    case invalidLegacyCredentialResult
    case invalidActiveAccountCount(Int)
    case lockFailed(path: String, operation: String, code: Int32)
    case fileOperationFailed(path: String, operation: String, code: Int32)
    case unsafePath(path: String, reason: String)
    case staleGeneration(expected: String, actual: String)
    case readbackMismatch(path: String)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status): return "Save failed: \(status)"
        case .loadFailed(let status): return "Load failed: \(status)"
        case .deleteFailed(let status): return "Delete failed: \(status)"
        case .duplicateAccountId(let accountId):
            return "Account store contains duplicate accountId identity: \(accountId)"
        case .duplicateLocalId(let id):
            return "Account store contains duplicate local id identity: \(id.uuidString)"
        case .missingAccountId:
            return "Account store contains a missing provider account identity"
        case .missingLocalId:
            return "Account store contains a missing local account identity"
        case .invalidLegacyCredentialResult:
            return "Legacy Keychain read succeeded without returning credential data"
        case .invalidActiveAccountCount(let count):
            return "A nonempty account store must contain exactly one active account; found \(count)"
        case .lockFailed(let path, let operation, let code):
            return "Account store lock \(operation) failed for \(path): errno \(code)"
        case .fileOperationFailed(let path, let operation, let code):
            return "Account store \(operation) failed for \(path): errno \(code)"
        case .unsafePath(let path, let reason):
            return "Unsafe account store path \(path): \(reason)"
        case .staleGeneration(let expected, let actual):
            return "Account store generation changed while locked: expected \(expected), found \(actual)"
        case .readbackMismatch(let path):
            return "Account store readback did not prove committed state for \(path)"
        }
    }
}
