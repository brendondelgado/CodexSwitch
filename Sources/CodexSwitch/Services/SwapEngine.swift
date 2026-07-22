import CryptoKit
import Foundation
import Darwin
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "SwapEngine")

struct CodexReloadSummary: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case noLocalRuntime
        case allDiscoveredRuntimesAcknowledged
        case restartRequiredOrFailed
    }

    let outcome: Outcome
    let discoveredRuntimeCount: Int
    let acknowledgedRuntimeCount: Int
    let operationFailed: Bool

    var unacknowledgedRuntimeCount: Int {
        discoveredRuntimeCount - acknowledgedRuntimeCount
    }

    init(
        discoveredRuntimeCount: Int,
        acknowledgedRuntimeCount: Int,
        operationFailed: Bool = false
    ) {
        let discovered = max(0, discoveredRuntimeCount)
        let acknowledged = max(0, min(acknowledgedRuntimeCount, discovered))
        self.discoveredRuntimeCount = discovered
        self.acknowledgedRuntimeCount = acknowledged
        self.operationFailed = operationFailed

        if operationFailed {
            outcome = .restartRequiredOrFailed
        } else if discovered == 0 {
            outcome = .noLocalRuntime
        } else if acknowledged == discovered {
            outcome = .allDiscoveredRuntimesAcknowledged
        } else {
            outcome = .restartRequiredOrFailed
        }
    }
}

extension HotSwapRuntimeKind: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct CodexSignalProcessIdentity: Codable, Equatable, Sendable {
    let pid: Int32
    let ownerUID: UInt32
    let executablePath: String
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    var startedAt: Date {
        Date(
            timeIntervalSince1970: TimeInterval(startSeconds)
                + TimeInterval(startMicroseconds) / 1_000_000
        )
    }
}

struct CodexKernelExecutableIdentity: Codable, Equatable, Sendable {
    let canonicalPath: String
    let device: UInt64
    let inode: UInt64

    init(canonicalPath: String, device: UInt64, inode: UInt64) {
        self.canonicalPath = canonicalPath
        self.device = device
        self.inode = inode
    }

    // Compatibility for older deterministic fixtures. Zero vnode fields are
    // rejected by every live binding validator and can never authorize a signal.
    init(path: String) {
        self.init(canonicalPath: path, device: 0, inode: 0)
    }
}

struct CodexAuthFileIdentity: Codable, Equatable, Sendable {
    let canonicalPath: String
    let device: UInt64
    let inode: UInt64
    let accountID: String
    let completeTokenFingerprint: String

    init(
        canonicalPath: String,
        device: UInt64 = 0,
        inode: UInt64 = 0,
        accountID: String = "",
        completeTokenFingerprint: String
    ) {
        self.canonicalPath = canonicalPath
        self.device = device
        self.inode = inode
        self.accountID = accountID
        self.completeTokenFingerprint = completeTokenFingerprint
    }
}

struct CodexReloadBinding: Codable, Equatable, Sendable {
    static let currentContractVersion = 3

    let contractVersion: Int
    let processIdentity: CodexSignalProcessIdentity
    let kernelExecutableIdentity: CodexKernelExecutableIdentity
    let runtimeKind: HotSwapRuntimeKind
    let authFileIdentity: CodexAuthFileIdentity
    let requestNonce: String
    let issuedAtUnixMilliseconds: Int64

    init(
        contractVersion: Int = currentContractVersion,
        processIdentity: CodexSignalProcessIdentity,
        kernelExecutableIdentity: CodexKernelExecutableIdentity,
        runtimeKind: HotSwapRuntimeKind,
        authFileIdentity: CodexAuthFileIdentity,
        requestNonce: String,
        issuedAtUnixMilliseconds: Int64
    ) {
        self.contractVersion = contractVersion
        self.processIdentity = processIdentity
        self.kernelExecutableIdentity = kernelExecutableIdentity
        self.runtimeKind = runtimeKind
        self.authFileIdentity = authFileIdentity
        self.requestNonce = requestNonce
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
    }
}

struct CodexReloadRequestArtifact: Codable, Equatable, Sendable {
    let binding: CodexReloadBinding
}

struct CodexReloadAcknowledgement: Codable, Equatable, Sendable {
    let binding: CodexReloadBinding
    let acknowledgedAtUnixMilliseconds: Int64
    let loadedTokenFingerprint: String
    let activeTokenFingerprint: String
    let frontendNotified: Bool
    let frontendWriteCount: Int
    let authGeneration: UInt64?
    let reconnectReady: Bool?
    let initializedFrontendCount: Int?
    let eligibleFrontendCount: Int?
    let rejectedFrontendCount: Int?
    let idleListenerReady: Bool?

    init(
        binding: CodexReloadBinding,
        acknowledgedAtUnixMilliseconds: Int64,
        loadedTokenFingerprint: String,
        activeTokenFingerprint: String,
        frontendNotified: Bool,
        frontendWriteCount: Int,
        authGeneration: UInt64?,
        reconnectReady: Bool?,
        initializedFrontendCount: Int? = nil,
        eligibleFrontendCount: Int? = nil,
        rejectedFrontendCount: Int? = nil,
        idleListenerReady: Bool? = nil
    ) {
        self.binding = binding
        self.acknowledgedAtUnixMilliseconds = acknowledgedAtUnixMilliseconds
        self.loadedTokenFingerprint = loadedTokenFingerprint
        self.activeTokenFingerprint = activeTokenFingerprint
        self.frontendNotified = frontendNotified
        self.frontendWriteCount = frontendWriteCount
        self.authGeneration = authGeneration
        self.reconnectReady = reconnectReady
        self.initializedFrontendCount = initializedFrontendCount
        self.eligibleFrontendCount = eligibleFrontendCount
        self.rejectedFrontendCount = rejectedFrontendCount
        self.idleListenerReady = idleListenerReady
    }
}

struct CodexReloadCapabilityReceipt: Codable, Equatable, Sendable {
    let acknowledgement: CodexReloadAcknowledgement
    let recordedAtUnixMilliseconds: Int64
}

enum CodexPGrepDiscoveryResult: Equatable, Sendable {
    case noMatches
    case snapshot(CodexPGrepProcessSnapshot)
    case failed(String)
}

struct CodexPGrepProcessSnapshot: Equatable, Sendable {
    let pids: [Int32]
    let isComplete: Bool
}

struct CodexIdentityBoundProcess: Equatable, Sendable {
    let identity: CodexSignalProcessIdentity
    let kernelExecutableIdentity: CodexKernelExecutableIdentity
    let arguments: [String]

    init(
        identity: CodexSignalProcessIdentity,
        kernelExecutableIdentity: CodexKernelExecutableIdentity,
        arguments: [String]
    ) {
        self.identity = identity
        self.kernelExecutableIdentity = kernelExecutableIdentity
        self.arguments = arguments
    }
}

struct CodexRuntimeTarget: Equatable, Sendable {
    let process: CodexIdentityBoundProcess
    let runtimeKind: HotSwapRuntimeKind
}

struct CodexRuntimeDiscoverySnapshot: Equatable, Sendable {
    let targets: [CodexRuntimeTarget]
    let isComplete: Bool
}

struct CodexLocalCLIRuntimeIdentity: Equatable, Sendable {
    let processIdentity: CodexSignalProcessIdentity
    let kernelExecutableIdentity: CodexKernelExecutableIdentity
}

struct CodexLocalCLIRuntimeTopology: Equatable, Sendable {
    let runtimes: [CodexLocalCLIRuntimeIdentity]
    let allRuntimesUseManagedRoute: Bool
}

struct CodexRuntimeObservation: Equatable, Sendable {
    let target: CodexRuntimeTarget
    let authFileIdentity: CodexAuthFileIdentity
}

struct CodexLocalRuntimeEvidence: Equatable, Sendable {
    let observation: CodexRuntimeObservation
    let startupAcknowledgement: CodexReloadAcknowledgement
}

struct CodexLocalRuntimeEvidenceSnapshot: Equatable, Sendable {
    let runtimes: [CodexLocalRuntimeEvidence]
    let isComplete: Bool

    init(runtimes: [CodexLocalRuntimeEvidence], isComplete: Bool) {
        self.isComplete = isComplete
        self.runtimes = isComplete ? runtimes : []
    }
}

struct CodexSecureFileSnapshot: Equatable, Sendable {
    let canonicalPath: String
    let device: UInt64
    let inode: UInt64
    let data: Data
    let modifiedAtUnixMilliseconds: Int64
}

struct CodexReloadExecutionResult: Equatable, Sendable {
    let discoverySnapshot: CodexRuntimeDiscoverySnapshot
    let newlyAcknowledgedPIDs: Set<Int32>
    let reusedAcknowledgedPIDs: Set<Int32>
    let operationFailed: Bool

    var acknowledgedPIDs: Set<Int32> {
        newlyAcknowledgedPIDs.union(reusedAcknowledgedPIDs)
    }
}

private enum CodexReloadRequestPersistenceError: Error {
    case bindingDrift
}

final class CodexReloadAttemptGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var activePIDs: Set<Int32> = []
    private let onContention: (@Sendable (Set<Int32>) -> Void)?

    init(onContention: (@Sendable (Set<Int32>) -> Void)? = nil) {
        self.onContention = onContention
    }

    func acquire(_ pids: Set<Int32>) {
        guard !pids.isEmpty else { return }
        condition.lock()
        var reportedContention = false
        while !activePIDs.isDisjoint(with: pids) {
            if !reportedContention {
                reportedContention = true
                onContention?(pids)
            }
            condition.wait()
        }
        activePIDs.formUnion(pids)
        condition.unlock()
    }

    func acquireAdmission(_ pids: Set<Int32>) -> CodexReloadAdmission {
        acquire(pids)
        return CodexReloadAdmission(gate: self, pids: pids)
    }

    func tryAcquire(_ pids: Set<Int32>) -> Bool {
        guard !pids.isEmpty else { return true }
        condition.lock()
        defer { condition.unlock() }
        guard activePIDs.isDisjoint(with: pids) else { return false }
        activePIDs.formUnion(pids)
        return true
    }

    func release(_ pids: Set<Int32>) {
        guard !pids.isEmpty else { return }
        condition.lock()
        activePIDs.subtract(pids)
        condition.broadcast()
        condition.unlock()
    }
}

final class CodexReloadAdmission: @unchecked Sendable {
    let pids: Set<Int32>

    private let gate: CodexReloadAttemptGate
    private let lock = NSLock()
    private var active = true

    fileprivate init(gate: CodexReloadAttemptGate, pids: Set<Int32>) {
        self.gate = gate
        self.pids = pids
    }

    deinit {
        release()
    }

    func release() {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        active = false
        lock.unlock()
        gate.release(pids)
    }

    fileprivate func admits(
        _ requiredPIDs: Set<Int32>,
        on expectedGate: CodexReloadAttemptGate
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
            && gate === expectedGate
            && requiredPIDs.isSubset(of: pids)
    }
}

enum SwapEngine {
    struct AuthFileWriteTestHooks: Sendable {
        var transaction = SecureAtomicFileTransaction.TestHooks()
    }

    private static let codexAuthPath = NSString("~/.codex/auth.json").expandingTildeInPath
    private static let maximumAuthFileBytes = 1_048_576
    private static let maximumReloadArtifactBytes = 65_536
    static let maximumReloadAcknowledgementAge: TimeInterval = 5 * 60
    static let maximumReloadAcknowledgementAgeMilliseconds: Int64 = 5 * 60 * 1_000
    static let maximumReloadCapabilityAgeMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1_000
    private static let resetTieFiveHourTolerance = 2.0
    private static let resetTieWeeklyTolerance = 5.0
    nonisolated static let reloadAttemptGate = CodexReloadAttemptGate()

    /// Score an account for swap eligibility. Higher = better candidate.
    /// Returns -1 for denied, exhausted, stale, or windowless snapshots.
    static func score(_ account: CodexAccount, now: Date = Date()) -> Double {
        guard account.isImmediatelyUsableReplacement(at: now),
              let snapshot = account.realQuotaSnapshot(at: now) else { return -1 }

        let planBase = planPriorityBase(for: account)
        var result = planBase

        if let fiveHour = snapshot.fiveHour {
            result += fiveHour.remainingPercent
        }
        if let weekly = snapshot.weekly {
            result += weekly.remainingPercent * 0.3
            if weekly.remainingPercent < 20 {
                result -= 50
            }
        }

        return result
    }

    static func isImmediatelyUsable(_ account: CodexAccount, now: Date = Date()) -> Bool {
        account.isImmediatelyUsableReplacement(at: now)
    }

    private static func planPriorityBase(for account: CodexAccount) -> Double {
        switch account.planPriority {
        case 4:
            return 15_000 // Pro: fastest inference and largest allowance
        case 3:
            return 10_000 // Pro Lite: above Plus, below full Pro
        case 2:
            return 5_000 // Plus/team/business: normal paid working pool
        default:
            return 100 // Free: usable only after paid accounts are spent/resetting
        }
    }

    /// Select the best account to swap to from candidates (excluding currently active)
    static func selectOptimalAccount(
        from accounts: [CodexAccount],
        now: Date = Date()
    ) -> CodexAccount? {
        rankedEligibleCandidates(from: accounts, now: now).first
    }

    /// Select a target for automatic failover using the shared eligibility and ranking policy.
    static func selectAutoSwapCandidate(
        from accounts: [CodexAccount],
        now: Date = Date()
    ) -> CodexAccount? {
        selectOptimalAccount(from: accounts, now: now)
    }

    /// Select a higher-tier account even when the active account still has
    /// quota. Pro accounts get the fastest inference, so a usable higher plan
    /// should not sit idle behind a healthy lower plan.
    static func selectPlanUpgradeCandidate(
        active: CodexAccount,
        from accounts: [CodexAccount],
        excluding excludedAccountIds: Set<UUID> = [],
        now: Date = Date()
    ) -> CodexAccount? {
        rankedEligibleCandidates(
            from: accounts,
            excluding: excludedAccountIds.union([active.id]),
            now: now,
            additionalEligibility: { $0.planPriority > active.planPriority }
        ).first
    }

    static func shouldHonorManualOverride(
        activeAccountId: UUID,
        manualOverrideAccountId: UUID?,
        activeNeedsRelief: Bool
    ) -> Bool {
        manualOverrideAccountId == activeAccountId && !activeNeedsRelief
    }

    static func earliestUsableReset(from accounts: [CodexAccount], now: Date = Date()) -> Date? {
        accounts
            .compactMap { $0.blockedQuotaRecoveryAt(now: now) }
            .min()
    }

    static func rankedEligibleCandidates(
        from accounts: [CodexAccount],
        excluding excludedAccountIds: Set<UUID> = [],
        now: Date,
        additionalEligibility: (CodexAccount) -> Bool = { _ in true }
    ) -> [CodexAccount] {
        accounts
            .filter { !$0.isActive && !excludedAccountIds.contains($0.id) }
            .filter(additionalEligibility)
            .filter { isImmediatelyUsable($0, now: now) }
            .sorted { isBetterCandidate($0, than: $1, now: now) }
    }

    private static func isBetterCandidate(
        _ left: CodexAccount,
        than right: CodexAccount,
        now: Date
    ) -> Bool {
        if let (leftReset, rightReset) = resetTieBreakerDates(left, right, now: now) {
            if leftReset != rightReset {
                return leftReset < rightReset
            }
        }
        let leftScore = score(left, now: now)
        let rightScore = score(right, now: now)
        if leftScore != rightScore { return leftScore > rightScore }
        return left.isOrderedBeforeByStableIdentity(right)
    }

    private static func resetTieBreakerDates(
        _ left: CodexAccount,
        _ right: CodexAccount,
        now: Date
    ) -> (Date, Date)? {
        guard left.planPriority == right.planPriority,
              let leftSnapshot = left.realQuotaSnapshot(at: now),
              let rightSnapshot = right.realQuotaSnapshot(at: now) else {
            return nil
        }

        if let leftFiveHour = leftSnapshot.fiveHour,
           let rightFiveHour = rightSnapshot.fiveHour,
           abs(leftFiveHour.remainingPercent - rightFiveHour.remainingPercent) <= resetTieFiveHourTolerance {
            let weeklyComparable: Bool
            switch (leftSnapshot.weekly, rightSnapshot.weekly) {
            case let (leftWeekly?, rightWeekly?):
                weeklyComparable = abs(leftWeekly.remainingPercent - rightWeekly.remainingPercent)
                    <= resetTieWeeklyTolerance
            case (nil, nil):
                weeklyComparable = true
            default:
                weeklyComparable = false
            }
            if weeklyComparable {
                return (leftFiveHour.resetsAt, rightFiveHour.resetsAt)
            }
        }

        if leftSnapshot.fiveHour == nil,
           rightSnapshot.fiveHour == nil,
           let leftWeekly = leftSnapshot.weekly,
           let rightWeekly = rightSnapshot.weekly,
           abs(leftWeekly.remainingPercent - rightWeekly.remainingPercent) <= resetTieWeeklyTolerance {
            return (leftWeekly.resetsAt, rightWeekly.resetsAt)
        }

        return nil
    }

    /// Explain why a candidate was selected as next-up over alternatives
    static func explainSelection(
        candidate: CodexAccount,
        allAccounts: [CodexAccount],
        now: Date = Date()
    ) -> String {
        guard let snapshot = candidate.realQuotaSnapshot(at: now) else {
            return "Selected but no quota data available yet."
        }

        let candidateScore = score(candidate, now: now)

        var lines: [String] = []

        // Primary factor
        if !candidate.planLabel.isEmpty {
            lines.append("\(candidate.planLabel) priority")
        }
        lines.append(quotaSummary(snapshot))

        if let weekly = snapshot.weekly {
            if weekly.effectiveRemainingPercent < 20 {
                lines.append("Low weekly quota; score penalized")
            } else if weekly.effectiveRemainingPercent < 50 {
                lines.append("Weekly at \(Int(weekly.effectiveRemainingPercent))%; factored into score")
            }
        }

        if let urgentWindow = snapshot.mostUrgentWindow {
            let mins = Int(max(0, urgentWindow.timeUntilReset) / 60)
            lines.append("\(windowLabel(urgentWindow.kind)) resets in \(mins / 60)h \(mins % 60)m")
        }

        // Compare against runners-up
        let eligible = allAccounts.filter {
            !$0.isActive && $0.id != candidate.id && score($0, now: now) > 0
        }
        let others = eligible.sorted { isBetterCandidate($0, than: $1, now: now) }

        if let runnerUp = others.first,
           let runnerUpSnapshot = runnerUp.realQuotaSnapshot(at: now),
           let candidateRemaining = snapshot.minimumRemainingPercent,
           let runnerUpRemaining = runnerUpSnapshot.minimumRemainingPercent {
            let diff = Int(candidateRemaining - runnerUpRemaining)
            if let (candidateReset, runnerUpReset) = resetTieBreakerDates(
                candidate,
                runnerUp,
                now: now
            ),
               candidateReset < runnerUpReset {
                lines.append("Comparable quota; earlier reset broke the tie")
            } else if diff > 0 {
                lines.append("+\(diff)% over next best (\(runnerUp.email.components(separatedBy: "@").first ?? "")@...)")
            } else {
                lines.append("Tied with others; quota mix broke the tie")
            }
        }

        let excluded = allAccounts.filter { !$0.isActive && score($0, now: now) <= 0 }
        if !excluded.isEmpty {
            lines.append("\(excluded.count) account\(excluded.count == 1 ? "" : "s") excluded (exhausted or no data)")
        }

        lines.append("Score: \(String(format: "%.0f", candidateScore))")

        return lines.joined(separator: "\n")
    }

    private static func quotaSummary(_ snapshot: QuotaSnapshot) -> String {
        snapshot.orderedPolicyWindows.map {
            "\(windowLabel($0.kind)): \(Int($0.effectiveRemainingPercent))%"
        }.joined(separator: " | ")
    }

    private static func windowLabel(_ kind: QuotaWindowKind) -> String {
        switch kind {
        case .fiveHour: return "5h"
        case .weekly: return "Weekly"
        case .unknown: return "Quota"
        }
    }

    /// Generate auth.json data for a given account
    static func generateAuthFileData(for account: CodexAccount) throws -> Data {
        let authFile = AuthFile(
            authMode: "chatgpt",
            openaiApiKey: nil,
            tokens: AuthTokens(
                idToken: account.idToken,
                accessToken: account.accessToken,
                refreshToken: account.refreshToken,
                accountId: account.accountId
            ),
            lastRefresh: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(authFile)
    }

    nonisolated static func pgrepDiscoveryResult(
        stdout: Data,
        terminationStatus: Int32,
        timedOut: Bool
    ) -> CodexPGrepDiscoveryResult {
        guard !timedOut else { return .failed("timeout") }
        guard terminationStatus == 0 || terminationStatus == 1 else {
            return .failed("status_\(terminationStatus)")
        }
        guard let output = String(data: stdout, encoding: .utf8) else {
            return .failed("invalid_utf8")
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if terminationStatus == 1 {
            return trimmed.isEmpty ? .noMatches : .failed("status_1_with_output")
        }
        guard !trimmed.isEmpty else {
            return .failed("status_0_without_output")
        }

        var commandLinesByPID: [Int32: String] = [:]
        var orderedPIDs: [Int32] = []
        var ambiguousPIDs: Set<Int32> = []
        var droppedRows = false

        for rawLine in output.split(whereSeparator: { $0.isNewline }) {
            let fields = rawLine.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0.isWhitespace }
            )
            guard fields.count == 2,
                  let pid = Int32(String(fields[0])),
                  pid > 0 else {
                droppedRows = true
                continue
            }

            let commandLine = String(fields[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commandLine.isEmpty else {
                droppedRows = true
                continue
            }

            guard !ambiguousPIDs.contains(pid) else {
                droppedRows = true
                continue
            }
            if let existingCommandLine = commandLinesByPID[pid] {
                if existingCommandLine != commandLine {
                    commandLinesByPID.removeValue(forKey: pid)
                    ambiguousPIDs.insert(pid)
                    droppedRows = true
                }
                continue
            }

            commandLinesByPID[pid] = commandLine
            orderedPIDs.append(pid)
        }

        let acceptedPIDs = orderedPIDs.filter { commandLinesByPID[$0] != nil }
        guard !acceptedPIDs.isEmpty else {
            return .failed("malformed_output")
        }
        return .snapshot(CodexPGrepProcessSnapshot(
            pids: acceptedPIDs,
            isComplete: !droppedRows
        ))
    }

    /// Send SIGHUP to running Codex CLI processes so they reload auth.json.
    /// Only sends if a SIGHUP-capable binary wrote a verification marker.
    nonisolated static let localCodexProcessDiscoveryArguments = [
        "-l",
        "-x",
        "codex",
    ]

    @discardableResult
    static func signalCodexReload(
        authorizeEffect: @Sendable () -> Bool = { true }
    ) -> CodexReloadSummary {
        guard authorizeEffect() else {
            return CodexReloadSummary(
                discoveredRuntimeCount: 0,
                acknowledgedRuntimeCount: 0,
                operationFailed: true
            )
        }
        let hasVerifiedSighupMarker = Self.hasVerifiedSighupMarker()
        if !hasVerifiedSighupMarker {
            logger.info("SIGHUP not verified by installed codex binary — skipping")
            SwapLog.append(.sighupSkipped(reason: "sighup-verified not found"))
        }

        let now = Date()
        let minAge: TimeInterval = 10  // Process must be running at least 10s

        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: localCodexProcessDiscoveryArguments,
            timeout: 3
        )
        let discoveryResult = pgrepDiscoveryResult(
            stdout: result.stdout,
            terminationStatus: result.terminationStatus,
            timedOut: result.timedOut
        )
        if case .failed(let reason) = discoveryResult {
            logger.error("Local Codex pgrep discovery failed: \(reason)")
            SwapLog.append(.sighupSkipped(reason: "pgrep failed: \(reason)"))
        }
        var managedRouteVerification:
            Result<CodexManagedRuntimeTrust.VerifiedRoute, CodexManagedRuntimeTrust.Failure>?
        let execution = executeReloadBatch(
            preliminaryPIDs: preliminaryReloadPIDs(from: discoveryResult),
            discoveryProvider: {
                runtimeDiscoverySnapshot(
                    from: discoveryResult,
                    runtimeKind: .localInteractiveCLI,
                    requiredOwnerUID: UInt32(getuid()),
                    identityProvider: signalProcessIdentity,
                    argumentProvider: processArguments
                )
            },
            requiredOwnerUID: UInt32(getuid()),
            candidateIsEligible: { target in
                hasVerifiedSighupMarker
                    && now.timeIntervalSince(target.process.identity.startedAt) >= minAge
            },
            makeBinding: { target in
                makeReloadBinding(for: target)
            },
            hotSwapSupport: { binding in
                guard authorizeEffect() else { return false }
                let hasStartupAcknowledgement = startupAcknowledgement(
                    matching: binding,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    now: Date()
                ) != nil
                let hasPriorRuntimeCapability = !hasStartupAcknowledgement
                    && ensurePriorRuntimeCapabilityReceipt(
                        matching: binding,
                        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                        now: Date()
                    )
                var managedRuntimeBootstrapAuthorized = false
                if !hasStartupAcknowledgement && !hasPriorRuntimeCapability {
                    let verification: Result<
                        CodexManagedRuntimeTrust.VerifiedRoute,
                        CodexManagedRuntimeTrust.Failure
                    >
                    if let cached = managedRouteVerification {
                        verification = cached
                    } else {
                        let verified = CodexManagedRuntimeTrust.verifyRoute(
                            managedLauncherPath:
                                CodexManagedRuntimeTrust.defaultManagedLauncherPath()
                        )
                        managedRouteVerification = verified
                        verification = verified
                    }

                    switch verification {
                    case .failure(let failure):
                        SwapLog.append(.debug(
                            "CLI_FIRST_ACK_BOOTSTRAP_DENIED pid=\(binding.processIdentity.pid) reason=\(failure.rawValue)"
                        ))
                    case .success(let verifiedRoute):
                        managedRuntimeBootstrapAuthorized =
                            CodexManagedRuntimeTrust.verifiedRouteAuthorizes(
                                binding,
                                verifiedRoute: verifiedRoute
                            )
                        SwapLog.append(.debug(
                            managedRuntimeBootstrapAuthorized
                                ? "CLI_FIRST_ACK_BOOTSTRAP_AUTHORIZED pid=\(binding.processIdentity.pid)"
                                : "CLI_FIRST_ACK_BOOTSTRAP_DENIED pid=\(binding.processIdentity.pid) reason=runtime_identity_mismatch"
                        ))
                    }
                }
                let supported = cliReloadCapabilityIsAuthorized(
                    binding: binding,
                    hasStartupAcknowledgement: hasStartupAcknowledgement,
                    managedRuntimeBootstrapAuthorized: managedRuntimeBootstrapAuthorized,
                    priorRuntimeCapabilityAuthorized: hasPriorRuntimeCapability
                )
                if !supported {
                    SwapLog.append(.sighupSkipped(
                        reason: "pid \(binding.processIdentity.pid) lacks complete identity-bound startup evidence"
                    ))
                }
                return supported
            },
            alreadyAcknowledged: { binding in
                startupAcknowledgement(
                    matching: binding,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    now: Date()
                ) != nil
            },
            bindingIsCurrent: { reloadBindingIsCurrent($0) },
            persistRequest: { authorizeEffect() && persistReloadRequest($0) },
            signal: { pid in authorizeEffect() && kill(pid, SIGHUP) == 0 },
            awaitAcknowledgements: waitForHotSwapAcknowledgements,
            gate: reloadAttemptGate
        )

        if execution.discoverySnapshot.targets.isEmpty {
            logger.info("No codex CLI processes found to signal")
            SwapLog.append(.sighupSkipped(reason: "no codex processes found"))
        }
        for pid in execution.reusedAcknowledgedPIDs {
            SwapLog.append(.debug("CLI_RELOAD_REUSED_ACK pid=\(pid)"))
        }
        for pid in execution.newlyAcknowledgedPIDs {
            logger.info("SIGHUP → pid \(pid) acknowledged")
            SwapLog.append(.sighupSent(pid: pid, startedAt: ""))
        }
        return codexReloadSummary(
            from: execution.discoverySnapshot,
            acknowledgedPIDs: execution.acknowledgedPIDs,
            operationFailed: execution.operationFailed
        )
    }

    nonisolated static func cliReloadCapabilityIsAuthorized(
        binding: CodexReloadBinding,
        hasStartupAcknowledgement: Bool,
        managedRuntimeBootstrapAuthorized: Bool,
        priorRuntimeCapabilityAuthorized: Bool = false
    ) -> Bool {
        binding.runtimeKind == .localInteractiveCLI
            && (
                hasStartupAcknowledgement
                    || managedRuntimeBootstrapAuthorized
                    || priorRuntimeCapabilityAuthorized
            )
    }

    nonisolated static func codexReloadSummary(
        from discoverySnapshot: CodexRuntimeDiscoverySnapshot,
        acknowledgedPIDs: Set<Int32>,
        operationFailed: Bool = false
    ) -> CodexReloadSummary {
        reloadSummary(
            from: discoverySnapshot,
            acknowledgedPIDs: acknowledgedPIDs,
            operationFailed: operationFailed
        )
    }

    @discardableResult
    static func signalDesktopAppServerReload() -> Bool {
        signalDesktopAppServerReloadSummary().outcome == .allDiscoveredRuntimesAcknowledged
    }

    @discardableResult
    static func signalDesktopAppServerReloadSummary() -> CodexReloadSummary {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-fl", "codex.*app-server"],
            timeout: 3
        )
        let discoveryResult = pgrepDiscoveryResult(
            stdout: result.stdout,
            terminationStatus: result.terminationStatus,
            timedOut: result.timedOut
        )
        if case .failed(let reason) = discoveryResult {
            SwapLog.append(.desktopExternalReloadSkipped(reason: "desktop pgrep failed: \(reason)"))
        }
        let hasVerifiedSighupMarker = Self.hasVerifiedSighupMarker()
        if !hasVerifiedSighupMarker {
            SwapLog.append(.desktopExternalReloadSkipped(reason: "sighup-verified not found"))
        }

        let execution = executeReloadBatch(
            preliminaryPIDs: preliminaryReloadPIDs(from: discoveryResult),
            discoveryProvider: {
                runtimeDiscoverySnapshot(
                    from: discoveryResult,
                    runtimeKind: .externalAppServer,
                    requiredOwnerUID: UInt32(getuid()),
                    identityProvider: signalProcessIdentity,
                    argumentProvider: processArguments
                )
            },
            requiredOwnerUID: UInt32(getuid()),
            candidateIsEligible: { _ in hasVerifiedSighupMarker },
            makeBinding: { target in
                makeReloadBinding(for: target)
            },
            hotSwapSupport: { binding in
                let hasStartupAcknowledgement = startupAcknowledgement(
                    matching: binding,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    now: Date()
                ) != nil
                let supported = desktopReloadCapabilityIsAuthorized(
                    binding: binding,
                    hasStartupAcknowledgement: hasStartupAcknowledgement,
                    firstAcknowledgementBootstrapAuthorized: false
                )
                if !supported {
                    SwapLog.append(.desktopExternalReloadSkipped(
                        reason: "pid \(binding.processIdentity.pid) lacks complete identity-bound startup evidence"
                    ))
                }
                return supported
            },
            alreadyAcknowledged: { binding in
                startupAcknowledgement(
                    matching: binding,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    now: Date()
                ) != nil
            },
            bindingIsCurrent: { reloadBindingIsCurrent($0) },
            persistRequest: { persistReloadRequest($0) },
            signal: { pid in kill(pid, SIGHUP) == 0 },
            awaitAcknowledgements: waitForHotSwapAcknowledgements,
            gate: reloadAttemptGate
        )
        for pid in execution.reusedAcknowledgedPIDs {
            SwapLog.append(.debug("DESKTOP_RELOAD_REUSED_ACK pid=\(pid)"))
        }
        for pid in execution.newlyAcknowledgedPIDs {
            logger.info("Desktop app-server SIGHUP → pid \(pid) acknowledged")
            SwapLog.append(.sighupSent(pid: pid, startedAt: "desktop-app-server"))
        }
        return desktopReloadSummary(
            from: execution.discoverySnapshot,
            acknowledgedPIDs: execution.acknowledgedPIDs,
            operationFailed: execution.operationFailed
        )
    }

    static func signalDesktopAppServerReloadSummary(
        admittedDiscoverySnapshot discoverySnapshot: CodexRuntimeDiscoverySnapshot,
        admission: CodexReloadAdmission,
        requiredOwnerUID: UInt32,
        authorizeEffect: @Sendable () -> Bool = { true },
        firstAcknowledgementBootstrap: @Sendable (CodexReloadBinding) -> Bool = { _ in false }
    ) -> CodexReloadSummary {
        let targetPIDs = Set(discoverySnapshot.targets.map { $0.process.identity.pid })
        guard admission.admits(targetPIDs, on: reloadAttemptGate) else {
            return desktopReloadSummary(
                from: CodexRuntimeDiscoverySnapshot(targets: [], isComplete: false),
                acknowledgedPIDs: [],
                operationFailed: true
            )
        }

        let hasVerifiedSighupMarker = Self.hasVerifiedSighupMarker()
        if !hasVerifiedSighupMarker {
            SwapLog.append(.desktopExternalReloadSkipped(reason: "sighup-verified not found"))
        }
        let execution = executeReloadBatchUnderAdmission(
            preliminaryPIDs: admission.pids,
            discoveryProvider: { discoverySnapshot },
            requiredOwnerUID: requiredOwnerUID,
            candidateIsEligible: { _ in hasVerifiedSighupMarker },
            makeBinding: { target in makeReloadBinding(for: target) },
            hotSwapSupport: { binding in
                guard authorizeEffect() else { return false }
                let hasStartupAcknowledgement = startupAcknowledgement(
                    matching: binding,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    now: Date()
                ) != nil
                let supported = desktopReloadCapabilityIsAuthorized(
                    binding: binding,
                    hasStartupAcknowledgement: hasStartupAcknowledgement,
                    firstAcknowledgementBootstrapAuthorized: !hasStartupAcknowledgement
                        && firstAcknowledgementBootstrap(binding)
                )
                if !supported {
                    SwapLog.append(.desktopExternalReloadSkipped(
                        reason: "pid \(binding.processIdentity.pid) lacks complete identity-bound startup evidence"
                    ))
                }
                return supported
            },
            alreadyAcknowledged: { binding in
                startupAcknowledgement(
                    matching: binding,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    now: Date()
                ) != nil
            },
            bindingIsCurrent: { reloadBindingIsCurrent($0) },
            persistRequest: { authorizeEffect() && persistReloadRequest($0) },
            signal: { pid in authorizeEffect() && kill(pid, SIGHUP) == 0 },
            awaitAcknowledgements: waitForHotSwapAcknowledgements
        )
        for pid in execution.reusedAcknowledgedPIDs {
            SwapLog.append(.debug("DESKTOP_RELOAD_REUSED_ACK pid=\(pid)"))
        }
        for pid in execution.newlyAcknowledgedPIDs {
            logger.info("Desktop app-server SIGHUP → pid \(pid) acknowledged")
            SwapLog.append(.sighupSent(pid: pid, startedAt: "desktop-app-server"))
        }
        return desktopReloadSummary(
            from: execution.discoverySnapshot,
            acknowledgedPIDs: execution.acknowledgedPIDs,
            operationFailed: execution.operationFailed
        )
    }

    nonisolated static func desktopReloadCapabilityIsAuthorized(
        binding: CodexReloadBinding,
        hasStartupAcknowledgement: Bool,
        firstAcknowledgementBootstrapAuthorized: Bool
    ) -> Bool {
        hasStartupAcknowledgement
            || (
                binding.runtimeKind == .externalAppServer
                    && firstAcknowledgementBootstrapAuthorized
            )
    }

    nonisolated static func desktopReloadSummary(
        from discoverySnapshot: CodexRuntimeDiscoverySnapshot,
        acknowledgedPIDs: Set<Int32>,
        operationFailed: Bool = false
    ) -> CodexReloadSummary {
        reloadSummary(
            from: discoverySnapshot,
            acknowledgedPIDs: acknowledgedPIDs,
            operationFailed: operationFailed
        )
    }

    private nonisolated static func reloadSummary(
        from discoverySnapshot: CodexRuntimeDiscoverySnapshot,
        acknowledgedPIDs: Set<Int32>,
        operationFailed: Bool = false
    ) -> CodexReloadSummary {
        let discoveredPIDs = Set(discoverySnapshot.targets.map { $0.process.identity.pid })
        return CodexReloadSummary(
            discoveredRuntimeCount: discoveredPIDs.count,
            acknowledgedRuntimeCount: discoveredPIDs.intersection(acknowledgedPIDs).count,
            operationFailed: operationFailed || !discoverySnapshot.isComplete
        )
    }

    nonisolated static func runtimeDiscoverySnapshot(
        from discoveryResult: CodexPGrepDiscoveryResult,
        runtimeKind: HotSwapRuntimeKind,
        requiredOwnerUID: UInt32,
        identityProvider: (Int32) -> CodexSignalProcessIdentity?,
        argumentProvider: (Int32) -> [String]?,
        kernelExecutableIdentityProvider: (Int32) -> CodexKernelExecutableIdentity? = {
            kernelExecutableIdentity(pid: $0)
        }
    ) -> CodexRuntimeDiscoverySnapshot {
        switch discoveryResult {
        case .noMatches:
            return CodexRuntimeDiscoverySnapshot(targets: [], isComplete: true)
        case .snapshot(let processSnapshot):
            return runtimeDiscoverySnapshot(
                from: processSnapshot,
                runtimeKind: runtimeKind,
                requiredOwnerUID: requiredOwnerUID,
                identityProvider: identityProvider,
                argumentProvider: argumentProvider,
                kernelExecutableIdentityProvider: kernelExecutableIdentityProvider
            )
        case .failed:
            return CodexRuntimeDiscoverySnapshot(targets: [], isComplete: false)
        }
    }

    nonisolated static func runtimeDiscoverySnapshot(
        from discoveryResult: CodexPGrepDiscoveryResult,
        runtimeKind: HotSwapRuntimeKind,
        requiredOwnerUID: UInt32
    ) -> CodexRuntimeDiscoverySnapshot {
        runtimeDiscoverySnapshot(
            from: discoveryResult,
            runtimeKind: runtimeKind,
            requiredOwnerUID: requiredOwnerUID,
            identityProvider: signalProcessIdentity,
            argumentProvider: processArguments,
            kernelExecutableIdentityProvider: kernelExecutableIdentity
        )
    }

    nonisolated static func runtimeDiscoverySnapshot(
        from processSnapshot: CodexPGrepProcessSnapshot,
        runtimeKind: HotSwapRuntimeKind,
        requiredOwnerUID: UInt32,
        identityProvider: (Int32) -> CodexSignalProcessIdentity?,
        argumentProvider: (Int32) -> [String]?,
        kernelExecutableIdentityProvider: (Int32) -> CodexKernelExecutableIdentity? = {
            kernelExecutableIdentity(pid: $0)
        }
    ) -> CodexRuntimeDiscoverySnapshot {
        var targets: [CodexRuntimeTarget] = []
        var isComplete = processSnapshot.isComplete

        for pid in processSnapshot.pids {
            guard let process = identityBoundProcess(
                pid: pid,
                requiredOwnerUID: requiredOwnerUID,
                identityProvider: identityProvider,
                argumentProvider: argumentProvider,
                kernelExecutableIdentityProvider: kernelExecutableIdentityProvider
            ) else {
                isComplete = false
                continue
            }
            guard processMatchesRuntime(process, runtimeKind: runtimeKind) else {
                continue
            }
            targets.append(CodexRuntimeTarget(process: process, runtimeKind: runtimeKind))
        }

        return CodexRuntimeDiscoverySnapshot(targets: targets, isComplete: isComplete)
    }

    nonisolated static func identityBoundProcess(
        pid: Int32,
        requiredOwnerUID: UInt32,
        identityProvider: (Int32) -> CodexSignalProcessIdentity?,
        argumentProvider: (Int32) -> [String]?,
        kernelExecutableIdentityProvider: (Int32) -> CodexKernelExecutableIdentity? = {
            kernelExecutableIdentity(pid: $0)
        }
    ) -> CodexIdentityBoundProcess? {
        guard let identityBefore = identityProvider(pid),
              identityBefore.ownerUID == requiredOwnerUID,
              let arguments = argumentProvider(pid),
              !arguments.isEmpty,
              signalIdentityMatches(
                  expected: identityBefore,
                  current: identityProvider(pid),
                  requiredOwnerUID: requiredOwnerUID
              ),
              let kernelExecutableIdentity = kernelExecutableIdentityProvider(pid),
              kernelExecutableIdentity.canonicalPath == identityBefore.executablePath,
              kernelExecutableIdentity.device > 0,
              kernelExecutableIdentity.inode > 0,
              signalIdentityMatches(
                  expected: identityBefore,
                  current: identityProvider(pid),
                  requiredOwnerUID: requiredOwnerUID
              ) else {
            return nil
        }
        return CodexIdentityBoundProcess(
            identity: identityBefore,
            kernelExecutableIdentity: kernelExecutableIdentity,
            arguments: arguments
        )
    }

    nonisolated static func processMatchesRuntime(
        _ process: CodexIdentityBoundProcess,
        runtimeKind: HotSwapRuntimeKind
    ) -> Bool {
        let executablePath = process.kernelExecutableIdentity.canonicalPath
        guard executablePath == process.identity.executablePath else { return false }
        let runtimeArguments = process.arguments.dropFirst().map { $0.lowercased() }

        switch runtimeKind {
        case .localInteractiveCLI:
            guard CLIStatusChecker.isCodexCLICommandLine(executablePath) else { return false }
            return !runtimeArguments.contains(where: { argument in
                argument == "app-server"
                    || argument == "exec"
                    || argument == "--ephemeral"
                    || argument == "--remote"
                    || argument.hasPrefix("--remote=")
            })
        case .externalAppServer:
            return runtimeArguments.contains("app-server")
                && DesktopRuntimeDiagnostics.classifyAppServerPath(executablePath) == .desktopAppServer
        case .headlessRemoteControlAppServer:
            return false
        }
    }

    nonisolated static func runtimeTargetIsCurrent(
        _ target: CodexRuntimeTarget,
        requiredOwnerUID: UInt32,
        identityProvider: (Int32) -> CodexSignalProcessIdentity? = {
            signalProcessIdentity(pid: $0)
        },
        argumentProvider: (Int32) -> [String]? = {
            processArguments(pid: $0)
        },
        kernelExecutableIdentityProvider: (Int32) -> CodexKernelExecutableIdentity? = {
            kernelExecutableIdentity(pid: $0)
        }
    ) -> Bool {
        let expectedProcess = target.process
        let expectedIdentity = expectedProcess.identity
        let pid = expectedIdentity.pid
        guard expectedIdentity.ownerUID == requiredOwnerUID,
              signalIdentityMatches(
                  expected: expectedIdentity,
                  current: identityProvider(pid),
                  requiredOwnerUID: requiredOwnerUID
              ),
              let argumentsBefore = argumentProvider(pid),
              argumentsBefore == expectedProcess.arguments,
              signalIdentityMatches(
                  expected: expectedIdentity,
                  current: identityProvider(pid),
                  requiredOwnerUID: requiredOwnerUID
              ),
              let executableBefore = kernelExecutableIdentityProvider(pid),
              executableBefore == expectedProcess.kernelExecutableIdentity,
              let argumentsAfter = argumentProvider(pid),
              argumentsAfter == argumentsBefore,
              kernelExecutableIdentityProvider(pid) == executableBefore,
              signalIdentityMatches(
                  expected: expectedIdentity,
                  current: identityProvider(pid),
                  requiredOwnerUID: requiredOwnerUID
              ) else {
            return false
        }
        return processMatchesRuntime(
            CodexIdentityBoundProcess(
                identity: expectedIdentity,
                kernelExecutableIdentity: executableBefore,
                arguments: argumentsAfter
            ),
            runtimeKind: target.runtimeKind
        )
    }

    private static func hasVerifiedSighupMarker() -> Bool {
        let markerDir = NSString("~/.codexswitch").expandingTildeInPath
        let markerNames = [
            "sighup-verified",
            "sighup-verified-tui",
            "sighup-verified-exec",
        ]
        return markerNames.contains { name in
            FileManager.default.fileExists(
                atPath: (markerDir as NSString).appendingPathComponent(name)
            )
        }
    }

    nonisolated static func preliminaryReloadPIDs(
        from discoveryResult: CodexPGrepDiscoveryResult
    ) -> Set<Int32> {
        guard case .snapshot(let snapshot) = discoveryResult else { return [] }
        return Set(snapshot.pids)
    }

    nonisolated static func executeReloadBatch(
        preliminaryPIDs: Set<Int32>,
        discoveryProvider: () -> CodexRuntimeDiscoverySnapshot,
        requiredOwnerUID: UInt32,
        candidateIsEligible: (CodexRuntimeTarget) -> Bool,
        makeBinding: (CodexRuntimeTarget) -> CodexReloadBinding?,
        hotSwapSupport: (CodexReloadBinding) -> Bool,
        alreadyAcknowledged: (CodexReloadBinding) -> Bool = { _ in false },
        bindingIsCurrent: (CodexReloadBinding) -> Bool,
        persistRequest: (CodexReloadBinding) -> Bool,
        signal: (Int32) -> Bool,
        awaitAcknowledgements: ([CodexReloadBinding]) -> Set<Int32>,
        gate: CodexReloadAttemptGate
    ) -> CodexReloadExecutionResult {
        guard preliminaryPIDs.allSatisfy({ $0 > 0 }) else {
            return CodexReloadExecutionResult(
                discoverySnapshot: CodexRuntimeDiscoverySnapshot(
                    targets: [],
                    isComplete: false
                ),
                newlyAcknowledgedPIDs: [],
                reusedAcknowledgedPIDs: [],
                operationFailed: true
            )
        }

        let admission = gate.acquireAdmission(preliminaryPIDs)
        defer { admission.release() }
        return executeReloadBatchUnderAdmission(
            preliminaryPIDs: preliminaryPIDs,
            discoveryProvider: discoveryProvider,
            requiredOwnerUID: requiredOwnerUID,
            candidateIsEligible: candidateIsEligible,
            makeBinding: makeBinding,
            hotSwapSupport: hotSwapSupport,
            alreadyAcknowledged: alreadyAcknowledged,
            bindingIsCurrent: bindingIsCurrent,
            persistRequest: persistRequest,
            signal: signal,
            awaitAcknowledgements: awaitAcknowledgements
        )
    }

    private nonisolated static func executeReloadBatchUnderAdmission(
        preliminaryPIDs: Set<Int32>,
        discoveryProvider: () -> CodexRuntimeDiscoverySnapshot,
        requiredOwnerUID: UInt32,
        candidateIsEligible: (CodexRuntimeTarget) -> Bool,
        makeBinding: (CodexRuntimeTarget) -> CodexReloadBinding?,
        hotSwapSupport: (CodexReloadBinding) -> Bool,
        alreadyAcknowledged: (CodexReloadBinding) -> Bool = { _ in false },
        bindingIsCurrent: (CodexReloadBinding) -> Bool,
        persistRequest: (CodexReloadBinding) -> Bool,
        signal: (Int32) -> Bool,
        awaitAcknowledgements: ([CodexReloadBinding]) -> Set<Int32>
    ) -> CodexReloadExecutionResult {
        guard preliminaryPIDs.allSatisfy({ $0 > 0 }) else {
            return CodexReloadExecutionResult(
                discoverySnapshot: CodexRuntimeDiscoverySnapshot(
                    targets: [],
                    isComplete: false
                ),
                newlyAcknowledgedPIDs: [],
                reusedAcknowledgedPIDs: [],
                operationFailed: true
            )
        }

        let discoverySnapshot = discoveryProvider()
        let targetPIDs = Set(discoverySnapshot.targets.map { $0.process.identity.pid })
        guard targetPIDs.count == discoverySnapshot.targets.count,
              targetPIDs.isSubset(of: preliminaryPIDs) else {
            return CodexReloadExecutionResult(
                discoverySnapshot: discoverySnapshot,
                newlyAcknowledgedPIDs: [],
                reusedAcknowledgedPIDs: [],
                operationFailed: true
            )
        }

        guard discoverySnapshot.isComplete else {
            return CodexReloadExecutionResult(
                discoverySnapshot: discoverySnapshot,
                newlyAcknowledgedPIDs: [],
                reusedAcknowledgedPIDs: [],
                operationFailed: true
            )
        }
        guard !discoverySnapshot.targets.isEmpty else {
            return CodexReloadExecutionResult(
                discoverySnapshot: discoverySnapshot,
                newlyAcknowledgedPIDs: [],
                reusedAcknowledgedPIDs: [],
                operationFailed: false
            )
        }

        var pendingBindings: [CodexReloadBinding] = []
        var reusedAcknowledgedPIDs: Set<Int32> = []
        var requestNonces: Set<String> = []
        var operationFailed = false

        for target in discoverySnapshot.targets {
            let expectedIdentity = target.process.identity
            guard expectedIdentity.ownerUID == requiredOwnerUID,
                  candidateIsEligible(target),
                  let binding = makeBinding(target),
                  binding.processIdentity == expectedIdentity,
                  binding.kernelExecutableIdentity == target.process.kernelExecutableIdentity,
                  binding.runtimeKind == target.runtimeKind,
                  !binding.requestNonce.isEmpty,
                  requestNonces.insert(binding.requestNonce).inserted,
                  hotSwapSupport(binding),
                  bindingIsCurrent(binding)
            else {
                operationFailed = true
                continue
            }

            if alreadyAcknowledged(binding) {
                reusedAcknowledgedPIDs.insert(expectedIdentity.pid)
                continue
            }

            guard persistRequest(binding) else {
                operationFailed = true
                continue
            }

            guard bindingIsCurrent(binding), signal(expectedIdentity.pid) else {
                operationFailed = true
                continue
            }

            pendingBindings.append(binding)
        }

        let newlyAcknowledgedPIDs = pendingBindings.isEmpty
            ? []
            : awaitAcknowledgements(pendingBindings)
                .intersection(pendingBindings.map { $0.processIdentity.pid })
        if newlyAcknowledgedPIDs.count != pendingBindings.count {
            operationFailed = true
        }
        return CodexReloadExecutionResult(
            discoverySnapshot: discoverySnapshot,
            newlyAcknowledgedPIDs: newlyAcknowledgedPIDs,
            reusedAcknowledgedPIDs: reusedAcknowledgedPIDs,
            operationFailed: operationFailed
        )
    }

    nonisolated static func makeReloadBinding(
        for target: CodexRuntimeTarget,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        requestNonce: String = UUID().uuidString,
        now: Date = Date()
    ) -> CodexReloadBinding? {
        guard target.process.identity.executablePath
                == target.process.kernelExecutableIdentity.canonicalPath,
              target.process.kernelExecutableIdentity.device > 0,
              target.process.kernelExecutableIdentity.inode > 0,
              let authFileIdentity = authFileIdentity(
                at: homeDirectory
                    .appendingPathComponent(".codex", isDirectory: true)
                    .appendingPathComponent("auth.json"),
                requiredOwnerUID: target.process.identity.ownerUID
              ),
              let issuedAt = unixMilliseconds(now),
              !requestNonce.isEmpty,
              requestNonce.utf8.count <= 256 else {
            return nil
        }
        return CodexReloadBinding(
            processIdentity: target.process.identity,
            kernelExecutableIdentity: target.process.kernelExecutableIdentity,
            runtimeKind: target.runtimeKind,
            authFileIdentity: authFileIdentity,
            requestNonce: requestNonce,
            issuedAtUnixMilliseconds: issuedAt
        )
    }

    nonisolated static func persistReloadRequest(
        _ binding: CodexReloadBinding,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bindingIsCurrent: (CodexReloadBinding) -> Bool = {
            reloadBindingIsCurrent($0)
        },
        transactionTestHooks: SecureAtomicFileTransaction.TestHooks = .init()
    ) -> Bool {
        let requestURL = reloadRequestURL(
            homeDirectory: homeDirectory,
            pid: binding.processIdentity.pid
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(CodexReloadRequestArtifact(binding: binding))
            guard data.count <= maximumReloadArtifactBytes else { return false }

            let transaction = SecureAtomicFileTransaction(
                path: requestURL.path,
                subject: "hot-swap request",
                testHooks: transactionTestHooks
            )
            try transaction.withExclusiveLock { file in
                let current = try file.read()
                guard bindingIsCurrent(binding) else {
                    throw CodexReloadRequestPersistenceError.bindingDrift
                }
                let committed = try file.replace(data, expectedGeneration: current.generation)
                guard let committedBytes = committed.bytes,
                      committedBytes == data,
                      try JSONDecoder().decode(
                        CodexReloadRequestArtifact.self,
                        from: committedBytes
                      ).binding == binding else {
                    throw SecureAtomicFileError.readbackMismatch(path: requestURL.path)
                }
            }
            return true
        } catch {
            logger.error(
                "Failed to persist hot-swap request for pid \(binding.processIdentity.pid): \(error.localizedDescription)"
            )
            return false
        }
    }

    private static func waitForHotSwapAcknowledgements(
        _ pendingBindings: [CodexReloadBinding]
    ) -> Set<Int32> {
        acknowledgedPIDsBeforeDeadline(
            pendingBindings: pendingBindings,
            timeoutNanoseconds: 5_000_000_000,
            pollIntervalNanoseconds: 100_000_000,
            monotonicNow: { DispatchTime.now().uptimeNanoseconds },
            sleep: { nanoseconds in
                Thread.sleep(forTimeInterval: Double(nanoseconds) / 1_000_000_000)
            },
            bindingIsCurrent: { binding in
                reloadBindingIsCurrent(binding)
            },
            ackExists: { binding in
                responseAcknowledgement(
                    for: binding,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    now: Date()
                )
                != nil
            }
        )
    }

    nonisolated static func acknowledgedPIDsBeforeDeadline(
        pendingBindings: [CodexReloadBinding],
        timeoutNanoseconds: UInt64,
        pollIntervalNanoseconds: UInt64,
        monotonicNow: () -> UInt64,
        sleep: (UInt64) -> Void,
        bindingIsCurrent: (CodexReloadBinding) -> Bool,
        ackExists: (CodexReloadBinding) -> Bool
    ) -> Set<Int32> {
        let startedAt = monotonicNow()
        let (candidateDeadline, overflow) = startedAt.addingReportingOverflow(timeoutNanoseconds)
        let deadline = overflow ? UInt64.max : candidateDeadline
        var remaining = Dictionary(
            uniqueKeysWithValues: pendingBindings.map { ($0.processIdentity.pid, $0) }
        )
        var acknowledgedPIDs: Set<Int32> = []

        while !remaining.isEmpty {
            for pid in Array(remaining.keys) {
                guard let binding = remaining[pid] else { continue }
                guard monotonicNow() <= deadline else { return acknowledgedPIDs }
                guard bindingIsCurrent(binding) else {
                    remaining.removeValue(forKey: pid)
                    continue
                }
                guard ackExists(binding) else { continue }
                if monotonicNow() <= deadline,
                   bindingIsCurrent(binding) {
                    acknowledgedPIDs.insert(pid)
                }
                remaining.removeValue(forKey: pid)
            }

            guard !remaining.isEmpty else { break }
            let currentTime = monotonicNow()
            guard currentTime < deadline else { break }
            let remainingTime = deadline - currentTime
            sleep(min(max(1, pollIntervalNanoseconds), remainingTime))
        }

        return acknowledgedPIDs
    }

    /// Read-only, identity-bound evidence for local policy decisions.
    nonisolated static func localCLIRuntimeTopology()
        -> CodexLocalCLIRuntimeTopology? {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: localCodexProcessDiscoveryArguments,
            timeout: 3
        )
        let discovery = runtimeDiscoverySnapshot(
            from: pgrepDiscoveryResult(
                stdout: result.stdout,
                terminationStatus: result.terminationStatus,
                timedOut: result.timedOut
            ),
            runtimeKind: .localInteractiveCLI,
            requiredOwnerUID: UInt32(getuid()),
            identityProvider: signalProcessIdentity,
            argumentProvider: processArguments,
            kernelExecutableIdentityProvider: kernelExecutableIdentity
        )
        let managedRuntimePath = CodexVersionChecker.managedRuntimeRoute(
            managedLauncherPath:
                CodexManagedRuntimeTrust.defaultManagedLauncherPath()
        )?.runtimePath
        return localCLIRuntimeTopology(
            discoverySnapshot: discovery,
            managedRuntimePath: managedRuntimePath
        )
    }

    nonisolated static func localCLIRuntimeTopology(
        discoverySnapshot: CodexRuntimeDiscoverySnapshot,
        managedRuntimePath: String?
    ) -> CodexLocalCLIRuntimeTopology? {
        guard discoverySnapshot.isComplete else { return nil }
        let runtimes = discoverySnapshot.targets
            .map {
                CodexLocalCLIRuntimeIdentity(
                    processIdentity: $0.process.identity,
                    kernelExecutableIdentity: $0.process.kernelExecutableIdentity
                )
            }
            .sorted {
                $0.processIdentity.pid < $1.processIdentity.pid
            }
        let allRuntimesUseManagedRoute = managedRuntimePath.map { path in
            runtimes.allSatisfy {
                $0.processIdentity.executablePath == path
                    && $0.kernelExecutableIdentity.canonicalPath == path
            }
        } ?? false
        return CodexLocalCLIRuntimeTopology(
            runtimes: runtimes,
            allRuntimesUseManagedRoute: allRuntimesUseManagedRoute
        )
    }

    nonisolated static func localRuntimeEvidenceSnapshot(
        runtimeKind: HotSwapRuntimeKind,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        requiredOwnerUID: UInt32 = UInt32(getuid())
    ) -> CodexLocalRuntimeEvidenceSnapshot {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: localCodexProcessDiscoveryArguments,
            timeout: 3
        )
        let discovery = runtimeDiscoverySnapshot(
            from: pgrepDiscoveryResult(
                stdout: result.stdout,
                terminationStatus: result.terminationStatus,
                timedOut: result.timedOut
            ),
            runtimeKind: runtimeKind,
            requiredOwnerUID: requiredOwnerUID,
            identityProvider: signalProcessIdentity,
            argumentProvider: processArguments,
            kernelExecutableIdentityProvider: kernelExecutableIdentity
        )

        return localRuntimeEvidenceSnapshot(
            discoverySnapshot: discovery,
            observationProvider: { target in
                runtimeObservation(
                    for: target,
                    homeDirectory: homeDirectory,
                    requiredOwnerUID: requiredOwnerUID
                )
            },
            startupAcknowledgementProvider: { observation in
                let candidateBinding = CodexReloadBinding(
                    processIdentity: observation.target.process.identity,
                    kernelExecutableIdentity: observation.target.process.kernelExecutableIdentity,
                    runtimeKind: observation.target.runtimeKind,
                    authFileIdentity: observation.authFileIdentity,
                    requestNonce: "observation-only",
                    issuedAtUnixMilliseconds: 0
                )
                return startupAcknowledgement(
                    matching: candidateBinding,
                    homeDirectory: homeDirectory,
                    now: Date()
                )
            },
            observationIsCurrent: { observation in
                runtimeObservationIsCurrent(
                    observation,
                    requiredOwnerUID: requiredOwnerUID,
                    identityProvider: signalProcessIdentity,
                    argumentProvider: processArguments,
                    kernelExecutableIdentityProvider: kernelExecutableIdentity,
                    authFileIdentityProvider: { path, ownerUID in
                        authFileIdentity(
                            at: URL(fileURLWithPath: path),
                            requiredOwnerUID: ownerUID
                        )
                    }
                )
            }
        )
    }

    nonisolated static func localRuntimeEvidenceSnapshot(
        discoverySnapshot: CodexRuntimeDiscoverySnapshot,
        observationProvider: (CodexRuntimeTarget) -> CodexRuntimeObservation?,
        startupAcknowledgementProvider: (CodexRuntimeObservation) -> CodexReloadAcknowledgement?,
        observationIsCurrent: (CodexRuntimeObservation) -> Bool
    ) -> CodexLocalRuntimeEvidenceSnapshot {
        guard discoverySnapshot.isComplete else {
            return CodexLocalRuntimeEvidenceSnapshot(runtimes: [], isComplete: false)
        }

        var runtimes: [CodexLocalRuntimeEvidence] = []
        for target in discoverySnapshot.targets {
            guard let observation = observationProvider(target),
                  observation.target == target,
                  observationIsCurrent(observation),
                  let acknowledgement = startupAcknowledgementProvider(observation),
                  bindingMatchesObservation(acknowledgement.binding, observation),
                  bindingIsStructurallyValid(acknowledgement.binding),
                  acknowledgement.loadedTokenFingerprint
                    == observation.authFileIdentity.completeTokenFingerprint,
                  acknowledgement.activeTokenFingerprint
                    == observation.authFileIdentity.completeTokenFingerprint,
                  acknowledgementShapeIsValid(acknowledgement),
                  observationIsCurrent(observation) else {
                return CodexLocalRuntimeEvidenceSnapshot(runtimes: [], isComplete: false)
            }
            runtimes.append(CodexLocalRuntimeEvidence(
                observation: observation,
                startupAcknowledgement: acknowledgement
            ))
        }
        return CodexLocalRuntimeEvidenceSnapshot(runtimes: runtimes, isComplete: true)
    }

    nonisolated static func runtimeDiscoveryIsAlreadyAcknowledged(
        _ discoverySnapshot: CodexRuntimeDiscoverySnapshot,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        requiredOwnerUID: UInt32 = UInt32(getuid()),
        maximumArtifactAgeMilliseconds: Int64 = maximumReloadAcknowledgementAgeMilliseconds
    ) -> Bool {
        guard !discoverySnapshot.targets.isEmpty else { return false }
        let evidence = localRuntimeEvidenceSnapshot(
            discoverySnapshot: discoverySnapshot,
            observationProvider: { target in
                runtimeObservation(
                    for: target,
                    homeDirectory: homeDirectory,
                    requiredOwnerUID: requiredOwnerUID
                )
            },
            startupAcknowledgementProvider: { observation in
                let candidateBinding = CodexReloadBinding(
                    processIdentity: observation.target.process.identity,
                    kernelExecutableIdentity: observation.target.process.kernelExecutableIdentity,
                    runtimeKind: observation.target.runtimeKind,
                    authFileIdentity: observation.authFileIdentity,
                    requestNonce: "observation-only",
                    issuedAtUnixMilliseconds: 0
                )
                return startupAcknowledgement(
                    matching: candidateBinding,
                    homeDirectory: homeDirectory,
                    now: Date(),
                    maximumArtifactAgeMilliseconds: maximumArtifactAgeMilliseconds
                )
            },
            observationIsCurrent: { observation in
                runtimeObservationIsCurrent(
                    observation,
                    requiredOwnerUID: requiredOwnerUID,
                    identityProvider: signalProcessIdentity,
                    argumentProvider: processArguments,
                    kernelExecutableIdentityProvider: kernelExecutableIdentity,
                    authFileIdentityProvider: { path, ownerUID in
                        authFileIdentity(
                            at: URL(fileURLWithPath: path),
                            requiredOwnerUID: ownerUID
                        )
                    }
                )
            }
        )
        return evidence.isComplete
            && evidence.runtimes.count == discoverySnapshot.targets.count
    }

    nonisolated static func alreadyAcknowledgedRuntimePIDs(
        _ discoverySnapshot: CodexRuntimeDiscoverySnapshot,
        expectedAccountID: String,
        expectedCompleteTokenFingerprint: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        requiredOwnerUID: UInt32 = UInt32(getuid()),
        maximumArtifactAgeMilliseconds: Int64 = maximumReloadAcknowledgementAgeMilliseconds
    ) -> Set<Int32> {
        alreadyAcknowledgedRuntimePIDs(
            discoverySnapshot,
            expectedAccountID: expectedAccountID,
            expectedCompleteTokenFingerprint: expectedCompleteTokenFingerprint,
            observationProvider: { target in
                runtimeObservation(
                    for: target,
                    homeDirectory: homeDirectory,
                    requiredOwnerUID: requiredOwnerUID
                )
            },
            startupAcknowledgementProvider: { observation in
                let candidateBinding = CodexReloadBinding(
                    processIdentity: observation.target.process.identity,
                    kernelExecutableIdentity: observation.target.process.kernelExecutableIdentity,
                    runtimeKind: observation.target.runtimeKind,
                    authFileIdentity: observation.authFileIdentity,
                    requestNonce: "observation-only",
                    issuedAtUnixMilliseconds: 0
                )
                return startupAcknowledgement(
                    matching: candidateBinding,
                    homeDirectory: homeDirectory,
                    now: Date(),
                    maximumArtifactAgeMilliseconds: maximumArtifactAgeMilliseconds
                )
            },
            observationIsCurrent: { observation in
                runtimeObservationIsCurrent(
                    observation,
                    requiredOwnerUID: requiredOwnerUID,
                    identityProvider: signalProcessIdentity,
                    argumentProvider: processArguments,
                    kernelExecutableIdentityProvider: kernelExecutableIdentity,
                    authFileIdentityProvider: { path, ownerUID in
                        authFileIdentity(
                            at: URL(fileURLWithPath: path),
                            requiredOwnerUID: ownerUID
                        )
                    }
                )
            }
        )
    }

    nonisolated static func alreadyAcknowledgedRuntimePIDs(
        _ discoverySnapshot: CodexRuntimeDiscoverySnapshot,
        expectedAccountID: String,
        expectedCompleteTokenFingerprint: String,
        observationProvider: (CodexRuntimeTarget) -> CodexRuntimeObservation?,
        startupAcknowledgementProvider: (CodexRuntimeObservation) -> CodexReloadAcknowledgement?,
        observationIsCurrent: (CodexRuntimeObservation) -> Bool
    ) -> Set<Int32> {
        guard discoverySnapshot.isComplete,
              accountIDBytesIfCanonical(expectedAccountID) != nil,
              isSHA256Hex(expectedCompleteTokenFingerprint) else {
            return []
        }

        var acknowledgedPIDs: Set<Int32> = []
        for target in discoverySnapshot.targets {
            guard let observation = observationProvider(target),
                  observation.target == target,
                  observation.authFileIdentity.accountID == expectedAccountID,
                  observation.authFileIdentity.completeTokenFingerprint
                    == expectedCompleteTokenFingerprint,
                  observationIsCurrent(observation),
                  let acknowledgement = startupAcknowledgementProvider(observation),
                  acknowledgementSupportsPassiveRuntimeEvidence(
                      acknowledgement,
                      observation: observation
                  ),
                  observationIsCurrent(observation) else {
                continue
            }
            acknowledgedPIDs.insert(target.process.identity.pid)
        }
        return acknowledgedPIDs
    }

    nonisolated static func runtimeObservation(
        for target: CodexRuntimeTarget,
        homeDirectory: URL,
        requiredOwnerUID: UInt32
    ) -> CodexRuntimeObservation? {
        guard target.process.identity.ownerUID == requiredOwnerUID,
              target.process.identity.executablePath
                == target.process.kernelExecutableIdentity.canonicalPath,
              target.process.kernelExecutableIdentity.device > 0,
              target.process.kernelExecutableIdentity.inode > 0,
              let authFileIdentity = authFileIdentity(
                at: homeDirectory
                    .appendingPathComponent(".codex", isDirectory: true)
                    .appendingPathComponent("auth.json"),
                requiredOwnerUID: requiredOwnerUID
              ) else {
            return nil
        }
        return CodexRuntimeObservation(
            target: target,
            authFileIdentity: authFileIdentity
        )
    }

    nonisolated static func runtimeObservationIsCurrent(
        _ observation: CodexRuntimeObservation,
        requiredOwnerUID: UInt32,
        identityProvider: (Int32) -> CodexSignalProcessIdentity?,
        argumentProvider: (Int32) -> [String]?,
        kernelExecutableIdentityProvider: (Int32) -> CodexKernelExecutableIdentity?,
        authFileIdentityProvider: (String, UInt32) -> CodexAuthFileIdentity?
    ) -> Bool {
        runtimeBindingStateIsCurrent(
            processIdentity: observation.target.process.identity,
            kernelExecutableIdentity: observation.target.process.kernelExecutableIdentity,
            runtimeKind: observation.target.runtimeKind,
            authFileIdentity: observation.authFileIdentity,
            requiredOwnerUID: requiredOwnerUID,
            identityProvider: identityProvider,
            argumentProvider: argumentProvider,
            kernelExecutableIdentityProvider: kernelExecutableIdentityProvider,
            authFileIdentityProvider: authFileIdentityProvider
        )
    }

    nonisolated static func reloadBindingIsCurrent(
        _ binding: CodexReloadBinding,
        identityProvider: (Int32) -> CodexSignalProcessIdentity? = {
            signalProcessIdentity(pid: $0)
        },
        argumentProvider: (Int32) -> [String]? = {
            processArguments(pid: $0)
        },
        kernelExecutableIdentityProvider: (Int32) -> CodexKernelExecutableIdentity? = {
            kernelExecutableIdentity(pid: $0)
        },
        authFileIdentityProvider: (String, UInt32) -> CodexAuthFileIdentity? = { path, ownerUID in
            authFileIdentity(at: URL(fileURLWithPath: path), requiredOwnerUID: ownerUID)
        }
    ) -> Bool {
        let ownerUID = binding.processIdentity.ownerUID
        return runtimeBindingStateIsCurrent(
            processIdentity: binding.processIdentity,
            kernelExecutableIdentity: binding.kernelExecutableIdentity,
            runtimeKind: binding.runtimeKind,
            authFileIdentity: binding.authFileIdentity,
            requiredOwnerUID: ownerUID,
            identityProvider: identityProvider,
            argumentProvider: argumentProvider,
            kernelExecutableIdentityProvider: kernelExecutableIdentityProvider,
            authFileIdentityProvider: authFileIdentityProvider
        )
    }

    nonisolated static func runtimeBindingStateIsCurrent(
        processIdentity: CodexSignalProcessIdentity,
        kernelExecutableIdentity: CodexKernelExecutableIdentity,
        runtimeKind: HotSwapRuntimeKind,
        authFileIdentity: CodexAuthFileIdentity,
        requiredOwnerUID: UInt32,
        identityProvider: (Int32) -> CodexSignalProcessIdentity?,
        argumentProvider: (Int32) -> [String]?,
        kernelExecutableIdentityProvider: (Int32) -> CodexKernelExecutableIdentity?,
        authFileIdentityProvider: (String, UInt32) -> CodexAuthFileIdentity?
    ) -> Bool {
        let pid = processIdentity.pid
        guard processIdentity.ownerUID == requiredOwnerUID,
              authFileIdentityIsStructurallyValid(authFileIdentity),
              signalIdentityMatches(
                  expected: processIdentity,
                  current: identityProvider(pid),
                  requiredOwnerUID: requiredOwnerUID
              ),
              let argumentsBefore = argumentProvider(pid),
              !argumentsBefore.isEmpty,
              signalIdentityMatches(
                  expected: processIdentity,
                  current: identityProvider(pid),
                  requiredOwnerUID: requiredOwnerUID
              ),
              let executableIdentityBefore = kernelExecutableIdentityProvider(pid),
              executableIdentityBefore == kernelExecutableIdentity,
              kernelExecutableIdentity.canonicalPath == processIdentity.executablePath,
              kernelExecutableIdentity.device > 0,
              kernelExecutableIdentity.inode > 0,
              let authFileIdentityBefore = authFileIdentityProvider(
                  authFileIdentity.canonicalPath,
                  requiredOwnerUID
              ),
              authFileIdentityBefore == authFileIdentity,
              let argumentsAfter = argumentProvider(pid),
              argumentsAfter == argumentsBefore,
              kernelExecutableIdentityProvider(pid) == executableIdentityBefore,
              authFileIdentityProvider(
                  authFileIdentity.canonicalPath,
                  requiredOwnerUID
              ) == authFileIdentityBefore,
              signalIdentityMatches(
                  expected: processIdentity,
                  current: identityProvider(pid),
                  requiredOwnerUID: requiredOwnerUID
              ) else {
            return false
        }

        return processMatchesRuntime(
            CodexIdentityBoundProcess(
                identity: processIdentity,
                kernelExecutableIdentity: kernelExecutableIdentity,
                arguments: argumentsAfter
            ),
            runtimeKind: runtimeKind
        )
    }

    nonisolated static func startupAcknowledgement(
        matching currentBinding: CodexReloadBinding,
        homeDirectory: URL,
        now: Date,
        maximumArtifactAgeMilliseconds: Int64 = maximumReloadAcknowledgementAgeMilliseconds
    ) -> CodexReloadAcknowledgement? {
        guard reloadBindingIsCurrent(currentBinding),
              let request = secureFileSnapshot(
                at: reloadRequestURL(
                    homeDirectory: homeDirectory,
                    pid: currentBinding.processIdentity.pid
                ).path,
                maximumBytes: maximumReloadArtifactBytes,
                requiredOwnerUID: currentBinding.processIdentity.ownerUID
              ),
              let acknowledgement = secureFileSnapshot(
                at: reloadAcknowledgementURL(
                    homeDirectory: homeDirectory,
                    pid: currentBinding.processIdentity.pid
                ).path,
                maximumBytes: maximumReloadArtifactBytes,
                requiredOwnerUID: currentBinding.processIdentity.ownerUID
              ),
              let nowMilliseconds = unixMilliseconds(now),
              let validated = validatedReloadAcknowledgement(
                request: request,
                acknowledgement: acknowledgement,
                currentBinding: currentBinding,
                expectedBinding: nil,
                nowUnixMilliseconds: nowMilliseconds,
                maximumArtifactAgeMilliseconds: maximumArtifactAgeMilliseconds
              ),
              reloadBindingIsCurrent(currentBinding) else {
            return nil
        }
        return validated
    }

    nonisolated static func priorRuntimeCapabilityAcknowledgement(
        matching currentBinding: CodexReloadBinding,
        homeDirectory: URL,
        now: Date,
        maximumArtifactAgeMilliseconds: Int64 = maximumReloadCapabilityAgeMilliseconds,
        bindingIsCurrent: (CodexReloadBinding) -> Bool = {
            reloadBindingIsCurrent($0)
        }
    ) -> CodexReloadAcknowledgement? {
        guard bindingIsCurrent(currentBinding),
              let request = secureFileSnapshot(
                at: reloadRequestURL(
                    homeDirectory: homeDirectory,
                    pid: currentBinding.processIdentity.pid
                ).path,
                maximumBytes: maximumReloadArtifactBytes,
                requiredOwnerUID: currentBinding.processIdentity.ownerUID
              ),
              let acknowledgement = secureFileSnapshot(
                at: reloadAcknowledgementURL(
                    homeDirectory: homeDirectory,
                    pid: currentBinding.processIdentity.pid
                ).path,
                maximumBytes: maximumReloadArtifactBytes,
                requiredOwnerUID: currentBinding.processIdentity.ownerUID
              ),
              let nowMilliseconds = unixMilliseconds(now),
              let validated = validatedReloadAcknowledgement(
                request: request,
                acknowledgement: acknowledgement,
                currentBinding: currentBinding,
                expectedBinding: nil,
                nowUnixMilliseconds: nowMilliseconds,
                maximumArtifactAgeMilliseconds: maximumArtifactAgeMilliseconds,
                requireCurrentAuthFileIdentity: false
              ),
              bindingIsCurrent(currentBinding) else {
            return nil
        }
        return validated
    }

    nonisolated static func ensurePriorRuntimeCapabilityReceipt(
        matching currentBinding: CodexReloadBinding,
        homeDirectory: URL,
        now: Date,
        maximumArtifactAgeMilliseconds: Int64 = maximumReloadCapabilityAgeMilliseconds,
        bindingIsCurrent: (CodexReloadBinding) -> Bool = {
            reloadBindingIsCurrent($0)
        }
    ) -> Bool {
        let receiptAcknowledgement = runtimeCapabilityReceiptAcknowledgement(
            matching: currentBinding,
            homeDirectory: homeDirectory,
            now: now,
            maximumArtifactAgeMilliseconds: maximumArtifactAgeMilliseconds,
            bindingIsCurrent: bindingIsCurrent
        )
        let currentAcknowledgement = priorRuntimeCapabilityAcknowledgement(
            matching: currentBinding,
            homeDirectory: homeDirectory,
            now: now,
            maximumArtifactAgeMilliseconds: maximumArtifactAgeMilliseconds,
            bindingIsCurrent: bindingIsCurrent
        )

        guard let currentAcknowledgement else {
            return receiptAcknowledgement != nil
        }
        if let receiptAcknowledgement,
           !reloadAcknowledgement(
               currentAcknowledgement,
               isNewerThan: receiptAcknowledgement
           ) {
            return true
        }
        return persistRuntimeCapabilityReceipt(
            currentAcknowledgement,
            currentBinding: currentBinding,
            homeDirectory: homeDirectory,
            now: now,
            bindingIsCurrent: bindingIsCurrent
        )
    }

    nonisolated private static func reloadAcknowledgement(
        _ candidate: CodexReloadAcknowledgement,
        isNewerThan existing: CodexReloadAcknowledgement
    ) -> Bool {
        if candidate.acknowledgedAtUnixMilliseconds
            != existing.acknowledgedAtUnixMilliseconds {
            return candidate.acknowledgedAtUnixMilliseconds
                > existing.acknowledgedAtUnixMilliseconds
        }
        return candidate.binding.issuedAtUnixMilliseconds
            > existing.binding.issuedAtUnixMilliseconds
    }

    nonisolated static func runtimeCapabilityReceiptAcknowledgement(
        matching currentBinding: CodexReloadBinding,
        homeDirectory: URL,
        now: Date,
        maximumArtifactAgeMilliseconds: Int64 = maximumReloadCapabilityAgeMilliseconds,
        maximumFutureSkewMilliseconds: Int64 = 30_000,
        bindingIsCurrent: (CodexReloadBinding) -> Bool = {
            reloadBindingIsCurrent($0)
        }
    ) -> CodexReloadAcknowledgement? {
        guard maximumArtifactAgeMilliseconds >= 0,
              maximumFutureSkewMilliseconds >= 0,
              bindingIsCurrent(currentBinding),
              let snapshot = secureFileSnapshot(
                at: reloadCapabilityReceiptURL(
                    homeDirectory: homeDirectory,
                    pid: currentBinding.processIdentity.pid
                ).path,
                maximumBytes: maximumReloadArtifactBytes,
                requiredOwnerUID: currentBinding.processIdentity.ownerUID
              ),
              let receipt = try? JSONDecoder().decode(
                CodexReloadCapabilityReceipt.self,
                from: snapshot.data
              ),
              bindingHasSameRuntimeCapability(
                receipt.acknowledgement.binding,
                currentBinding
              ),
              bindingIsStructurallyValid(receipt.acknowledgement.binding),
              receipt.acknowledgement.loadedTokenFingerprint
                == receipt.acknowledgement.binding.authFileIdentity.completeTokenFingerprint,
              receipt.acknowledgement.activeTokenFingerprint
                == receipt.acknowledgement.loadedTokenFingerprint,
              acknowledgementShapeIsValid(receipt.acknowledgement),
              let nowMilliseconds = unixMilliseconds(now),
              let processStartedAt = processStartUnixMilliseconds(
                receipt.acknowledgement.binding.processIdentity
              ) else {
            return nil
        }

        let issuedAt = receipt.acknowledgement.binding.issuedAtUnixMilliseconds
        let acknowledgedAt = receipt.acknowledgement.acknowledgedAtUnixMilliseconds
        let recordedAt = receipt.recordedAtUnixMilliseconds
        let oldestAccepted = subtractingWithoutOverflow(
            nowMilliseconds,
            maximumArtifactAgeMilliseconds
        )
        let newestAccepted = addingWithoutOverflow(
            nowMilliseconds,
            maximumFutureSkewMilliseconds
        )
        let processStartLowerBound = subtractingWithoutOverflow(
            processStartedAt,
            maximumFutureSkewMilliseconds
        )
        let issueLowerBound = subtractingWithoutOverflow(
            issuedAt,
            maximumFutureSkewMilliseconds
        )
        let recordedLowerBound = subtractingWithoutOverflow(
            recordedAt,
            maximumFutureSkewMilliseconds
        )
        guard issuedAt >= processStartLowerBound,
              acknowledgedAt >= issuedAt,
              recordedAt >= acknowledgedAt,
              snapshot.modifiedAtUnixMilliseconds >= issueLowerBound,
              snapshot.modifiedAtUnixMilliseconds >= recordedLowerBound,
              [
                issuedAt,
                acknowledgedAt,
                recordedAt,
                snapshot.modifiedAtUnixMilliseconds,
              ].allSatisfy({ $0 >= oldestAccepted && $0 <= newestAccepted }),
              bindingIsCurrent(currentBinding) else {
            return nil
        }
        return receipt.acknowledgement
    }

    nonisolated static func persistRuntimeCapabilityReceipt(
        _ acknowledgement: CodexReloadAcknowledgement,
        currentBinding: CodexReloadBinding,
        homeDirectory: URL,
        now: Date,
        bindingIsCurrent: (CodexReloadBinding) -> Bool = {
            reloadBindingIsCurrent($0)
        }
    ) -> Bool {
        guard bindingHasSameRuntimeCapability(
            acknowledgement.binding,
            currentBinding
        ), acknowledgementShapeIsValid(acknowledgement),
        acknowledgement.loadedTokenFingerprint
            == acknowledgement.binding.authFileIdentity.completeTokenFingerprint,
        acknowledgement.activeTokenFingerprint == acknowledgement.loadedTokenFingerprint,
        let recordedAt = unixMilliseconds(now),
        recordedAt >= acknowledgement.acknowledgedAtUnixMilliseconds else {
            return false
        }

        let receipt = CodexReloadCapabilityReceipt(
            acknowledgement: acknowledgement,
            recordedAtUnixMilliseconds: recordedAt
        )
        let receiptURL = reloadCapabilityReceiptURL(
            homeDirectory: homeDirectory,
            pid: currentBinding.processIdentity.pid
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(receipt)
            guard data.count <= maximumReloadArtifactBytes else { return false }
            let transaction = SecureAtomicFileTransaction(
                path: receiptURL.path,
                subject: "hot-swap capability receipt"
            )
            try transaction.withExclusiveLock { file in
                let current = try file.read()
                guard bindingIsCurrent(currentBinding) else {
                    throw CodexReloadRequestPersistenceError.bindingDrift
                }
                let committed = try file.replace(
                    data,
                    expectedGeneration: current.generation
                )
                guard committed.bytes == data,
                      try JSONDecoder().decode(
                        CodexReloadCapabilityReceipt.self,
                        from: committed.bytes ?? Data()
                      ) == receipt else {
                    throw SecureAtomicFileError.readbackMismatch(path: receiptURL.path)
                }
            }
            return bindingIsCurrent(currentBinding)
        } catch {
            logger.error(
                "Failed to persist hot-swap capability receipt for pid \(currentBinding.processIdentity.pid): \(error.localizedDescription)"
            )
            return false
        }
    }

    nonisolated static func responseAcknowledgement(
        for binding: CodexReloadBinding,
        homeDirectory: URL,
        now: Date
    ) -> CodexReloadAcknowledgement? {
        guard reloadBindingIsCurrent(binding),
              let request = secureFileSnapshot(
                at: reloadRequestURL(
                    homeDirectory: homeDirectory,
                    pid: binding.processIdentity.pid
                ).path,
                maximumBytes: maximumReloadArtifactBytes,
                requiredOwnerUID: binding.processIdentity.ownerUID
              ),
              let acknowledgement = secureFileSnapshot(
                at: reloadAcknowledgementURL(
                    homeDirectory: homeDirectory,
                    pid: binding.processIdentity.pid
                ).path,
                maximumBytes: maximumReloadArtifactBytes,
                requiredOwnerUID: binding.processIdentity.ownerUID
              ),
              let nowMilliseconds = unixMilliseconds(now),
              let validated = validatedReloadAcknowledgement(
                request: request,
                acknowledgement: acknowledgement,
                currentBinding: binding,
                expectedBinding: binding,
                nowUnixMilliseconds: nowMilliseconds
              ),
              reloadBindingIsCurrent(binding) else {
            return nil
        }
        return validated
    }

    nonisolated static func validatedReloadAcknowledgement(
        request: CodexSecureFileSnapshot,
        acknowledgement: CodexSecureFileSnapshot,
        currentBinding: CodexReloadBinding,
        expectedBinding: CodexReloadBinding?,
        nowUnixMilliseconds: Int64,
        maximumArtifactAgeMilliseconds: Int64 = maximumReloadAcknowledgementAgeMilliseconds,
        maximumFutureSkewMilliseconds: Int64 = 30_000,
        requireCurrentAuthFileIdentity: Bool = true
    ) -> CodexReloadAcknowledgement? {
        guard maximumArtifactAgeMilliseconds >= 0,
              maximumFutureSkewMilliseconds >= 0,
              let requestArtifact = try? JSONDecoder().decode(
                CodexReloadRequestArtifact.self,
                from: request.data
              ),
              let ack = try? JSONDecoder().decode(
                CodexReloadAcknowledgement.self,
                from: acknowledgement.data
              ),
              requestArtifact.binding == ack.binding,
              expectedBinding.map({ requestArtifact.binding == $0 }) ?? true,
              (
                requireCurrentAuthFileIdentity
                    ? bindingHasSameRuntimeAuthority(requestArtifact.binding, currentBinding)
                    : bindingHasSameRuntimeCapability(
                        requestArtifact.binding,
                        currentBinding
                    )
              ),
              bindingIsStructurallyValid(requestArtifact.binding),
              ack.loadedTokenFingerprint
                == requestArtifact.binding.authFileIdentity.completeTokenFingerprint,
              ack.activeTokenFingerprint == ack.loadedTokenFingerprint,
              acknowledgementShapeIsValid(ack),
              let processStartedAt = processStartUnixMilliseconds(
                requestArtifact.binding.processIdentity
              ) else {
            return nil
        }

        let issuedAt = requestArtifact.binding.issuedAtUnixMilliseconds
        let acknowledgedAt = ack.acknowledgedAtUnixMilliseconds
        let oldestAccepted = subtractingWithoutOverflow(
            nowUnixMilliseconds,
            maximumArtifactAgeMilliseconds
        )
        let newestAccepted = addingWithoutOverflow(
            nowUnixMilliseconds,
            maximumFutureSkewMilliseconds
        )
        let processStartLowerBound = subtractingWithoutOverflow(
            processStartedAt,
            maximumFutureSkewMilliseconds
        )
        let issueLowerBound = subtractingWithoutOverflow(
            issuedAt,
            maximumFutureSkewMilliseconds
        )
        let acknowledgementLowerBound = subtractingWithoutOverflow(
            acknowledgedAt,
            maximumFutureSkewMilliseconds
        )
        let requestMTimeLowerBound = subtractingWithoutOverflow(
            request.modifiedAtUnixMilliseconds,
            maximumFutureSkewMilliseconds
        )

        guard issuedAt >= processStartLowerBound,
              acknowledgedAt >= issuedAt,
              request.modifiedAtUnixMilliseconds >= issueLowerBound,
              acknowledgement.modifiedAtUnixMilliseconds >= acknowledgementLowerBound,
              acknowledgement.modifiedAtUnixMilliseconds >= requestMTimeLowerBound,
              [
                issuedAt,
                acknowledgedAt,
                request.modifiedAtUnixMilliseconds,
                acknowledgement.modifiedAtUnixMilliseconds,
              ].allSatisfy({ $0 >= oldestAccepted && $0 <= newestAccepted }) else {
            return nil
        }
        return ack
    }

    nonisolated static func bindingHasSameRuntimeAuthority(
        _ lhs: CodexReloadBinding,
        _ rhs: CodexReloadBinding
    ) -> Bool {
        bindingHasSameRuntimeCapability(lhs, rhs)
            && lhs.authFileIdentity == rhs.authFileIdentity
    }

    nonisolated static func bindingHasSameRuntimeCapability(
        _ lhs: CodexReloadBinding,
        _ rhs: CodexReloadBinding
    ) -> Bool {
        lhs.contractVersion == rhs.contractVersion
            && lhs.processIdentity == rhs.processIdentity
            && lhs.kernelExecutableIdentity == rhs.kernelExecutableIdentity
            && lhs.runtimeKind == rhs.runtimeKind
            && lhs.authFileIdentity.canonicalPath == rhs.authFileIdentity.canonicalPath
            && lhs.authFileIdentity.device == rhs.authFileIdentity.device
    }

    nonisolated static func bindingMatchesObservation(
        _ binding: CodexReloadBinding,
        _ observation: CodexRuntimeObservation
    ) -> Bool {
        bindingIsStructurallyValid(binding)
            && binding.processIdentity == observation.target.process.identity
            && binding.kernelExecutableIdentity
                == observation.target.process.kernelExecutableIdentity
            && binding.runtimeKind == observation.target.runtimeKind
            && binding.authFileIdentity == observation.authFileIdentity
    }

    nonisolated static func acknowledgementSupportsPassiveRuntimeEvidence(
        _ acknowledgement: CodexReloadAcknowledgement,
        observation: CodexRuntimeObservation
    ) -> Bool {
        bindingMatchesObservation(acknowledgement.binding, observation)
            && acknowledgement.loadedTokenFingerprint
                == observation.authFileIdentity.completeTokenFingerprint
            && acknowledgement.activeTokenFingerprint
                == observation.authFileIdentity.completeTokenFingerprint
            && acknowledgementShapeIsValid(acknowledgement)
    }

    private nonisolated static func acknowledgementShapeIsValid(
        _ acknowledgement: CodexReloadAcknowledgement
    ) -> Bool {
        switch acknowledgement.binding.runtimeKind {
        case .externalAppServer:
            return externalAppServerAcknowledgementIsValid(
                acknowledgement,
                allowIdleListener: false
            )
        case .headlessRemoteControlAppServer:
            return externalAppServerAcknowledgementIsValid(
                acknowledgement,
                allowIdleListener: true
            )
        case .localInteractiveCLI:
            return !acknowledgement.frontendNotified
                && acknowledgement.frontendWriteCount == 0
                && acknowledgement.authGeneration != nil
                && acknowledgement.reconnectReady == true
                && acknowledgement.initializedFrontendCount == nil
                && acknowledgement.eligibleFrontendCount == nil
                && acknowledgement.rejectedFrontendCount == nil
                && acknowledgement.idleListenerReady != true
        }
    }

    private nonisolated static func externalAppServerAcknowledgementIsValid(
        _ acknowledgement: CodexReloadAcknowledgement,
        allowIdleListener: Bool
    ) -> Bool {
        guard let initialized = acknowledgement.initializedFrontendCount,
              let eligible = acknowledgement.eligibleFrontendCount,
              let rejected = acknowledgement.rejectedFrontendCount,
              initialized >= 0,
              eligible >= 0,
              rejected >= 0,
              eligible <= Int.max - rejected,
              eligible + rejected == initialized else {
            return false
        }
        let deliveredToFrontend = acknowledgement.idleListenerReady != true
            && acknowledgement.frontendNotified
            && eligible > 0
            && acknowledgement.frontendWriteCount == eligible
        let idleListener = allowIdleListener
            && acknowledgement.idleListenerReady == true
            && !acknowledgement.frontendNotified
            && acknowledgement.frontendWriteCount == 0
            && eligible == 0
        return acknowledgement.reconnectReady != true
            && (deliveredToFrontend || idleListener)
    }

    private nonisolated static func bindingIsStructurallyValid(
        _ binding: CodexReloadBinding
    ) -> Bool {
        binding.contractVersion == CodexReloadBinding.currentContractVersion
            && binding.processIdentity.pid > 0
            && binding.processIdentity.executablePath.hasPrefix("/")
            && canonicalAbsolutePath(binding.kernelExecutableIdentity.canonicalPath)
                == binding.kernelExecutableIdentity.canonicalPath
            && binding.kernelExecutableIdentity.canonicalPath
                == binding.processIdentity.executablePath
            && binding.kernelExecutableIdentity.device > 0
            && binding.kernelExecutableIdentity.inode > 0
            && authFileIdentityIsStructurallyValid(binding.authFileIdentity)
            && !binding.requestNonce.isEmpty
            && binding.requestNonce.utf8.count <= 256
    }

    private nonisolated static func authFileIdentityIsStructurallyValid(
        _ identity: CodexAuthFileIdentity
    ) -> Bool {
        canonicalAbsolutePath(identity.canonicalPath) == identity.canonicalPath
            && identity.device > 0
            && identity.inode > 0
            && accountIDBytesIfCanonical(identity.accountID) != nil
            && isSHA256Hex(identity.completeTokenFingerprint)
    }

    nonisolated static func accountIDBytesIfCanonical(
        _ accountID: String?
    ) -> Data? {
        guard let accountID else { return nil }
        let bytes = Data(accountID.utf8)
        guard !bytes.isEmpty,
              bytes.count <= 1_024,
              bytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
            return nil
        }
        return bytes
    }

    private nonisolated static func reloadRequestURL(
        homeDirectory: URL,
        pid: Int32
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".codexswitch", isDirectory: true)
            .appendingPathComponent("hotswap-request", isDirectory: true)
            .appendingPathComponent("\(pid).json")
    }

    private nonisolated static func reloadAcknowledgementURL(
        homeDirectory: URL,
        pid: Int32
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".codexswitch", isDirectory: true)
            .appendingPathComponent("hotswap-ack", isDirectory: true)
            .appendingPathComponent("\(pid).json")
    }

    private nonisolated static func reloadCapabilityReceiptURL(
        homeDirectory: URL,
        pid: Int32
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".codexswitch", isDirectory: true)
            .appendingPathComponent("hotswap-capability", isDirectory: true)
            .appendingPathComponent("\(pid).json")
    }

    nonisolated static func authFileIdentity(
        at url: URL,
        requiredOwnerUID: UInt32
    ) -> CodexAuthFileIdentity? {
        guard let snapshot = secureFileSnapshot(
            at: url.path,
            maximumBytes: maximumAuthFileBytes,
            requiredOwnerUID: requiredOwnerUID
        ),
        let authFile = try? JSONDecoder().decode(AuthFile.self, from: snapshot.data) else {
            return nil
        }

        let tokenValues = [
            authFile.tokens.idToken,
            authFile.tokens.accessToken,
            authFile.tokens.refreshToken,
        ]
        guard tokenValues.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), accountIDBytesIfCanonical(authFile.tokens.accountId) != nil else {
            return nil
        }

        guard let fingerprint = completeTokenFingerprint(
            idToken: authFile.tokens.idToken,
            accessToken: authFile.tokens.accessToken,
            refreshToken: authFile.tokens.refreshToken,
            accountID: authFile.tokens.accountId
        ) else {
            return nil
        }
        return CodexAuthFileIdentity(
            canonicalPath: snapshot.canonicalPath,
            device: snapshot.device,
            inode: snapshot.inode,
            accountID: authFile.tokens.accountId,
            completeTokenFingerprint: fingerprint
        )
    }

    nonisolated static func completeTokenFingerprint(
        for account: CodexAccount
    ) -> String? {
        completeTokenFingerprint(
            idToken: account.idToken,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            accountID: account.accountId
        )
    }

    nonisolated static func completeTokenFingerprint(
        idToken: String,
        accessToken: String,
        refreshToken: String,
        accountID: String
    ) -> String? {
        let tokenValues = [idToken, accessToken, refreshToken]
        guard tokenValues.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), accountIDBytesIfCanonical(accountID) != nil else {
            return nil
        }

        var fingerprintInput = Data()
        for value in tokenValues + [accountID] {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { fingerprintInput.append(contentsOf: $0) }
            fingerprintInput.append(bytes)
        }
        return SHA256.hash(data: fingerprintInput)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func secureFileSnapshot(
        at path: String,
        maximumBytes: Int,
        requiredOwnerUID: UInt32
    ) -> CodexSecureFileSnapshot? {
        guard maximumBytes > 0,
              let canonicalPath = canonicalAbsolutePath(path) else {
            return nil
        }
        let components = canonicalPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let fileName = components.last, components.count > 1 else { return nil }

        var directoryDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else { return nil }
        defer { Darwin.close(directoryDescriptor) }

        var rootMetadata = stat()
        guard fstat(directoryDescriptor, &rootMetadata) == 0,
              secureDirectoryMetadataIsValid(
                rootMetadata,
                requiredOwnerUID: requiredOwnerUID
              ) else {
            return nil
        }

        for component in components.dropLast() {
            let nextDescriptor = Darwin.openat(
                directoryDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard nextDescriptor >= 0 else { return nil }

            var metadata = stat()
            guard fstat(nextDescriptor, &metadata) == 0,
                  secureDirectoryMetadataIsValid(
                    metadata,
                    requiredOwnerUID: requiredOwnerUID
                  ) else {
                Darwin.close(nextDescriptor)
                return nil
            }
            Darwin.close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        let fileDescriptor = Darwin.openat(
            directoryDescriptor,
            fileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard fileDescriptor >= 0 else { return nil }
        defer { Darwin.close(fileDescriptor) }

        var metadataBefore = stat()
        guard fstat(fileDescriptor, &metadataBefore) == 0,
              metadataBefore.st_mode & S_IFMT == S_IFREG,
              metadataBefore.st_uid == uid_t(requiredOwnerUID),
              metadataBefore.st_mode & mode_t(0o777) == mode_t(0o600),
              metadataBefore.st_dev > 0,
              metadataBefore.st_ino > 0,
              metadataBefore.st_size > 0,
              metadataBefore.st_size <= off_t(maximumBytes),
              let modifiedAt = unixMilliseconds(
                seconds: Int64(metadataBefore.st_mtimespec.tv_sec),
                nanoseconds: Int64(metadataBefore.st_mtimespec.tv_nsec)
              ) else {
            return nil
        }

        let expectedSize = Int(metadataBefore.st_size)
        var data = Data()
        data.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: min(16 * 1024, maximumBytes))
        while data.count < expectedSize {
            let count = Darwin.read(
                fileDescriptor,
                &buffer,
                min(buffer.count, expectedSize - data.count)
            )
            if count > 0 {
                data.append(contentsOf: buffer.prefix(Int(count)))
            } else if count == 0 {
                return nil
            } else if errno != EINTR {
                return nil
            }
        }

        var extraByte: UInt8 = 0
        let extraCount = Darwin.read(fileDescriptor, &extraByte, 1)
        guard extraCount == 0 else { return nil }

        var metadataAfter = stat()
        guard fstat(fileDescriptor, &metadataAfter) == 0,
              metadataAfter.st_dev == metadataBefore.st_dev,
              metadataAfter.st_ino == metadataBefore.st_ino,
              metadataAfter.st_size == metadataBefore.st_size,
              metadataAfter.st_mtimespec.tv_sec == metadataBefore.st_mtimespec.tv_sec,
              metadataAfter.st_mtimespec.tv_nsec == metadataBefore.st_mtimespec.tv_nsec else {
            return nil
        }
        return CodexSecureFileSnapshot(
            canonicalPath: canonicalPath,
            device: UInt64(metadataBefore.st_dev),
            inode: UInt64(metadataBefore.st_ino),
            data: data,
            modifiedAtUnixMilliseconds: modifiedAt
        )
    }

    private nonisolated static func secureDirectoryMetadataIsValid(
        _ metadata: stat,
        requiredOwnerUID: UInt32
    ) -> Bool {
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return false }
        let writableByNonOwner = metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) != 0
        if metadata.st_uid == 0 {
            return !writableByNonOwner || metadata.st_mode & mode_t(S_ISVTX) != 0
        }
        return metadata.st_uid == uid_t(requiredOwnerUID) && !writableByNonOwner
    }

    private nonisolated static func canonicalAbsolutePath(_ path: String) -> String? {
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else { return nil }
        let components = expanded.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            return nil
        }
        let canonical = NSString(string: expanded).standardizingPath
        return canonical.hasPrefix("/") ? canonical : nil
    }

    private nonisolated static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private nonisolated static func processStartUnixMilliseconds(
        _ identity: CodexSignalProcessIdentity
    ) -> Int64? {
        let (secondsMilliseconds, secondsOverflow) = identity.startSeconds
            .multipliedReportingOverflow(by: 1_000)
        guard !secondsOverflow else { return nil }
        let (total, totalOverflow) = secondsMilliseconds.addingReportingOverflow(
            identity.startMicroseconds / 1_000
        )
        guard !totalOverflow, total <= UInt64(Int64.max) else { return nil }
        return Int64(total)
    }

    private nonisolated static func unixMilliseconds(_ date: Date) -> Int64? {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds <= Double(Int64.max) else {
            return nil
        }
        return Int64(milliseconds.rounded(.down))
    }

    private nonisolated static func unixMilliseconds(
        seconds: Int64,
        nanoseconds: Int64
    ) -> Int64? {
        let (secondsMilliseconds, secondsOverflow) = seconds
            .multipliedReportingOverflow(by: 1_000)
        let (total, totalOverflow) = secondsMilliseconds.addingReportingOverflow(
            nanoseconds / 1_000_000
        )
        return secondsOverflow || totalOverflow ? nil : total
    }

    private nonisolated static func addingWithoutOverflow(
        _ lhs: Int64,
        _ rhs: Int64
    ) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : result
    }

    private nonisolated static func subtractingWithoutOverflow(
        _ lhs: Int64,
        _ rhs: Int64
    ) -> Int64 {
        let (result, overflow) = lhs.subtractingReportingOverflow(rhs)
        return overflow ? Int64.min : result
    }

    private nonisolated static func processArguments(pid: Int32) -> [String]? {
        guard pid > 0 else { return nil }
        var mib = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), pid]
        var bufferSize = 0
        let sizeStatus = mib.withUnsafeMutableBufferPointer { mibBuffer in
            sysctl(
                mibBuffer.baseAddress,
                UInt32(mibBuffer.count),
                nil,
                &bufferSize,
                nil,
                0
            )
        }
        guard sizeStatus == 0, bufferSize >= MemoryLayout<Int32>.size else { return nil }

        var bytes = [UInt8](repeating: 0, count: bufferSize)
        let readStatus = mib.withUnsafeMutableBufferPointer { mibBuffer in
            bytes.withUnsafeMutableBytes { byteBuffer in
                sysctl(
                    mibBuffer.baseAddress,
                    UInt32(mibBuffer.count),
                    byteBuffer.baseAddress,
                    &bufferSize,
                    nil,
                    0
                )
            }
        }
        guard readStatus == 0,
              bufferSize >= MemoryLayout<Int32>.size,
              bufferSize <= bytes.count else {
            return nil
        }
        bytes.removeSubrange(bufferSize..<bytes.count)

        let argumentCount = bytes.withUnsafeBytes {
            $0.loadUnaligned(as: Int32.self)
        }
        guard argumentCount > 0, Int(argumentCount) <= bytes.count else { return nil }

        var offset = MemoryLayout<Int32>.size
        guard let executableTerminator = bytes[offset...].firstIndex(of: 0) else { return nil }
        offset = executableTerminator + 1
        while offset < bytes.count, bytes[offset] == 0 {
            offset += 1
        }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argumentCount))
        for _ in 0..<Int(argumentCount) {
            guard offset <= bytes.count,
                  let terminator = bytes[offset...].firstIndex(of: 0),
                  let argument = String(bytes: bytes[offset..<terminator], encoding: .utf8) else {
                return nil
            }
            arguments.append(argument)
            offset = terminator + 1
        }
        return arguments
    }

    private nonisolated static func executablePath(for pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro that Swift may not import on
        // newer SDKs. 4096 is the documented 4 * MAXPATHLEN value.
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: bytes, encoding: .utf8) else { return nil }
        return canonicalAbsolutePath(path)
    }

    private nonisolated static func kernelExecutableIdentity(
        pid: Int32
    ) -> CodexKernelExecutableIdentity? {
        guard let processExecutablePath = executablePath(for: pid) else { return nil }

        let executeProtection: UInt32 = 0x04
        let maximumRegionCount = 4_096
        var address: UInt64 = 0
        var mappedExecutableImages: [CodexKernelExecutableIdentity] = []
        var reachedEnd = false

        for _ in 0..<maximumRegionCount {
            var region = proc_regionwithpathinfo()
            let size = proc_pidinfo(
                pid,
                PROC_PIDREGIONPATHINFO,
                address,
                &region,
                Int32(MemoryLayout<proc_regionwithpathinfo>.size)
            )
            if size == 0 {
                reachedEnd = true
                break
            }
            guard size == MemoryLayout<proc_regionwithpathinfo>.size else { return nil }

            let regionInfo = region.prp_prinfo
            let (nextAddress, overflow) = regionInfo.pri_address.addingReportingOverflow(
                regionInfo.pri_size
            )
            guard !overflow, regionInfo.pri_size > 0, nextAddress > address else { return nil }
            address = nextAddress

            guard regionInfo.pri_protection & executeProtection != 0 else { continue }
            let vnodeStat = region.prp_vip.vip_vi.vi_stat
            guard mode_t(vnodeStat.vst_mode) & S_IFMT == S_IFREG,
                  vnodeStat.vst_dev > 0,
                  vnodeStat.vst_ino > 0,
                  let mappedPath = boundedKernelPath(from: &region.prp_vip.vip_path),
                  let canonicalMappedPath = canonicalAbsolutePath(mappedPath) else {
                continue
            }
            mappedExecutableImages.append(CodexKernelExecutableIdentity(
                canonicalPath: canonicalMappedPath,
                device: UInt64(vnodeStat.vst_dev),
                inode: vnodeStat.vst_ino
            ))
        }

        guard reachedEnd else { return nil }
        return kernelExecutableIdentity(
            processExecutablePath: processExecutablePath,
            mappedExecutableImages: mappedExecutableImages
        )
    }

    nonisolated static func kernelExecutableIdentity(
        processExecutablePath: String,
        mappedExecutableImages: [CodexKernelExecutableIdentity]
    ) -> CodexKernelExecutableIdentity? {
        guard let canonicalProcessPath = canonicalAbsolutePath(processExecutablePath) else {
            return nil
        }

        var selected: CodexKernelExecutableIdentity?
        for image in mappedExecutableImages where image.canonicalPath == canonicalProcessPath {
            guard canonicalAbsolutePath(image.canonicalPath) == image.canonicalPath,
                  image.device > 0,
                  image.inode > 0 else {
                return nil
            }
            if let selected, selected != image {
                return nil
            }
            selected = image
        }
        return selected
    }

    private nonisolated static func boundedKernelPath<T>(from tuple: inout T) -> String? {
        withUnsafeBytes(of: &tuple) { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard let terminator = bytes.firstIndex(of: 0), terminator > 0 else {
                return nil
            }
            return String(bytes: bytes[..<terminator], encoding: .utf8)
        }
    }

    nonisolated static func signalIdentityMatches(
        expected: CodexSignalProcessIdentity,
        current: CodexSignalProcessIdentity?,
        requiredOwnerUID: UInt32
    ) -> Bool {
        guard let current else { return false }
        return current.ownerUID == requiredOwnerUID && current == expected
    }

    private nonisolated static func signalProcessIdentity(
        pid: Int32
    ) -> CodexSignalProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size == MemoryLayout<proc_bsdinfo>.size,
              let executablePath = executablePath(for: pid) else {
            return nil
        }
        return CodexSignalProcessIdentity(
            pid: pid,
            ownerUID: UInt32(info.pbi_uid),
            executablePath: executablePath,
            startSeconds: UInt64(info.pbi_start_tvsec),
            startMicroseconds: UInt64(info.pbi_start_tvusec)
        )
    }

    /// Durably replace auth.json and prove its complete token set before returning.
    static func writeAuthFile(
        for account: CodexAccount,
        path: String? = nil,
        testHooks: AuthFileWriteTestHooks = AuthFileWriteTestHooks()
    ) throws {
        let targetPath = path ?? codexAuthPath
        let data = try generateAuthFileData(for: account)
        let transaction = SecureAtomicFileTransaction(
            path: targetPath,
            subject: "auth file",
            testHooks: testHooks.transaction
        )

        try transaction.withExclusiveLock { lockedFile in
            let current = try lockedFile.read()
            let committed = try lockedFile.replace(data, expectedGeneration: current.generation)
            guard let committedBytes = committed.bytes,
                  committedBytes == data,
                  let readback = try? JSONDecoder().decode(AuthFile.self, from: committedBytes),
                  readback.authMode == "chatgpt",
                  readback.tokens.accountId == account.accountId,
                  readback.tokens.accessToken == account.accessToken,
                  readback.tokens.refreshToken == account.refreshToken,
                  readback.tokens.idToken == account.idToken else {
                throw SecureAtomicFileError.readbackMismatch(path: targetPath)
            }
        }
    }
}
