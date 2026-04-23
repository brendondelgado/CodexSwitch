import Testing
import Foundation
import Security
@testable import CodexSwitch

/// Probe whether Keychain access works in this environment.
/// Returns false when running without entitlements (e.g. `swift test` on CI).
private func keychainAvailable() -> Bool {
    let probe = "CodexSwitch-Probe-\(UUID().uuidString)"
    let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: probe,
        kSecAttrAccount as String: "probe",
        kSecValueData as String: Data("x".utf8),
    ]
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus == errSecSuccess {
        let delQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probe,
        ]
        SecItemDelete(delQuery as CFDictionary)
        return true
    }
    return false
}

@Suite("KeychainStore")
struct KeychainStoreTests {
    private func makeTempStore() throws -> (KeychainStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitch-KeychainStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("accounts.json")
        return (KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storeURL: storeURL), dir)
    }

    // Use unique service names per test to avoid polluting real Keychain
    @Test("Store and retrieve account credentials")
    func storeAndRetrieve() throws {
        try withKnownIssue("Keychain unavailable without entitlements", isIntermittent: true) {
            guard keychainAvailable() else { throw KeychainError.saveFailed(-50) }
            let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)")
            let account = CodexAccount(
                email: "test@example.com",
                accessToken: "access_123",
                refreshToken: "refresh_456",
                idToken: "id_789",
                accountId: "acc-test"
            )
            try store.save(account)
            let loaded = try store.loadAll()
            #expect(loaded.count == 1)
            #expect(loaded[0].email == "test@example.com")
            #expect(loaded[0].accessToken == "access_123")
            #expect(loaded[0].accountId == "acc-test")

            // Cleanup
            try store.delete(account.id)
        }
    }

    @Test("Update existing account")
    func updateAccount() throws {
        try withKnownIssue("Keychain unavailable without entitlements", isIntermittent: true) {
            guard keychainAvailable() else { throw KeychainError.saveFailed(-50) }
            let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)")
            var account = CodexAccount(
                email: "test@example.com",
                accessToken: "old_token",
                refreshToken: "refresh",
                idToken: "id",
                accountId: "acc-1"
            )
            try store.save(account)
            account.accessToken = "new_token"
            try store.save(account)
            let loaded = try store.loadAll()
            #expect(loaded.count == 1)
            #expect(loaded[0].accessToken == "new_token")

            try store.delete(account.id)
        }
    }

    @Test("Delete account")
    func deleteAccount() throws {
        try withKnownIssue("Keychain unavailable without entitlements", isIntermittent: true) {
            guard keychainAvailable() else { throw KeychainError.saveFailed(-50) }
            let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)")
            let account = CodexAccount(
                email: "test@example.com",
                accessToken: "t",
                refreshToken: "r",
                idToken: "i",
                accountId: "acc-del"
            )
            try store.save(account)
            try store.delete(account.id)
            let loaded = try store.loadAll()
            #expect(loaded.isEmpty)
        }
    }

    @Test("Import from auth.json format")
    func importFromAuthJson() throws {
        let json = """
        {
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": null,
            "tokens": {
                "id_token": "idt_abc",
                "access_token": "act_def",
                "refresh_token": "rft_ghi",
                "account_id": "df3c3241-56e1-4dfb-b6aa-dd0f6e3286a1"
            },
            "last_refresh": "2026-03-12T08:44:18.860111Z"
        }
        """
        let account = try AccountImporter.accountFromAuthJSON(json.data(using: .utf8)!)
        #expect(account.accessToken == "act_def")
        #expect(account.accountId == "df3c3241-56e1-4dfb-b6aa-dd0f6e3286a1")
        #expect(account.email.contains("@")) // Extracted from JWT or fallback
    }

    @Test("Replacing all accounts persists only one active account")
    func replaceAllNormalizesActiveFlags() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let plus = CodexAccount(
            email: "plus@test.com",
            accessToken: "t1",
            refreshToken: "r1",
            idToken: "i1",
            accountId: "plus-account",
            isActive: true
        )
        let pro = CodexAccount(
            email: "pro@test.com",
            accessToken: "t2",
            refreshToken: "r2",
            idToken: "i2",
            accountId: "pro-account",
            isActive: true
        )

        try store.replaceAll([plus, pro])

        let loaded = try store.loadAll()
        let activeAccounts = loaded.filter(\.isActive)
        #expect(activeAccounts.count == 1)
        #expect(activeAccounts.first?.accountId == "pro-account")
    }

    @Test("Re-authentication state survives file round-trip")
    func reauthenticationStateRoundTrips() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let account = CodexAccount(
            email: "stale@test.com",
            accessToken: "t1",
            refreshToken: "r1",
            idToken: "i1",
            accountId: "stale-account",
            reauthenticationError: "Re-authentication required — refresh token rejected",
            isActive: false
        )

        try store.replaceAll([account])

        let loaded = try store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].reauthenticationError == "Re-authentication required — refresh token rejected")
    }
}
