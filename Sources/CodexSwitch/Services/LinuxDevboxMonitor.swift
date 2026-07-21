import CryptoKit
import Darwin
import Foundation
import Security

struct LinuxDevboxMonitorSettings: Equatable, Sendable {
    let enabled: Bool
    let host: String
    let user: String
    let sshKeyPath: String
    let port: Int

    var isConfigured: Bool {
        enabled && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LinuxDevboxReadinessTaskContext: Equatable, Sendable {
    let generation: UInt64
    let settings: LinuxDevboxMonitorSettings

    func authorizesPublication(
        currentGeneration: UInt64,
        currentSettings: LinuxDevboxMonitorSettings
    ) -> Bool {
        generation == currentGeneration && settings == currentSettings
    }
}

struct LinuxDevboxReadiness: Codable, Equatable, Sendable {
    let ready: Bool
    let summary: String
    let accountStoreOk: Bool?
    let authWritable: Bool?
    let daemonRunning: Bool?
    let accountCount: Int?
    let activeEmail: String?
    let activeProviderAccountId: String?
    let readyCandidateCount: Int?
    let issues: [String]?

    init(
        ready: Bool,
        summary: String,
        accountStoreOk: Bool?,
        authWritable: Bool?,
        daemonRunning: Bool?,
        accountCount: Int?,
        activeEmail: String?,
        activeProviderAccountId: String? = nil,
        readyCandidateCount: Int?,
        issues: [String]?
    ) {
        self.ready = ready
        self.summary = summary
        self.accountStoreOk = accountStoreOk
        self.authWritable = authWritable
        self.daemonRunning = daemonRunning
        self.accountCount = accountCount
        self.activeEmail = activeEmail
        self.activeProviderAccountId = activeProviderAccountId
        self.readyCandidateCount = readyCandidateCount
        self.issues = issues
    }
}

struct LinuxDevboxAccountState: Codable, Equatable, Sendable {
    let email: String
    let providerAccountId: String?
    let isActive: Bool
    let quotaSnapshot: QuotaSnapshot?
    let planType: String?
    let lastRefreshed: Date?
    let subscriptionRenewsAt: Date?
    let subscriptionExpiresAt: Date?
    let subscriptionWillRenew: Bool?
    let hasActiveSubscription: Bool?
    var rateLimitResetBank: RateLimitResetBank? = nil
    var runtimeUnusableUntil: Date? = nil
    var runtimeUnusableReason: String? = nil

    init(
        email: String,
        providerAccountId: String? = nil,
        isActive: Bool,
        quotaSnapshot: QuotaSnapshot?,
        planType: String?,
        lastRefreshed: Date?,
        subscriptionRenewsAt: Date?,
        subscriptionExpiresAt: Date?,
        subscriptionWillRenew: Bool?,
        hasActiveSubscription: Bool?,
        rateLimitResetBank: RateLimitResetBank? = nil,
        runtimeUnusableUntil: Date? = nil,
        runtimeUnusableReason: String? = nil
    ) {
        self.email = email
        self.providerAccountId = providerAccountId
        self.isActive = isActive
        self.quotaSnapshot = quotaSnapshot
        self.planType = planType
        self.lastRefreshed = lastRefreshed
        self.subscriptionRenewsAt = subscriptionRenewsAt
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.subscriptionWillRenew = subscriptionWillRenew
        self.hasActiveSubscription = hasActiveSubscription
        self.rateLimitResetBank = rateLimitResetBank
        self.runtimeUnusableUntil = runtimeUnusableUntil
        self.runtimeUnusableReason = runtimeUnusableReason
    }
}

private struct LinuxDevboxAccountStateReport: Codable, Sendable {
    let accounts: [LinuxDevboxAccountState]
    let credentialSetFingerprint: String?
}

struct LinuxDevboxStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case notConfigured
        case checking
        case ready
        case stale
        case notReady
        case failed
    }

    enum Invalidation: CaseIterable, Equatable, Sendable {
        case activeSessionUnverified
        case negative
        case failed
        case deferred
        case decodedInvalid
        case barrierBlocked
        case expired

        var state: State {
            switch self {
            case .negative, .barrierBlocked:
                return .notReady
            case .failed, .decodedInvalid:
                return .failed
            case .activeSessionUnverified, .deferred, .expired:
                return .stale
            }
        }
    }

    let state: State
    let summary: String
    let activeEmail: String?
    let activeProviderAccountId: String?

    init(
        state: State,
        summary: String,
        activeEmail: String?,
        activeProviderAccountId: String? = nil
    ) {
        self.state = state
        self.summary = summary
        self.activeEmail = activeEmail
        self.activeProviderAccountId = activeProviderAccountId
    }

    static let notConfigured = LinuxDevboxStatus(
        state: .notConfigured,
        summary: "Linux devbox monitor is not configured",
        activeEmail: nil,
        activeProviderAccountId: nil
    )

    static let checking = LinuxDevboxStatus(
        state: .checking,
        summary: "checking VPS hot-swap readiness...",
        activeEmail: nil,
        activeProviderAccountId: nil
    )

    static func invalidated(
        by invalidation: Invalidation,
        summary: String
    ) -> LinuxDevboxStatus {
        LinuxDevboxStatus(
            state: invalidation.state,
            summary: summary,
            activeEmail: nil,
            activeProviderAccountId: nil
        )
    }

    var isVisible: Bool {
        state != .notConfigured
    }

    var isHealthy: Bool {
        state == .ready
    }

    var shouldShowCheckingPlaceholderBeforeRefresh: Bool {
        state == .notConfigured
    }

    static func shouldSuppressTransientIssueNotification(
        wasReady: Bool?,
        consecutiveIssueChecks: Int
    ) -> Bool {
        wasReady == true && consecutiveIssueChecks < 2
    }

    static func accountMirrorIsFresh(
        observedAt: Date?,
        now: Date,
        maximumAge: TimeInterval
    ) -> Bool {
        guard let observedAt, maximumAge >= 0 else { return false }
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age <= maximumAge
    }

    func hasFreshReadinessProof(
        mirrorObservedAt: Date?,
        now: Date,
        maximumAge: TimeInterval
    ) -> Bool {
        state == .ready && Self.accountMirrorIsFresh(
            observedAt: mirrorObservedAt,
            now: now,
            maximumAge: maximumAge
        )
    }

    static func activeSessionRequiresInvalidation(
        hasActiveRemoteSession: Bool,
        status: LinuxDevboxStatus,
        mirrorObservedAt: Date?,
        now: Date,
        maximumAge: TimeInterval
    ) -> Bool {
        hasActiveRemoteSession && !status.hasFreshReadinessProof(
            mirrorObservedAt: mirrorObservedAt,
            now: now,
            maximumAge: maximumAge
        )
    }

    var icon: String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .checking: return "clock.arrow.circlepath"
        case .stale, .notReady, .failed: return "exclamationmark.triangle.fill"
        case .notConfigured: return "server.rack"
        }
    }

    var label: String {
        switch state {
        case .ready:
            if let activeEmail {
                return "VPS CLI — Ready: \(activeEmail)"
            }
            return "VPS CLI — Ready"
        case .checking:
            return "VPS CLI — Checking hot-swap readiness"
        case .stale:
            return "VPS CLI — Stale: \(summary)"
        case .notReady:
            return "VPS CLI — Not ready: \(summary)"
        case .failed:
            return "VPS CLI — Check failed: \(summary)"
        case .notConfigured:
            return "VPS CLI — Not configured"
        }
    }
}

enum CredentialSyncFailureDisposition: String, CaseIterable, Equatable, Sendable {
    case notCredentialSync
    case retryablePreExecution
    case rejected
    case outcomeUnknown
    case cleanupUnresolved

    var allowsAutomaticRetry: Bool {
        self == .retryablePreExecution
    }

    var requiresPersistentHold: Bool {
        self == .outcomeUnknown || self == .cleanupUnresolved
    }
}

struct LinuxDevboxMonitorFailure: Error, Equatable, Sendable {
    let message: String
    let credentialSyncDisposition: CredentialSyncFailureDisposition

    init(
        message: String,
        credentialSyncDisposition: CredentialSyncFailureDisposition = .notCredentialSync
    ) {
        self.message = message
        self.credentialSyncDisposition = credentialSyncDisposition
    }

    var isDecodedInvalidObservation: Bool {
        message.hasPrefix("Failed to parse Linux devbox ")
    }
}

struct LinuxDevboxCredentialStateEvidence: Equatable, Sendable {
    let accountIdentityFingerprint: String
    let credentialSetFingerprint: String
    let activeProviderAccountId: String
    let activeTokenHashPrefix: String
    let authMatchesActiveStoreToken: Bool
}

struct LinuxDevboxCredentialSyncOperation: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Equatable, Sendable {
        case pending
        case unresolved
    }

    static let schemaVersion = 2

    let version: Int
    let operationID: String
    let targetFingerprint: String
    let credentialFingerprint: String
    let expectedAccountIdentityFingerprint: String
    let expectedCredentialSetFingerprint: String
    let expectedActiveProviderAccountId: String
    let expectedActiveTokenHashPrefix: String
    let baselineAccountIdentityFingerprint: String
    let baselineCredentialSetFingerprint: String
    let baselineActiveProviderAccountId: String
    let baselineActiveTokenHashPrefix: String
    let baselineAuthMatchesActiveStoreToken: Bool
    let localDirectory: String
    let remoteDirectory: String
    let createdAt: Date
    var phase: Phase
    var reason: String

    init(
        operationID: String,
        targetFingerprint: String,
        credentialFingerprint: String,
        expectedAccountIdentityFingerprint: String,
        expectedCredentialSetFingerprint: String,
        expectedActiveProviderAccountId: String,
        expectedActiveTokenHashPrefix: String,
        baseline: LinuxDevboxCredentialStateEvidence,
        localDirectory: String,
        remoteDirectory: String,
        createdAt: Date,
        phase: Phase = .pending,
        reason: String
    ) {
        self.version = Self.schemaVersion
        self.operationID = operationID
        self.targetFingerprint = targetFingerprint
        self.credentialFingerprint = credentialFingerprint
        self.expectedAccountIdentityFingerprint = expectedAccountIdentityFingerprint
        self.expectedCredentialSetFingerprint = expectedCredentialSetFingerprint
        self.expectedActiveProviderAccountId = expectedActiveProviderAccountId
        self.expectedActiveTokenHashPrefix = expectedActiveTokenHashPrefix
        self.baselineAccountIdentityFingerprint = baseline.accountIdentityFingerprint
        self.baselineCredentialSetFingerprint = baseline.credentialSetFingerprint
        self.baselineActiveProviderAccountId = baseline.activeProviderAccountId
        self.baselineActiveTokenHashPrefix = baseline.activeTokenHashPrefix
        self.baselineAuthMatchesActiveStoreToken = baseline.authMatchesActiveStoreToken
        self.localDirectory = localDirectory
        self.remoteDirectory = remoteDirectory
        self.createdAt = createdAt
        self.phase = phase
        self.reason = reason
    }

    var baseline: LinuxDevboxCredentialStateEvidence {
        LinuxDevboxCredentialStateEvidence(
            accountIdentityFingerprint: baselineAccountIdentityFingerprint,
            credentialSetFingerprint: baselineCredentialSetFingerprint,
            activeProviderAccountId: baselineActiveProviderAccountId,
            activeTokenHashPrefix: baselineActiveTokenHashPrefix,
            authMatchesActiveStoreToken: baselineAuthMatchesActiveStoreToken
        )
    }

    var expected: LinuxDevboxCredentialStateEvidence {
        LinuxDevboxCredentialStateEvidence(
            accountIdentityFingerprint: expectedAccountIdentityFingerprint,
            credentialSetFingerprint: expectedCredentialSetFingerprint,
            activeProviderAccountId: expectedActiveProviderAccountId,
            activeTokenHashPrefix: expectedActiveTokenHashPrefix,
            authMatchesActiveStoreToken: true
        )
    }
}

enum LinuxDevboxCredentialSyncJournalError: Error, Equatable, LocalizedError {
    case invalidRecord(String)
    case operationAlreadyPending(String)
    case operationChanged(expected: String, actual: String?)

    var errorDescription: String? {
        switch self {
        case .invalidRecord(let reason):
            return "Invalid Linux devbox credential-sync journal: \(reason)"
        case .operationAlreadyPending(let operationID):
            return "Linux devbox credential sync \(operationID) is already pending"
        case .operationChanged(let expected, let actual):
            return "Linux devbox credential-sync journal changed: expected \(expected), found \(actual ?? "none")"
        }
    }
}

struct LinuxDevboxCredentialSyncJournal: Sendable {
    static let defaultPath = NSString(
        string: "~/.codexswitch/linux-devbox-credential-sync.json"
    ).expandingTildeInPath
    private static let maximumRecordBytes = 64 * 1024

    private let transaction: SecureAtomicFileTransaction

    init(path: String = defaultPath) {
        transaction = SecureAtomicFileTransaction(
            path: path,
            subject: "Linux devbox credential-sync journal"
        )
    }

    func load() throws -> LinuxDevboxCredentialSyncOperation? {
        try transaction.withExclusiveLock { lockedFile in
            try decode(lockedFile.read().bytes)
        }
    }

    func begin(_ operation: LinuxDevboxCredentialSyncOperation) throws {
        try validate(operation)
        try transaction.withExclusiveLock { lockedFile in
            let current = try lockedFile.read()
            if let pending = try decode(current.bytes) {
                throw LinuxDevboxCredentialSyncJournalError.operationAlreadyPending(
                    pending.operationID
                )
            }
            _ = try lockedFile.replace(try encode(operation), expectedGeneration: current.generation)
        }
    }

    func markUnresolved(operationID: String, reason: String) throws {
        try transaction.withExclusiveLock { lockedFile in
            let current = try lockedFile.read()
            guard var operation = try decode(current.bytes), operation.operationID == operationID else {
                throw LinuxDevboxCredentialSyncJournalError.operationChanged(
                    expected: operationID,
                    actual: try decode(current.bytes)?.operationID
                )
            }
            operation.phase = .unresolved
            operation.reason = reason
            try validate(operation)
            _ = try lockedFile.replace(try encode(operation), expectedGeneration: current.generation)
        }
    }

    func clear(operationID: String) throws {
        try transaction.withExclusiveLock { lockedFile in
            let current = try lockedFile.read()
            guard let operation = try decode(current.bytes), operation.operationID == operationID else {
                throw LinuxDevboxCredentialSyncJournalError.operationChanged(
                    expected: operationID,
                    actual: try decode(current.bytes)?.operationID
                )
            }
            _ = try lockedFile.remove(expectedGeneration: current.generation)
        }
    }

    private func encode(_ operation: LinuxDevboxCredentialSyncOperation) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(operation)
        guard data.count <= Self.maximumRecordBytes else {
            throw LinuxDevboxCredentialSyncJournalError.invalidRecord("record is too large")
        }
        return data
    }

    private func decode(_ data: Data?) throws -> LinuxDevboxCredentialSyncOperation? {
        guard let data else { return nil }
        guard data.count <= Self.maximumRecordBytes else {
            throw LinuxDevboxCredentialSyncJournalError.invalidRecord("record is too large")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let operation = try decoder.decode(LinuxDevboxCredentialSyncOperation.self, from: data)
        try validate(operation)
        return operation
    }

    private func validate(_ operation: LinuxDevboxCredentialSyncOperation) throws {
        guard operation.version == LinuxDevboxCredentialSyncOperation.schemaVersion else {
            throw LinuxDevboxCredentialSyncJournalError.invalidRecord("unsupported schema version")
        }
        guard let identifier = UUID(uuidString: operation.operationID),
              identifier.uuidString.lowercased() == operation.operationID else {
            throw LinuxDevboxCredentialSyncJournalError.invalidRecord("operation identifier is not a UUID")
        }
        let expectedSuffix = operation.operationID.lowercased()
        guard operation.remoteDirectory == "/tmp/codexswitch-auto-sync-\(expectedSuffix)",
              (operation.localDirectory as NSString).lastPathComponent
                == "codexswitch-linux-credential-sync-\(expectedSuffix)" else {
            throw LinuxDevboxCredentialSyncJournalError.invalidRecord("staging path does not match operation")
        }
        guard isLowercaseHex(operation.targetFingerprint, count: 64),
              isLowercaseHex(operation.credentialFingerprint, count: 64),
              isLowercaseHex(operation.expectedAccountIdentityFingerprint, count: 64),
              isLowercaseHex(operation.baselineAccountIdentityFingerprint, count: 64),
              isLowercaseHex(operation.expectedCredentialSetFingerprint, count: 64),
              isLowercaseHex(operation.baselineCredentialSetFingerprint, count: 64),
              isLowercaseHex(operation.expectedActiveTokenHashPrefix, count: 12),
              isLowercaseHex(operation.baselineActiveTokenHashPrefix, count: 12),
              !operation.expectedActiveProviderAccountId.isEmpty,
              !operation.baselineActiveProviderAccountId.isEmpty,
              operation.expectedActiveProviderAccountId.utf8.count <= 256,
              operation.baselineActiveProviderAccountId.utf8.count <= 256,
              operation.reason.utf8.count <= 4 * 1024,
              !operation.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LinuxDevboxCredentialSyncJournalError.invalidRecord("required evidence is incomplete")
        }
    }

    private func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

enum LinuxDevboxCredentialSyncReconciliation: Equatable, Sendable {
    case committed
    case safeToRetry
    case unresolved(String)
}

enum LinuxDevboxMonitor {
    static let maximumRemoteProviderAccountIdBytes = 256

    enum SSHRetryPolicy: Equatable, Sendable {
        case readOnly
        case preExecutionTransportOnly
    }

    private enum RemoteCommandExecutionState: Equatable, Sendable {
        case notStarted
        case completed
        case unknown
    }

    private struct SSHCommandOutcome: Sendable {
        let result: ProcessRunResult
        let executionState: RemoteCommandExecutionState
    }

    enum RemotePollingMode: Equatable, Sendable {
        case statusOnly
        case activeSession
    }

    static let tailscaleBinaryPath = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    static let remoteExecutionMarkerPrefix = "__CODEXSWITCH_REMOTE_COMMAND_STARTED_"
    static let remoteCompletionMarkerPrefix = "__CODEXSWITCH_REMOTE_COMMAND_COMPLETED_"
    static let remoteCleanupFailureMarker = "__CODEXSWITCH_REMOTE_CLEANUP_FAILED__"
    static let activeRemoteAccountStatePollInterval: TimeInterval = 5
    static let normalReadinessPollInterval: TimeInterval = 60
    static let automaticCredentialBundleLifetime: TimeInterval = 10 * 60
    static let pollAccountRetryPolicy: SSHRetryPolicy = .preExecutionTransportOnly

    private struct RemoteAuthDiagnostics: Decodable, Sendable {
        let activeAccountId: String?
        let activeTokenHashPrefix: String?
        let authMatchesActiveStoreToken: Bool
    }

    static func credentialSyncFingerprint(accounts: [CodexAccount]) -> String {
        var hasher = SHA256()
        for account in accounts.sorted(by: {
            if $0.accountId != $1.accountId { return $0.accountId < $1.accountId }
            return $0.email.lowercased() < $1.email.lowercased()
        }) {
            updateHash(&hasher, account.accountId)
            updateHash(&hasher, account.email.lowercased())
            updateHash(&hasher, account.accessToken)
            updateHash(&hasher, account.refreshToken)
            updateHash(&hasher, account.idToken)
            updateHash(&hasher, account.isActive ? "active" : "inactive")
            updateHash(&hasher, account.planType ?? "")
            updateHash(&hasher, account.subscriptionWillRenew.map(String.init) ?? "")
            updateHash(&hasher, account.hasActiveSubscription.map(String.init) ?? "")
            if let bank = account.rateLimitResetBank {
                updateHash(&hasher, String(bank.availableCount))
                updateHash(&hasher, String(bank.totalEarnedCount))
                updateHash(&hasher, fingerprintDate(bank.fetchedAt))
                for credit in bank.credits.sorted(by: { $0.id < $1.id }) {
                    updateHash(&hasher, credit.id)
                    updateHash(&hasher, credit.status)
                    updateHash(&hasher, fingerprintDate(credit.expiresAt))
                }
            }
            updateHash(&hasher, account.runtimeUnusableReason ?? "")
            updateHash(&hasher, fingerprintDate(account.subscriptionRenewsAt))
            updateHash(&hasher, fingerprintDate(account.subscriptionExpiresAt))
            updateHash(&hasher, fingerprintDate(account.fiveHourPrimedAt))
            updateHash(&hasher, fingerprintDate(account.runtimeUnusableUntil))
            if let snapshot = account.quotaSnapshot {
                updateHash(&hasher, fingerprintQuotaSnapshot(snapshot))
            }
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func credentialSyncTargetFingerprint(
        settings: LinuxDevboxMonitorSettings
    ) -> String {
        var hasher = SHA256()
        updateHash(&hasher, settings.user)
        updateHash(&hasher, settings.host)
        updateHash(&hasher, String(settings.port))
        updateHash(&hasher, NSString(string: settings.sshKeyPath).expandingTildeInPath)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func credentialSyncAccountsPreservingRemoteActive(
        accounts: [CodexAccount],
        remoteActiveProviderAccountId: String
    ) -> Result<[CodexAccount], LinuxDevboxMonitorFailure> {
        guard !remoteActiveProviderAccountId.isEmpty,
              accounts.contains(where: { $0.accountId == remoteActiveProviderAccountId }) else {
            return .failure(LinuxDevboxMonitorFailure(
                message: "VPS active account is absent from the Mac credential pool; sync refused to preserve host ownership",
                credentialSyncDisposition: .rejected
            ))
        }

        var synchronized = accounts
        for index in synchronized.indices {
            synchronized[index].isActive =
                synchronized[index].accountId == remoteActiveProviderAccountId
        }
        return .success(synchronized)
    }

    static func credentialAccountIdentityFingerprint(accounts: [CodexAccount]) -> String {
        var hasher = SHA256()
        for account in accounts.sorted(by: { $0.accountId < $1.accountId }) {
            updateHash(&hasher, account.accountId)
            updateHash(&hasher, account.isActive ? "active" : "inactive")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func credentialAccountIdentityFingerprint(
        states: [LinuxDevboxAccountState]
    ) -> String? {
        let identified = states.compactMap { state -> (String, Bool)? in
            guard let accountID = state.providerAccountId, !accountID.isEmpty else { return nil }
            return (accountID, state.isActive)
        }
        guard identified.count == states.count else { return nil }

        var hasher = SHA256()
        for (accountID, isActive) in identified.sorted(by: { $0.0 < $1.0 }) {
            updateHash(&hasher, accountID)
            updateHash(&hasher, isActive ? "active" : "inactive")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func credentialSetFingerprint(accounts: [CodexAccount]) -> String? {
        guard accounts.filter(\.isActive).count == 1,
              Set(accounts.map(\.accountId)).count == accounts.count,
              accounts.allSatisfy({
                  !$0.accountId.isEmpty
                      && !$0.idToken.isEmpty
                      && !$0.accessToken.isEmpty
                      && !$0.refreshToken.isEmpty
              }) else {
            return nil
        }

        var hasher = SHA256()
        for account in accounts.sorted(by: { $0.accountId < $1.accountId }) {
            updateLengthPrefixedHash(&hasher, account.accountId)
            updateLengthPrefixedHash(&hasher, account.idToken)
            updateLengthPrefixedHash(&hasher, account.accessToken)
            updateLengthPrefixedHash(&hasher, account.refreshToken)
            updateLengthPrefixedHash(&hasher, account.isActive ? "active" : "inactive")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func activeTokenHashPrefix(accounts: [CodexAccount]) -> String? {
        guard accounts.filter(\.isActive).count == 1,
              let account = accounts.first(where: \.isActive) else {
            return nil
        }
        let parts = [account.idToken, account.accessToken, account.refreshToken, account.accountId]
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }

        var hasher = SHA256()
        for part in parts {
            updateLengthPrefixedHash(&hasher, part)
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    static func makeCredentialSyncOperation(
        settings: LinuxDevboxMonitorSettings,
        accounts: [CodexAccount],
        credentialFingerprint: String,
        baseline: LinuxDevboxCredentialStateEvidence,
        operationID: UUID = UUID(),
        createdAt: Date = Date(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Result<LinuxDevboxCredentialSyncOperation, LinuxDevboxMonitorFailure> {
        guard accounts.filter(\.isActive).count == 1,
              let active = accounts.first(where: \.isActive),
              let tokenHashPrefix = activeTokenHashPrefix(accounts: accounts),
              let credentialSetFingerprint = credentialSetFingerprint(accounts: accounts) else {
            return .failure(LinuxDevboxMonitorFailure(
                message: "Credential sync requires exactly one active account with complete tokens",
                credentialSyncDisposition: .rejected
            ))
        }

        let identifier = operationID.uuidString.lowercased()
        let localDirectory = temporaryDirectory
            .appendingPathComponent(
                "codexswitch-linux-credential-sync-\(identifier)",
                isDirectory: true
            )
            .path
        let remoteDirectory = "/tmp/codexswitch-auto-sync-\(identifier)"
        return .success(LinuxDevboxCredentialSyncOperation(
            operationID: identifier,
            targetFingerprint: credentialSyncTargetFingerprint(settings: settings),
            credentialFingerprint: credentialFingerprint,
            expectedAccountIdentityFingerprint: credentialAccountIdentityFingerprint(accounts: accounts),
            expectedCredentialSetFingerprint: credentialSetFingerprint,
            expectedActiveProviderAccountId: active.accountId,
            expectedActiveTokenHashPrefix: tokenHashPrefix,
            baseline: baseline,
            localDirectory: localDirectory,
            remoteDirectory: remoteDirectory,
            createdAt: createdAt,
            reason: "Credential sync may have started; reconciliation is required after interruption"
        ))
    }

    static func credentialSyncReconciliation(
        operation: LinuxDevboxCredentialSyncOperation,
        remoteStageAbsent: Bool,
        observed: LinuxDevboxCredentialStateEvidence?
    ) -> LinuxDevboxCredentialSyncReconciliation {
        guard remoteStageAbsent else {
            return .unresolved("Private remote credential staging still exists at \(operation.remoteDirectory)")
        }
        guard let observed else {
            return .unresolved("Remote credential-state evidence is unavailable")
        }
        if observed == operation.expected {
            return .committed
        }
        if observed == operation.baseline {
            return .safeToRetry
        }
        return .unresolved("Remote credential state matches neither the expected commit nor the pre-mutation baseline")
    }

    static func credentialSyncOwnsLocalStagePath(
        operation: LinuxDevboxCredentialSyncOperation,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let directory = URL(fileURLWithPath: operation.localDirectory, isDirectory: true)
            .standardizedFileURL
        let actualParent = directory.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let expectedParent = temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return actualParent.path == expectedParent.path
            && directory.lastPathComponent
                == "codexswitch-linux-credential-sync-\(operation.operationID)"
    }

    static func remotePollingMode(hasActiveRemoteSession: Bool) -> RemotePollingMode {
        hasActiveRemoteSession ? .activeSession : .statusOnly
    }

    static func isInteractiveCodexVPSAttachRunning() -> Bool {
        isCodexVPSRemoteSessionRunning()
    }

    static func isCodexVPSRemoteSessionRunning() -> Bool {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "command"],
            timeout: 1
        )
        guard result.terminationStatus == 0, !result.timedOut else { return false }
        return isCodexVPSRemoteSessionRunning(psOutput: result.stdoutString)
    }

    static func isInteractiveCodexVPSAttachRunning(psOutput: String) -> Bool {
        isCodexVPSRemoteSessionRunning(psOutput: psOutput)
    }

    static func isCodexVPSRemoteSessionRunning(psOutput: String) -> Bool {
        psOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .contains { rawLine in
                let line = rawLine.lowercased()
                if line.contains("/usr/bin/ssh") || line.contains("tailscale nc") {
                    return false
                }
                if line.contains("/codex-vps") {
                    return true
                }
                guard line.contains("--remote") else {
                    return false
                }
                let targetsCodexVPS = line.contains("100.95.84.123:8390")
                    || line.contains("127.0.0.1:18390")
                let isCodexClient = line.contains("/codex")
                    || line.contains(" codex ")
                    || line.contains("patched-mac-remote-client")
                return targetsCodexVPS && isCodexClient
            }
    }

    static func shouldRunReadinessCheck(
        now: Date = Date(),
        lastFullCheckAt: Date?,
        hasActiveRemoteSession: Bool,
        force: Bool
    ) -> Bool {
        if force || hasActiveRemoteSession {
            return true
        }
        guard let lastFullCheckAt else {
            return true
        }
        return now.timeIntervalSince(lastFullCheckAt) >= normalReadinessPollInterval
    }

    static func settings(from defaults: UserDefaults = .standard) -> LinuxDevboxMonitorSettings {
        LinuxDevboxMonitorSettings(
            enabled: defaults.bool(forKey: "linuxDevboxMonitorEnabled"),
            host: defaults.string(forKey: "linuxDevboxHost") ?? "",
            user: defaults.string(forKey: "linuxDevboxUser") ?? "",
            sshKeyPath: defaults.string(forKey: "linuxDevboxSSHKeyPath") ?? "",
            port: max(defaults.integer(forKey: "linuxDevboxSSHPort"), 22)
        )
    }

    static func sshArgumentCandidates(settings: LinuxDevboxMonitorSettings) -> [[String]] {
        var base = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ControlPersist=no",
            "-p", "\(settings.port)",
        ]
        if !settings.sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base.append(contentsOf: ["-i", NSString(string: settings.sshKeyPath).expandingTildeInPath])
        }

        let target = "\(settings.user)@\(settings.host)"
        var candidates: [[String]] = []
        if FileManager.default.isExecutableFile(atPath: tailscaleBinaryPath) {
            var proxy = base
            proxy.append(contentsOf: [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ProxyCommand=\(tailscaleBinaryPath) nc %h %p",
                target,
            ])
            candidates.append(proxy)
        }

        var direct = base
        direct.append(target)
        candidates.append(direct)
        return candidates
    }

    private static func runSSH(
        settings: LinuxDevboxMonitorSettings,
        remoteCommand: String,
        timeout: TimeInterval,
        retryPolicy: SSHRetryPolicy
    ) -> ProcessRunResult {
        let outcome = runSSHOutcome(
            settings: settings,
            remoteCommand: remoteCommand,
            timeout: timeout,
            retryPolicy: retryPolicy
        )
        guard outcome.executionState != .unknown else {
            return ProcessRunResult(
                terminationStatus: -1,
                stdout: outcome.result.stdout,
                stderr: Data("Remote command completion could not be proven".utf8),
                timedOut: outcome.result.timedOut,
                stdoutTruncated: outcome.result.stdoutTruncated,
                stderrTruncated: outcome.result.stderrTruncated
            )
        }
        return outcome.result
    }

    private static func runSSHOutcome(
        settings: LinuxDevboxMonitorSettings,
        remoteCommand: String,
        timeout: TimeInterval,
        retryPolicy: SSHRetryPolicy
    ) -> SSHCommandOutcome {
        runSSHOutcomeWithCandidates(
            sshArgumentCandidates(settings: settings),
            remoteCommand: remoteCommand,
            timeout: timeout,
            retryPolicy: retryPolicy
        ) { executableURL, arguments, commandTimeout in
            ProcessRunner.run(
                executableURL: executableURL,
                arguments: arguments,
                timeout: commandTimeout
            )
        }
    }

    static func runSSHWithCandidates(
        _ candidates: [[String]],
        remoteCommand: String,
        timeout: TimeInterval,
        retryPolicy: SSHRetryPolicy,
        executionToken: String = UUID().uuidString.lowercased(),
        runner: (URL, [String], TimeInterval) -> ProcessRunResult
    ) -> ProcessRunResult {
        runSSHOutcomeWithCandidates(
            candidates,
            remoteCommand: remoteCommand,
            timeout: timeout,
            retryPolicy: retryPolicy,
            executionToken: executionToken,
            runner: runner
        ).result
    }

    private static func runSSHOutcomeWithCandidates(
        _ candidates: [[String]],
        remoteCommand: String,
        timeout: TimeInterval,
        retryPolicy: SSHRetryPolicy,
        executionToken: String = UUID().uuidString.lowercased(),
        runner: (URL, [String], TimeInterval) -> ProcessRunResult
    ) -> SSHCommandOutcome {
        var lastOutcome: SSHCommandOutcome?
        let executionMarker = remoteExecutionMarker(executionToken: executionToken)
        let completionMarker = remoteCompletionMarker(executionToken: executionToken)
        for (index, candidate) in candidates.enumerated() {
            let markedCommand = remoteCommandEnvelope(
                remoteCommand: remoteCommand,
                executionMarker: executionMarker,
                completionMarker: completionMarker
            )
            let arguments = candidate + [markedCommand]
            let rawResult = runner(URL(fileURLWithPath: "/usr/bin/ssh"), arguments, timeout)
            let result = removingRemoteExecutionMarkers(
                start: executionMarker,
                completion: completionMarker,
                from: rawResult
            )
            let executionState: RemoteCommandExecutionState
            if remoteCommandCompletionIsProven(
                completionMarker: completionMarker,
                result: rawResult
            ) {
                executionState = .completed
            } else if isDefiniteLocalProcessLaunchFailure(rawResult) {
                executionState = .notStarted
            } else {
                executionState = .unknown
            }
            let outcome = SSHCommandOutcome(
                result: result,
                executionState: executionState
            )
            if result.terminationStatus == 0,
               !result.timedOut,
               executionState == .completed {
                return outcome
            }
            lastOutcome = outcome
            guard index + 1 < candidates.count else { break }
            if retryPolicy == .preExecutionTransportOnly,
               outcome.executionState != .notStarted {
                break
            }
        }
        return lastOutcome ?? SSHCommandOutcome(
            result: ProcessRunResult(
                terminationStatus: -1,
                stdout: Data(),
                stderr: Data("No SSH candidates available".utf8),
                timedOut: false
            ),
            executionState: .notStarted
        )
    }

    static func remoteExecutionMarker(executionToken: String) -> String {
        "\(remoteExecutionMarkerPrefix)\(executionToken)__"
    }

    static func remoteCompletionMarker(executionToken: String) -> String {
        "\(remoteCompletionMarkerPrefix)\(executionToken)__"
    }

    static func remoteCommandEnvelope(
        remoteCommand: String,
        executionMarker: String,
        completionMarker: String
    ) -> String {
        """
        printf '%s\\n' \(shellQuote(executionMarker)) >&2
        /bin/sh -c \(shellQuote(remoteCommand))
        codexswitch_remote_status=$?
        printf '%s %s\\n' \(shellQuote(completionMarker)) "$codexswitch_remote_status" >&2
        exit "$codexswitch_remote_status"
        """
    }

    static func isDefiniteLocalProcessLaunchFailure(_ result: ProcessRunResult) -> Bool {
        result.terminationStatus == -1 && !result.timedOut
    }

    static func remoteCommandCompletionIsProven(
        completionMarker: String,
        result: ProcessRunResult
    ) -> Bool {
        remoteCompletionStatus(
            completionMarker: completionMarker,
            stderr: result.stderrString
        ) == result.terminationStatus
    }

    private static func remoteCompletionStatus(
        completionMarker: String,
        stderr: String
    ) -> Int32? {
        let prefix = "\(completionMarker) "
        let values = stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> Int32? in
                let value = String(line)
                guard value.hasPrefix(prefix) else { return nil }
                return Int32(value.dropFirst(prefix.count))
            }
        guard values.count == 1 else { return nil }
        return values[0]
    }

    private static func removingRemoteExecutionMarkers(
        start executionMarker: String,
        completion completionMarker: String,
        from result: ProcessRunResult
    ) -> ProcessRunResult {
        guard result.stderrString.contains(executionMarker)
                || result.stderrString.contains(completionMarker) else {
            return result
        }
        let completionPrefix = "\(completionMarker) "
        let cleaned = result.stderrString
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter {
                let line = String($0)
                return line != executionMarker && !line.hasPrefix(completionPrefix)
            }
            .joined(separator: "\n")
        return ProcessRunResult(
            terminationStatus: result.terminationStatus,
            stdout: result.stdout,
            stderr: Data(cleaned.utf8),
            timedOut: result.timedOut,
            stdoutTruncated: result.stdoutTruncated,
            stderrTruncated: result.stderrTruncated
        )
    }

    private static func runSCP(
        settings: LinuxDevboxMonitorSettings,
        localPaths: [String],
        remoteDirectory: String,
        timeout: TimeInterval,
        retryPolicy: SSHRetryPolicy = .preExecutionTransportOnly
    ) -> ProcessRunResult {
        var lastResult: ProcessRunResult?
        let candidates = scpArgumentCandidates(settings: settings)
        for (index, candidate) in candidates.enumerated() {
            let target = "\(settings.user)@\(settings.host):\(remoteDirectory)/"
            let result = ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/scp"),
                arguments: candidate + localPaths + [target],
                timeout: timeout
            )
            if result.terminationStatus == 0, !result.timedOut {
                return result
            }
            lastResult = result
            guard index + 1 < candidates.count else { break }
            if retryPolicy == .preExecutionTransportOnly,
               !isDefiniteLocalProcessLaunchFailure(result) {
                break
            }
        }
        return lastResult ?? ProcessRunResult(
            terminationStatus: -1,
            stdout: Data(),
            stderr: Data("No SCP candidates available".utf8),
            timedOut: false
        )
    }

    static func check(settings: LinuxDevboxMonitorSettings) -> Result<LinuxDevboxReadiness, LinuxDevboxMonitorFailure> {
        guard settings.isConfigured else {
            return .failure(LinuxDevboxMonitorFailure(message: "Linux devbox monitor is not configured"))
        }

        let result = runSSH(
            settings: settings,
            remoteCommand: remoteReadinessCommand(),
            timeout: 20,
            retryPolicy: .readOnly
        )

        guard !result.timedOut else {
            return .failure(LinuxDevboxMonitorFailure(message: "SSH timed out while checking Linux devbox"))
        }
        guard result.terminationStatus == 0 else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(LinuxDevboxMonitorFailure(message: message.isEmpty ? "SSH check failed with status \(result.terminationStatus)" : message))
        }

        do {
            return .success(try JSONDecoder().decode(LinuxDevboxReadiness.self, from: result.stdout))
        } catch {
            return .failure(LinuxDevboxMonitorFailure(message: "Failed to parse Linux devbox readiness JSON: \(error.localizedDescription)"))
        }
    }

    static func pollAccount(
        settings: LinuxDevboxMonitorSettings,
        selector: String
    ) -> Result<String, LinuxDevboxMonitorFailure> {
        guard settings.isConfigured else {
            return .failure(LinuxDevboxMonitorFailure(message: "Linux devbox monitor is not configured"))
        }

        let outcome = runSSHOutcome(
            settings: settings,
            remoteCommand: "export PATH=\"$HOME/.local/bin:$PATH\"; codexswitch-cli poll \(shellQuote(selector))",
            timeout: 25,
            retryPolicy: pollAccountRetryPolicy
        )
        let result = outcome.result

        guard !result.timedOut, outcome.executionState != .unknown else {
            return .failure(LinuxDevboxMonitorFailure(
                message: "Linux devbox poll outcome is unknown and was not replayed",
                credentialSyncDisposition: .outcomeUnknown
            ))
        }
        guard result.terminationStatus == 0 else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = message.isEmpty
                ? "SSH poll failed with status \(result.terminationStatus)"
                : message
            let signalInterrupted = isCredentialMutationSignalStatus(
                result.terminationStatus
            )
            return .failure(LinuxDevboxMonitorFailure(
                message: signalInterrupted
                    ? "Signal interrupted Linux devbox poll after it started; outcome is unknown"
                    : "\(detail); persisted poll outcome is unknown",
                credentialSyncDisposition: .outcomeUnknown
            ))
        }
        return .success(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func syncCredentials(
        settings: LinuxDevboxMonitorSettings,
        accounts: [CodexAccount],
        operation: LinuxDevboxCredentialSyncOperation
    ) -> Result<String, LinuxDevboxMonitorFailure> {
        guard settings.isConfigured else {
            return .failure(LinuxDevboxMonitorFailure(
                message: "Linux devbox monitor is not configured",
                credentialSyncDisposition: .rejected
            ))
        }
        guard credentialSyncOwnsLocalStagePath(operation: operation) else {
            return .failure(LinuxDevboxMonitorFailure(
                message: "Credential sync local staging path is not operation-owned",
                credentialSyncDisposition: .rejected
            ))
        }
        guard !accounts.isEmpty else {
            return .failure(LinuxDevboxMonitorFailure(
                message: "No accounts are available to sync",
                credentialSyncDisposition: .rejected
            ))
        }
        guard operation.targetFingerprint == credentialSyncTargetFingerprint(settings: settings),
              operation.credentialFingerprint == credentialSyncFingerprint(accounts: accounts),
              operation.expectedAccountIdentityFingerprint
                == credentialAccountIdentityFingerprint(accounts: accounts),
              operation.expectedCredentialSetFingerprint
                == credentialSetFingerprint(accounts: accounts),
              operation.expectedActiveTokenHashPrefix == activeTokenHashPrefix(accounts: accounts),
              operation.expectedActiveProviderAccountId
                == accounts.first(where: \.isActive)?.accountId else {
            return .failure(LinuxDevboxMonitorFailure(
                message: "Credential sync operation no longer matches the account snapshot",
                credentialSyncDisposition: .rejected
            ))
        }

        let bundleName = "codexswitch-auto-sync-\(operation.operationID).csbundle"
        let passphraseName = "codexswitch-auto-sync-\(operation.operationID).passphrase"
        let tempDirectory = URL(fileURLWithPath: operation.localDirectory, isDirectory: true)
        let result: Result<String, LinuxDevboxMonitorFailure>

        do {
            try createPrivateLocalCredentialStage(at: tempDirectory)
            let passphrase = try randomPassphrase()
            let bundleURL = tempDirectory.appendingPathComponent(bundleName)
            let passphraseURL = tempDirectory.appendingPathComponent(passphraseName)
            let bundle = try LinuxDevboxExportService().makeEncryptedBundle(
                accounts: accounts,
                passphrase: passphrase,
                confirmation: passphrase,
                lifetime: automaticCredentialBundleLifetime
            )
            try writePrivateLocalCredentialFile(bundle.data, to: bundleURL)
            try writePrivateLocalCredentialFile(Data(passphrase.utf8), to: passphraseURL)
            result = transferCredentials(
                settings: settings,
                operation: operation,
                bundleURL: bundleURL,
                passphraseURL: passphraseURL
            )
        } catch {
            result = .failure(LinuxDevboxMonitorFailure(
                message: "Failed to prepare Linux devbox credential bundle: \(error.localizedDescription)",
                credentialSyncDisposition: .rejected
            ))
        }

        if let cleanupFailure = cleanupLocalCredentialStage(at: tempDirectory) {
            let original: String?
            if case .failure(let failure) = result {
                original = failure.message
            } else {
                original = nil
            }
            return .failure(LinuxDevboxMonitorFailure(
                message: [original, cleanupFailure].compactMap { $0 }.joined(separator: "; "),
                credentialSyncDisposition: .cleanupUnresolved
            ))
        }
        return result
    }

    private static func transferCredentials(
        settings: LinuxDevboxMonitorSettings,
        operation: LinuxDevboxCredentialSyncOperation,
        bundleURL: URL,
        passphraseURL: URL
    ) -> Result<String, LinuxDevboxMonitorFailure> {
        let remoteDirectory = operation.remoteDirectory
        let stageOutcome = runSSHOutcome(
            settings: settings,
            remoteCommand: remoteCredentialStagingCommand(remoteDirectory: remoteDirectory),
            timeout: 20,
            retryPolicy: .preExecutionTransportOnly
        )
        let stageResult = stageOutcome.result
        guard !stageResult.timedOut, stageOutcome.executionState != .unknown else {
            return .failure(failureAfterRemoteCleanup(
                settings: settings,
                remoteDirectory: remoteDirectory,
                message: "Private Linux devbox staging outcome is unknown; credential sync was not retried",
                disposition: .cleanupUnresolved
            ))
        }
        guard stageResult.terminationStatus == 0 else {
            let message = stageResult.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = message.isEmpty
                ? "Private Linux devbox staging failed with status \(stageResult.terminationStatus)"
                : message
            if stageOutcome.executionState == .notStarted {
                return .failure(LinuxDevboxMonitorFailure(
                    message: detail,
                    credentialSyncDisposition: .retryablePreExecution
                ))
            }
            return .failure(failureAfterRemoteCleanup(
                settings: settings,
                remoteDirectory: remoteDirectory,
                message: detail,
                disposition: .rejected
            ))
        }

        let copyResult = runSCP(
            settings: settings,
            localPaths: [bundleURL.path, passphraseURL.path],
            remoteDirectory: remoteDirectory,
            timeout: 30
        )
        guard !copyResult.timedOut else {
            return .failure(failureAfterRemoteCleanup(
                settings: settings,
                remoteDirectory: remoteDirectory,
                message: "Credential copy outcome is unknown; credential sync was not retried",
                disposition: .cleanupUnresolved
            ))
        }
        guard copyResult.terminationStatus == 0 else {
            let message = copyResult.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(failureAfterRemoteCleanup(
                settings: settings,
                remoteDirectory: remoteDirectory,
                message: message.isEmpty
                    ? "SCP credential sync failed with status \(copyResult.terminationStatus)"
                    : message,
                disposition: isDefiniteLocalProcessLaunchFailure(copyResult)
                    ? .retryablePreExecution
                    : .rejected
            ))
        }

        let importOutcome = runSSHOutcome(
            settings: settings,
            remoteCommand: remoteCredentialSyncCommand(
                remoteDirectory: remoteDirectory,
                bundleName: bundleURL.lastPathComponent,
                passphraseName: passphraseURL.lastPathComponent
            ),
            timeout: 45,
            retryPolicy: .preExecutionTransportOnly
        )
        let importResult = importOutcome.result
        if importResult.stderrString.contains(remoteCleanupFailureMarker) {
            return .failure(LinuxDevboxMonitorFailure(
                message: "Linux devbox credential update finished, but private staging cleanup is unresolved at \(remoteDirectory)",
                credentialSyncDisposition: .cleanupUnresolved
            ))
        }
        guard !importResult.timedOut else {
            return .failure(LinuxDevboxMonitorFailure(
                message: "SSH timed out while updating Linux devbox credentials; outcome is unknown and the mutation was not retried",
                credentialSyncDisposition: .outcomeUnknown
            ))
        }
        guard importOutcome.executionState != .unknown else {
            return .failure(LinuxDevboxMonitorFailure(
                message: "Linux devbox credential update has no matching completion evidence; outcome is unknown and the mutation was not retried",
                credentialSyncDisposition: .outcomeUnknown
            ))
        }
        guard importResult.terminationStatus == 0 else {
            let message = importResult.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = message.isEmpty
                ? "Linux devbox credential update failed with status \(importResult.terminationStatus)"
                : message
            if importOutcome.executionState != .notStarted,
               completedCredentialImportFailureDisposition(importResult.terminationStatus)
                == .outcomeUnknown {
                return .failure(LinuxDevboxMonitorFailure(
                    message: "\(detail); signal interrupted the remote mutation and its outcome is unknown",
                    credentialSyncDisposition: .outcomeUnknown
                ))
            }
            switch importOutcome.executionState {
            case .notStarted:
                return .failure(failureAfterRemoteCleanup(
                    settings: settings,
                    remoteDirectory: remoteDirectory,
                    message: detail,
                    disposition: .retryablePreExecution
                ))
            case .completed:
                return .failure(LinuxDevboxMonitorFailure(
                    message: detail,
                    credentialSyncDisposition: .rejected
                ))
            case .unknown:
                return .failure(LinuxDevboxMonitorFailure(
                    message: "\(detail); remote mutation outcome is unknown and was not retried",
                    credentialSyncDisposition: .outcomeUnknown
                ))
            }
        }

        return .success(importResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isCredentialMutationSignalStatus(_ status: Int32) -> Bool {
        status == 129 || status == 130 || status == 143
    }

    static func completedCredentialImportFailureDisposition(
        _ status: Int32
    ) -> CredentialSyncFailureDisposition {
        isCredentialMutationSignalStatus(status) ? .outcomeUnknown : .rejected
    }

    static func credentialSyncHoldReason(
        for failure: LinuxDevboxMonitorFailure
    ) -> String {
        switch failure.credentialSyncDisposition {
        case .outcomeUnknown:
            return "Remote credential mutation outcome is unknown; read-only reconciliation is required"
        case .cleanupUnresolved:
            return "Credential staging cleanup is unresolved; absence must be proven before reconciliation"
        case .notCredentialSync, .retryablePreExecution, .rejected:
            return failure.message
        }
    }

    static func swapAccount(
        settings: LinuxDevboxMonitorSettings,
        selector: String
    ) -> Result<String, LinuxDevboxMonitorFailure> {
        guard settings.isConfigured else {
            return .failure(LinuxDevboxMonitorFailure(message: "Linux devbox monitor is not configured"))
        }

        let outcome = runSSHOutcome(
            settings: settings,
            remoteCommand: remoteSwapCommand(selector: selector),
            timeout: 30,
            retryPolicy: .preExecutionTransportOnly
        )
        let result = outcome.result

        guard !result.timedOut, outcome.executionState != .unknown else {
            return .failure(LinuxDevboxMonitorFailure(
                message: "Linux devbox account swap outcome is unknown and the mutation was not retried"
            ))
        }
        guard result.terminationStatus == 0 else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(LinuxDevboxMonitorFailure(message: message.isEmpty ? "SSH swap failed with status \(result.terminationStatus)" : message))
        }
        return .success(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func fetchUsageReport(
        settings: LinuxDevboxMonitorSettings,
        days: Int = 30
    ) -> Result<CodexTokenUsageReport, LinuxDevboxMonitorFailure> {
        guard settings.isConfigured else {
            return .failure(LinuxDevboxMonitorFailure(message: "Linux devbox monitor is not configured"))
        }

        let result = runSSH(
            settings: settings,
            remoteCommand: remoteUsageReportCommand(days: days),
            timeout: 90,
            retryPolicy: .readOnly
        )

        guard !result.timedOut else {
            return .failure(LinuxDevboxMonitorFailure(message: "SSH timed out while fetching Linux devbox token usage"))
        }
        guard result.terminationStatus == 0 else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(LinuxDevboxMonitorFailure(message: message.isEmpty ? "SSH usage check failed with status \(result.terminationStatus)" : message))
        }

        do {
            return .success(try JSONDecoder().decode(CodexTokenUsageReport.self, from: result.stdout))
        } catch {
            return .failure(LinuxDevboxMonitorFailure(message: "Failed to parse Linux devbox token usage JSON: \(error.localizedDescription)"))
        }
    }

    static func fetchAccountStates(
        settings: LinuxDevboxMonitorSettings
    ) -> Result<[LinuxDevboxAccountState], LinuxDevboxMonitorFailure> {
        switch fetchAccountStateReport(settings: settings) {
        case .success(let report):
            return .success(report.accounts)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private static func fetchAccountStateReport(
        settings: LinuxDevboxMonitorSettings
    ) -> Result<LinuxDevboxAccountStateReport, LinuxDevboxMonitorFailure> {
        guard settings.isConfigured else {
            return .failure(LinuxDevboxMonitorFailure(message: "Linux devbox monitor is not configured"))
        }

        let result = runSSH(
            settings: settings,
            remoteCommand: remoteAccountStateCommand(),
            timeout: 20,
            retryPolicy: .readOnly
        )

        guard !result.timedOut else {
            return .failure(LinuxDevboxMonitorFailure(message: "SSH timed out while fetching Linux devbox account state"))
        }
        guard result.terminationStatus == 0 else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(LinuxDevboxMonitorFailure(message: message.isEmpty ? "SSH account state check failed with status \(result.terminationStatus)" : message))
        }

        do {
            return .success(try accountStateDecoder().decode(
                LinuxDevboxAccountStateReport.self,
                from: result.stdout
            ))
        } catch {
            return .failure(LinuxDevboxMonitorFailure(message: "Failed to parse Linux devbox account state JSON: \(error.localizedDescription)"))
        }
    }

    static func captureCredentialStateEvidence(
        settings: LinuxDevboxMonitorSettings
    ) -> Result<LinuxDevboxCredentialStateEvidence, LinuxDevboxMonitorFailure> {
        guard settings.isConfigured else {
            return .failure(LinuxDevboxMonitorFailure(message: "Linux devbox monitor is not configured"))
        }

        let before: LinuxDevboxAccountStateReport
        switch fetchAccountStateReport(settings: settings) {
        case .success(let report):
            before = report
        case .failure(let failure):
            return .failure(failure)
        }

        let diagnosticsResult = runSSH(
            settings: settings,
            remoteCommand: "export PATH=\"$HOME/.local/bin:$PATH\"; codexswitch-cli auth-diagnostics --json",
            timeout: 20,
            retryPolicy: .readOnly
        )
        guard !diagnosticsResult.timedOut, diagnosticsResult.terminationStatus == 0 else {
            return .failure(LinuxDevboxMonitorFailure(
                message: "Remote auth diagnostics failed with status \(diagnosticsResult.terminationStatus)"
            ))
        }

        let diagnostics: RemoteAuthDiagnostics
        do {
            diagnostics = try JSONDecoder().decode(
                RemoteAuthDiagnostics.self,
                from: diagnosticsResult.stdout
            )
        } catch {
            return .failure(LinuxDevboxMonitorFailure(
                message: "Failed to parse remote auth diagnostics: \(error.localizedDescription)"
            ))
        }

        let after: LinuxDevboxAccountStateReport
        switch fetchAccountStateReport(settings: settings) {
        case .success(let report):
            after = report
        case .failure(let failure):
            return .failure(failure)
        }
        guard let beforeAccountFingerprint = credentialAccountIdentityFingerprint(
                  states: before.accounts
              ),
              let accountFingerprint = credentialAccountIdentityFingerprint(
                  states: after.accounts
              ),
              beforeAccountFingerprint == accountFingerprint,
              let beforeCredentialSetFingerprint = before.credentialSetFingerprint,
              let credentialSetFingerprint = after.credentialSetFingerprint,
              beforeCredentialSetFingerprint == credentialSetFingerprint,
              isLowercaseHex(credentialSetFingerprint, count: 64),
              let activeAccountID = diagnostics.activeAccountId,
              !activeAccountID.isEmpty,
              after.accounts.filter(\.isActive).count == 1,
              after.accounts.first(where: \.isActive)?.providerAccountId == activeAccountID,
              let activeTokenHashPrefix = diagnostics.activeTokenHashPrefix,
              isLowercaseHex(activeTokenHashPrefix, count: 12) else {
            return .failure(LinuxDevboxMonitorFailure(
                message: "Remote credential-state evidence is incomplete or changed while observed"
            ))
        }

        return .success(LinuxDevboxCredentialStateEvidence(
            accountIdentityFingerprint: accountFingerprint,
            credentialSetFingerprint: credentialSetFingerprint,
            activeProviderAccountId: activeAccountID,
            activeTokenHashPrefix: activeTokenHashPrefix,
            authMatchesActiveStoreToken: diagnostics.authMatchesActiveStoreToken
        ))
    }

    static func reconcileCredentialSync(
        settings: LinuxDevboxMonitorSettings,
        operation: LinuxDevboxCredentialSyncOperation
    ) -> LinuxDevboxCredentialSyncReconciliation {
        guard credentialSyncTargetFingerprint(settings: settings) == operation.targetFingerprint else {
            return .unresolved("Configured Linux devbox target changed while credential sync was pending")
        }
        guard credentialSyncOwnsLocalStagePath(operation: operation) else {
            return .unresolved("Credential sync local staging path is not operation-owned")
        }
        if let cleanupFailure = cleanupLocalCredentialStage(
            at: URL(fileURLWithPath: operation.localDirectory, isDirectory: true)
        ) {
            return .unresolved(cleanupFailure)
        }

        let stageResult = runSSH(
            settings: settings,
            remoteCommand: remoteCredentialStageAbsenceCommand(
                remoteDirectory: operation.remoteDirectory
            ),
            timeout: 15,
            retryPolicy: .readOnly
        )
        guard !stageResult.timedOut, stageResult.terminationStatus == 0 else {
            if stageResult.terminationStatus == 75 {
                return .unresolved(
                    "Private remote credential staging still exists at \(operation.remoteDirectory)"
                )
            }
            return .unresolved("Remote credential staging could not be inspected")
        }

        let observed: LinuxDevboxCredentialStateEvidence?
        switch captureCredentialStateEvidence(settings: settings) {
        case .success(let evidence):
            observed = evidence
        case .failure:
            return .unresolved("Remote credential-state evidence could not be collected")
        }
        return credentialSyncReconciliation(
            operation: operation,
            remoteStageAbsent: true,
            observed: observed
        )
    }

    static func decodeAccountStates(data: Data) throws -> [LinuxDevboxAccountState] {
        try accountStateDecoder().decode(LinuxDevboxAccountStateReport.self, from: data).accounts
    }

    private static func accountStateDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: value)
            }
            let string = try container.decode(String.self)
            if let value = Double(string) {
                return Date(timeIntervalSinceReferenceDate: value)
            }

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) {
                return date
            }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: string) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected Apple reference-date seconds or ISO8601 date string"
            )
        }
        return decoder
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func remoteCredentialStageAbsenceCommand(remoteDirectory: String) -> String {
        let stage = shellQuote(remoteDirectory)
        return "if /usr/bin/test -e \(stage) || /usr/bin/test -L \(stage); then exit 75; fi"
    }

    static func remoteCredentialStagingCommand(remoteDirectory: String) -> String {
        "umask 077; mkdir -m 700 -- \(shellQuote(remoteDirectory))"
    }

    static func remoteCredentialSyncCommand(
        remoteDirectory: String,
        bundleName: String,
        passphraseName: String,
        removeExecutable: String = "/bin/rm"
    ) -> String {
        let stage = shellQuote(remoteDirectory)
        let bundle = shellQuote("\(remoteDirectory)/\(bundleName)")
        let passphrase = shellQuote("\(remoteDirectory)/\(passphraseName)")
        let remover = shellQuote(removeExecutable)
        return """
        stage=\(stage)
        cleanup_with_status() {
            status="$1"
            trap - EXIT HUP INT TERM
            if \(remover) -rf -- "$stage" && [ ! -e "$stage" ] && [ ! -L "$stage" ]; then
                exit "$status"
            fi
            printf '%s %s\\n' '\(remoteCleanupFailureMarker)' "$stage" >&2
            if [ "$status" -eq 0 ]; then
                exit 74
            fi
            exit "$status"
        }
        trap 'cleanup_with_status "$?"' EXIT
        trap 'cleanup_with_status 129' HUP
        trap 'cleanup_with_status 130' INT
        trap 'cleanup_with_status 143' TERM
        set -eu
        umask 077
        chmod 600 \(bundle) \(passphrase)
        export PATH="$HOME/.local/bin:$PATH"
        CODEXSWITCH_IMPORT_PASSPHRASE_FILE=\(passphrase) codexswitch-cli update-bundle --preserve-active \(bundle)
        """
    }

    static func cleanupLocalCredentialStage(
        at directory: URL,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        pathExists: (String) -> Bool = { pathExistsWithoutFollowingSymlinks($0) }
    ) -> String? {
        guard pathExists(directory.path) else { return nil }
        do {
            try removeItem(directory)
        } catch {
            return "Private local credential staging cleanup failed at \(directory.path): \(error.localizedDescription)"
        }
        guard !pathExists(directory.path) else {
            return "Private local credential staging cleanup could not prove absence at \(directory.path)"
        }
        return nil
    }

    private static func failureAfterRemoteCleanup(
        settings: LinuxDevboxMonitorSettings,
        remoteDirectory: String,
        message: String,
        disposition: CredentialSyncFailureDisposition
    ) -> LinuxDevboxMonitorFailure {
        if let cleanupFailure = cleanupRemoteCredentialStage(
            settings: settings,
            remoteDirectory: remoteDirectory
        ) {
            return LinuxDevboxMonitorFailure(
                message: "\(message); \(cleanupFailure)",
                credentialSyncDisposition: .cleanupUnresolved
            )
        }
        return LinuxDevboxMonitorFailure(
            message: message,
            credentialSyncDisposition: disposition
        )
    }

    private static func cleanupRemoteCredentialStage(
        settings: LinuxDevboxMonitorSettings,
        remoteDirectory: String
    ) -> String? {
        let outcome = runSSHOutcome(
            settings: settings,
            remoteCommand: "stage=\(shellQuote(remoteDirectory)); /bin/rm -rf -- \"$stage\" && [ ! -e \"$stage\" ] && [ ! -L \"$stage\" ]",
            timeout: 15,
            retryPolicy: .preExecutionTransportOnly
        )
        let result = outcome.result
        guard !result.timedOut,
              result.terminationStatus == 0,
              outcome.executionState == .completed else {
            let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = detail.isEmpty
                ? "status \(result.terminationStatus)"
                : detail
            return "private staging cleanup is unresolved at \(remoteDirectory): \(reason)"
        }
        return nil
    }

    private static func pathExistsWithoutFollowingSymlinks(_ path: String) -> Bool {
        var metadata = stat()
        if lstat(path, &metadata) == 0 {
            return true
        }
        return errno != ENOENT
    }

    static func createPrivateLocalCredentialStage(at directory: URL) throws {
        guard mkdir(directory.path, mode_t(S_IRWXU)) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: directory.path]
            )
        }
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(0o077) == 0 else {
            throw LinuxDevboxCredentialSyncJournalError.invalidRecord(
                "local credential staging is not a private current-user directory"
            )
        }
    }

    static func writePrivateLocalCredentialFile(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        defer { Darwin.close(descriptor) }

        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(count == 0 ? EIO : errno),
                        userInfo: [NSFilePathErrorKey: url.path]
                    )
                }
            }
        }
        guard fsync(descriptor) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
    }

    static func remoteSwapCommand(selector: String) -> String {
        "export PATH=\"$HOME/.local/bin:$PATH\"; codexswitch-cli swap \(shellQuote(selector))"
    }

    static func scpArgumentCandidates(settings: LinuxDevboxMonitorSettings) -> [[String]] {
        var base = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ControlPersist=no",
            "-P", "\(settings.port)",
        ]
        if !settings.sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base.append(contentsOf: ["-i", NSString(string: settings.sshKeyPath).expandingTildeInPath])
        }

        var candidates: [[String]] = []
        if FileManager.default.isExecutableFile(atPath: tailscaleBinaryPath) {
            var proxy = base
            proxy.append(contentsOf: [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ProxyCommand=\(tailscaleBinaryPath) nc %h %p",
            ])
            candidates.append(proxy)
        }

        candidates.append(base)
        return candidates
    }

    private static func randomPassphrase() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw LinuxDevboxExportError.randomBytesFailed
        }
        return Data(bytes).base64EncodedString()
    }

    private static func updateHash(_ hasher: inout SHA256, _ value: String) {
        hasher.update(data: Data(value.utf8))
        hasher.update(data: Data([0]))
    }

    private static func updateLengthPrefixedHash(_ hasher: inout SHA256, _ value: String) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: bytes)
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func fingerprintDate(_ date: Date?) -> String {
        guard let date else { return "" }
        return String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            date.timeIntervalSinceReferenceDate
        )
    }

    private static func fingerprintQuotaSnapshot(_ snapshot: QuotaSnapshot) -> String {
        let header = [
            "allowed=\(snapshot.allowed.map(String.init) ?? "unknown")",
            "limitReached=\(snapshot.limitReached.map(String.init) ?? "unknown")",
        ]
        return (header + snapshot.orderedWindows.map(fingerprintQuotaWindow))
            .joined(separator: "|")
    }

    private static func fingerprintQuotaWindow(_ window: QuotaWindow) -> String {
        [
            window.kind.rawValue,
            String(window.durationSeconds),
            String(
                format: "%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                window.usedPercent
            ),
            fingerprintDate(window.resetsAt),
            window.hardLimitReached ? "hard" : "soft",
            window.source.rateLimit.rawValue,
            window.source.slot.rawValue,
            window.source.limitName ?? "",
            window.source.meteredFeature ?? "",
        ].joined(separator: ":")
    }

    static func remoteAccountStateCommand() -> String {
        """
        python3 - <<'PY'
        import hashlib, json, pathlib

        home = pathlib.Path.home()
        path = home / ".codexswitch" / "accounts.json"

        def account_value(account, *names):
            for name in names:
                if name in account:
                    return account.get(name)
            return None

        def stable_id(value):
            if not isinstance(value, str):
                return None
            value = value.strip()
            if not value or len(value.encode("utf-8")) > 256:
                return None
            if any(ord(character) < 32 or ord(character) == 127 for character in value):
                return None
            return value

        def public_value(value):
            if isinstance(value, dict):
                visible = {}
                for key, nested in value.items():
                    normalized_key = "".join(
                        character.lower()
                        for character in str(key)
                        if character.isalnum()
                    )
                    if "token" in normalized_key:
                        continue
                    visible[key] = public_value(nested)
                return visible
            if isinstance(value, list):
                return [public_value(nested) for nested in value]
            return value

        def contains_credential_value(value, credentials):
            if isinstance(value, dict):
                return any(
                    contains_credential_value(nested, credentials)
                    for nested in value.values()
                )
            if isinstance(value, list):
                return any(
                    contains_credential_value(nested, credentials)
                    for nested in value
                )
            return isinstance(value, str) and value in credentials

        def credential_set_fingerprint(accounts):
            normalized = []
            for account in accounts:
                account_id = stable_id(account_value(account, "accountId", "account_id"))
                id_token = account_value(account, "idToken", "id_token")
                access_token = account_value(account, "accessToken", "access_token")
                refresh_token = account_value(account, "refreshToken", "refresh_token")
                values = (account_id, id_token, access_token, refresh_token)
                if any(not isinstance(value, str) or not value for value in values):
                    return None
                normalized.append((*values, bool(account_value(account, "isActive", "is_active"))))

            account_ids = [account[0] for account in normalized]
            if len(set(account_ids)) != len(account_ids):
                return None
            if sum(1 for account in normalized if account[4]) != 1:
                return None

            digest = hashlib.sha256()
            for account_id, id_token, access_token, refresh_token, is_active in sorted(normalized):
                for value in (
                    account_id,
                    id_token,
                    access_token,
                    refresh_token,
                    "active" if is_active else "inactive",
                ):
                    encoded = value.encode("utf-8")
                    digest.update(len(encoded).to_bytes(8, "big"))
                    digest.update(encoded)
            return digest.hexdigest()

        def sanitized(account):
            return {
                "email": account_value(account, "email") or "",
                "providerAccountId": stable_id(account_value(account, "accountId", "account_id")),
                "isActive": bool(account_value(account, "isActive", "is_active")),
                "quotaSnapshot": account_value(account, "quotaSnapshot", "quota_snapshot"),
                "planType": account_value(account, "planType", "plan_type", "plan"),
                "lastRefreshed": account_value(account, "lastRefreshed", "last_refreshed"),
                "subscriptionRenewsAt": account_value(account, "subscriptionRenewsAt", "subscription_renews_at"),
                "subscriptionExpiresAt": account_value(account, "subscriptionExpiresAt", "subscription_expires_at"),
                "subscriptionWillRenew": account_value(account, "subscriptionWillRenew", "subscription_will_renew"),
                "hasActiveSubscription": account_value(account, "hasActiveSubscription", "has_active_subscription"),
                "rateLimitResetBank": account_value(account, "rateLimitResetBank", "rate_limit_reset_bank"),
                "runtimeUnusableUntil": account_value(account, "runtimeUnusableUntil", "runtime_unusable_until"),
                "runtimeUnusableReason": account_value(account, "runtimeUnusableReason", "runtime_unusable_reason"),
            }

        if not path.exists():
            print(json.dumps({"accounts": []}))
            raise SystemExit(0)

        raw = json.loads(path.read_text())
        accounts = raw.get("accounts", []) if isinstance(raw, dict) else raw
        accounts = [account for account in accounts if isinstance(account, dict)]
        fingerprint = credential_set_fingerprint(accounts)
        visible_accounts = [
            public_value(sanitized(account))
            for account in accounts
            if account_value(account, "email")
        ]
        payload = {
            "accounts": visible_accounts,
            "credentialSetFingerprint": fingerprint,
        }
        credentials = {
            value
            for account in accounts
            for value in (
                account_value(account, "idToken", "id_token"),
                account_value(account, "accessToken", "access_token"),
                account_value(account, "refreshToken", "refresh_token"),
            )
            if isinstance(value, str) and value
        }
        if contains_credential_value(payload, credentials):
            raise SystemExit(74)
        print(json.dumps(payload, separators=(",", ":")))
        PY
        """
    }

    static func remoteReadinessCommand() -> String {
        """
        export PATH="$HOME/.local/bin:$PATH"
        python3 - <<'PY'
        import json, subprocess

        def run_json(arguments):
            completed = subprocess.run(
                arguments,
                check=True,
                capture_output=True,
                text=True,
                timeout=10,
            )
            return json.loads(completed.stdout)

        def stable_id(value):
            if not isinstance(value, str):
                return None
            value = value.strip()
            if not value or len(value.encode("utf-8")) > 256:
                return None
            if any(ord(character) < 32 or ord(character) == 127 for character in value):
                return None
            return value

        readiness = run_json(["codexswitch-cli", "doctor", "--json"])
        diagnostics = run_json(["codexswitch-cli", "auth-diagnostics", "--json"])
        readiness["activeProviderAccountId"] = stable_id(
            diagnostics.get("activeAccountId")
        )
        print(json.dumps(readiness, separators=(",", ":")))
        PY
        """
    }

    static func remoteUsageReportCommand(days: Int) -> String {
        let safeDays = max(1, min(days, 365))
        return """
        python3 - <<'PY'
        import json, sqlite3, pathlib, time, hashlib, re

        DAYS = \(safeDays)
        REFERENCE = 978307200
        LONG_CONTEXT_THRESHOLD = 272000
        MODEL_CAPABILITIES = (
            (re.compile(r"^gpt-5(?:\\.\\d+)?(?:[-.].*)?$", re.I), frozenset(("long_context_pricing",))),
        )
        home = pathlib.Path.home()

        def load_accounts():
            path = home / ".codexswitch" / "accounts.json"
            if not path.exists():
                return []
            raw = json.loads(path.read_text())
            return raw.get("accounts", []) if isinstance(raw, dict) else raw

        def token_hashes(accounts):
            hashes = []
            for account in accounts:
                tokens = [
                    account.get("accessToken") or account.get("access_token") or "",
                    account.get("refreshToken") or account.get("refresh_token") or "",
                ]
                for token in tokens:
                    if not token:
                        continue
                    hashes.append(hashlib.sha256(token.encode()).hexdigest()[:12])
            return sorted(set(hashes))

        def field(line, name):
            needle = name + "="
            start = line.find(needle)
            if start < 0:
                return None
            value = line[start + len(needle):]
            if value.startswith('"'):
                value = value[1:]
                end = value.find('"')
                return value[:end] if end >= 0 else None
            end = len(value)
            for idx, char in enumerate(value):
                if char.isspace() or char in ("}", ":", ","):
                    end = idx
                    break
            return value[:end]

        def int_field(line, name):
            value = field(line, name)
            try:
                return int(value) if value is not None else None
            except ValueError:
                return None

        def json_int_field(line, name):
            patterns = [
                r'"' + re.escape(name) + r'"\\s*:\\s*(\\d+)',
                re.escape(name) + r':\\s*(\\d+)',
            ]
            for pattern in patterns:
                match = re.search(pattern, line)
                if match:
                    return int(match.group(1))
            return None

        def json_string_field(line, name):
            match = re.search(r'"' + re.escape(name) + r'"\\s*:\\s*"([^"]+)"', line)
            return match.group(1) if match else None

        def normalize_model(model):
            normalized = (model or "").split("}")[0].replace("\\n", " ").replace("\\t", " ").strip()
            return normalized or "unknown"

        def model_has_capability(model, capability):
            normalized = normalize_model(model)
            if normalized == "unknown":
                return False
            return any(
                pattern.fullmatch(normalized) and capability in capabilities
                for pattern, capabilities in MODEL_CAPABILITIES
            )

        def uses_long_context_pricing(event):
            return (
                event.get("kind") == "response"
                and event["inputTokens"] > LONG_CONTEXT_THRESHOLD
                and model_has_capability(event.get("model"), "long_context_pricing")
            )

        def parse_json_object_usage(line):
            match = re.search(r'"type"\\s*:\\s*"response\\.completed"', line)
            if not match:
                return None
            start = line.rfind("{", 0, match.start())
            if start < 0:
                return None
            depth = 0
            in_string = False
            escaped = False
            end = None
            for idx in range(start, len(line)):
                char = line[idx]
                if in_string:
                    if escaped:
                        escaped = False
                    elif char == "\\\\":
                        escaped = True
                    elif char == '"':
                        in_string = False
                elif char == '"':
                    in_string = True
                elif char == "{":
                    depth += 1
                elif char == "}":
                    depth -= 1
                    if depth == 0:
                        end = idx
                        break
            if end is None:
                return None
            try:
                root = json.loads(line[start:end + 1])
            except Exception:
                return None
            if not isinstance(root, dict) or root.get("type") != "response.completed":
                return None
            response = root.get("response") or {}
            usage = response.get("usage") or {}
            input_tokens = usage.get("input_tokens")
            output_tokens = usage.get("output_tokens")
            if input_tokens is None or output_tokens is None:
                return None
            input_details = usage.get("input_tokens_details") or {}
            output_details = usage.get("output_tokens_details") or {}
            cached_tokens = input_details.get("cached_tokens")
            if cached_tokens is None:
                cached_tokens = usage.get("cached_tokens") or usage.get("cached_input_tokens") or 0
            reasoning_tokens = output_details.get("reasoning_tokens")
            if reasoning_tokens is None:
                reasoning_tokens = usage.get("reasoning_tokens") or 0
            model = response.get("model") or json_string_field(line, "model")
            return int(input_tokens), int(cached_tokens), int(output_tokens), int(reasoning_tokens), model

        def parse_turn_aggregate_usage(line):
            if "codex.turn.token_usage.input_tokens" not in line:
                return None
            turn_id = field(line, "turn.id")
            input_tokens = int_field(line, "codex.turn.token_usage.input_tokens")
            cached_tokens = int_field(line, "codex.turn.token_usage.cached_input_tokens")
            output_tokens = int_field(line, "codex.turn.token_usage.output_tokens")
            if turn_id is None or input_tokens is None or cached_tokens is None or output_tokens is None:
                return None
            reasoning_tokens = int_field(line, "codex.turn.token_usage.reasoning_output_tokens") or 0
            model = field(line, "model") or field(line, "slug")
            return {
                "kind": "turn",
                "sessionId": field(line, "codexswitch_session") or field(line, "thread_id") or field(line, "thread.id"),
                "turnId": turn_id,
                "timestamp": field(line, "codexswitch_ts") or field(line, "event.timestamp") or "unknown-timestamp",
                "model": normalize_model(model),
                "inputTokens": int(input_tokens),
                "cachedInputTokens": min(int(cached_tokens or 0), int(input_tokens)),
                "outputTokens": int(output_tokens),
                "reasoningTokens": int(reasoning_tokens),
            }

        def parse_token_count_usage(line):
            if '"type":"token_count"' not in line and '"type": "token_count"' not in line:
                return None
            start = line.find("{")
            if start < 0:
                return None
            try:
                root = json.loads(line[start:])
            except Exception:
                return None
            if root.get("type") != "event_msg":
                return None
            payload = root.get("payload") or {}
            if payload.get("type") != "token_count":
                return None
            info = payload.get("info") or {}
            total = info.get("total_token_usage") or {}
            input_tokens = total.get("input_tokens")
            output_tokens = total.get("output_tokens")
            if input_tokens is None or output_tokens is None:
                return None
            cached_tokens = total.get("cached_input_tokens") or 0
            reasoning_tokens = total.get("reasoning_output_tokens") or 0
            return {
                "kind": "session",
                "sessionId": field(line, "codexswitch_session") or field(line, "thread_id") or field(line, "thread.id"),
                "timestamp": root.get("timestamp") or field(line, "codexswitch_ts") or "unknown-timestamp",
                "model": normalize_model(field(line, "codexswitch_model") or field(line, "model")),
                "inputTokens": int(input_tokens),
                "cachedInputTokens": min(int(cached_tokens or 0), int(input_tokens)),
                "outputTokens": int(output_tokens),
                "reasoningTokens": int(reasoning_tokens),
            }

        def usage_lines():
            lines = []
            cutoff = int(time.time() - DAYS * 86400)
            sqlite_path = home / ".codex" / "logs_2.sqlite"
            if sqlite_path.exists():
                conn = sqlite3.connect(sqlite_path)
                rows = conn.execute(
                    '''
                    select 'codexswitch_ts=' || ts || ' codexswitch_target=' || target || ' ' || replace(feedback_log_body, char(10), ' ') from logs
                    where (feedback_log_body like '%response.completed%'
                        or feedback_log_body like '%codex.turn.token_usage.input_tokens%')
                      and ts >= ?
                    order by ts asc
                    ''',
                    (cutoff,),
                ).fetchall()
                lines.extend(row[0] for row in rows)

            session_root = home / ".codex" / "sessions"
            if session_root.exists():
                def model_in(line):
                    try:
                        root = json.loads(line)
                    except Exception:
                        return None
                    payload = root.get("payload") or {}
                    candidates = []
                    if root.get("type") in ("session_meta", "turn_context"):
                        candidates.extend([
                            payload.get("model"),
                            payload.get("model_slug"),
                            payload.get("slug"),
                        ])
                    elif root.get("type") == "event_msg" and payload.get("type") == "token_count":
                        info = payload.get("info") or {}
                        candidates.extend([
                            payload.get("model"),
                            payload.get("model_slug"),
                            payload.get("slug"),
                            info.get("model"),
                            info.get("model_slug"),
                        ])
                    for candidate in candidates:
                        if isinstance(candidate, str) and candidate.strip():
                            return candidate.strip()
                    return None

                def token_count_score(line):
                    try:
                        root = json.loads(line)
                    except Exception:
                        return None
                    if root.get("type") != "event_msg":
                        return None
                    payload = root.get("payload") or {}
                    if payload.get("type") != "token_count":
                        return None
                    total = (payload.get("info") or {}).get("total_token_usage") or {}
                    return (
                        int(total.get("input_tokens") or 0)
                        + int(total.get("output_tokens") or 0)
                        + int(total.get("reasoning_output_tokens") or 0)
                    )

                def tail_lines(path, max_bytes=8 * 1024 * 1024):
                    try:
                        size = path.stat().st_size
                        with path.open("rb") as handle:
                            if size > max_bytes:
                                handle.seek(size - max_bytes)
                                handle.readline()
                            data = handle.read()
                    except OSError:
                        return []
                    return data.decode("utf-8", errors="ignore").splitlines()

                def session_id_for(path):
                    matches = re.findall(
                        r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
                        path.stem,
                        re.I,
                    )
                    return matches[-1] if matches else path.stem

                for path in sorted(session_root.rglob("*.jsonl")):
                    try:
                        if path.stat().st_mtime < cutoff:
                            continue
                    except OSError:
                        continue
                    session_id = session_id_for(path)
                    model = "unknown"
                    best_line = None
                    best_score = -1
                    for raw_line in tail_lines(path):
                        found_model = model_in(raw_line)
                        if found_model:
                            model = found_model
                        if '"type":"token_count"' not in raw_line and '"type": "token_count"' not in raw_line:
                            continue
                        score = token_count_score(raw_line)
                        if score is not None and score >= best_score:
                            best_score = score
                            best_line = raw_line.strip()
                    if best_line:
                        lines.append(f"codexswitch_session={session_id} codexswitch_model={model} " + best_line)
            return lines

        by_model = {}
        response_seen = set()
        response_events = []
        turn_aggregates = {}
        session_totals = {}
        first_event_at = None

        def add_usage(event):
            global first_event_at
            timestamp = event["timestamp"]
            model = event["model"]
            input_tokens = event["inputTokens"]
            cached_tokens = event["cachedInputTokens"]
            output_tokens = event["outputTokens"]
            reasoning_tokens = event["reasoningTokens"]
            try:
                event_seconds = float(timestamp)
                first_event_at = event_seconds if first_event_at is None else min(first_event_at, event_seconds)
            except ValueError:
                pass
            usage = by_model.setdefault(model, {
                "model": model,
                "inputTokens": 0,
                "cachedInputTokens": 0,
                "outputTokens": 0,
                "reasoningTokens": 0,
                "completionCount": 0,
                "longContextInputTokens": 0,
                "longContextCachedInputTokens": 0,
                "longContextOutputTokens": 0,
            })
            usage["inputTokens"] += input_tokens
            usage["cachedInputTokens"] += cached_tokens
            usage["outputTokens"] += output_tokens
            usage["reasoningTokens"] += reasoning_tokens
            usage["completionCount"] += 1
            if uses_long_context_pricing(event):
                usage["longContextInputTokens"] += input_tokens
                usage["longContextCachedInputTokens"] += cached_tokens
                usage["longContextOutputTokens"] += output_tokens

        def add_long_context_pricing(event):
            model = event["model"]
            input_tokens = event["inputTokens"]
            cached_tokens = event["cachedInputTokens"]
            output_tokens = event["outputTokens"]
            usage = by_model.setdefault(model, {
                "model": model,
                "inputTokens": 0,
                "cachedInputTokens": 0,
                "outputTokens": 0,
                "reasoningTokens": 0,
                "completionCount": 0,
                "longContextInputTokens": 0,
                "longContextCachedInputTokens": 0,
                "longContextOutputTokens": 0,
            })
            usage["longContextInputTokens"] += input_tokens
            usage["longContextCachedInputTokens"] += cached_tokens
            usage["longContextOutputTokens"] += output_tokens

        for line in usage_lines():
            session_event = parse_token_count_usage(line)
            if session_event is not None:
                session_id = session_event.get("sessionId")
                if session_id:
                    existing = session_totals.get(session_id)
                    score = session_event["inputTokens"] + session_event["outputTokens"] + session_event["reasoningTokens"]
                    existing_score = -1 if existing is None else existing["inputTokens"] + existing["outputTokens"] + existing["reasoningTokens"]
                    if score >= existing_score:
                        session_totals[session_id] = session_event
                continue

            turn_event = parse_turn_aggregate_usage(line)
            if turn_event is not None:
                existing = turn_aggregates.get(turn_event["turnId"])
                score = turn_event["inputTokens"] + turn_event["outputTokens"] + turn_event["reasoningTokens"]
                existing_score = -1 if existing is None else existing["inputTokens"] + existing["outputTokens"] + existing["reasoningTokens"]
                if score >= existing_score:
                    turn_aggregates[turn_event["turnId"]] = turn_event
                continue

            input_tokens = int_field(line, "input_token_count")
            cached_tokens = int_field(line, "cached_token_count")
            output_tokens = int_field(line, "output_token_count")
            reasoning_tokens = int_field(line, "reasoning_token_count") or 0
            model = field(line, "slug") or field(line, "model")
            if input_tokens is None or cached_tokens is None or output_tokens is None:
                parsed_json = parse_json_object_usage(line)
                if parsed_json is not None:
                    input_tokens, cached_tokens, output_tokens, reasoning_tokens, model = parsed_json
                else:
                    input_tokens = json_int_field(line, "input_tokens")
                    cached_tokens = json_int_field(line, "cached_tokens") or json_int_field(line, "cached_input_tokens") or 0
                    output_tokens = json_int_field(line, "output_tokens")
                    reasoning_tokens = json_int_field(line, "reasoning_tokens") or 0
                    model = json_string_field(line, "model") or model
            if input_tokens is None or output_tokens is None:
                continue
            timestamp = field(line, "codexswitch_ts") or field(line, "event.timestamp") or "unknown-timestamp"
            model = normalize_model(model)
            cached_tokens = min(cached_tokens or 0, input_tokens)
            turn_id = field(line, "turn.id")
            key = (timestamp, turn_id, model, input_tokens, cached_tokens, output_tokens, reasoning_tokens)
            if key in response_seen:
                continue
            response_seen.add(key)
            response_events.append({
                "kind": "response",
                "sessionId": field(line, "codexswitch_session") or field(line, "thread_id") or field(line, "thread.id"),
                "turnId": turn_id,
                "timestamp": timestamp,
                "model": model,
                "inputTokens": input_tokens,
                "cachedInputTokens": cached_tokens,
                "outputTokens": output_tokens,
                "reasoningTokens": reasoning_tokens,
            })

        aggregated_session_ids = set(session_totals.keys())
        aggregated_turn_ids = set(turn_aggregates.keys())
        for event in sorted(session_totals.values(), key=lambda item: item["timestamp"]):
            add_usage(event)
        for event in sorted(turn_aggregates.values(), key=lambda item: item["timestamp"]):
            if event.get("sessionId") in aggregated_session_ids:
                continue
            add_usage(event)
        for event in sorted(response_events, key=lambda item: item["timestamp"]):
            if event.get("kind") != "response":
                continue
            if not uses_long_context_pricing(event):
                continue
            if event.get("sessionId") in aggregated_session_ids or event.get("turnId") in aggregated_turn_ids:
                add_long_context_pricing(event)
        for event in sorted(response_events, key=lambda item: item["timestamp"]):
            if event.get("sessionId") in aggregated_session_ids:
                continue
            if event.get("turnId") in aggregated_turn_ids:
                continue
            add_usage(event)

        report = {
            "source": "linuxDevbox",
            "generatedAt": time.time() - REFERENCE,
            "windowDays": DAYS,
            "accountTokenHashPrefixes": token_hashes(load_accounts()),
            "models": sorted(by_model.values(), key=lambda item: item["model"]),
        }
        if first_event_at is not None:
            report["firstEventAt"] = first_event_at - REFERENCE
        print(json.dumps(report))
        PY
        """
    }
}
