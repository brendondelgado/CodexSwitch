import Testing
import Foundation
@testable import CodexSwitch

@Suite("KeychainStore")
struct KeychainStoreTests {
    // Use unique service names per test to avoid polluting real Keychain
    @Test("Store and retrieve account credentials")
    func storeAndRetrieve() throws {
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

    @Test("Update existing account")
    func updateAccount() throws {
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

    @Test("Delete account")
    func deleteAccount() throws {
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
}
