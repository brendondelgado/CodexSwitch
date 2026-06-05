import CryptoKit
import Foundation
import Security

enum LinuxDevboxExportError: Error, LocalizedError, Equatable {
    case noAccounts
    case passphraseTooShort
    case passphrasesDoNotMatch
    case randomBytesFailed

    var errorDescription: String? {
        switch self {
        case .noAccounts:
            return "No accounts are available to export."
        case .passphraseTooShort:
            return "Passphrase must be at least 12 characters."
        case .passphrasesDoNotMatch:
            return "Passphrases do not match."
        case .randomBytesFailed:
            return "Failed to generate secure random bytes."
        }
    }
}

struct LinuxDevboxExportService: Sendable {
    static let format = "codexswitch-linux-devbox-bundle"
    static let schemaVersion = 1
    static let kdf = "sha256-passphrase-salt-v1"
    static let cipher = "aes-256-gcm"

    var now: @Sendable () -> Date = { Date() }
    var hostName: @Sendable () -> String = { Host.current().localizedName ?? "unknown-host" }

    func makeEncryptedBundle(
        accounts: [CodexAccount],
        passphrase: String,
        confirmation: String,
        lifetime: TimeInterval = 30 * 60
    ) throws -> (data: Data, metadata: LinuxDevboxBundleMetadata) {
        guard !accounts.isEmpty else { throw LinuxDevboxExportError.noAccounts }
        guard passphrase.count >= 12 else { throw LinuxDevboxExportError.passphraseTooShort }
        guard passphrase == confirmation else { throw LinuxDevboxExportError.passphrasesDoNotMatch }

        let createdAt = now()
        let exportAccounts = accounts.preferHighestUsablePlanActive()
        let active = exportAccounts.first(where: \.isActive)
        let metadata = LinuxDevboxBundleMetadata(
            schemaVersion: Self.schemaVersion,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(lifetime),
            exportedByHost: hostName(),
            accountCount: accounts.count,
            activeAccountId: nil,
            activeEmail: active?.email,
            emails: exportAccounts.map(\.email)
        )
        let payload = LinuxDevboxBundlePayload(metadata: metadata, accounts: exportAccounts)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payloadData = try encoder.encode(payload)

        let salt = try Self.secureRandomBytes(count: 32)
        let nonceBytes = try Self.secureRandomBytes(count: 12)
        let key = SymmetricKey(data: Self.deriveKey(passphrase: passphrase, salt: salt))
        let sealedBox = try AES.GCM.seal(payloadData, using: key, nonce: AES.GCM.Nonce(data: nonceBytes))
        var ciphertext = sealedBox.ciphertext
        ciphertext.append(sealedBox.tag)

        let bundle = LinuxDevboxEncryptedBundle(
            format: Self.format,
            schemaVersion: Self.schemaVersion,
            kdf: Self.kdf,
            cipher: Self.cipher,
            metadata: metadata,
            salt: salt.base64EncodedString(),
            nonce: nonceBytes.base64EncodedString(),
            ciphertext: ciphertext.base64EncodedString()
        )
        return (try encoder.encode(bundle), metadata)
    }

    func export(
        accounts: [CodexAccount],
        passphrase: String,
        confirmation: String,
        outputDirectory: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    ) throws -> LinuxDevboxExportResult {
        let bundle = try makeEncryptedBundle(
            accounts: accounts,
            passphrase: passphrase,
            confirmation: confirmation
        )
        let fileURL = outputDirectory.appendingPathComponent(Self.fileName(for: bundle.metadata.createdAt))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try bundle.data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        return LinuxDevboxExportResult(
            fileURL: fileURL,
            metadata: bundle.metadata,
            importCommand: "ssh user@devbox 'codexswitch-cli import ~/\(fileURL.lastPathComponent) && codexswitch-cli doctor'",
            copyCommand: "scp \(fileURL.path) user@devbox:~/"
        )
    }

    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "codexswitch-linux-devbox-\(formatter.string(from: date)).csbundle"
    }

    static func deriveKey(passphrase: String, salt: Data) -> Data {
        var input = Data(passphrase.utf8)
        input.append(salt)
        let digest = SHA256.hash(data: input)
        return Data(digest)
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw LinuxDevboxExportError.randomBytesFailed }
        return Data(bytes)
    }
}

private extension Array where Element == CodexAccount {
    func preferHighestUsablePlanActive() -> [CodexAccount] {
        var accounts = self
        let active = accounts.first(where: \.isActive)
        let target: CodexAccount?
        if let active {
            target = SwapEngine.selectPlanUpgradeCandidate(active: active, from: accounts) ?? active
        } else {
            target = SwapEngine.selectOptimalAccount(from: accounts) ?? accounts.first
        }
        guard let target else { return accounts }
        for index in accounts.indices {
            accounts[index].isActive = accounts[index].id == target.id
        }
        return accounts
    }
}
