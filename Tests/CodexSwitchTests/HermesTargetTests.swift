import Foundation
import Testing
@testable import CodexSwitch

@Suite("HermesTarget")
struct HermesTargetTests {
    private func account() -> CodexAccount {
        CodexAccount(
            email: "hermes@example.com",
            accessToken: "access-secret",
            refreshToken: "refresh-secret",
            idToken: "id-secret",
            accountId: "acct-123"
        )
    }

    @Test("Merges OpenAI Codex OAuth state without removing unrelated providers")
    func mergesAuthState() throws {
        let merged = HermesTarget.mergeHermesAuth(
            account: account(),
            existing: [
                "providers": [
                    "anthropic": ["api_key": "keep-me"],
                    "openai-codex": ["custom": "keep-this-too"],
                ],
            ]
        )

        #expect(merged["active_provider"] as? String == "openai-codex")
        let providers = try #require(merged["providers"] as? [String: Any])
        let anthropic = try #require(providers["anthropic"] as? [String: Any])
        #expect(anthropic["api_key"] as? String == "keep-me")
        let codex = try #require(providers["openai-codex"] as? [String: Any])
        #expect(codex["custom"] as? String == "keep-this-too")
        #expect(codex["auth_mode"] as? String == "chatgpt")
        let tokens = try #require(codex["tokens"] as? [String: Any])
        #expect(tokens["access_token"] as? String == "access-secret")
        #expect(tokens["refresh_token"] as? String == "refresh-secret")
        #expect(tokens["id_token"] as? String == "id-secret")
        #expect(tokens["account_id"] as? String == "acct-123")
    }

    @Test("Updates only Hermes model provider settings")
    func updatesModelConfig() {
        let input = """
        ui:
          theme: dark
        model:
          default: "old"
          provider: "auto"
          base_url: "https://old.example"
        other:
          enabled: true
        """

        let updated = HermesTarget.updateModelConfigText(input)

        #expect(updated.contains("ui:\n  theme: dark"))
        #expect(updated.contains("model:\n  default: \"gpt-5.5\"\n  provider: \"openai-codex\"\n  base_url: \"https://chatgpt.com/backend-api/codex\""))
        #expect(updated.contains("other:\n  enabled: true"))
    }

    @Test("Writes auth atomically with secret permissions and backs up existing env")
    func applyLocalWritesAuthAndPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswitch-hermes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let envURL = root.appendingPathComponent(".env")
        try "UNRELATED=1\n".write(to: envURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: envURL.path)

        let result = try HermesTarget.applyLocal(account: account(), hermesHome: root)

        #expect(result.tokenHashPrefix == HermesTarget.tokenHashPrefix("access-secret"))
        #expect(result.envBackupPath != nil)
        let authURL = root.appendingPathComponent("auth.json")
        let auth = try JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any]
        #expect(auth?["active_provider"] as? String == "openai-codex")
        let authPerms = try FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? Int
        let envPerms = try FileManager.default.attributesOfItem(atPath: envURL.path)[.posixPermissions] as? Int
        #expect(authPerms == 0o600)
        #expect(envPerms == 0o600)
        #expect((try String(contentsOf: envURL)).contains("UNRELATED=1"))
    }
}
