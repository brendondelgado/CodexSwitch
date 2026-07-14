import CryptoKit
import Foundation
import Security

enum LinuxDevboxExportError: Error, LocalizedError, Equatable {
    case noAccounts
    case tooManyAccounts
    case passphraseTooShort
    case passphraseTooLong
    case passphrasesDoNotMatch
    case accountFieldTooLarge
    case payloadTooLarge
    case invalidKeyDerivationParameters
    case randomBytesFailed

    var errorDescription: String? {
        switch self {
        case .noAccounts:
            return "No accounts are available to export."
        case .tooManyAccounts:
            return "Too many accounts are present for one credential bundle."
        case .passphraseTooShort:
            return "Passphrase must be at least 12 characters."
        case .passphraseTooLong:
            return "Passphrase exceeds the credential bundle limit."
        case .passphrasesDoNotMatch:
            return "Passphrases do not match."
        case .accountFieldTooLarge:
            return "An account field exceeds the credential bundle limit."
        case .payloadTooLarge:
            return "Credential bundle payload exceeds the size limit."
        case .invalidKeyDerivationParameters:
            return "Credential bundle key derivation parameters are invalid."
        case .randomBytesFailed:
            return "Failed to generate secure random bytes."
        }
    }
}

struct LinuxDevboxExportService: Sendable {
    static let format = "codexswitch-linux-devbox-bundle"
    static let schemaVersion = 2
    static let kdf = "pbkdf2-hmac-sha256-v2"
    static let iterations = 600_000
    static let cipher = "aes-256-gcm"
    static let saltByteCount = 32
    static let nonceByteCount = 12
    static let authenticationTagByteCount = 16
    static let derivedKeyByteCount = 32
    static let maximumAccountCount = 128
    static let maximumPassphraseByteCount = 1_024
    static let maximumTokenByteCount = 256 * 1_024
    static let maximumEmailByteCount = 320
    static let maximumInnerStringByteCount = 4 * 1_024
    static let maximumQuotaWindowCount = 32
    static let maximumResetCreditCount = 128
    static let maximumPlaintextByteCount = 8 * 1_024 * 1_024

    var now: @Sendable () -> Date = { Date() }
    var hostName: @Sendable () -> String = { Host.current().localizedName ?? "unknown-host" }
    var randomBytes: @Sendable (Int) throws -> Data = { count in
        try LinuxDevboxExportService.secureRandomBytes(count: count)
    }

    func makeEncryptedBundle(
        accounts: [CodexAccount],
        passphrase: String,
        confirmation: String,
        lifetime: TimeInterval = 30 * 60
    ) throws -> (data: Data, metadata: LinuxDevboxBundleMetadata) {
        guard !accounts.isEmpty else { throw LinuxDevboxExportError.noAccounts }
        guard accounts.count <= Self.maximumAccountCount else {
            throw LinuxDevboxExportError.tooManyAccounts
        }
        guard passphrase.count >= 12 else { throw LinuxDevboxExportError.passphraseTooShort }
        guard passphrase.utf8.count <= Self.maximumPassphraseByteCount else {
            throw LinuxDevboxExportError.passphraseTooLong
        }
        guard passphrase == confirmation else { throw LinuxDevboxExportError.passphrasesDoNotMatch }
        try Self.validateAccountFields(accounts)

        let createdAt = now()
        let exportedByHost = hostName()
        guard exportedByHost.utf8.count <= Self.maximumInnerStringByteCount else {
            throw LinuxDevboxExportError.accountFieldTooLarge
        }
        let exportAccounts = accounts.preferHighestUsablePlanActive()
        let active = exportAccounts.first(where: \.isActive)
        let metadata = LinuxDevboxBundleMetadata(
            schemaVersion: Self.schemaVersion,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(lifetime),
            exportedByHost: exportedByHost,
            accountCount: exportAccounts.count,
            activeAccountId: active?.accountId,
            activeEmail: active?.email,
            emails: exportAccounts.map(\.email)
        )
        let payload = LinuxDevboxBundlePayload(metadata: metadata, accounts: exportAccounts)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var payloadData = try encoder.encode(payload)
        defer { payloadData.resetBytes(in: 0..<payloadData.count) }
        guard payloadData.count <= Self.maximumPlaintextByteCount else {
            throw LinuxDevboxExportError.payloadTooLarge
        }

        let salt = try randomBytes(Self.saltByteCount)
        let nonceBytes = try randomBytes(Self.nonceByteCount)
        guard salt.count == Self.saltByteCount, nonceBytes.count == Self.nonceByteCount else {
            throw LinuxDevboxExportError.randomBytesFailed
        }

        var passphraseBytes = Data(passphrase.utf8)
        defer { passphraseBytes.resetBytes(in: 0..<passphraseBytes.count) }
        var derivedKey = try Self.deriveKey(
            passphraseBytes: passphraseBytes,
            salt: salt,
            iterations: Self.iterations
        )
        defer { derivedKey.resetBytes(in: 0..<derivedKey.count) }
        let key = SymmetricKey(data: derivedKey)
        let sealedBox = try AES.GCM.seal(payloadData, using: key, nonce: AES.GCM.Nonce(data: nonceBytes))
        var ciphertext = sealedBox.ciphertext
        ciphertext.append(sealedBox.tag)

        let bundle = LinuxDevboxEncryptedBundle(
            format: Self.format,
            schemaVersion: Self.schemaVersion,
            kdf: Self.kdf,
            iterations: Self.iterations,
            cipher: Self.cipher,
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

    static func deriveKey(passphraseBytes: Data, salt: Data, iterations: Int) throws -> Data {
        guard !passphraseBytes.isEmpty, !salt.isEmpty, iterations > 0 else {
            throw LinuxDevboxExportError.invalidKeyDerivationParameters
        }

        let key = SymmetricKey(data: passphraseBytes)
        var firstBlock = salt
        var blockIndex = UInt32(1).bigEndian
        withUnsafeBytes(of: &blockIndex) { firstBlock.append(contentsOf: $0) }

        var intermediate = Data(HMAC<SHA256>.authenticationCode(for: firstBlock, using: key))
        defer { intermediate.resetBytes(in: 0..<intermediate.count) }
        guard intermediate.count == Self.derivedKeyByteCount else {
            throw LinuxDevboxExportError.invalidKeyDerivationParameters
        }
        var derived = intermediate
        defer { derived.resetBytes(in: 0..<derived.count) }

        if iterations > 1 {
            for _ in 1..<iterations {
                let next = HMAC<SHA256>.authenticationCode(for: intermediate, using: key)
                intermediate.withUnsafeMutableBytes {
                    (intermediateBytes: UnsafeMutableRawBufferPointer) in
                    derived.withUnsafeMutableBytes {
                        (derivedBytes: UnsafeMutableRawBufferPointer) in
                        next.withUnsafeBytes { (nextBytes: UnsafeRawBufferPointer) in
                            for index in nextBytes.indices {
                                let byte = nextBytes[index]
                                intermediateBytes[index] = byte
                                derivedBytes[index] = derivedBytes[index] ^ byte
                            }
                        }
                    }
                }
            }
        }
        return Data(derived)
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        guard count > 0 else { throw LinuxDevboxExportError.randomBytesFailed }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else { throw LinuxDevboxExportError.randomBytesFailed }
        return Data(bytes)
    }

    private static func validateAccountFields(_ accounts: [CodexAccount]) throws {
        for account in accounts {
            let tokens = [account.accessToken, account.refreshToken, account.idToken]
            guard tokens.allSatisfy({ $0.utf8.count <= maximumTokenByteCount }) else {
                throw LinuxDevboxExportError.accountFieldTooLarge
            }
            guard account.email.utf8.count <= maximumEmailByteCount else {
                throw LinuxDevboxExportError.accountFieldTooLarge
            }
            let strings = [
                account.accountId,
                account.planType ?? "",
                account.runtimeUnusableReason ?? "",
            ]
            guard strings.allSatisfy({ $0.utf8.count <= maximumInnerStringByteCount }) else {
                throw LinuxDevboxExportError.accountFieldTooLarge
            }

            if let snapshot = account.quotaSnapshot {
                guard snapshot.windows.count <= maximumQuotaWindowCount else {
                    throw LinuxDevboxExportError.accountFieldTooLarge
                }
                let sourceStrings = snapshot.windows.flatMap { window in
                    [window.source.limitName, window.source.meteredFeature].compactMap { $0 }
                }
                guard sourceStrings.allSatisfy({ $0.utf8.count <= maximumInnerStringByteCount }) else {
                    throw LinuxDevboxExportError.accountFieldTooLarge
                }
            }

            if let bank = account.rateLimitResetBank {
                guard bank.credits.count <= maximumResetCreditCount else {
                    throw LinuxDevboxExportError.accountFieldTooLarge
                }
                let creditStrings = bank.credits.flatMap { credit in
                    [
                        credit.id,
                        credit.resetType,
                        credit.status,
                        credit.title,
                        credit.description,
                    ].compactMap { $0 }
                }
                guard creditStrings.allSatisfy({ $0.utf8.count <= maximumInnerStringByteCount }) else {
                    throw LinuxDevboxExportError.accountFieldTooLarge
                }
            }
        }
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
