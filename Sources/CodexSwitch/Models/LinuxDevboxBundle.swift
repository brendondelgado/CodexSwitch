import Foundation

struct LinuxDevboxBundleMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let createdAt: Date
    let expiresAt: Date
    let exportedByHost: String
    let accountCount: Int
    let activeAccountId: String?
    let activeEmail: String?
    let emails: [String]
}

struct LinuxDevboxBundlePayload: Codable, Sendable {
    let metadata: LinuxDevboxBundleMetadata
    let accounts: [CodexAccount]
}

struct LinuxDevboxEncryptedBundle: Codable, Equatable, Sendable {
    let format: String
    let schemaVersion: Int
    let kdf: String
    let iterations: Int
    let cipher: String
    let salt: String
    let nonce: String
    let ciphertext: String
}

struct LinuxDevboxExportResult: Equatable, Sendable {
    let fileURL: URL
    let metadata: LinuxDevboxBundleMetadata
    let importCommand: String
    let copyCommand: String
}
