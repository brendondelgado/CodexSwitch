import CryptoKit
import Foundation
import Testing
@testable import CodexSwitch

@Suite("Linux devbox export")
struct LinuxDevboxExportServiceTests {
    @Test("PBKDF2 HMAC SHA256 matches the one-block reference vector")
    func pbkdf2MatchesReferenceVector() throws {
        var key = try LinuxDevboxExportService.deriveKey(
            passphraseBytes: Data("password".utf8),
            salt: Data("salt".utf8),
            iterations: 1
        )
        defer { key.resetBytes(in: 0..<key.count) }

        #expect(key.count == LinuxDevboxExportService.derivedKeyByteCount)
        #expect(key.hexString == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    @Test("V2 envelope exposes only exact cryptographic routing fields")
    func v2EnvelopeKeepsMetadataConfidential() throws {
        let fixture = try loadFixtureSpec()
        let service = try deterministicService(fixture: fixture)
        let bundle = try service.makeEncryptedBundle(
            accounts: [fixture.account.codexAccount],
            passphrase: fixture.passphrase,
            confirmation: fixture.passphrase,
            lifetime: fixture.expiresAt.timeIntervalSince(fixture.createdAt)
        )
        let bundleText = String(decoding: bundle.data, as: UTF8.self)
        let object = try #require(
            JSONSerialization.jsonObject(with: bundle.data) as? [String: Any]
        )

        #expect(Set(object.keys) == [
            "format", "schemaVersion", "kdf", "iterations", "cipher", "salt", "nonce", "ciphertext",
        ])
        #expect(object["format"] as? String == LinuxDevboxExportService.format)
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object["kdf"] as? String == "pbkdf2-hmac-sha256-v2")
        #expect(object["iterations"] as? Int == 600_000)
        #expect(object["cipher"] as? String == "aes-256-gcm")
        #expect(bundle.metadata.accountCount == 1)
        #expect(bundle.metadata.activeAccountId == fixture.account.accountId)
        #expect(bundle.metadata.activeEmail == fixture.account.email)
        #expect(bundle.metadata.emails == [fixture.account.email])
        for confidentialValue in [
            fixture.account.email,
            fixture.account.id.uuidString,
            fixture.account.accountId,
            fixture.account.accessToken,
            fixture.account.refreshToken,
            fixture.account.idToken,
            fixture.hostName,
        ] {
            #expect(!bundleText.contains(confidentialValue))
        }

        let payload = try decryptV2Bundle(bundle.data, passphrase: fixture.passphrase)
        #expect(payload.metadata == bundle.metadata)
        #expect(payload.accounts.count == 1)
        #expect(payload.accounts[0].email == fixture.account.email)
        #expect(payload.accounts[0].accessToken == fixture.account.accessToken)
        #expect(payload.metadata.accountCount == payload.accounts.count)
        #expect(payload.metadata.emails == payload.accounts.map(\.email))
        #expect(payload.metadata.activeAccountId == payload.accounts.first(where: \.isActive)?.accountId)
        #expect(payload.metadata.activeEmail == payload.accounts.first(where: \.isActive)?.email)
    }

    @Test("Deterministic Swift generation matches the cross-language v2 fixture")
    func deterministicGenerationMatchesFixture() throws {
        let fixture = try loadFixtureSpec()
        let service = try deterministicService(fixture: fixture)
        let generated = try service.makeEncryptedBundle(
            accounts: [fixture.account.codexAccount],
            passphrase: fixture.passphrase,
            confirmation: fixture.passphrase,
            lifetime: fixture.expiresAt.timeIntervalSince(fixture.createdAt)
        )
        let expectedData = try Data(contentsOf: fixtureURL("v2.csbundle"))
        let decoder = JSONDecoder()
        let generatedEnvelope = try decoder.decode(LinuxDevboxEncryptedBundle.self, from: generated.data)
        let expectedEnvelope = try decoder.decode(LinuxDevboxEncryptedBundle.self, from: expectedData)

        #expect(generatedEnvelope == expectedEnvelope)
        let payload = try decryptV2Bundle(expectedData, passphrase: fixture.passphrase)
        let expectedPayloadData = try Data(contentsOf: fixtureURL("v2-payload.json"))
        let payloadDecoder = JSONDecoder()
        payloadDecoder.dateDecodingStrategy = .iso8601
        let expectedPayload = try payloadDecoder.decode(
            LinuxDevboxBundlePayload.self,
            from: expectedPayloadData
        )
        #expect(payload.metadata.schemaVersion == 2)
        #expect(payload.metadata.exportedByHost == fixture.hostName)
        #expect(payload.accounts.map(\.email) == [fixture.account.email])
        #expect(payload.metadata == expectedPayload.metadata)
        #expect(payload.accounts.map(\.id) == expectedPayload.accounts.map(\.id))
        #expect(payload.accounts.map(\.accessToken) == expectedPayload.accounts.map(\.accessToken))
    }

    @Test("Bundle creation preserves the caller-selected active account")
    func bundleCreationDoesNotRerankTheActiveAccount() throws {
        var plus = CodexAccount(
            email: "plus@example.com",
            accessToken: "plus-access",
            refreshToken: "plus-refresh",
            idToken: "plus-id",
            accountId: "plus-account",
            isActive: true
        )
        plus.planType = "plus"
        var pro = CodexAccount(
            email: "pro@example.com",
            accessToken: "pro-access",
            refreshToken: "pro-refresh",
            idToken: "pro-id",
            accountId: "pro-account",
            isActive: false
        )
        pro.planType = "pro"
        let service = LinuxDevboxExportService(
            randomBytes: { Data(repeating: 0x42, count: $0) }
        )

        let bundle = try service.makeEncryptedBundle(
            accounts: [plus, pro],
            passphrase: "host-ownership-test",
            confirmation: "host-ownership-test"
        )

        #expect(bundle.metadata.activeAccountId == "plus-account")
        #expect(bundle.metadata.activeEmail == "plus@example.com")
    }

    @Test("Export writes a mode 0600 csbundle with import commands")
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
        let attributes = try FileManager.default.attributesOfItem(atPath: result.fileURL.path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber).uint16Value

        #expect(result.fileURL.lastPathComponent == "codexswitch-linux-devbox-20300101-000000.csbundle")
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))
        #expect(mode == 0o600)
        #expect(result.copyCommand.contains("scp"))
        #expect(result.importCommand.contains("codexswitch-cli import"))
    }

    @Test("Export rejects passphrase and account bounds before encryption")
    func exportRejectsInvalidBounds() throws {
        var account = CodexAccount(
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
        #expect(throws: LinuxDevboxExportError.passphraseTooLong) {
            let passphrase = String(repeating: "x", count: LinuxDevboxExportService.maximumPassphraseByteCount + 1)
            try service.makeEncryptedBundle(accounts: [account], passphrase: passphrase, confirmation: passphrase)
        }
        #expect(throws: LinuxDevboxExportError.passphrasesDoNotMatch) {
            try service.makeEncryptedBundle(
                accounts: [account],
                passphrase: "long-test-passphrase",
                confirmation: "different-passphrase"
            )
        }

        account.accessToken = String(
            repeating: "x",
            count: LinuxDevboxExportService.maximumTokenByteCount + 1
        )
        #expect(throws: LinuxDevboxExportError.accountFieldTooLarge) {
            try service.makeEncryptedBundle(
                accounts: [account],
                passphrase: "long-test-passphrase",
                confirmation: "long-test-passphrase"
            )
        }

        account.accessToken = "access"
        account.email = String(
            repeating: "x",
            count: LinuxDevboxExportService.maximumEmailByteCount + 1
        )
        #expect(throws: LinuxDevboxExportError.accountFieldTooLarge) {
            try service.makeEncryptedBundle(
                accounts: [account],
                passphrase: "long-test-passphrase",
                confirmation: "long-test-passphrase"
            )
        }

        let oversizedHostService = LinuxDevboxExportService(
            hostName: {
                String(
                    repeating: "x",
                    count: LinuxDevboxExportService.maximumInnerStringByteCount + 1
                )
            }
        )
        account.email = "dev@example.com"
        #expect(throws: LinuxDevboxExportError.accountFieldTooLarge) {
            try oversizedHostService.makeEncryptedBundle(
                accounts: [account],
                passphrase: "long-test-passphrase",
                confirmation: "long-test-passphrase"
            )
        }
    }
}

private struct CredentialBundleFixtureSpec: Decodable, Sendable {
    let passphrase: String
    let saltBase64: String
    let nonceBase64: String
    let createdAt: Date
    let expiresAt: Date
    let hostName: String
    let account: CredentialBundleFixtureAccount
}

private struct CredentialBundleFixtureAccount: Decodable, Sendable {
    let id: UUID
    let email: String
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let accountId: String
    let planType: String

    var codexAccount: CodexAccount {
        CodexAccount(
            id: id,
            email: email,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: accountId,
            planType: planType,
            isActive: true
        )
    }
}

private enum CredentialBundleFixtureError: Error {
    case invalidFixture
}

private func loadFixtureSpec() throws -> CredentialBundleFixtureSpec {
    let data = try Data(contentsOf: fixtureURL("fixture.json"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CredentialBundleFixtureSpec.self, from: data)
}

private func deterministicService(
    fixture: CredentialBundleFixtureSpec
) throws -> LinuxDevboxExportService {
    guard let salt = Data(base64Encoded: fixture.saltBase64),
          let nonce = Data(base64Encoded: fixture.nonceBase64) else {
        throw CredentialBundleFixtureError.invalidFixture
    }
    return LinuxDevboxExportService(
        now: { fixture.createdAt },
        hostName: { fixture.hostName },
        randomBytes: { count in
            switch count {
            case LinuxDevboxExportService.saltByteCount:
                return salt
            case LinuxDevboxExportService.nonceByteCount:
                return nonce
            default:
                throw CredentialBundleFixtureError.invalidFixture
            }
        }
    )
}

private func decryptV2Bundle(
    _ data: Data,
    passphrase: String
) throws -> LinuxDevboxBundlePayload {
    let decoder = JSONDecoder()
    let envelope = try decoder.decode(LinuxDevboxEncryptedBundle.self, from: data)
    guard envelope.format == LinuxDevboxExportService.format,
          envelope.schemaVersion == LinuxDevboxExportService.schemaVersion,
          envelope.kdf == LinuxDevboxExportService.kdf,
          envelope.iterations == LinuxDevboxExportService.iterations,
          envelope.cipher == LinuxDevboxExportService.cipher,
          let salt = Data(base64Encoded: envelope.salt),
          let nonceData = Data(base64Encoded: envelope.nonce),
          let combined = Data(base64Encoded: envelope.ciphertext),
          combined.count >= LinuxDevboxExportService.authenticationTagByteCount else {
        throw CredentialBundleFixtureError.invalidFixture
    }

    var passphraseBytes = Data(passphrase.utf8)
    defer { passphraseBytes.resetBytes(in: 0..<passphraseBytes.count) }
    var derivedKey = try LinuxDevboxExportService.deriveKey(
        passphraseBytes: passphraseBytes,
        salt: salt,
        iterations: envelope.iterations
    )
    defer { derivedKey.resetBytes(in: 0..<derivedKey.count) }
    let tagStart = combined.count - LinuxDevboxExportService.authenticationTagByteCount
    let sealedBox = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonceData),
        ciphertext: Data(combined[..<tagStart]),
        tag: Data(combined[tagStart...])
    )
    var plaintext = try AES.GCM.open(sealedBox, using: SymmetricKey(data: derivedKey))
    defer { plaintext.resetBytes(in: 0..<plaintext.count) }

    let payloadDecoder = JSONDecoder()
    payloadDecoder.dateDecodingStrategy = .iso8601
    return try payloadDecoder.decode(LinuxDevboxBundlePayload.self, from: plaintext)
}

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/CredentialBundle", isDirectory: true)
        .appendingPathComponent(name)
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
