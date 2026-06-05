import Foundation
import Testing
@testable import CodexSwitch

@Suite("Linux devbox export")
struct LinuxDevboxExportServiceTests {
    @Test("Encrypted bundle metadata does not leak tokens")
    func encryptedBundleMetadataDoesNotLeakTokens() throws {
        let account = CodexAccount(
            email: "dev@example.com",
            accessToken: "access-token-secret",
            refreshToken: "refresh-token-secret",
            idToken: "id-token-secret",
            accountId: "account-id-secret",
            planType: "plus",
            isActive: true
        )
        let service = LinuxDevboxExportService(
            now: { Date(timeIntervalSince1970: 1_893_456_000) },
            hostName: { "test-host" }
        )

        let bundle = try service.makeEncryptedBundle(
            accounts: [account],
            passphrase: "long-test-passphrase",
            confirmation: "long-test-passphrase"
        )
        let bundleText = String(decoding: bundle.data, as: UTF8.self)

        #expect(bundle.metadata.accountCount == 1)
        #expect(bundle.metadata.activeEmail == "dev@example.com")
        #expect(bundleText.contains("\"createdAt\" : \"2030-01-01T00:00:00Z\""))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encrypted = try decoder.decode(LinuxDevboxEncryptedBundle.self, from: bundle.data)
        let nonce = try #require(Data(base64Encoded: encrypted.nonce))
        let ciphertext = try #require(Data(base64Encoded: encrypted.ciphertext))
        #expect(ciphertext.prefix(nonce.count) != nonce)
        #expect(bundleText.contains("dev@example.com"))
        #expect(!bundleText.contains("access-token-secret"))
        #expect(!bundleText.contains("refresh-token-secret"))
        #expect(!bundleText.contains("id-token-secret"))
        #expect(!bundleText.contains("account-id-secret"))
    }

    @Test("Export writes cxbundle with import commands")
    func exportWritesBundleWithImportCommands() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexswitch-export-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let account = CodexAccount(
            email: "dev@example.com",
            accessToken: "access-token-secret",
            refreshToken: "refresh-token-secret",
            idToken: "id-token-secret",
            accountId: "account-id-secret",
            isActive: true
        )
        let service = LinuxDevboxExportService(
            now: { Date(timeIntervalSince1970: 1_893_456_000) },
            hostName: { "test-host" }
        )

        let result = try service.export(
            accounts: [account],
            passphrase: "long-test-passphrase",
            confirmation: "long-test-passphrase",
            outputDirectory: dir
        )

        #expect(result.fileURL.lastPathComponent == "codexswitch-linux-devbox-20300101-000000.csbundle")
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))
        #expect(result.copyCommand.contains("scp"))
        #expect(result.importCommand.contains("codexswitch-cli import"))
    }

    @Test("Export rejects short or mismatched passphrases")
    func exportRejectsWeakPassphrases() throws {
        let account = CodexAccount(
            email: "dev@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "account"
        )
        let service = LinuxDevboxExportService()

        #expect(throws: LinuxDevboxExportError.passphraseTooShort) {
            try service.makeEncryptedBundle(accounts: [account], passphrase: "short", confirmation: "short")
        }
        #expect(throws: LinuxDevboxExportError.passphrasesDoNotMatch) {
            try service.makeEncryptedBundle(
                accounts: [account],
                passphrase: "long-test-passphrase",
                confirmation: "different-passphrase"
            )
        }
    }
}
