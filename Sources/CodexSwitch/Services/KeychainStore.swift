import Foundation
import Security
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "AccountStore")

/// File-based account storage at ~/.codexswitch/accounts.json (600 permissions).
/// Migrates from legacy Keychain on first load.
struct KeychainStore: Sendable {
    let service: String
    private let storeURL: URL
    private static let allAccountsKey = "all-accounts"
    private static let defaultStoreURL: URL = {
        let dir = URL(fileURLWithPath: NSString("~/.codexswitch").expandingTildeInPath, isDirectory: true)
        return dir.appendingPathComponent("accounts.json")
    }()

    init(
        service: String = "com.codexswitch.accounts",
        storeURL: URL = Self.defaultStoreURL
    ) {
        self.service = service
        self.storeURL = storeURL
    }

    func save(_ account: CodexAccount) throws {
        var accounts = try loadAll()
        // Deduplicate by accountId (OpenAI account UUID), not local id
        if let idx = accounts.firstIndex(where: { $0.accountId == account.accountId }) {
            accounts[idx] = account
        } else {
            accounts.append(account)
        }
        try saveAll(accounts)
    }

    func replaceAll(_ accounts: [CodexAccount]) throws {
        try saveAll(accounts)
    }

    func loadAll() throws -> [CodexAccount] {
        // Try file store first (no fileExists check — avoids TOCTOU race)
        do {
            let data = try Data(contentsOf: storeURL)
            return try JSONDecoder().decode([CodexAccount].self, from: data)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // File doesn't exist — fall through to Keychain migration
        }

        // Migrate from legacy Keychain if present
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.allAccountsKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var legacyResult: AnyObject?
        let status = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult)

        if status == errSecItemNotFound {
            return []
        }
        if status != errSecSuccess {
            // Keychain denied — may be a fresh build with no ACL.
            // Return empty rather than throw, so app still launches.
            logger.warning("Keychain read failed (status: \(status)) — returning empty. Re-add accounts to migrate.")
            return []
        }
        guard let data = legacyResult as? Data else {
            return []
        }

        let accounts = try JSONDecoder().decode([CodexAccount].self, from: data)
        logger.info("Migrating \(accounts.count) accounts from Keychain to file store")

        // Save to file, then clean up Keychain
        try saveAll(accounts)
        SecItemDelete(legacyQuery as CFDictionary)

        return accounts
    }

    func delete(_ accountId: UUID) throws {
        var accounts = try loadAll()
        accounts.removeAll { $0.id == accountId }
        if accounts.isEmpty {
            try deleteAll()
        } else {
            try saveAll(accounts)
        }
    }

    func deleteAll() throws {
        if FileManager.default.fileExists(atPath: storeURL.path) {
            try FileManager.default.removeItem(at: storeURL)
        }
        // Also clean up legacy Keychain if present
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.allAccountsKey,
        ]
        SecItemDelete(legacyQuery as CFDictionary)
    }

    // MARK: - Private

    private func saveAll(_ accounts: [CodexAccount]) throws {
        let normalizedAccounts = normalized(accounts)

        // Ensure directory exists
        let storeDir = storeURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: storeDir.path) {
            try FileManager.default.createDirectory(
                at: storeDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalizedAccounts)

        // .atomic already writes to tmp + renames internally
        try data.write(to: storeURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storeURL.path
        )
    }

    private func normalized(_ accounts: [CodexAccount]) -> [CodexAccount] {
        let activeIndices = accounts.indices.filter { accounts[$0].isActive }
        guard activeIndices.count > 1, let indexToKeep = activeIndices.last else {
            return accounts
        }

        var normalizedAccounts = accounts
        for index in normalizedAccounts.indices {
            normalizedAccounts[index].isActive = (index == indexToKeep)
        }
        logger.warning("Normalized \(activeIndices.count) active accounts down to one in file store")
        return normalizedAccounts
    }
}

enum KeychainError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let s): return "Save failed: \(s)"
        case .loadFailed(let s): return "Load failed: \(s)"
        case .deleteFailed(let s): return "Delete failed: \(s)"
        }
    }
}
