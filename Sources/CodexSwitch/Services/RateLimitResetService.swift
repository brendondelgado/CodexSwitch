import Foundation
import os

private let rateLimitResetLogger = Logger(subsystem: "com.codexswitch", category: "RateLimitReset")

enum RateLimitResetSettings {
    static let automaticRedemptionDefaultsKey = "automaticRateLimitResetRedemption"
}

struct RateLimitResetHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
}

enum RateLimitResetServiceError: Error, Sendable, Equatable {
    case invalidResponse
    case httpError(Int)
    case malformedInventory
    case malformedConsumeResponse
    case missingCreditIdentifier
    case creditAlreadySucceeded(String)
    case unresolvedAttempt(UUID)
    case submissionUnauthorized
    case journalUnavailable(String)
    case transport(String)
}

enum RateLimitResetConsumeResult: Sendable, Equatable {
    case reconciliationRequired(UUID)
    case noCredit
    case nothingToReset
}

enum RateLimitResetAttemptState: String, Codable, Sendable, Equatable {
    case prepared
    case submitted
    case reconciling
    case pendingPersistence
    case succeeded
    case notApplied

    var isTerminal: Bool {
        switch self {
        case .succeeded, .notApplied: true
        case .prepared, .submitted, .reconciling, .pendingPersistence: false
        }
    }
}

struct RateLimitResetAttempt: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let providerAccountId: String
    let creditId: String
    let startingAvailableCount: Int
    let startingBankFetchedAt: Date
    let startingQuotaFetchedAt: Date?
    let createdAt: Date
    var submittedAt: Date?
    var state: RateLimitResetAttemptState
    var consumeResponseCode: String?
    var updatedAt: Date
}

struct RateLimitResetSubmissionPermit: Sendable, Equatable {
    let attemptId: UUID
    let providerAccountId: String
    let creditId: String
    let targetAccountId: UUID
    let activationGeneration: UUID
    let leaseGeneration: UInt64
    let runtimePermit: AccountActivationRuntimePermit
    let activationEffectPermit: AccountActivationEffectPermit
    let issuedAt: Date
    private let oneShotNonce: UUID

    init(
        attemptId: UUID,
        providerAccountId: String,
        creditId: String,
        targetAccountId: UUID,
        activationGeneration: UUID,
        leaseGeneration: UInt64,
        runtimePermit: AccountActivationRuntimePermit,
        activationEffectPermit: AccountActivationEffectPermit,
        issuedAt: Date,
        oneShotNonce: UUID = UUID()
    ) {
        self.attemptId = attemptId
        self.providerAccountId = providerAccountId
        self.creditId = creditId
        self.targetAccountId = targetAccountId
        self.activationGeneration = activationGeneration
        self.leaseGeneration = leaseGeneration
        self.runtimePermit = runtimePermit
        self.activationEffectPermit = activationEffectPermit
        self.issuedAt = issuedAt
        self.oneShotNonce = oneShotNonce
    }

    func matches(_ attempt: RateLimitResetAttempt, at date: Date) -> Bool {
        attempt.id == attemptId
            && attempt.providerAccountId == providerAccountId
            && attempt.creditId == creditId
            && runtimePermit.targetAccountId == targetAccountId
            && runtimePermit.activationGeneration == activationGeneration
            && runtimePermit.requiredPhase == .confirmed
            && runtimePermit.evidence.runtimeCurrentAccountId == targetAccountId
            && activationEffectPermit.targetAccountId == targetAccountId
            && activationEffectPermit.activationGeneration == activationGeneration
            && activationEffectPermit.requiredPhase == .confirmed
            && activationEffectPermit.leaseGeneration == leaseGeneration
            && activationEffectPermit.runtimePermit == runtimePermit
            && runtimePermit.evidence.observedAt <= issuedAt
            && runtimePermit.evidence.expiresAt > issuedAt
            && issuedAt <= date
            && runtimePermit.evidence.expiresAt > date
            && activationEffectPermit.isCurrentlyAuthorized(at: date)
    }
}

enum RateLimitResetReconciliationOutcome: Sendable, Equatable {
    case noAttempt
    case unresolved(RateLimitResetAttempt)
    case pendingPersistence(RateLimitResetAttempt)
}

actor RateLimitResetService {
    typealias Transport = @Sendable (URLRequest) async throws -> RateLimitResetHTTPResponse
    typealias SubmissionAuthorization = @Sendable (
        RateLimitResetAttempt
    ) async -> RateLimitResetSubmissionPermit?

    private static let inventoryURL = URL(
        string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    )!
    private static let consumeURL = URL(
        string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume"
    )!

    private let transport: Transport
    private var journal: RateLimitResetAttemptJournal

    init(
        session: URLSession = .shared,
        journalURL: URL = RateLimitResetAttemptJournal.defaultURL,
        journalTestHooks: RateLimitResetAttemptJournal.TestHooks = .init()
    ) {
        self.transport = { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RateLimitResetServiceError.invalidResponse
            }
            return RateLimitResetHTTPResponse(statusCode: http.statusCode, data: data)
        }
        self.journal = RateLimitResetAttemptJournal(url: journalURL, testHooks: journalTestHooks)
    }

    init(
        transport: @escaping Transport,
        journalURL: URL = RateLimitResetAttemptJournal.defaultURL,
        journalTestHooks: RateLimitResetAttemptJournal.TestHooks = .init()
    ) {
        self.transport = transport
        self.journal = RateLimitResetAttemptJournal(url: journalURL, testHooks: journalTestHooks)
    }

    func fetchBank(
        for account: CodexAccount,
        force: Bool = false,
        now: Date = Date()
    ) async throws -> RateLimitResetBank {
        if !force,
           let bank = account.rateLimitResetBank,
           bank.isFresh(at: now) {
            return bank
        }

        let response: RateLimitResetHTTPResponse
        do {
            response = try await transport(Self.authorizedRequest(url: Self.inventoryURL, account: account))
        } catch let error as RateLimitResetServiceError {
            throw error
        } catch {
            throw RateLimitResetServiceError.transport(error.localizedDescription)
        }

        guard response.statusCode == 200 else {
            throw RateLimitResetServiceError.httpError(response.statusCode)
        }

        do {
            let payload = try JSONDecoder().decode(InventoryPayload.self, from: response.data)
            guard payload.availableCount >= 0, payload.totalEarnedCount >= 0 else {
                throw RateLimitResetServiceError.malformedInventory
            }
            let credits = try payload.credits.map { try $0.credit() }
            return RateLimitResetBank(
                availableCount: payload.availableCount,
                totalEarnedCount: payload.totalEarnedCount,
                credits: credits,
                fetchedAt: now
            )
        } catch let error as RateLimitResetServiceError {
            throw error
        } catch {
            rateLimitResetLogger.error("Reset inventory decode failed: \(error.localizedDescription, privacy: .public)")
            throw RateLimitResetServiceError.malformedInventory
        }
    }

    func consume(
        for account: CodexAccount,
        bank: RateLimitResetBank,
        now: Date = Date(),
        redeemRequestId: UUID = UUID(),
        authorizeSubmission: @escaping SubmissionAuthorization
    ) async throws -> RateLimitResetConsumeResult {
        guard let creditId = bank.oldestExpiringCredit(at: now)?.id else {
            throw RateLimitResetServiceError.missingCreditIdentifier
        }
        let attempt = RateLimitResetAttempt(
            id: redeemRequestId,
            providerAccountId: account.accountId,
            creditId: creditId,
            startingAvailableCount: bank.availableCount,
            startingBankFetchedAt: bank.fetchedAt,
            startingQuotaFetchedAt: account.realQuotaSnapshot?.fetchedAt,
            createdAt: now,
            submittedAt: nil,
            state: .prepared,
            consumeResponseCode: nil,
            updatedAt: now
        )
        try journal.prepare(attempt, now: now)

        let body = ConsumeRequest(
            creditId: creditId,
            redeemRequestId: redeemRequestId.uuidString.lowercased()
        )
        var request = Self.authorizedRequest(url: Self.consumeURL, account: account)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        try journal.markSubmitted(id: attempt.id, at: now)
        guard let permit = await authorizeSubmission(attempt) else {
            try journal.markNotApplied(
                id: attempt.id,
                responseCode: "authorization_lost",
                at: Date()
            )
            throw RateLimitResetServiceError.submissionUnauthorized
        }

        let finalAuthorizationAt = Date()
        let journalAttempt = try journal.unresolvedAttempt(
            for: attempt.providerAccountId
        )
        guard journalAttempt?.id == attempt.id,
              journalAttempt?.state == .submitted,
              journalAttempt?.creditId == attempt.creditId,
              permit.matches(attempt, at: finalAuthorizationAt) else {
            try journal.markNotApplied(
                id: attempt.id,
                responseCode: "authorization_lost",
                at: finalAuthorizationAt
            )
            throw RateLimitResetServiceError.submissionUnauthorized
        }

        let response: RateLimitResetHTTPResponse
        do {
            response = try await transport(request)
        } catch {
            try journal.markReconciling(id: attempt.id, responseCode: nil, at: Date())
            throw RateLimitResetServiceError.transport(error.localizedDescription)
        }

        guard response.statusCode == 200 else {
            try journal.markReconciling(id: attempt.id, responseCode: "http_\(response.statusCode)", at: Date())
            throw RateLimitResetServiceError.httpError(response.statusCode)
        }
        guard let payload = try? JSONDecoder().decode(ConsumeResponse.self, from: response.data) else {
            try journal.markReconciling(id: attempt.id, responseCode: "malformed", at: Date())
            throw RateLimitResetServiceError.malformedConsumeResponse
        }

        switch payload.code {
        case "reset", "already_redeemed":
            try journal.markReconciling(id: attempt.id, responseCode: payload.code, at: Date())
            return .reconciliationRequired(attempt.id)
        case "no_credit":
            try journal.markNotApplied(id: attempt.id, responseCode: payload.code, at: Date())
            return .noCredit
        case "nothing_to_reset":
            try journal.markNotApplied(id: attempt.id, responseCode: payload.code, at: Date())
            return .nothingToReset
        default:
            try journal.markReconciling(id: attempt.id, responseCode: payload.code, at: Date())
            throw RateLimitResetServiceError.malformedConsumeResponse
        }
    }

    func unresolvedAttempt(for providerAccountId: String) throws -> RateLimitResetAttempt? {
        try journal.unresolvedAttempt(for: providerAccountId)
    }

    func unresolvedProviderAccountIds() throws -> Set<String> {
        Set(try journal.allAttempts().filter { !$0.state.isTerminal }.map(\.providerAccountId))
    }

    func allAttempts() throws -> [RateLimitResetAttempt] {
        try journal.allAttempts()
    }

    func finalizeReconciliationAfterPersistence(
        attemptId: UUID,
        now: Date = Date()
    ) throws -> RateLimitResetAttempt {
        try journal.finalizeSucceeded(id: attemptId, at: now)
    }

    func reconcile(
        for account: CodexAccount,
        bank: RateLimitResetBank,
        snapshot: QuotaSnapshot,
        now: Date = Date()
    ) throws -> RateLimitResetReconciliationOutcome {
        guard let attempt = try journal.unresolvedAttempt(for: account.accountId) else {
            return .noAttempt
        }
        let attemptedAt = attempt.submittedAt ?? attempt.createdAt
        guard bank.fetchedAt > attemptedAt,
              bank.isFresh(at: now),
              snapshot.fetchedAt > attemptedAt,
              snapshot.isFresh(at: now) else {
            return .unresolved(attempt)
        }
        if attempt.state == .pendingPersistence {
            return .pendingPersistence(attempt)
        }

        let matchingCredit = bank.credits.first {
            $0.normalizedRedemptionIdentifier == attempt.creditId
        }
        let status = matchingCredit?.status.lowercased()
        let explicitlyConsumed = matchingCredit?.redeemedAt != nil
            || status == "redeemed"
            || status == "consumed"
            || status == "used"
        let missingWithCountDecrease = matchingCredit == nil
            && bank.availableCount < attempt.startingAvailableCount
        let inventoryProvesConsumption = explicitlyConsumed || missingWithCountDecrease
        let quotaProvesRecovery = snapshot.isImmediatelyUsable

        guard inventoryProvesConsumption, quotaProvesRecovery else {
            return .unresolved(attempt)
        }

        let pendingPersistence = try journal.markPendingPersistence(id: attempt.id, at: now)
        return .pendingPersistence(pendingPersistence)
    }

    private static func authorizedRequest(url: URL, account: CodexAccount) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return request
    }
}

struct RateLimitResetAttemptJournal {
    enum PersistenceBoundary: Sendable, Equatable {
        case prepared
        case submitted
        case reconciling
        case pendingPersistence
        case terminal
    }

    struct TestHooks: Sendable {
        var transaction = SecureAtomicFileTransaction.TestHooks()
        var beforeCommit: (@Sendable (PersistenceBoundary) throws -> Void)? = nil
    }

    static let version = 1
    static let terminalRetentionInterval: TimeInterval = 30 * 24 * 60 * 60
    static let maximumTerminalAttempts = 100
    static let defaultURL = URL(fileURLWithPath: NSString(
        string: "~/.codexswitch/reset-attempts.json"
    ).expandingTildeInPath)

    private struct Envelope: Codable {
        let version: Int
        let attempts: [RateLimitResetAttempt]
    }

    let url: URL
    private let transaction: SecureAtomicFileTransaction
    private let testHooks: TestHooks
    private var attempts: [RateLimitResetAttempt] = []

    init(url: URL, testHooks: TestHooks = .init()) {
        self.url = url
        self.testHooks = testHooks
        self.transaction = SecureAtomicFileTransaction(
            path: url.path,
            subject: "reset journal",
            testHooks: testHooks.transaction
        )
    }

    mutating func unresolvedAttempt(
        for providerAccountId: String
    ) throws -> RateLimitResetAttempt? {
        try Self.unresolvedAttempt(for: providerAccountId, in: loadLatest())
    }

    mutating func allAttempts() throws -> [RateLimitResetAttempt] {
        try loadLatest()
    }

    private mutating func loadLatest() throws -> [RateLimitResetAttempt] {
        do {
            let loaded = try transaction.withExclusiveLock { lockedFile in
                try Self.decode(lockedFile.read().bytes)
            }
            attempts = loaded
            return loaded
        } catch let error as RateLimitResetServiceError {
            throw error
        } catch {
            throw RateLimitResetServiceError.journalUnavailable(error.localizedDescription)
        }
    }

    mutating func prepare(_ attempt: RateLimitResetAttempt, now: Date) throws {
        try transact(boundary: .prepared, now: now) { attempts in
            if let unresolved = Self.unresolvedAttempt(
                for: attempt.providerAccountId,
                in: attempts
            ) {
                throw RateLimitResetServiceError.unresolvedAttempt(unresolved.id)
            }
            if attempts.contains(where: {
                $0.creditId == attempt.creditId && $0.state == .succeeded
            }) {
                throw RateLimitResetServiceError.creditAlreadySucceeded(attempt.creditId)
            }
            guard !attempts.contains(where: { $0.id == attempt.id }) else {
                throw RateLimitResetServiceError.journalUnavailable(
                    "duplicate reset attempt identifier"
                )
            }
            attempts.append(attempt)
        }
    }

    mutating func markSubmitted(id: UUID, at date: Date) throws {
        try update(id: id, boundary: .submitted) {
            $0.submittedAt = date
            $0.state = .submitted
            $0.updatedAt = date
        }
    }

    mutating func markReconciling(id: UUID, responseCode: String?, at date: Date) throws {
        try update(id: id, boundary: .reconciling) {
            $0.state = .reconciling
            $0.consumeResponseCode = responseCode
            $0.updatedAt = date
        }
    }

    mutating func markNotApplied(id: UUID, responseCode: String, at date: Date) throws {
        try update(id: id, boundary: .terminal) {
            $0.state = .notApplied
            $0.consumeResponseCode = responseCode
            $0.updatedAt = date
        }
    }

    mutating func markPendingPersistence(
        id: UUID,
        at date: Date
    ) throws -> RateLimitResetAttempt {
        try update(id: id, boundary: .pendingPersistence) {
            guard !$0.state.isTerminal else {
                throw RateLimitResetServiceError.journalUnavailable(
                    "terminal reset attempt cannot return to pending persistence"
                )
            }
            $0.state = .pendingPersistence
            $0.updatedAt = date
        }
        guard let attempt = attempts.first(where: { $0.id == id }) else {
            throw RateLimitResetServiceError.journalUnavailable("reset attempt disappeared")
        }
        return attempt
    }

    mutating func finalizeSucceeded(id: UUID, at date: Date) throws -> RateLimitResetAttempt {
        try update(id: id, boundary: .terminal) {
            guard $0.state == .pendingPersistence else {
                throw RateLimitResetServiceError.journalUnavailable(
                    "reset attempt is not awaiting account persistence"
                )
            }
            $0.state = .succeeded
            $0.updatedAt = date
        }
        guard let attempt = attempts.first(where: { $0.id == id }) else {
            throw RateLimitResetServiceError.journalUnavailable("reset attempt disappeared")
        }
        return attempt
    }

    private mutating func update(
        id: UUID,
        boundary: PersistenceBoundary,
        mutation: (inout RateLimitResetAttempt) throws -> Void
    ) throws {
        try transact(boundary: boundary, now: nil) { attempts in
            guard let index = attempts.firstIndex(where: { $0.id == id }) else {
                throw RateLimitResetServiceError.journalUnavailable("reset attempt not found")
            }
            try mutation(&attempts[index])
        }
    }

    private mutating func transact(
        boundary: PersistenceBoundary,
        now: Date?,
        mutation: (inout [RateLimitResetAttempt]) throws -> Void
    ) throws {
        do {
            let committedAttempts = try transaction.withExclusiveLock { lockedFile in
                let current = try lockedFile.read()
                var proposed = try Self.decode(current.bytes)
                try mutation(&proposed)
                let pruneDate = now
                    ?? proposed.map(\.updatedAt).max()
                    ?? Date.distantPast
                proposed = Self.pruned(proposed, now: pruneDate)
                try testHooks.beforeCommit?(boundary)
                let data = try Self.encode(proposed)
                let committed = try lockedFile.replace(
                    data,
                    expectedGeneration: current.generation
                )
                return try Self.decode(committed.bytes)
            }
            attempts = committedAttempts
        } catch let error as RateLimitResetServiceError {
            throw error
        } catch {
            throw RateLimitResetServiceError.journalUnavailable(error.localizedDescription)
        }
    }

    private static func unresolvedAttempt(
        for providerAccountId: String,
        in attempts: [RateLimitResetAttempt]
    ) -> RateLimitResetAttempt? {
        attempts
            .filter { $0.providerAccountId == providerAccountId && !$0.state.isTerminal }
            .max { $0.createdAt < $1.createdAt }
    }

    private static func pruned(
        _ attempts: [RateLimitResetAttempt],
        now: Date
    ) -> [RateLimitResetAttempt] {
        let cutoff = now.addingTimeInterval(-terminalRetentionInterval)
        let unresolved = attempts.filter { !$0.state.isTerminal }
        let terminal = attempts
            .filter { $0.state.isTerminal && $0.updatedAt >= cutoff }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maximumTerminalAttempts)
        return unresolved + terminal
    }

    private static func decode(_ data: Data?) throws -> [RateLimitResetAttempt] {
        guard let data else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == version else {
            throw RateLimitResetServiceError.journalUnavailable(
                "unsupported reset journal version \(envelope.version)"
            )
        }
        return envelope.attempts
    }

    private static func encode(_ attempts: [RateLimitResetAttempt]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(version: version, attempts: attempts))
    }
}

private struct InventoryPayload: Decodable {
    let availableCount: Int
    let credits: [CreditPayload]
    let totalEarnedCount: Int

    private enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case credits
        case totalEarnedCount = "total_earned_count"
    }
}

private struct CreditPayload: Decodable {
    let id: String
    let resetType: String?
    let status: String
    let grantedAt: String?
    let expiresAt: String?
    let redeemedAt: String?
    let title: String?
    let description: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case resetType = "reset_type"
        case status
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
        case redeemedAt = "redeemed_at"
        case title
        case description
    }

    func credit() throws -> RateLimitResetCredit {
        RateLimitResetCredit(
            id: id,
            resetType: resetType,
            status: status,
            grantedAt: try Self.date(grantedAt),
            expiresAt: try Self.date(expiresAt),
            redeemedAt: try Self.date(redeemedAt),
            title: title,
            description: description
        )
    }

    private static func date(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        if let date = internet.date(from: value) {
            return date
        }
        throw RateLimitResetServiceError.malformedInventory
    }
}

private struct ConsumeRequest: Encodable {
    let creditId: String
    let redeemRequestId: String

    private enum CodingKeys: String, CodingKey {
        case creditId = "credit_id"
        case redeemRequestId = "redeem_request_id"
    }
}

private struct ConsumeResponse: Decodable {
    let code: String
}
