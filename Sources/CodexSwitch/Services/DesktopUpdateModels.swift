import Foundation

struct CodexDesktopAppRelease: Codable, Equatable, Sendable {
    let shortVersion: String
    let bundleVersion: String
    let downloadURL: URL
    let archiveSHA256: String?
    let archiveEdSignature: String?
    let archiveLength: Int64?

    init(
        shortVersion: String,
        bundleVersion: String,
        downloadURL: URL,
        archiveSHA256: String? = nil,
        archiveEdSignature: String? = nil,
        archiveLength: Int64? = nil
    ) {
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
        self.downloadURL = downloadURL
        self.archiveSHA256 = archiveSHA256
        self.archiveEdSignature = archiveEdSignature
        self.archiveLength = archiveLength
    }

    var versionLabel: String {
        "\(shortVersion) (\(bundleVersion))"
    }
}

struct CodexDesktopAppUpdateResult: Sendable {
    let success: Bool
    let message: String
    let cleanupPending: Bool

    init(success: Bool, message: String, cleanupPending: Bool = false) {
        self.success = success
        self.message = message
        self.cleanupPending = cleanupPending
    }
}

enum CodexDesktopStagedInstallDecision: Equatable, Sendable {
    case discard
    case waitForDesktopQuit
    case install
}

struct CodexDesktopStagedUpdate: Codable, Equatable, Sendable {
    let shortVersion: String
    let bundleVersion: String
    let downloadURL: URL
    let appPath: String
    let stagedAt: Date
    let generationIdentifier: String?
    let validationSeal: CodexDesktopStagedValidationSeal?
    let archiveSHA256: String?
    let archiveLength: Int64?

    init(
        shortVersion: String,
        bundleVersion: String,
        downloadURL: URL,
        appPath: String,
        stagedAt: Date,
        generationIdentifier: String? = nil,
        validationSeal: CodexDesktopStagedValidationSeal? = nil,
        archiveSHA256: String? = nil,
        archiveLength: Int64? = nil
    ) {
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
        self.downloadURL = downloadURL
        self.appPath = appPath
        self.stagedAt = stagedAt
        self.generationIdentifier = generationIdentifier
        self.validationSeal = validationSeal
        self.archiveSHA256 = archiveSHA256
        self.archiveLength = archiveLength
    }

    var release: CodexDesktopAppRelease {
        CodexDesktopAppRelease(
            shortVersion: shortVersion,
            bundleVersion: bundleVersion,
            downloadURL: downloadURL,
            archiveSHA256: archiveSHA256,
            archiveLength: archiveLength
        )
    }

    func matches(_ release: CodexDesktopAppRelease) -> Bool {
        guard shortVersion == release.shortVersion,
              bundleVersion == release.bundleVersion else { return false }
        switch (archiveSHA256, release.archiveSHA256) {
        case (.some(let stagedDigest), .some(let releaseDigest)):
            guard stagedDigest.caseInsensitiveCompare(releaseDigest) == .orderedSame else {
                return false
            }
        case (.none, .none):
            // Legacy unpinned test/migration data has no immutable payload
            // identity, so it may only reuse the exact original URL.
            guard downloadURL == release.downloadURL else { return false }
        default:
            return false
        }
        if let archiveLength {
            guard archiveLength == release.archiveLength else { return false }
        }
        return true
    }
}

struct CodexDesktopStagedFileSeal: Codable, Equatable, Sendable {
    let relativePath: String
    let byteCount: Int64
    let modificationDate: Date
    let contentSHA256: String?
    let posixPermissions: UInt16?

    init(
        relativePath: String,
        byteCount: Int64,
        modificationDate: Date,
        contentSHA256: String? = nil,
        posixPermissions: UInt16? = nil
    ) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        self.contentSHA256 = contentSHA256
        self.posixPermissions = posixPermissions
    }
}

struct CodexDesktopStagedValidationSeal: Codable, Equatable, Sendable {
    let formatVersion: Int?
    let validatedAt: Date
    let files: [CodexDesktopStagedFileSeal]

    init(
        formatVersion: Int? = 2,
        validatedAt: Date,
        files: [CodexDesktopStagedFileSeal]
    ) {
        self.formatVersion = formatVersion
        self.validatedAt = validatedAt
        self.files = files
    }
}

enum CodexDesktopBundleValidationResult: Equatable, Sendable {
    case valid
    case invalid(String)
    case unavailable(String)
    case cancelled
}

struct CodexDesktopTrustCommandResult: Equatable, Sendable {
    let timedOut: Bool
    let cancelled: Bool
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    let reaped: Bool

    init(
        timedOut: Bool = false,
        cancelled: Bool = false,
        terminationStatus: Int32,
        standardOutput: String = "",
        standardError: String = "",
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false,
        reaped: Bool = true
    ) {
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.reaped = reaped
    }
}

struct DesktopSigningIdentityEvidence: Equatable, Sendable {
    let appleAnchorSatisfied: Bool
    let teamIdentifiers: [String]
    let bundleIdentifiers: [String]
}

enum CodexDesktopVersionDisposition: Equatable, Sendable {
    case updateAvailable
    case current(String)
}

enum CodexDesktopStagedGenerationResolution: Equatable, Sendable {
    case reuse(CodexDesktopStagedUpdate)
    case preserveForRetry(String)
    case revoke(String)
    case cancelled
}

enum CodexDesktopPendingGenerationResolution: Equatable, Sendable {
    case ready(CodexDesktopStagedUpdate)
    case preserveForRetry(String)
    case revoke(String)
    case cancelled
}

enum CodexDesktopDownloadedGenerationPreparationResult: Equatable, Sendable {
    case staged(CodexDesktopStagedUpdate)
    case pendingAssessment(CodexDesktopStagedUpdate, reason: String)
}

enum CodexDesktopUpdatePreparationResult: Sendable {
    case upToDate(String)
    case alreadyStaged(CodexDesktopStagedUpdate)
    case staged(CodexDesktopStagedUpdate)
    case deferred(String)
    case failed(String)
}

enum CodexDesktopStagedInstallResult: Sendable {
    case none
    case waitingForDesktopQuit(CodexDesktopStagedUpdate)
    case deferred(String)
    case discarded(String)
    case installed(
        path: String,
        release: CodexDesktopAppRelease,
        transaction: CodexDesktopInstallationTransactionCompletion,
        cleanupPending: Bool
    )
    case failed(String)
}

enum CodexDesktopUpdateOperation: String, Equatable, Sendable {
    case checking
    case staging
    case recovering
    case installingStagedUpdate
    case restoringStock
    case maintainingStorage
}

enum CodexDesktopInstallationTransactionKind: String, Codable, Equatable, Sendable {
    case stagedUpdate
    case stockRestore
}

struct CodexDesktopInstallationTransactionCompletion: Equatable, Sendable {
    let identifier: UInt64
    let kind: CodexDesktopInstallationTransactionKind
    let committed: Bool
    let cleanupPending: Bool
}

enum CodexDesktopInstallationTransactionState: Equatable, Sendable {
    case idle
    case active(
        identifier: UInt64,
        kind: CodexDesktopInstallationTransactionKind,
        applicationsChangeObserved: Bool
    )
}

enum CodexDesktopApplicationsChangeDisposition: Equatable, Sendable {
    case externalChange
    case internalTransactionCompleted(CodexDesktopInstallationTransactionCompletion)
    case internalTransactionChangeSuppressed(identifier: UInt64)
}

struct CodexDesktopUpdateBackoff: Equatable, Sendable {
    nonisolated static let initialDelay: TimeInterval = 60
    nonisolated static let maximumDelay: TimeInterval = 60 * 60

    private(set) var consecutiveFailureCount = 0
    private(set) var retryNotBefore: Date?

    func permitsAttempt(at date: Date) -> Bool {
        retryNotBefore.map { date >= $0 } ?? true
    }

    @discardableResult
    mutating func recordFailure(at date: Date) -> TimeInterval {
        consecutiveFailureCount += 1
        let delay = Self.delay(forFailureCount: consecutiveFailureCount)
        retryNotBefore = date.addingTimeInterval(delay)
        return delay
    }

    mutating func recordSuccess() {
        consecutiveFailureCount = 0
        retryNotBefore = nil
    }

    static func delay(forFailureCount failureCount: Int) -> TimeInterval {
        guard failureCount > 0 else { return 0 }
        let exponent = min(failureCount - 1, 16)
        return min(initialDelay * pow(2, Double(exponent)), maximumDelay)
    }
}

enum CodexDesktopInstallRetryPolicy {
    nonisolated static let maximumAttempts = 10
    nonisolated static let initialDelay: TimeInterval = 0.25
    nonisolated static let maximumDelay: TimeInterval = 5

    static func delayBeforeAttempt(_ attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return min(initialDelay * pow(2, Double(attempt - 1)), maximumDelay)
    }
}

struct CodexDesktopTemporaryWorkspaceCleanupReport: Equatable, Sendable {
    let removedDirectoryCount: Int
    let reclaimedBytes: UInt64
}

struct CodexDesktopUpdateStorageCleanupReport: Equatable, Sendable {
    let removedArtifactCount: Int
    let reclaimedBytes: UInt64
}

struct CodexDesktopStartupMaintenanceReport: Sendable {
    let installRecovery: DesktopInstallRecoveryResult?
    let installRecoveryFailure: String?
    let temporaryWorkspace: CodexDesktopTemporaryWorkspaceCleanupReport?
    let temporaryWorkspaceFailure: String?
    let updateStorage: CodexDesktopUpdateStorageCleanupReport?
    let updateStorageFailure: String?

    static let empty = CodexDesktopStartupMaintenanceReport(
        installRecovery: nil,
        installRecoveryFailure: nil,
        temporaryWorkspace: nil,
        temporaryWorkspaceFailure: nil,
        updateStorage: nil,
        updateStorageFailure: nil
    )
}

enum DesktopRejectedReleaseReasonClass: String, Codable, Equatable, Sendable {
    case strictSignature
    case gatekeeperRejection
    case signingIdentity
    case bundleStructure
    case releaseMetadata
}

struct DesktopRejectedReleaseFingerprint: Codable, Equatable, Sendable {
    let shortVersion: String
    let bundleVersion: String
    let downloadURL: URL
    let archiveSHA256: String?
    let reasonClass: DesktopRejectedReleaseReasonClass
    let rejectedAt: Date

    func matches(_ release: CodexDesktopAppRelease) -> Bool {
        guard let recordedDigest = archiveSHA256?.lowercased(),
              let releaseDigest = release.archiveSHA256?.lowercased(),
              recordedDigest.count == 64,
              releaseDigest.count == 64 else {
            return false
        }
        return bundleVersion == release.bundleVersion
            && recordedDigest == releaseDigest
    }
}

struct DesktopDefinitiveReleaseRejection: Error, Equatable, LocalizedError, Sendable {
    let reason: String
    let reasonClass: DesktopRejectedReleaseReasonClass

    var errorDescription: String? { reason }
}

struct DesktopAppcastCacheEnvelope: Codable, Equatable, Sendable {
    let appcastBytes: Data
    let etag: String?
    let lastModified: String?
}

enum DesktopInstallJournalPhase: String, Codable, Equatable, Sendable {
    case prepared
    case swapped
    case validating
    case rollback
    case committed
    case cleanupPending
}

struct DesktopInstallPathIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct DesktopInstallBundleIdentity: Codable, Equatable, Sendable {
    let root: DesktopInstallPathIdentity
    let contentSHA256: String
    let entryCount: Int
    let byteCount: UInt64

    func hasSameContent(as other: DesktopInstallBundleIdentity) -> Bool {
        contentSHA256 == other.contentSHA256
            && entryCount == other.entryCount
            && byteCount == other.byteCount
    }
}

struct CodexDesktopRollbackGeneration: Codable, Equatable, Sendable {
    let formatVersion: Int
    let generationIdentifier: String
    let appPath: String
    let sourceDestinationPath: String
    let shortVersion: String
    let bundleVersion: String
    let preservedAt: Date
    let bundleIdentity: DesktopInstallBundleIdentity
}

struct DesktopInstallJournal: Codable, Equatable, Sendable {
    let version: Int
    let transactionIdentifier: UUID
    let kind: CodexDesktopInstallationTransactionKind
    let destinationPath: String
    let incomingPath: String
    let transactionRootIdentity: DesktopInstallPathIdentity?
    let destinationDirectoryIdentity: DesktopInstallPathIdentity?
    let destinationExisted: Bool
    let incomingIdentity: DesktopInstallPathIdentity
    let previousDestinationIdentity: DesktopInstallPathIdentity?
    let incomingBundleIdentity: DesktopInstallBundleIdentity?
    let previousDestinationBundleIdentity: DesktopInstallBundleIdentity?
    let previousBundleVersion: String?
    let previousShortVersion: String?
    let expectedBundleVersion: String
    let expectedShortVersion: String
    let phase: DesktopInstallJournalPhase
    let createdAt: Date

    func withPhase(_ phase: DesktopInstallJournalPhase) -> DesktopInstallJournal {
        DesktopInstallJournal(
            version: version,
            transactionIdentifier: transactionIdentifier,
            kind: kind,
            destinationPath: destinationPath,
            incomingPath: incomingPath,
            transactionRootIdentity: transactionRootIdentity,
            destinationDirectoryIdentity: destinationDirectoryIdentity,
            destinationExisted: destinationExisted,
            incomingIdentity: incomingIdentity,
            previousDestinationIdentity: previousDestinationIdentity,
            incomingBundleIdentity: incomingBundleIdentity,
            previousDestinationBundleIdentity: previousDestinationBundleIdentity,
            previousBundleVersion: previousBundleVersion,
            previousShortVersion: previousShortVersion,
            expectedBundleVersion: expectedBundleVersion,
            expectedShortVersion: expectedShortVersion,
            phase: phase,
            createdAt: createdAt
        )
    }
}
