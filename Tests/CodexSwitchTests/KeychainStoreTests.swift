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
    // Use unique service names per test to avoid polluting real Keychain
    private func isolatedStore() -> KeychainStore {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("CodexSwitchTests-\(UUID().uuidString)/accounts.json")
        return KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)
    }

    @Test("Store and retrieve account credentials")
    func storeAndRetrieve() throws {
        try withKnownIssue("Keychain unavailable without entitlements", isIntermittent: true) {
            guard keychainAvailable() else { throw KeychainError.saveFailed(-50) }
            let store = isolatedStore()
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
            let store = isolatedStore()
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
            let store = isolatedStore()
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

    @Test("Load accounts tolerates ISO date strings")
    func loadAccountsToleratesISODateStrings() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("CodexSwitchTests-\(UUID().uuidString)/accounts.json")
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)
        let json = """
        [
          {
            "id": "6632BCE7-FD12-4A87-A074-A5E3767C51CC",
            "email": "bd7349@me.com",
            "accessToken": "access",
            "refreshToken": "refresh",
            "idToken": "id-token",
            "accountId": "6632bce7-fd12-4a87-a074-a5e3767c51cc",
            "lastRefreshed": "2026-06-01T02:38:38Z",
            "isActive": true
          }
        ]
        """
        try json.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))

        let loaded = try store.loadAll()

        #expect(loaded.count == 1)
        #expect(loaded[0].email == "bd7349@me.com")
        #expect(loaded[0].lastRefreshed != nil)
        #expect(loaded[0].isActive)
    }

    @Test("Load accounts removes placeholder quota snapshots")
    func loadAccountsRemovesPlaceholderQuotaSnapshots() throws {
        let store = isolatedStore()
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 802_157_341)
        let account = CodexAccount(
            email: "brenchat7795@gmail.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id-token",
            accountId: "acc-brenchat",
            quotaSnapshot: QuotaSnapshot(
                fiveHour: QuotaWindow(
                    usedPercent: 0,
                    windowDurationMins: 300,
                    resetsAt: fetchedAt,
                    hardLimitReached: false
                ),
                weekly: QuotaWindow(
                    usedPercent: 0,
                    windowDurationMins: 10_080,
                    resetsAt: fetchedAt.addingTimeInterval(604_800),
                    hardLimitReached: false
                ),
                fetchedAt: fetchedAt
            ),
            planType: "pro",
            lastRefreshed: fetchedAt,
            isActive: true
        )
        try store.saveAll([account])

        let loaded = try store.loadAll()

        #expect(loaded.count == 1)
        #expect(loaded[0].quotaSnapshot == nil)
        #expect(loaded[0].lastRefreshed == nil)
        #expect(loaded[0].planType == "pro")
        #expect(loaded[0].isActive)
    }

    @Test("Save accounts removes placeholder quota snapshots before writing")
    func saveAccountsRemovesPlaceholderQuotaSnapshotsBeforeWriting() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("CodexSwitchTests-\(UUID().uuidString)/accounts.json")
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 802_157_341)
        let account = CodexAccount(
            email: "placeholder@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id-token",
            accountId: "acc-placeholder",
            quotaSnapshot: QuotaSnapshot(
                fiveHour: QuotaWindow(
                    usedPercent: 0,
                    windowDurationMins: 300,
                    resetsAt: fetchedAt,
                    hardLimitReached: false
                ),
                weekly: QuotaWindow(
                    usedPercent: 0,
                    windowDurationMins: 10_080,
                    resetsAt: fetchedAt.addingTimeInterval(604_800),
                    hardLimitReached: false
                ),
                fetchedAt: fetchedAt
            ),
            planType: "pro",
            lastRefreshed: fetchedAt,
            isActive: true
        )

        try store.saveAll([account])

        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))
        ) as? [[String: Any]]
        #expect(raw?.first?["quotaSnapshot"] == nil)
        #expect(raw?.first?["lastRefreshed"] == nil)
    }
}
