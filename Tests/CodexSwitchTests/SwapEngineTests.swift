import Testing
import Darwin
import Foundation
@testable import CodexSwitch

private final class LockedTestState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ operation: (inout Value) -> Void) {
        lock.lock()
        operation(&value)
        lock.unlock()
    }
}

private final class TestSemaphore: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait() {
        semaphore.wait()
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }
}

@Suite("SwapEngine")
struct SwapEngineTests {
    @Test("Earliest usable reset ignores healthy windows")
    func earliestUsableResetIgnoresHealthyWindows() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fiveHourReset = now.addingTimeInterval(600)
        let weeklyReset = now.addingTimeInterval(3_600)
        let healthyReset = now.addingTimeInterval(60)
        let exhausted = CodexAccount(
            email: "spent@test.com",
            accessToken: "a",
            refreshToken: "r",
            idToken: "i",
            accountId: "spent",
            quotaSnapshot: QuotaSnapshot(
                fiveHour: QuotaWindow(usedPercent: 99.2, windowDurationMins: 300, resetsAt: fiveHourReset, hardLimitReached: false),
                weekly: QuotaWindow(usedPercent: 100, windowDurationMins: 10_080, resetsAt: weeklyReset, hardLimitReached: true),
                fetchedAt: now
            )
        )
        let healthy = CodexAccount(
            email: "healthy@test.com",
            accessToken: "a",
            refreshToken: "r",
            idToken: "i",
            accountId: "healthy",
            quotaSnapshot: QuotaSnapshot(
                fiveHour: QuotaWindow(usedPercent: 10, windowDurationMins: 300, resetsAt: healthyReset, hardLimitReached: false),
                weekly: QuotaWindow(usedPercent: 10, windowDurationMins: 10_080, resetsAt: healthyReset, hardLimitReached: false),
                fetchedAt: now
            )
        )

        #expect(SwapEngine.earliestUsableReset(from: [exhausted, healthy], now: now) == weeklyReset)
    }

    @Test("Earliest usable reset takes the maximum blocked reset per account, then the pool minimum")
    func earliestUsableResetUsesPerAccountRecovery() {
        let now = Date(timeIntervalSince1970: 10_000)
        let first = account(
            email: "first@test.com",
            snapshot: QuotaSnapshot(
                allowed: false,
                limitReached: true,
                fetchedAt: now,
                windows: [
                    quotaWindow(kind: .fiveHour, usedPercent: 100, resetsAt: now.addingTimeInterval(300)),
                    quotaWindow(kind: .weekly, usedPercent: 100, resetsAt: now.addingTimeInterval(3_600)),
                ]
            )
        )
        let second = account(
            email: "second@test.com",
            snapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: now,
                windows: [
                    quotaWindow(kind: .weekly, usedPercent: 100, resetsAt: now.addingTimeInterval(1_800)),
                ]
            )
        )

        #expect(SwapEngine.earliestUsableReset(from: [first, second], now: now) == now.addingTimeInterval(1_800))
    }

    @Test("Healthy weekly-only account is usable and scored")
    func healthyWeeklyOnlyAccountIsUsable() {
        let snapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: Date(),
            windows: [quotaWindow(kind: .weekly, usedPercent: 25)]
        )
        let weeklyOnly = account(email: "weekly@test.com", snapshot: snapshot, planType: "plus")

        #expect(SwapEngine.score(weeklyOnly) > 0)
        #expect(SwapEngine.isImmediatelyUsable(weeklyOnly))
        #expect(SwapEngine.selectOptimalAccount(from: [weeklyOnly])?.id == weeklyOnly.id)
    }

    @Test("Exhausted or denied weekly-only account is blocked")
    func blockedWeeklyOnlyAccountIsIneligible() {
        let exhausted = account(
            email: "exhausted@test.com",
            snapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: Date(),
                windows: [quotaWindow(kind: .weekly, usedPercent: 100)]
            )
        )
        let denied = account(
            email: "denied@test.com",
            snapshot: QuotaSnapshot(
                allowed: false,
                limitReached: true,
                fetchedAt: Date(),
                windows: [quotaWindow(kind: .weekly, usedPercent: 20)]
            )
        )

        #expect(exhausted.needsQuotaRelief)
        #expect(denied.needsQuotaRelief)
        #expect(SwapEngine.score(exhausted) == -1)
        #expect(SwapEngine.score(denied) == -1)
        #expect(!SwapEngine.isImmediatelyUsable(exhausted))
        #expect(!SwapEngine.isImmediatelyUsable(denied))
    }

    @Test("Windowless snapshot is unknown and legacy two-window snapshot remains usable")
    func windowlessAndLegacySnapshotPolicy() {
        let windowless = account(
            email: "unknown@test.com",
            snapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: Date(),
                windows: []
            )
        )
        let legacy = makeAccount(fiveHourRemaining: 80, weeklyRemaining: 70)

        #expect(!windowless.hasRealQuotaData)
        #expect(windowless.needsQuotaRelief)
        #expect(SwapEngine.score(windowless) == -1)
        #expect(!SwapEngine.isImmediatelyUsable(windowless))
        #expect(legacy.realQuotaSnapshot?.windows.count == 2)
        #expect(SwapEngine.isImmediatelyUsable(legacy))
    }

    @Test("Unknown-only diagnostics are unavailable for selection and scoring")
    func unknownOnlyDiagnosticsAreNotSelectable() {
        let unknownOnly = account(
            email: "diagnostic@test.com",
            snapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: Date(),
                windows: [quotaWindow(kind: .unknown, usedPercent: 0)]
            )
        )

        #expect(!unknownOnly.hasRealQuotaData)
        #expect(unknownOnly.needsQuotaRelief)
        #expect(SwapEngine.score(unknownOnly) == -1)
        #expect(!SwapEngine.isImmediatelyUsable(unknownOnly))
        #expect(SwapEngine.selectOptimalAccount(from: [unknownOnly]) == nil)
        #expect(SwapEngine.selectAutoSwapCandidate(from: [unknownOnly]) == nil)
    }

    @Test("Replacement eligibility requires every token and provider identity")
    func replacementEligibilityRequiresCompleteCredentials() {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let snapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: now,
            windows: [
                quotaWindow(
                    kind: .weekly,
                    usedPercent: 20,
                    resetsAt: now.addingTimeInterval(604_800)
                ),
            ]
        )
        let complete = account(email: "complete@example.com", snapshot: snapshot)
        var missingAccess = complete
        missingAccess.accessToken = " \n "
        var missingRefresh = complete
        missingRefresh.refreshToken = ""
        var missingIDToken = complete
        missingIDToken.idToken = "\t"
        var missingProviderID = complete
        missingProviderID.accountId = "  "
        let incomplete = [missingAccess, missingRefresh, missingIDToken, missingProviderID]

        #expect(complete.hasCompleteRuntimeCredentials)
        #expect(complete.isImmediatelyUsableReplacement(at: now))
        #expect(SwapEngine.isImmediatelyUsable(complete, now: now))
        #expect(SwapEngine.score(complete, now: now) > 0)

        for candidate in incomplete {
            #expect(!candidate.hasCompleteRuntimeCredentials)
            #expect(!candidate.isImmediatelyUsableReplacement(at: now))
            #expect(!SwapEngine.isImmediatelyUsable(candidate, now: now))
            #expect(SwapEngine.score(candidate, now: now) == -1)
        }
        #expect(SwapEngine.selectOptimalAccount(from: incomplete, now: now) == nil)
    }

    @Test("Replacement eligibility rejects every active runtime block")
    func replacementEligibilityUsesRuntimeStateAtDecisionTime() {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let snapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: now,
            windows: [
                quotaWindow(
                    kind: .weekly,
                    usedPercent: 20,
                    resetsAt: now.addingTimeInterval(604_800)
                ),
            ]
        )
        let ready = account(email: "ready@example.com", snapshot: snapshot)
        var reauthentication = ready
        reauthentication.runtimeUnusableUntil = now.addingTimeInterval(3_600)
        reauthentication.runtimeUnusableReason = "token_expired"
        var hardRuntimeBlock = ready
        hardRuntimeBlock.runtimeUnusableUntil = now.addingTimeInterval(3_600)
        hardRuntimeBlock.runtimeUnusableReason = "transport_failure"
        var quotaOnlyRuntimeBlock = ready
        quotaOnlyRuntimeBlock.runtimeUnusableUntil = now.addingTimeInterval(3_600)
        quotaOnlyRuntimeBlock.runtimeUnusableReason = "usage_limit"

        #expect(reauthentication.requiresReauthentication(at: now))
        #expect(!reauthentication.isImmediatelyUsableReplacement(at: now))
        #expect(hardRuntimeBlock.hasHardRuntimeBlock(at: now))
        #expect(!hardRuntimeBlock.isImmediatelyUsableReplacement(at: now))
        #expect(quotaOnlyRuntimeBlock.isQuotaRuntimeLimited(at: now))
        #expect(!quotaOnlyRuntimeBlock.hasHardRuntimeBlock(at: now))
        #expect(quotaOnlyRuntimeBlock.realQuotaSnapshot(at: now) != nil)
        #expect(quotaOnlyRuntimeBlock.isQuotaImmediatelyUsable(at: now))
        #expect(!quotaOnlyRuntimeBlock.isImmediatelyUsableReplacement(at: now))
        #expect(!SwapEngine.isImmediatelyUsable(quotaOnlyRuntimeBlock, now: now))
        #expect(SwapEngine.score(quotaOnlyRuntimeBlock, now: now) == -1)
    }

    private func account(
        email: String,
        snapshot: QuotaSnapshot,
        planType: String = "pro"
    ) -> CodexAccount {
        CodexAccount(
            email: email,
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: email,
            quotaSnapshot: snapshot,
            planType: planType
        )
    }

    private func quotaWindow(
        kind: QuotaWindowKind,
        usedPercent: Double,
        resetsAt: Date = Date().addingTimeInterval(86_400)
    ) -> QuotaWindow {
        let durationSeconds = switch kind {
        case .fiveHour: 18_000
        case .weekly: 604_800
        case .unknown: 14_400
        }
        return QuotaWindow(
            kind: kind,
            durationSeconds: durationSeconds,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
        )
    }

    private func makeAccount(
        id: UUID = UUID(),
        fiveHourRemaining: Double,
        weeklyRemaining: Double,
        resetsInSeconds: TimeInterval = 3600,
        planType: String? = nil,
        isActive: Bool = false,
        fiveHourHardLimitReached: Bool = false
    ) -> CodexAccount {
        CodexAccount(
            id: id,
            email: "test-\(id.uuidString.prefix(4))@test.com",
            accessToken: "t",
            refreshToken: "r",
            idToken: "i",
            accountId: "acc-\(id.uuidString.prefix(8))",
            quotaSnapshot: QuotaSnapshot(
                fiveHour: QuotaWindow(
                    usedPercent: 100 - fiveHourRemaining,
                    windowDurationMins: 300,
                    resetsAt: Date().addingTimeInterval(resetsInSeconds),
                    hardLimitReached: fiveHourHardLimitReached
                ),
                weekly: QuotaWindow(
                    usedPercent: 100 - weeklyRemaining,
                    windowDurationMins: 10080,
                    resetsAt: Date().addingTimeInterval(resetsInSeconds * 4),
                    hardLimitReached: false
                ),
                fetchedAt: Date()
            ),
            planType: planType,
            isActive: isActive
        )
    }

    private func signalIdentity(
        pid: Int32,
        ownerUID: UInt32 = 501,
        executablePath: String = "/Users/me/.local/share/codexswitch/prepared-codex/0.144.1/codex",
        startSeconds: UInt64 = 1_000,
        startMicroseconds: UInt64 = 12
    ) -> CodexSignalProcessIdentity {
        CodexSignalProcessIdentity(
            pid: pid,
            ownerUID: ownerUID,
            executablePath: executablePath,
            startSeconds: startSeconds,
            startMicroseconds: startMicroseconds
        )
    }

    private func kernelIdentity(
        path: String,
        device: UInt64 = 7,
        inode: UInt64 = 9_001
    ) -> CodexKernelExecutableIdentity {
        CodexKernelExecutableIdentity(
            canonicalPath: path,
            device: device,
            inode: inode
        )
    }

    private func runtimeTarget(
        pid: Int32,
        runtimeKind: HotSwapRuntimeKind,
        ownerUID: UInt32 = 501,
        arguments: [String]? = nil
    ) -> CodexRuntimeTarget {
        let defaultArguments: [String]
        switch runtimeKind {
        case .externalAppServer:
            defaultArguments = ["codex", "app-server", "--analytics-default-enabled"]
        case .headlessRemoteControlAppServer:
            defaultArguments = [
                "codex", "app-server", "--remote-control", "--listen",
                "ws://127.0.0.1:8390",
            ]
        case .localInteractiveCLI:
            defaultArguments = ["codex", "resume", "thread-\(pid)"]
        }
        let identity = signalIdentity(pid: pid, ownerUID: ownerUID)
        return CodexRuntimeTarget(
            process: CodexIdentityBoundProcess(
                identity: identity,
                kernelExecutableIdentity: kernelIdentity(
                    path: identity.executablePath,
                    inode: 10_000 + UInt64(pid)
                ),
                arguments: arguments ?? defaultArguments
            ),
            runtimeKind: runtimeKind
        )
    }

    private func reloadBinding(
        target: CodexRuntimeTarget,
        requestNonce: String? = nil,
        issuedAtUnixMilliseconds: Int64 = 1_500_000,
        executablePath: String? = nil,
        kernelExecutablePath: String? = nil,
        executableDevice: UInt64? = nil,
        executableInode: UInt64? = nil,
        runtimeKind: HotSwapRuntimeKind? = nil,
        authPath: String = "/Users/me/.codex/auth.json",
        authDevice: UInt64 = 8,
        authInode: UInt64 = 12_001,
        accountID: String = "account-1",
        tokenFingerprint: String = String(repeating: "a", count: 64),
        startSeconds: UInt64? = nil
    ) -> CodexReloadBinding {
        let original = target.process.identity
        let path = executablePath ?? original.executablePath
        let identity = CodexSignalProcessIdentity(
            pid: original.pid,
            ownerUID: original.ownerUID,
            executablePath: path,
            startSeconds: startSeconds ?? original.startSeconds,
            startMicroseconds: original.startMicroseconds
        )
        return CodexReloadBinding(
            processIdentity: identity,
            kernelExecutableIdentity: kernelIdentity(
                path: kernelExecutablePath ?? path,
                device: executableDevice ?? target.process.kernelExecutableIdentity.device,
                inode: executableInode ?? target.process.kernelExecutableIdentity.inode
            ),
            runtimeKind: runtimeKind ?? target.runtimeKind,
            authFileIdentity: CodexAuthFileIdentity(
                canonicalPath: authPath,
                device: authDevice,
                inode: authInode,
                accountID: accountID,
                completeTokenFingerprint: tokenFingerprint
            ),
            requestNonce: requestNonce ?? "nonce-\(original.pid)",
            issuedAtUnixMilliseconds: issuedAtUnixMilliseconds
        )
    }

    private func acknowledgement(
        binding: CodexReloadBinding,
        acknowledgedAtUnixMilliseconds: Int64 = 1_500_100
    ) -> CodexReloadAcknowledgement {
        let isCLI = binding.runtimeKind == .localInteractiveCLI
        return CodexReloadAcknowledgement(
            binding: binding,
            acknowledgedAtUnixMilliseconds: acknowledgedAtUnixMilliseconds,
            loadedTokenFingerprint: binding.authFileIdentity.completeTokenFingerprint,
            activeTokenFingerprint: binding.authFileIdentity.completeTokenFingerprint,
            frontendNotified: !isCLI,
            frontendWriteCount: isCLI ? 0 : 1,
            authGeneration: isCLI ? 7 : nil,
            reconnectReady: isCLI ? true : nil
        )
    }

    private func artifactSnapshots(
        binding: CodexReloadBinding,
        acknowledgement overrideAcknowledgement: CodexReloadAcknowledgement? = nil,
        requestModifiedAt: Int64 = 1_500_050,
        acknowledgementModifiedAt: Int64 = 1_500_150
    ) -> (CodexSecureFileSnapshot, CodexSecureFileSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let requestData = try! encoder.encode(CodexReloadRequestArtifact(binding: binding))
        let ackData = try! encoder.encode(
            overrideAcknowledgement ?? acknowledgement(binding: binding)
        )
        return (
            CodexSecureFileSnapshot(
                canonicalPath: "/Users/me/.codexswitch/hotswap-request/\(binding.processIdentity.pid).json",
                device: 9,
                inode: 20_001,
                data: requestData,
                modifiedAtUnixMilliseconds: requestModifiedAt
            ),
            CodexSecureFileSnapshot(
                canonicalPath: "/Users/me/.codexswitch/hotswap-ack/\(binding.processIdentity.pid).json",
                device: 9,
                inode: 20_002,
                data: ackData,
                modifiedAtUnixMilliseconds: acknowledgementModifiedAt
            )
        )
    }

    @Test("Selects account with highest remaining 5hr quota")
    func selectsHighestQuota() {
        let a = makeAccount(fiveHourRemaining: 30, weeklyRemaining: 80)
        let b = makeAccount(fiveHourRemaining: 90, weeklyRemaining: 50)
        let c = makeAccount(fiveHourRemaining: 60, weeklyRemaining: 70)
        let best = SwapEngine.selectOptimalAccount(from: [a, b, c])
        #expect(best?.id == b.id)
    }

    @Test("Excludes exhausted accounts")
    func excludesExhausted() {
        let exhausted = makeAccount(fiveHourRemaining: 0, weeklyRemaining: 0)
        let available = makeAccount(fiveHourRemaining: 20, weeklyRemaining: 50)
        let best = SwapEngine.selectOptimalAccount(from: [exhausted, available])
        #expect(best?.id == available.id)
    }

    @Test("Returns nil when all exhausted")
    func allExhausted() {
        let a = makeAccount(fiveHourRemaining: 0, weeklyRemaining: 0)
        let b = makeAccount(fiveHourRemaining: 0, weeklyRemaining: 0)
        let best = SwapEngine.selectOptimalAccount(from: [a, b])
        #expect(best == nil)
    }

    @Test("Tiebreaker uses weekly remaining")
    func tiebreaker() {
        let a = makeAccount(fiveHourRemaining: 50, weeklyRemaining: 30)
        let b = makeAccount(fiveHourRemaining: 50, weeklyRemaining: 80)
        let best = SwapEngine.selectOptimalAccount(from: [a, b])
        #expect(best?.id == b.id)
    }

    @Test("Swap ties use shared provider-first stable identity ordering")
    func swapTieUsesStableProviderIdentity() {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let sharedSnapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: now,
            windows: [
                quotaWindow(
                    kind: .weekly,
                    usedPercent: 20,
                    resetsAt: now.addingTimeInterval(604_800)
                ),
            ]
        )
        var alphaProvider = account(
            email: "zulu@example.com",
            snapshot: sharedSnapshot,
            planType: "plus"
        )
        alphaProvider.accountId = " alpha-provider "
        var betaProvider = account(
            email: "alpha@example.com",
            snapshot: sharedSnapshot,
            planType: "plus"
        )
        betaProvider.accountId = "BETA-PROVIDER"

        #expect(SwapEngine.selectOptimalAccount(
            from: [betaProvider, alphaProvider],
            now: now
        )?.id == alphaProvider.id)
        #expect(SwapEngine.selectOptimalAccount(
            from: [alphaProvider, betaProvider],
            now: now
        )?.id == alphaProvider.id)
    }

    @Test("Comparable paid accounts prefer earlier five-hour reset")
    func comparablePaidAccountsPreferEarlierFiveHourReset() {
        let laterResetSlightlyMoreWeekly = makeAccount(
            fiveHourRemaining: 100,
            weeklyRemaining: 53,
            resetsInSeconds: 4 * 3600,
            planType: "plus"
        )
        let earlierResetSlightlyLessWeekly = makeAccount(
            fiveHourRemaining: 100,
            weeklyRemaining: 52,
            resetsInSeconds: 600,
            planType: "plus"
        )

        let best = SwapEngine.selectOptimalAccount(from: [
            laterResetSlightlyMoreWeekly,
            earlierResetSlightlyLessWeekly,
        ])

        #expect(best?.id == earlierResetSlightlyLessWeekly.id)
    }

    @Test("Earlier five-hour reset does not beat meaningful quota gap")
    func earlierFiveHourResetDoesNotBeatMeaningfulQuotaGap() {
        let earlierResetLowWeekly = makeAccount(
            fiveHourRemaining: 100,
            weeklyRemaining: 40,
            resetsInSeconds: 600,
            planType: "plus"
        )
        let laterResetHighWeekly = makeAccount(
            fiveHourRemaining: 100,
            weeklyRemaining: 80,
            resetsInSeconds: 4 * 3600,
            planType: "plus"
        )

        let best = SwapEngine.selectOptimalAccount(from: [
            earlierResetLowWeekly,
            laterResetHighWeekly,
        ])

        #expect(best?.id == laterResetHighWeekly.id)
    }

    @Test("Next-up excludes accounts at the auto-swap threshold")
    func nextUpExcludesAutoSwapThresholdAccounts() {
        let nearlyWeeklyExhaustedPro = makeAccount(
            fiveHourRemaining: 100,
            weeklyRemaining: 1,
            planType: "pro"
        )
        let readyPlus = makeAccount(
            fiveHourRemaining: 84,
            weeklyRemaining: 84,
            planType: "plus"
        )

        let best = SwapEngine.selectOptimalAccount(from: [nearlyWeeklyExhaustedPro, readyPlus])

        #expect(best?.id == readyPlus.id)
        #expect(!SwapEngine.isImmediatelyUsable(nearlyWeeklyExhaustedPro))
    }

    @Test("Next-up excludes placeholder quota snapshots")
    func nextUpExcludesPlaceholderQuotaSnapshots() {
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 802_157_341)
        let placeholderPro = CodexAccount(
            email: "placeholder-pro@test.com",
            accessToken: "t",
            refreshToken: "r",
            idToken: "i",
            accountId: "placeholder-pro",
            quotaSnapshot: QuotaSnapshot(
                fiveHour: QuotaWindow(
                    usedPercent: 0,
                    windowDurationMins: 300,
                    resetsAt: fetchedAt,
                    hardLimitReached: false
                ),
                weekly: QuotaWindow(
                    usedPercent: 0,
                    windowDurationMins: 10_080,
                    resetsAt: fetchedAt.addingTimeInterval(604_800),
                    hardLimitReached: false
                ),
                fetchedAt: fetchedAt
            ),
            planType: "pro"
        )
        let readyPlus = makeAccount(
            fiveHourRemaining: 60,
            weeklyRemaining: 60,
            planType: "plus"
        )

        let best = SwapEngine.selectOptimalAccount(from: [placeholderPro, readyPlus])

        #expect(placeholderPro.realQuotaSnapshot == nil)
        #expect(SwapEngine.score(placeholderPro) == -1)
        #expect(!SwapEngine.isImmediatelyUsable(placeholderPro))
        #expect(best?.id == readyPlus.id)
    }

    @Test("Next-up excludes runtime-blocked accounts with stale quota")
    func nextUpExcludesRuntimeBlockedAccountsWithStaleQuota() {
        let blockedPro = makeAccount(
            fiveHourRemaining: 100,
            weeklyRemaining: 100,
            planType: "pro"
        )
        var blocked = blockedPro
        blocked.runtimeUnusableUntil = Date().addingTimeInterval(30 * 24 * 60 * 60)
        blocked.runtimeUnusableReason = "token_expired"
        let readyPlus = makeAccount(
            fiveHourRemaining: 60,
            weeklyRemaining: 60,
            planType: "plus"
        )

        let best = SwapEngine.selectOptimalAccount(from: [blocked, readyPlus])

        #expect(blocked.requiresReauthentication)
        #expect(blocked.realQuotaSnapshot == nil)
        #expect(SwapEngine.score(blocked) == -1)
        #expect(!SwapEngine.isImmediatelyUsable(blocked))
        #expect(best?.id == readyPlus.id)
    }

    @Test("Usage-limit runtime block keeps fresh quota visible but is not selectable")
    func usageLimitRuntimeBlockKeepsQuotaVisibleButIsNotSelectable() {
        var quotaLimitedPro = makeAccount(
            fiveHourRemaining: 70,
            weeklyRemaining: 70,
            planType: "pro"
        )
        quotaLimitedPro.runtimeUnusableUntil = Date().addingTimeInterval(6 * 60 * 60)
        quotaLimitedPro.runtimeUnusableReason = "usage_limit"
        let readyPlus = makeAccount(
            fiveHourRemaining: 60,
            weeklyRemaining: 60,
            planType: "plus"
        )

        let best = SwapEngine.selectOptimalAccount(from: [quotaLimitedPro, readyPlus])

        #expect(quotaLimitedPro.isQuotaRuntimeLimited)
        #expect(!quotaLimitedPro.hasHardRuntimeBlock)
        #expect(quotaLimitedPro.realQuotaSnapshot != nil)
        #expect(quotaLimitedPro.runtimeStatusText == nil)
        #expect(quotaLimitedPro.isQuotaImmediatelyUsable)
        #expect(!quotaLimitedPro.isImmediatelyUsableReplacement)
        #expect(SwapEngine.score(quotaLimitedPro) == -1)
        #expect(!SwapEngine.isImmediatelyUsable(quotaLimitedPro))
        #expect(best?.id == readyPlus.id)
    }

    @Test("Usage-limit runtime block shows quota but exhausted 5h is not usable")
    func usageLimitRuntimeBlockWithExhaustedFiveHourShowsQuotaButIsNotUsable() {
        var quotaLimitedPro = makeAccount(
            fiveHourRemaining: 0,
            weeklyRemaining: 69,
            planType: "pro"
        )
        quotaLimitedPro.runtimeUnusableUntil = Date().addingTimeInterval(60 * 60)
        quotaLimitedPro.runtimeUnusableReason = "usage_limit"

        #expect(quotaLimitedPro.realQuotaSnapshot != nil)
        #expect(quotaLimitedPro.runtimeStatusText == nil)
        #expect(SwapEngine.score(quotaLimitedPro) == -1)
        #expect(!SwapEngine.isImmediatelyUsable(quotaLimitedPro))
    }

    @Test("Bonus for accounts about to reset")
    func resetBonus() {
        // Account A has less remaining but resets in 10 minutes
        let a = makeAccount(fiveHourRemaining: 5, weeklyRemaining: 50, resetsInSeconds: 600)
        // Account B has more remaining but resets in 4 hours
        let b = makeAccount(fiveHourRemaining: 20, weeklyRemaining: 50, resetsInSeconds: 14400)
        // B should win because A is almost empty even with reset bonus
        let best = SwapEngine.selectOptimalAccount(from: [a, b])
        #expect(best?.id == b.id)
    }

    @Test("Auth file generation")
    func authFileGeneration() throws {
        let account = CodexAccount(
            email: "test@test.com",
            accessToken: "act",
            refreshToken: "rft",
            idToken: "idt",
            accountId: "acc-123"
        )
        let data = try SwapEngine.generateAuthFileData(for: account)
        let decoded = try JSONDecoder().decode(AuthFile.self, from: data)
        #expect(decoded.authMode == "chatgpt")
        #expect(decoded.tokens.accessToken == "act")
        #expect(decoded.tokens.accountId == "acc-123")
    }

    @Test("Atomic auth file write and cleanup")
    func atomicWrite() throws {
        let account = CodexAccount(
            email: "test@test.com",
            accessToken: "act",
            refreshToken: "rft",
            idToken: "idt",
            accountId: "acc-123"
        )
        let testURL = makeSecureTestFileURL(
            prefix: "codexswitch-test-auth",
            fileName: "auth.json"
        )
        let testPath = testURL.path

        defer {
            try? FileManager.default.removeItem(at: testURL.deletingLastPathComponent())
        }

        try SwapEngine.writeAuthFile(for: account, path: testPath)

        // Verify file exists and is readable
        let data = try Data(contentsOf: URL(fileURLWithPath: testPath))
        let decoded = try JSONDecoder().decode(AuthFile.self, from: data)
        #expect(decoded.tokens.accessToken == "act")
        #expect(decoded.tokens.refreshToken == "rft")

        // Verify permissions are 0600
        let attrs = try FileManager.default.attributesOfItem(atPath: testPath)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test("Score excludes accounts with no snapshot")
    func scoreNoSnapshot() {
        let account = CodexAccount(
            email: "test@test.com",
            accessToken: "t",
            refreshToken: "r",
            idToken: "i",
            accountId: "acc-1"
        )
        #expect(SwapEngine.score(account) == -1)
    }

    @Test("Score returns -1 for both-windows-exhausted")
    func scoreBothExhausted() {
        let account = makeAccount(fiveHourRemaining: 0, weeklyRemaining: 0)
        #expect(SwapEngine.score(account) == -1)
    }

    @Test("Past exhausted reset is not usable until polling confirms reset")
    func pastExhaustedResetRequiresConfirmation() {
        let staleReset = makeAccount(
            fiveHourRemaining: 0,
            weeklyRemaining: 80,
            resetsInSeconds: -60,
            planType: "pro",
            fiveHourHardLimitReached: true
        )
        let readyPlus = makeAccount(
            fiveHourRemaining: 30,
            weeklyRemaining: 80,
            planType: "plus"
        )

        #expect(SwapEngine.score(staleReset) == -1)
        #expect(!SwapEngine.isImmediatelyUsable(staleReset))
        #expect(SwapEngine.selectAutoSwapCandidate(from: [staleReset, readyPlus])?.id == readyPlus.id)
    }

    @Test("Skips currently active account in selection")
    func skipsActive() {
        let active = makeAccount(fiveHourRemaining: 90, weeklyRemaining: 90, isActive: true)
        let other = makeAccount(fiveHourRemaining: 50, weeklyRemaining: 50)
        let best = SwapEngine.selectOptimalAccount(from: [active, other])
        #expect(best?.id == other.id)
    }

    @Test("Auto-swap candidates can have five percent remaining")
    func autoSwapCandidateAllowsFivePercentRemaining() {
        let active = makeAccount(fiveHourRemaining: 1, weeklyRemaining: 90, isActive: true)
        let fivePercent = makeAccount(fiveHourRemaining: 5, weeklyRemaining: 90)
        let onePercent = makeAccount(fiveHourRemaining: 1, weeklyRemaining: 90)

        let best = SwapEngine.selectAutoSwapCandidate(from: [active, fivePercent, onePercent])

        #expect(best?.id == fivePercent.id)
    }

    @Test("Hard rate-limit on active account is never a usable score")
    func hardRateLimitTreatsAccountAsExhausted() {
        let active = makeAccount(
            fiveHourRemaining: 1.1,
            weeklyRemaining: 90,
            isActive: true,
            fiveHourHardLimitReached: true
        )
        let other = makeAccount(fiveHourRemaining: 5, weeklyRemaining: 90)

        #expect(SwapEngine.score(active) == -1)
        #expect(!SwapEngine.isImmediatelyUsable(active))
        let best = SwapEngine.selectAutoSwapCandidate(from: [active, other])
        #expect(best?.id == other.id)
    }

    @Test("Plan tier outranks raw free-account quota")
    func planTierOutranksFreeQuota() {
        let free = makeAccount(fiveHourRemaining: 100, weeklyRemaining: 100, planType: "free")
        let plus = makeAccount(fiveHourRemaining: 100, weeklyRemaining: 100, planType: "plus")
        let proLite = makeAccount(fiveHourRemaining: 100, weeklyRemaining: 100, planType: "pro_lite")
        let plusResettingSoon = makeAccount(
            fiveHourRemaining: 0,
            weeklyRemaining: 80,
            resetsInSeconds: 600,
            planType: "plus"
        )
        let proLow = makeAccount(fiveHourRemaining: 5, weeklyRemaining: 50, planType: "pro")
        let proLowWeekly = makeAccount(fiveHourRemaining: 5, weeklyRemaining: 2, planType: "pro")

        let best = SwapEngine.selectOptimalAccount(from: [free, plusResettingSoon, proLow])

        #expect(best?.id == proLow.id)
        #expect(SwapEngine.score(proLowWeekly) > SwapEngine.score(proLite))
        #expect(proLite.planPriority > plus.planPriority)
        #expect(plus.planPriority > free.planPriority)
        #expect(SwapEngine.score(proLite) > SwapEngine.score(plus))
        #expect(SwapEngine.score(plus) > SwapEngine.score(free))
        #expect(SwapEngine.score(plusResettingSoon) == -1)
    }

    @Test("Pro aliases outrank Plus")
    func proAliasesOutrankPlus() {
        let plus = makeAccount(fiveHourRemaining: 100, weeklyRemaining: 100, planType: "chatgpt_plus")
        let pro = makeAccount(fiveHourRemaining: 5, weeklyRemaining: 50, planType: "ChatGPT Pro")
        let proMonthly = makeAccount(fiveHourRemaining: 5, weeklyRemaining: 50, planType: "pro-monthly")
        let proLite = makeAccount(fiveHourRemaining: 100, weeklyRemaining: 100, planType: "chatgpt_pro_lite")

        #expect(plus.planPriority == 2)
        #expect(pro.planPriority == 4)
        #expect(proMonthly.planPriority == 4)
        #expect(proLite.planPriority == 3)
        #expect(SwapEngine.score(pro) > SwapEngine.score(plus))
    }

    @Test("Healthy Plus rotates to usable Pro")
    func healthyPlusRotatesToUsablePro() {
        let activePlus = makeAccount(
            fiveHourRemaining: 80,
            weeklyRemaining: 80,
            planType: "plus",
            isActive: true
        )
        let readyPlus = makeAccount(fiveHourRemaining: 100, weeklyRemaining: 100, planType: "plus")
        let readyPro = makeAccount(fiveHourRemaining: 10, weeklyRemaining: 30, planType: "pro")
        let spentPro = makeAccount(fiveHourRemaining: 1, weeklyRemaining: 100, planType: "pro")

        let upgrade = SwapEngine.selectPlanUpgradeCandidate(
            active: activePlus,
            from: [activePlus, readyPlus, readyPro, spentPro]
        )

        #expect(upgrade?.id == readyPro.id)
    }

    @Test("Active Pro does not downgrade to Plus")
    func activeProDoesNotDowngradeToPlus() {
        let activePro = makeAccount(
            fiveHourRemaining: 10,
            weeklyRemaining: 30,
            planType: "pro",
            isActive: true
        )
        let readyPlus = makeAccount(fiveHourRemaining: 100, weeklyRemaining: 100, planType: "plus")

        #expect(SwapEngine.selectPlanUpgradeCandidate(active: activePro, from: [activePro, readyPlus]) == nil)
    }

    @Test("Manual account selection blocks plan upgrade until exhausted")
    func manualSelectionBlocksPlanUpgradeUntilExhausted() {
        let activePlus = makeAccount(
            fiveHourRemaining: 100,
            weeklyRemaining: 50,
            planType: "plus",
            isActive: true
        )

        #expect(SwapEngine.shouldHonorManualOverride(
            activeAccountId: activePlus.id,
            manualOverrideAccountId: activePlus.id,
            activeNeedsRelief: false
        ))
        #expect(!SwapEngine.shouldHonorManualOverride(
            activeAccountId: activePlus.id,
            manualOverrideAccountId: activePlus.id,
            activeNeedsRelief: true
        ))
        #expect(!SwapEngine.shouldHonorManualOverride(
            activeAccountId: activePlus.id,
            manualOverrideAccountId: UUID(),
            activeNeedsRelief: false
        ))
    }

    @Test("Typed runtime classification uses executable identity and current argv")
    func typedRuntimeClassificationUsesIdentityAndCurrentArguments() {
        let managedIdentity = signalIdentity(pid: 41)
        let managedKernelIdentity = kernelIdentity(path: managedIdentity.executablePath)
        let interactive = CodexIdentityBoundProcess(
            identity: managedIdentity,
            kernelExecutableIdentity: managedKernelIdentity,
            arguments: ["stale-argv-zero", "resume", "thread-1"]
        )
        let exec = CodexIdentityBoundProcess(
            identity: managedIdentity,
            kernelExecutableIdentity: managedKernelIdentity,
            arguments: ["stale-argv-zero", "exec", "--json"]
        )
        let remote = CodexIdentityBoundProcess(
            identity: managedIdentity,
            kernelExecutableIdentity: managedKernelIdentity,
            arguments: ["stale-argv-zero", "--remote=ws://127.0.0.1", "resume", "thread-1"]
        )
        let appServer = CodexIdentityBoundProcess(
            identity: managedIdentity,
            kernelExecutableIdentity: managedKernelIdentity,
            arguments: ["stale-argv-zero", "app-server"]
        )
        let vendorIdentity = signalIdentity(pid: 42, executablePath: "/opt/homebrew/bin/codex")
        let vendorAppServer = CodexIdentityBoundProcess(
            identity: vendorIdentity,
            kernelExecutableIdentity: kernelIdentity(path: vendorIdentity.executablePath),
            arguments: ["codex", "app-server"]
        )

        #expect(SwapEngine.processMatchesRuntime(interactive, runtimeKind: .localInteractiveCLI))
        #expect(!SwapEngine.processMatchesRuntime(exec, runtimeKind: .localInteractiveCLI))
        #expect(!SwapEngine.processMatchesRuntime(remote, runtimeKind: .localInteractiveCLI))
        #expect(!SwapEngine.processMatchesRuntime(appServer, runtimeKind: .localInteractiveCLI))
        #expect(SwapEngine.processMatchesRuntime(appServer, runtimeKind: .externalAppServer))
        #expect(!SwapEngine.processMatchesRuntime(vendorAppServer, runtimeKind: .externalAppServer))
    }

    @Test("Identity-bound argv capture requires owner and matching identities")
    func identityBoundArgumentsRequireStableOwnedIdentity() {
        let expected = signalIdentity(pid: 41)
        var events: [String] = []
        let process = SwapEngine.identityBoundProcess(
            pid: 41,
            requiredOwnerUID: 501,
            identityProvider: { _ in
                events.append("identity")
                return expected
            },
            argumentProvider: { _ in
                events.append("arguments")
                return ["codex", "resume", "thread-1"]
            },
            kernelExecutableIdentityProvider: { _ in
                events.append("executable")
                return self.kernelIdentity(path: expected.executablePath)
            }
        )
        #expect(process?.identity == expected)
        #expect(process?.arguments == ["codex", "resume", "thread-1"])
        #expect(events == ["identity", "arguments", "identity", "executable", "identity"])

        let reused = signalIdentity(pid: 41, startSeconds: 1_001)
        var identityReads = 0
        let changedProcess = SwapEngine.identityBoundProcess(
            pid: 41,
            requiredOwnerUID: 501,
            identityProvider: { _ in
                identityReads += 1
                return identityReads == 1 ? expected : reused
            },
            argumentProvider: { _ in ["codex", "resume", "thread-1"] },
            kernelExecutableIdentityProvider: { _ in
                self.kernelIdentity(path: expected.executablePath)
            }
        )
        #expect(changedProcess == nil)

        #expect(SwapEngine.identityBoundProcess(
            pid: 41,
            requiredOwnerUID: 501,
            identityProvider: { _ in expected },
            argumentProvider: { _ in ["codex", "resume", "thread-1"] },
            kernelExecutableIdentityProvider: { _ in
                self.kernelIdentity(path: "/tmp/replaced-codex")
            }
        ) == nil)

        var readWrongOwnerArguments = false
        #expect(SwapEngine.identityBoundProcess(
            pid: 41,
            requiredOwnerUID: 502,
            identityProvider: { _ in expected },
            argumentProvider: { _ in
                readWrongOwnerArguments = true
                return ["codex"]
            },
            kernelExecutableIdentityProvider: { _ in
                self.kernelIdentity(path: expected.executablePath)
            }
        ) == nil)
        #expect(!readWrongOwnerArguments)
    }

    @Test("Mapped executable identity requires one canonical path, device, and inode")
    func mappedExecutableIdentityRejectsPathDeviceAndInodeAmbiguity() {
        let path = "/Users/me/.local/share/codexswitch/prepared-codex/codex"
        let expected = kernelIdentity(path: path, device: 7, inode: 9_001)
        #expect(SwapEngine.kernelExecutableIdentity(
            processExecutablePath: path,
            mappedExecutableImages: [expected, expected]
        ) == expected)
        #expect(SwapEngine.kernelExecutableIdentity(
            processExecutablePath: path,
            mappedExecutableImages: [kernelIdentity(path: "/tmp/codex")]
        ) == nil)
        #expect(SwapEngine.kernelExecutableIdentity(
            processExecutablePath: path,
            mappedExecutableImages: [expected, kernelIdentity(path: path, device: 8, inode: 9_001)]
        ) == nil)
        #expect(SwapEngine.kernelExecutableIdentity(
            processExecutablePath: path,
            mappedExecutableImages: [expected, kernelIdentity(path: path, device: 7, inode: 9_002)]
        ) == nil)
    }

    @Test("Binding revalidation checks argv, executable vnode, and complete auth")
    func bindingRevalidationChecksEveryAuthority() {
        let target = runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI)
        let binding = reloadBinding(target: target)
        let currentArguments = ["codex", "resume", "thread-41"]
        var events: [String] = []
        #expect(SwapEngine.reloadBindingIsCurrent(
            binding,
            identityProvider: { _ in
                events.append("identity")
                return binding.processIdentity
            },
            argumentProvider: { _ in
                events.append("arguments")
                return currentArguments
            },
            kernelExecutableIdentityProvider: { _ in
                events.append("executable")
                return binding.kernelExecutableIdentity
            },
            authFileIdentityProvider: { _, _ in
                events.append("auth")
                return binding.authFileIdentity
            }
        ))
        #expect(events == [
            "identity", "arguments", "identity", "executable", "auth", "arguments",
            "executable", "auth", "identity",
        ])

        #expect(!SwapEngine.reloadBindingIsCurrent(
            binding,
            identityProvider: { _ in binding.processIdentity },
            argumentProvider: { _ in currentArguments },
            kernelExecutableIdentityProvider: { _ in
                self.kernelIdentity(path: "/tmp/replaced-codex")
            },
            authFileIdentityProvider: { _, _ in binding.authFileIdentity }
        ))

        for executableDrift in [
            self.kernelIdentity(
                path: binding.kernelExecutableIdentity.canonicalPath,
                device: binding.kernelExecutableIdentity.device + 1,
                inode: binding.kernelExecutableIdentity.inode
            ),
            self.kernelIdentity(
                path: binding.kernelExecutableIdentity.canonicalPath,
                device: binding.kernelExecutableIdentity.device,
                inode: binding.kernelExecutableIdentity.inode + 1
            ),
        ] {
            #expect(!SwapEngine.reloadBindingIsCurrent(
                binding,
                identityProvider: { _ in binding.processIdentity },
                argumentProvider: { _ in currentArguments },
                kernelExecutableIdentityProvider: { _ in executableDrift },
                authFileIdentityProvider: { _, _ in binding.authFileIdentity }
            ))
        }

        let changedAuth = CodexAuthFileIdentity(
            canonicalPath: binding.authFileIdentity.canonicalPath,
            device: binding.authFileIdentity.device,
            inode: binding.authFileIdentity.inode,
            accountID: binding.authFileIdentity.accountID,
            completeTokenFingerprint: String(repeating: "b", count: 64)
        )
        #expect(!SwapEngine.reloadBindingIsCurrent(
            binding,
            identityProvider: { _ in binding.processIdentity },
            argumentProvider: { _ in currentArguments },
            kernelExecutableIdentityProvider: { _ in binding.kernelExecutableIdentity },
            authFileIdentityProvider: { _, _ in changedAuth }
        ))

        var argumentReads = 0
        #expect(!SwapEngine.reloadBindingIsCurrent(
            binding,
            identityProvider: { _ in binding.processIdentity },
            argumentProvider: { _ in
                argumentReads += 1
                return argumentReads == 1
                    ? currentArguments
                    : ["codex", "app-server"]
            },
            kernelExecutableIdentityProvider: { _ in binding.kernelExecutableIdentity },
            authFileIdentityProvider: { _, _ in binding.authFileIdentity }
        ))
    }

    @Test("Typed reload summaries remain truthful")
    func typedReloadSummariesRemainTruthful() {
        let empty = CodexRuntimeDiscoverySnapshot(targets: [], isComplete: true)
        let complete = CodexRuntimeDiscoverySnapshot(
            targets: [runtimeTarget(pid: 42, runtimeKind: .localInteractiveCLI)],
            isComplete: true
        )
        let incomplete = CodexRuntimeDiscoverySnapshot(
            targets: [runtimeTarget(pid: 51, runtimeKind: .externalAppServer)],
            isComplete: false
        )

        #expect(SwapEngine.codexReloadSummary(
            from: empty,
            acknowledgedPIDs: []
        ).outcome == .noLocalRuntime)
        #expect(SwapEngine.codexReloadSummary(
            from: complete,
            acknowledgedPIDs: [42]
        ).outcome == .allDiscoveredRuntimesAcknowledged)

        let failed = SwapEngine.desktopReloadSummary(
            from: incomplete,
            acknowledgedPIDs: [51]
        )
        #expect(failed.discoveredRuntimeCount == 1)
        #expect(failed.acknowledgedRuntimeCount == 1)
        #expect(failed.operationFailed)
        #expect(failed.outcome == .restartRequiredOrFailed)
    }

    @Test("Desktop first ACK bootstrap never authorizes CLI or an untrusted bridge")
    func desktopFirstAcknowledgementBootstrapIsNarrow() {
        let desktopBinding = reloadBinding(
            target: runtimeTarget(pid: 41, runtimeKind: .externalAppServer)
        )
        let cliBinding = reloadBinding(
            target: runtimeTarget(pid: 42, runtimeKind: .localInteractiveCLI)
        )

        #expect(SwapEngine.desktopReloadCapabilityIsAuthorized(
            binding: desktopBinding,
            hasStartupAcknowledgement: true,
            firstAcknowledgementBootstrapAuthorized: false
        ))
        #expect(SwapEngine.desktopReloadCapabilityIsAuthorized(
            binding: desktopBinding,
            hasStartupAcknowledgement: false,
            firstAcknowledgementBootstrapAuthorized: true
        ))
        #expect(!SwapEngine.desktopReloadCapabilityIsAuthorized(
            binding: desktopBinding,
            hasStartupAcknowledgement: false,
            firstAcknowledgementBootstrapAuthorized: false
        ))
        #expect(!SwapEngine.desktopReloadCapabilityIsAuthorized(
            binding: cliBinding,
            hasStartupAcknowledgement: false,
            firstAcknowledgementBootstrapAuthorized: true
        ))
    }

    @Test("CLI first ACK bootstrap is limited to an interactive CLI")
    func cliFirstAcknowledgementBootstrapIsNarrow() {
        let cliBinding = reloadBinding(
            target: runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI)
        )
        let desktopBinding = reloadBinding(
            target: runtimeTarget(pid: 42, runtimeKind: .externalAppServer)
        )

        #expect(SwapEngine.cliReloadCapabilityIsAuthorized(
            binding: cliBinding,
            hasStartupAcknowledgement: true,
            managedRuntimeBootstrapAuthorized: false
        ))
        #expect(SwapEngine.cliReloadCapabilityIsAuthorized(
            binding: cliBinding,
            hasStartupAcknowledgement: false,
            managedRuntimeBootstrapAuthorized: true
        ))
        #expect(!SwapEngine.cliReloadCapabilityIsAuthorized(
            binding: cliBinding,
            hasStartupAcknowledgement: false,
            managedRuntimeBootstrapAuthorized: false
        ))
        #expect(!SwapEngine.cliReloadCapabilityIsAuthorized(
            binding: desktopBinding,
            hasStartupAcknowledgement: false,
            managedRuntimeBootstrapAuthorized: true
        ))
    }

    @Test("Local CLI preliminary discovery uses the exact process name")
    func localCLIPreliminaryDiscoveryIsExact() {
        #expect(
            SwapEngine.localCodexProcessDiscoveryArguments
                == ["-l", "-x", "codex"]
        )
        #expect(!SwapEngine.localCodexProcessDiscoveryArguments.contains("-f"))
    }

    @Test("Local CLI topology is complete, sorted, and route-aware")
    func localCLITopologyIsRouteAware() throws {
        let targets = [
            runtimeTarget(pid: 42, runtimeKind: .localInteractiveCLI),
            runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI),
        ]
        let discovery = CodexRuntimeDiscoverySnapshot(
            targets: targets,
            isComplete: true
        )
        let managedPath = targets[0].process.identity.executablePath
        let topology = try #require(SwapEngine.localCLIRuntimeTopology(
            discoverySnapshot: discovery,
            managedRuntimePath: managedPath
        ))

        #expect(topology.runtimes.map(\.processIdentity.pid) == [41, 42])
        #expect(topology.allRuntimesUseManagedRoute)
        #expect(SwapEngine.localCLIRuntimeTopology(
            discoverySnapshot: discovery,
            managedRuntimePath: "/other/codex"
        )?.allRuntimesUseManagedRoute == false)
        #expect(SwapEngine.localCLIRuntimeTopology(
            discoverySnapshot: CodexRuntimeDiscoverySnapshot(
                targets: targets,
                isComplete: false
            ),
            managedRuntimePath: managedPath
        ) == nil)
    }

    @Test("Incomplete CLI and desktop discovery sends zero signals")
    func incompleteDiscoverySendsNoSignals() {
        let parsed = SwapEngine.pgrepDiscoveryResult(
            stdout: Data("41 /stale/pgrep/command --untrusted\nmalformed-row\n".utf8),
            terminationStatus: 0,
            timedOut: false
        )
        guard case .snapshot(let processSnapshot) = parsed else {
            Issue.record("Expected a typed incomplete process snapshot")
            return
        }

        for runtimeKind in [HotSwapRuntimeKind.localInteractiveCLI, .externalAppServer] {
            let pid: Int32 = 41
            let identity = signalIdentity(pid: pid)
            let arguments = runtimeKind == .localInteractiveCLI
                ? ["codex", "resume", "thread-41"]
                : ["codex", "app-server"]
            let discovery = SwapEngine.runtimeDiscoverySnapshot(
                from: processSnapshot,
                runtimeKind: runtimeKind,
                requiredOwnerUID: 501,
                identityProvider: { $0 == pid ? identity : nil },
                argumentProvider: { $0 == pid ? arguments : nil },
                kernelExecutableIdentityProvider: { candidatePID in
                    candidatePID == pid
                        ? self.kernelIdentity(path: identity.executablePath)
                        : nil
                }
            )
            var capabilityChecks = 0
            var preparedRequests = 0
            var signaledPIDs: [Int32] = []
            var ackWaits = 0

            let execution = SwapEngine.executeReloadBatch(
                preliminaryPIDs: [pid],
                discoveryProvider: { discovery },
                requiredOwnerUID: 501,
                candidateIsEligible: { _ in true },
                makeBinding: { target in
                    preparedRequests += 1
                    return reloadBinding(target: target)
                },
                hotSwapSupport: { _ in
                    capabilityChecks += 1
                    return true
                },
                bindingIsCurrent: { _ in true },
                persistRequest: { _ in true },
                signal: { candidatePID in
                    signaledPIDs.append(candidatePID)
                    return true
                },
                awaitAcknowledgements: { _ in
                    ackWaits += 1
                    return []
                },
                gate: CodexReloadAttemptGate()
            )

            #expect(execution.operationFailed)
            #expect(execution.acknowledgedPIDs.isEmpty)
            #expect(capabilityChecks == 0)
            #expect(preparedRequests == 0)
            #expect(signaledPIDs.isEmpty)
            #expect(ackWaits == 0)

            let summary = runtimeKind == .localInteractiveCLI
                ? SwapEngine.codexReloadSummary(
                    from: discovery,
                    acknowledgedPIDs: execution.acknowledgedPIDs,
                    operationFailed: execution.operationFailed
                )
                : SwapEngine.desktopReloadSummary(
                    from: discovery,
                    acknowledgedPIDs: execution.acknowledgedPIDs,
                    operationFailed: execution.operationFailed
                )
            #expect(summary.operationFailed)
            #expect(summary.outcome == .restartRequiredOrFailed)
        }
    }

    @Test("pgrep discovery sanitizes mixed valid and malformed rows")
    func pgrepDiscoverySanitizesMixedRows() {
        let output = """
        42 /usr/local/bin/codex resume thread-1
        43
        not-a-pgrep-line
        44 /opt/homebrew/bin/codex resume thread-2
        45 /usr/bin/python3 /tmp/codex-observer.py
        """
        let result = SwapEngine.pgrepDiscoveryResult(
            stdout: Data(output.utf8),
            terminationStatus: 0,
            timedOut: false
        )

        #expect(result == .snapshot(CodexPGrepProcessSnapshot(
            pids: [42, 44, 45],
            isComplete: false
        )))
    }

    @Test("pgrep discovery rejects status zero snapshots with no usable rows")
    func pgrepDiscoveryRejectsAllMalformedRows() {
        let output = """
        42
        not-a-pgrep-line
        0 /usr/local/bin/codex
        2147483648 /opt/homebrew/bin/codex
        """

        let result = SwapEngine.pgrepDiscoveryResult(
            stdout: Data(output.utf8),
            terminationStatus: 0,
            timedOut: false
        )
        #expect(result == .failed("malformed_output"))

        var processReads = 0
        let discovery = SwapEngine.runtimeDiscoverySnapshot(
            from: result,
            runtimeKind: .localInteractiveCLI,
            requiredOwnerUID: 501,
            identityProvider: { _ in
                processReads += 1
                return nil
            },
            argumentProvider: { _ in
                processReads += 1
                return nil
            },
            kernelExecutableIdentityProvider: { _ in
                processReads += 1
                return nil
            }
        )
        var signaledPIDs: [Int32] = []
        let execution = SwapEngine.executeReloadBatch(
            preliminaryPIDs: [],
            discoveryProvider: { discovery },
            requiredOwnerUID: 501,
            candidateIsEligible: { _ in true },
            makeBinding: { reloadBinding(target: $0) },
            hotSwapSupport: { _ in true },
            bindingIsCurrent: { _ in true },
            persistRequest: { _ in true },
            signal: { pid in
                signaledPIDs.append(pid)
                return true
            },
            awaitAcknowledgements: { _ in [] },
            gate: CodexReloadAttemptGate()
        )

        #expect(!discovery.isComplete)
        #expect(processReads == 0)
        #expect(signaledPIDs.isEmpty)
        #expect(execution.operationFailed)
    }

    @Test("pgrep discovery enforces status zero and one semantics")
    func pgrepDiscoveryEnforcesTerminationStatus() {
        #expect(SwapEngine.pgrepDiscoveryResult(
            stdout: Data(),
            terminationStatus: 0,
            timedOut: true
        ) == .failed("timeout"))
        #expect(SwapEngine.pgrepDiscoveryResult(
            stdout: Data(),
            terminationStatus: 2,
            timedOut: false
        ) == .failed("status_2"))
        #expect(SwapEngine.pgrepDiscoveryResult(
            stdout: Data(),
            terminationStatus: 0,
            timedOut: false
        ) == .failed("status_0_without_output"))
        #expect(SwapEngine.pgrepDiscoveryResult(
            stdout: Data(),
            terminationStatus: 1,
            timedOut: false
        ) == .noMatches)
        #expect(SwapEngine.pgrepDiscoveryResult(
            stdout: Data(" \t\n".utf8),
            terminationStatus: 1,
            timedOut: false
        ) == .noMatches)
        #expect(SwapEngine.pgrepDiscoveryResult(
            stdout: Data("42 /usr/local/bin/codex\n".utf8),
            terminationStatus: 1,
            timedOut: false
        ) == .failed("status_1_with_output"))
    }

    @Test("pgrep discovery rejects invalid UTF-8 for status zero or one")
    func pgrepDiscoveryRejectsInvalidUTF8() {
        var output = Data("42 /usr/local/bin/codex\n".utf8)
        output.append(0xff)

        #expect(SwapEngine.pgrepDiscoveryResult(
            stdout: output,
            terminationStatus: 0,
            timedOut: false
        ) == .failed("invalid_utf8"))
        #expect(SwapEngine.pgrepDiscoveryResult(
            stdout: output,
            terminationStatus: 1,
            timedOut: false
        ) == .failed("invalid_utf8"))
    }

    @Test("pgrep discovery deduplicates exact rows and quarantines ambiguous PIDs")
    func pgrepDiscoveryHandlesDuplicatePIDs() {
        let duplicateOutput = "\n\t42   /usr/local/bin/codex resume thread-1  \r\n"
            + "42\t/usr/local/bin/codex resume thread-1\n\n"

        #expect(SwapEngine.pgrepDiscoveryResult(
            stdout: Data(duplicateOutput.utf8),
            terminationStatus: 0,
            timedOut: false
        ) == .snapshot(CodexPGrepProcessSnapshot(pids: [42], isComplete: true)))

        let sameExecutableDifferentArguments = """
        42 /usr/local/bin/codex resume thread-1
        42 /usr/local/bin/codex resume thread-2
        43 /opt/homebrew/bin/codex resume thread-3
        """
        #expect(SwapEngine.pgrepDiscoveryResult(
            stdout: Data(sameExecutableDifferentArguments.utf8),
            terminationStatus: 0,
            timedOut: false
        ) == .snapshot(CodexPGrepProcessSnapshot(pids: [43], isComplete: false)))

        let differentExecutables = """
        42 /usr/local/bin/codex resume thread-1
        42 /opt/homebrew/bin/codex resume thread-2
        43 /opt/homebrew/bin/codex resume thread-3
        """
        #expect(SwapEngine.pgrepDiscoveryResult(
            stdout: Data(differentExecutables.utf8),
            terminationStatus: 0,
            timedOut: false
        ) == .snapshot(CodexPGrepProcessSnapshot(pids: [43], isComplete: false)))

        let onlyDifferentArguments = """
        42 /usr/local/bin/codex resume thread-1
        42 /usr/local/bin/codex resume thread-2
        """
        #expect(SwapEngine.pgrepDiscoveryResult(
            stdout: Data(onlyDifferentArguments.utf8),
            terminationStatus: 0,
            timedOut: false
        ) == .failed("malformed_output"))

        let onlyDifferentExecutables = """
        42 /usr/local/bin/codex resume thread-1
        42 /opt/homebrew/bin/codex resume thread-2
        """
        #expect(SwapEngine.pgrepDiscoveryResult(
            stdout: Data(onlyDifferentExecutables.utf8),
            terminationStatus: 0,
            timedOut: false
        ) == .failed("malformed_output"))
    }

    @Test("Complete reload ACK binding rejects every identity and authority drift")
    func completeReloadBindingRejectsIdentityAndAuthorityDrift() {
        let target = runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI)
        let binding = reloadBinding(target: target)
        let artifacts = artifactSnapshots(binding: binding)
        let now: Int64 = 1_500_200

        #expect(SwapEngine.validatedReloadAcknowledgement(
            request: artifacts.0,
            acknowledgement: artifacts.1,
            currentBinding: binding,
            expectedBinding: binding,
            nowUnixMilliseconds: now
        ) == acknowledgement(binding: binding))

        let staleStart = reloadBinding(target: target, startSeconds: 1_001)
        let wrongPath = reloadBinding(target: target, authPath: "/tmp/auth.json")
        let fingerprintDrift = reloadBinding(
            target: target,
            tokenFingerprint: String(repeating: "b", count: 64)
        )
        let accountDrift = reloadBinding(target: target, accountID: "account-2")
        let authDeviceDrift = reloadBinding(
            target: target,
            authDevice: binding.authFileIdentity.device + 1
        )
        let authInodeDrift = reloadBinding(
            target: target,
            authInode: binding.authFileIdentity.inode + 1
        )
        let executableDrift = reloadBinding(target: target, executablePath: "/tmp/codex")
        let deviceDrift = reloadBinding(
            target: target,
            executableDevice: binding.kernelExecutableIdentity.device + 1
        )
        let inodeDrift = reloadBinding(
            target: target,
            executableInode: binding.kernelExecutableIdentity.inode + 1
        )
        let runtimeDrift = reloadBinding(target: target, runtimeKind: .externalAppServer)
        for changed in [
            staleStart,
            wrongPath,
            fingerprintDrift,
            accountDrift,
            authDeviceDrift,
            authInodeDrift,
            executableDrift,
            deviceDrift,
            inodeDrift,
            runtimeDrift,
        ] {
            #expect(SwapEngine.validatedReloadAcknowledgement(
                request: artifacts.0,
                acknowledgement: artifacts.1,
                currentBinding: changed,
                expectedBinding: nil,
                nowUnixMilliseconds: now
            ) == nil)
        }

        let wrongNonce = reloadBinding(target: target, requestNonce: "wrong-nonce")
        let wrongNonceArtifacts = artifactSnapshots(binding: wrongNonce)
        #expect(SwapEngine.validatedReloadAcknowledgement(
            request: wrongNonceArtifacts.0,
            acknowledgement: wrongNonceArtifacts.1,
            currentBinding: binding,
            expectedBinding: binding,
            nowUnixMilliseconds: now
        ) == nil)

        for structurallyInvalid in [
            reloadBinding(target: target, authDevice: 0),
            reloadBinding(target: target, authInode: 0),
        ] {
            let invalidArtifacts = artifactSnapshots(binding: structurallyInvalid)
            #expect(SwapEngine.validatedReloadAcknowledgement(
                request: invalidArtifacts.0,
                acknowledgement: invalidArtifacts.1,
                currentBinding: structurallyInvalid,
                expectedBinding: structurallyInvalid,
                nowUnixMilliseconds: now
            ) == nil)
        }
    }

    @Test("External ACK distinguishes an idle listener from failed frontend delivery")
    func externalAcknowledgementDistinguishesIdleListenerFromFailedDelivery() {
        let target = runtimeTarget(pid: 41, runtimeKind: .headlessRemoteControlAppServer)
        let binding = reloadBinding(target: target)
        let now: Int64 = 1_500_200
        let candidate = {
            (
                initialized: Int?,
                eligible: Int?,
                notified: Bool,
                completed: Int,
                idle: Bool
            ) in
            CodexReloadAcknowledgement(
                binding: binding,
                acknowledgedAtUnixMilliseconds: 1_500_100,
                loadedTokenFingerprint: binding.authFileIdentity.completeTokenFingerprint,
                activeTokenFingerprint: binding.authFileIdentity.completeTokenFingerprint,
                frontendNotified: notified,
                frontendWriteCount: completed,
                authGeneration: 7,
                reconnectReady: nil,
                initializedFrontendCount: initialized,
                eligibleFrontendCount: eligible,
                idleListenerReady: idle
            )
        }
        let isValid = { (acknowledgement: CodexReloadAcknowledgement) in
            let artifacts = artifactSnapshots(
                binding: binding,
                acknowledgement: acknowledgement
            )
            return SwapEngine.validatedReloadAcknowledgement(
                request: artifacts.0,
                acknowledgement: artifacts.1,
                currentBinding: binding,
                expectedBinding: binding,
                nowUnixMilliseconds: now
            ) != nil
        }

        #expect(isValid(candidate(0, 0, false, 0, true)))
        #expect(isValid(candidate(2, 2, true, 1, false)))
        #expect(!isValid(candidate(nil, nil, true, 1, false)))
        #expect(!isValid(candidate(nil, 2, true, 1, false)))
        #expect(!isValid(candidate(2, nil, true, 1, false)))
        #expect(!isValid(candidate(1, 2, true, 1, false)))
        #expect(!isValid(candidate(nil, nil, false, 0, true)))
        #expect(!isValid(candidate(1, 1, false, 0, true)))
        #expect(!isValid(candidate(0, 1, false, 0, true)))
        #expect(!isValid(candidate(0, 0, false, 0, false)))
        #expect(!isValid(candidate(1, 1, false, 0, false)))
        #expect(!isValid(candidate(1, 1, true, 2, false)))

        let strictTarget = runtimeTarget(pid: 42, runtimeKind: .externalAppServer)
        let strictBinding = reloadBinding(target: strictTarget)
        let strictLegacyArtifacts = artifactSnapshots(binding: strictBinding)
        #expect(SwapEngine.validatedReloadAcknowledgement(
            request: strictLegacyArtifacts.0,
            acknowledgement: strictLegacyArtifacts.1,
            currentBinding: strictBinding,
            expectedBinding: strictBinding,
            nowUnixMilliseconds: now
        ) != nil)

        let strictIdle = CodexReloadAcknowledgement(
            binding: strictBinding,
            acknowledgedAtUnixMilliseconds: 1_500_100,
            loadedTokenFingerprint: strictBinding.authFileIdentity.completeTokenFingerprint,
            activeTokenFingerprint: strictBinding.authFileIdentity.completeTokenFingerprint,
            frontendNotified: false,
            frontendWriteCount: 0,
            authGeneration: 7,
            reconnectReady: nil,
            initializedFrontendCount: 0,
            eligibleFrontendCount: 0,
            idleListenerReady: true
        )
        let strictArtifacts = artifactSnapshots(
            binding: strictBinding,
            acknowledgement: strictIdle
        )
        #expect(SwapEngine.validatedReloadAcknowledgement(
            request: strictArtifacts.0,
            acknowledgement: strictArtifacts.1,
            currentBinding: strictBinding,
            expectedBinding: strictBinding,
            nowUnixMilliseconds: now
        ) == nil)
    }

    @Test("Reload artifacts reject stale and future authority")
    func reloadArtifactsRejectStaleAndFutureAuthority() {
        let target = runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI)
        let binding = reloadBinding(target: target)
        let now: Int64 = 1_500_200

        let stale = artifactSnapshots(
            binding: binding,
            requestModifiedAt: 1_400_000,
            acknowledgementModifiedAt: 1_400_100
        )
        #expect(SwapEngine.validatedReloadAcknowledgement(
            request: stale.0,
            acknowledgement: stale.1,
            currentBinding: binding,
            expectedBinding: binding,
            nowUnixMilliseconds: now,
            maximumArtifactAgeMilliseconds: 1_000,
            maximumFutureSkewMilliseconds: 10
        ) == nil)

        let future = artifactSnapshots(
            binding: binding,
            requestModifiedAt: now + 11,
            acknowledgementModifiedAt: now + 12
        )
        #expect(SwapEngine.validatedReloadAcknowledgement(
            request: future.0,
            acknowledgement: future.1,
            currentBinding: binding,
            expectedBinding: binding,
            nowUnixMilliseconds: now,
            maximumArtifactAgeMilliseconds: 1_000,
            maximumFutureSkewMilliseconds: 10
        ) == nil)

        let futureBinding = reloadBinding(
            target: target,
            issuedAtUnixMilliseconds: now + 11
        )
        let futureBindingArtifacts = artifactSnapshots(
            binding: futureBinding,
            acknowledgement: acknowledgement(
                binding: futureBinding,
                acknowledgedAtUnixMilliseconds: now + 12
            ),
            requestModifiedAt: now,
            acknowledgementModifiedAt: now
        )
        #expect(SwapEngine.validatedReloadAcknowledgement(
            request: futureBindingArtifacts.0,
            acknowledgement: futureBindingArtifacts.1,
            currentBinding: futureBinding,
            expectedBinding: futureBinding,
            nowUnixMilliseconds: now,
            maximumArtifactAgeMilliseconds: 1_000,
            maximumFutureSkewMilliseconds: 10
        ) == nil)

        let issuedBeforeStart = reloadBinding(
            target: target,
            issuedAtUnixMilliseconds: 1_500_000,
            startSeconds: 1_600
        )
        let issuedBeforeStartArtifacts = artifactSnapshots(binding: issuedBeforeStart)
        #expect(SwapEngine.validatedReloadAcknowledgement(
            request: issuedBeforeStartArtifacts.0,
            acknowledgement: issuedBeforeStartArtifacts.1,
            currentBinding: issuedBeforeStart,
            expectedBinding: issuedBeforeStart,
            nowUnixMilliseconds: now,
            maximumArtifactAgeMilliseconds: 1_000,
            maximumFutureSkewMilliseconds: 10
        ) == nil)
    }

    @Test("Read-only runtime evidence fails closed on any incomplete proof")
    func localRuntimeEvidenceSnapshotIsTypedAndFailClosed() {
        let target = runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI)
        let discovery = CodexRuntimeDiscoverySnapshot(targets: [target], isComplete: true)
        let binding = reloadBinding(target: target)
        let observation = CodexRuntimeObservation(
            target: target,
            authFileIdentity: binding.authFileIdentity
        )
        let ack = acknowledgement(binding: binding)
        var currentChecks = 0

        let complete = SwapEngine.localRuntimeEvidenceSnapshot(
            discoverySnapshot: discovery,
            observationProvider: { $0 == target ? observation : nil },
            startupAcknowledgementProvider: { $0 == observation ? ack : nil },
            observationIsCurrent: { candidate in
                currentChecks += 1
                return candidate == observation
            }
        )
        #expect(complete.isComplete)
        #expect(complete.runtimes == [CodexLocalRuntimeEvidence(
            observation: observation,
            startupAcknowledgement: ack
        )])
        #expect(currentChecks == 2)

        currentChecks = 0
        let changedDuringAcceptance = SwapEngine.localRuntimeEvidenceSnapshot(
            discoverySnapshot: discovery,
            observationProvider: { _ in observation },
            startupAcknowledgementProvider: { _ in ack },
            observationIsCurrent: { _ in
                currentChecks += 1
                return currentChecks == 1
            }
        )
        #expect(!changedDuringAcceptance.isComplete)
        #expect(changedDuringAcceptance.runtimes.isEmpty)

        var providersCalled = false
        let incomplete = SwapEngine.localRuntimeEvidenceSnapshot(
            discoverySnapshot: CodexRuntimeDiscoverySnapshot(
                targets: [target],
                isComplete: false
            ),
            observationProvider: { _ in
                providersCalled = true
                return observation
            },
            startupAcknowledgementProvider: { _ in
                providersCalled = true
                return ack
            },
            observationIsCurrent: { _ in
                providersCalled = true
                return true
            }
        )
        #expect(!incomplete.isComplete)
        #expect(incomplete.runtimes.isEmpty)
        #expect(!providersCalled)
    }

    @Test("Status evidence rejects argv runtime-kind drift during ACK acceptance")
    func runtimeEvidenceAcceptanceReclassifiesCurrentArguments() {
        let target = runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI)
        let discovery = CodexRuntimeDiscoverySnapshot(targets: [target], isComplete: true)
        let binding = reloadBinding(target: target)
        let observation = CodexRuntimeObservation(
            target: target,
            authFileIdentity: binding.authFileIdentity
        )
        let ack = acknowledgement(binding: binding)
        var validationCount = 0

        let snapshot = SwapEngine.localRuntimeEvidenceSnapshot(
            discoverySnapshot: discovery,
            observationProvider: { _ in observation },
            startupAcknowledgementProvider: { _ in ack },
            observationIsCurrent: { candidate in
                validationCount += 1
                let arguments = validationCount == 1
                    ? ["codex", "resume", "thread-41"]
                    : ["codex", "app-server"]
                return SwapEngine.runtimeObservationIsCurrent(
                    candidate,
                    requiredOwnerUID: 501,
                    identityProvider: { _ in binding.processIdentity },
                    argumentProvider: { _ in arguments },
                    kernelExecutableIdentityProvider: { _ in binding.kernelExecutableIdentity },
                    authFileIdentityProvider: { _, _ in binding.authFileIdentity }
                )
            }
        )

        #expect(validationCount == 2)
        #expect(!snapshot.isComplete)
        #expect(snapshot.runtimes.isEmpty)
    }

    @Test("Structured request persistence writes the complete binding")
    func structuredRequestPersistenceWritesCompleteBinding() throws {
        let fileManager = FileManager.default
        let home = try makeSecureTestDirectoryURL(prefix: "codexswitch-binding")
        defer { try? fileManager.removeItem(at: home) }
        let root = home.appendingPathComponent(".codexswitch", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let binding = reloadBinding(
            target: runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI)
        )
        #expect(SwapEngine.persistReloadRequest(
            binding,
            homeDirectory: home,
            bindingIsCurrent: { $0 == binding }
        ))

        let requestURL = root
            .appendingPathComponent("hotswap-request", isDirectory: true)
            .appendingPathComponent("41.json")
        let artifact = try JSONDecoder().decode(
            CodexReloadRequestArtifact.self,
            from: Data(contentsOf: requestURL)
        )
        let attributes = try fileManager.attributesOfItem(atPath: requestURL.path)
        #expect(artifact.binding == binding)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!fileManager.fileExists(atPath: requestURL.deletingPathExtension().path + ".nonce"))
    }

    @Test("Request binding drift after lock leaves the request unchanged and suppresses signal")
    func requestWriteRevalidatesInsideExclusiveLock() throws {
        let fileManager = FileManager.default
        let home = try makeSecureTestDirectoryURL(prefix: "codexswitch-request-drift")
        defer { try? fileManager.removeItem(at: home) }
        let root = home.appendingPathComponent(".codexswitch", isDirectory: true)
        let requestDirectory = root.appendingPathComponent("hotswap-request", isDirectory: true)
        try fileManager.createDirectory(at: requestDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: requestDirectory.path)

        let target = runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI)
        let binding = reloadBinding(target: target, requestNonce: "locked-drift")
        let requestURL = requestDirectory.appendingPathComponent("41.json")
        let sentinel = Data("existing-request".utf8)
        try sentinel.write(to: requestURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
        let attributesBefore = try fileManager.attributesOfItem(atPath: requestURL.path)
        let events = LockedTestState<[String]>([])
        let signaledPIDs = LockedTestState<[Int32]>([])
        let acknowledgementWaits = LockedTestState(0)

        let execution = SwapEngine.executeReloadBatch(
            preliminaryPIDs: [41],
            discoveryProvider: {
                CodexRuntimeDiscoverySnapshot(targets: [target], isComplete: true)
            },
            requiredOwnerUID: 501,
            candidateIsEligible: { _ in true },
            makeBinding: { _ in binding },
            hotSwapSupport: { _ in true },
            bindingIsCurrent: { _ in true },
            persistRequest: { candidate in
                SwapEngine.persistReloadRequest(
                    candidate,
                    homeDirectory: home,
                    bindingIsCurrent: { _ in
                        events.update { $0.append("revalidated") }
                        return false
                    },
                    transactionTestHooks: .init(afterLock: {
                        events.update { $0.append("locked") }
                    })
                )
            },
            signal: { pid in
                signaledPIDs.update { $0.append(pid) }
                return true
            },
            awaitAcknowledgements: { _ in
                acknowledgementWaits.update { $0 += 1 }
                return []
            },
            gate: CodexReloadAttemptGate()
        )

        let attributesAfter = try fileManager.attributesOfItem(atPath: requestURL.path)
        #expect(events.read() == ["locked", "revalidated"])
        #expect(try Data(contentsOf: requestURL) == sentinel)
        #expect((attributesAfter[.systemNumber] as? NSNumber) == (attributesBefore[.systemNumber] as? NSNumber))
        #expect((attributesAfter[.systemFileNumber] as? NSNumber) == (attributesBefore[.systemFileNumber] as? NSNumber))
        #expect((attributesAfter[.size] as? NSNumber) == (attributesBefore[.size] as? NSNumber))
        #expect((attributesAfter[.modificationDate] as? Date) == (attributesBefore[.modificationDate] as? Date))
        #expect(signaledPIDs.read().isEmpty)
        #expect(acknowledgementWaits.read() == 0)
        #expect(execution.acknowledgedPIDs.isEmpty)
        #expect(execution.operationFailed)
    }

    @Test("Auth evidence is complete, bounded, mode checked, and no-follow")
    func authEvidenceUsesSecureCompleteTokenFingerprint() throws {
        let fileManager = FileManager.default
        let home = try makeSecureTestDirectoryURL(prefix: "codexswitch-auth-evidence")
        defer { try? fileManager.removeItem(at: home) }
        let authDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try fileManager.createDirectory(at: authDirectory, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: authDirectory.path)
        let authURL = authDirectory.appendingPathComponent("auth.json")
        let auth = AuthFile(
            authMode: "chatgpt",
            openaiApiKey: nil,
            tokens: AuthTokens(
                idToken: "id",
                accessToken: "access",
                refreshToken: "refresh",
                accountId: "account"
            ),
            lastRefresh: "2026-07-13T00:00:00Z"
        )
        let authData = try JSONEncoder().encode(auth)
        try authData.write(to: authURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

        let identity = try #require(SwapEngine.authFileIdentity(
            at: authURL,
            requiredOwnerUID: UInt32(getuid())
        ))
        #expect(identity.canonicalPath == authURL.path)
        #expect(identity.device > 0)
        #expect(identity.inode > 0)
        #expect(identity.accountID == "account")
        #expect(identity.completeTokenFingerprint.count == 64)
        #expect(SwapEngine.secureFileSnapshot(
            at: authURL.path,
            maximumBytes: authData.count - 1,
            requiredOwnerUID: UInt32(getuid())
        ) == nil)

        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: authURL.path)
        #expect(SwapEngine.authFileIdentity(
            at: authURL,
            requiredOwnerUID: UInt32(getuid())
        ) == nil)
        try fileManager.removeItem(at: authURL)

        let target = home.appendingPathComponent("target-auth.json")
        try authData.write(to: target)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try fileManager.createSymbolicLink(at: authURL, withDestinationURL: target)
        #expect(SwapEngine.authFileIdentity(
            at: authURL,
            requiredOwnerUID: UInt32(getuid())
        ) == nil)
    }

    @Test("Identical auth replacement inode fails signaling ACKs and evidence")
    func identicalAuthReplacementFailsEveryAuthorizationPath() throws {
        let fileManager = FileManager.default
        let home = try makeSecureTestDirectoryURL(prefix: "codexswitch-auth-inode")
        defer { try? fileManager.removeItem(at: home) }
        let authDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try fileManager.createDirectory(at: authDirectory, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: authDirectory.path)

        let authURL = authDirectory.appendingPathComponent("auth.json")
        let replacementURL = authDirectory.appendingPathComponent("replacement.json")
        let oldInodeKeeperURL = authDirectory.appendingPathComponent("old-auth.keep")
        let authData = try JSONEncoder().encode(AuthFile(
            authMode: "chatgpt",
            openaiApiKey: nil,
            tokens: AuthTokens(
                idToken: "id",
                accessToken: "access",
                refreshToken: "refresh",
                accountId: "account"
            ),
            lastRefresh: "2026-07-13T00:00:00Z"
        ))
        try authData.write(to: authURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        let oldAuth = try #require(SwapEngine.authFileIdentity(
            at: authURL,
            requiredOwnerUID: UInt32(getuid())
        ))

        try #require(Darwin.link(authURL.path, oldInodeKeeperURL.path) == 0)
        try authData.write(to: replacementURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: replacementURL.path
        )
        try #require(Darwin.rename(replacementURL.path, authURL.path) == 0)
        let currentAuth = try #require(SwapEngine.authFileIdentity(
            at: authURL,
            requiredOwnerUID: UInt32(getuid())
        ))

        #expect(currentAuth.completeTokenFingerprint == oldAuth.completeTokenFingerprint)
        #expect(currentAuth.device == oldAuth.device)
        #expect(currentAuth.inode != oldAuth.inode)

        let ownerUID = UInt32(getuid())
        let target = runtimeTarget(
            pid: 41,
            runtimeKind: .localInteractiveCLI,
            ownerUID: ownerUID
        )
        let oldBinding = reloadBinding(
            target: target,
            authPath: oldAuth.canonicalPath,
            authDevice: oldAuth.device,
            authInode: oldAuth.inode,
            accountID: oldAuth.accountID,
            tokenFingerprint: oldAuth.completeTokenFingerprint
        )
        let currentBinding = reloadBinding(
            target: target,
            authPath: currentAuth.canonicalPath,
            authDevice: currentAuth.device,
            authInode: currentAuth.inode,
            accountID: currentAuth.accountID,
            tokenFingerprint: currentAuth.completeTokenFingerprint
        )

        func bindingIsCurrent(_ binding: CodexReloadBinding) -> Bool {
            SwapEngine.reloadBindingIsCurrent(
                binding,
                identityProvider: { _ in binding.processIdentity },
                argumentProvider: { _ in target.process.arguments },
                kernelExecutableIdentityProvider: { _ in binding.kernelExecutableIdentity },
                authFileIdentityProvider: { path, ownerUID in
                    SwapEngine.authFileIdentity(
                        at: URL(fileURLWithPath: path),
                        requiredOwnerUID: ownerUID
                    )
                }
            )
        }

        #expect(!bindingIsCurrent(oldBinding))
        #expect(bindingIsCurrent(currentBinding))

        var signaledPIDs: [Int32] = []
        let execution = SwapEngine.executeReloadBatch(
            preliminaryPIDs: [41],
            discoveryProvider: {
                CodexRuntimeDiscoverySnapshot(targets: [target], isComplete: true)
            },
            requiredOwnerUID: ownerUID,
            candidateIsEligible: { _ in true },
            makeBinding: { _ in oldBinding },
            hotSwapSupport: { _ in true },
            bindingIsCurrent: bindingIsCurrent,
            persistRequest: { _ in true },
            signal: { pid in
                signaledPIDs.append(pid)
                return true
            },
            awaitAcknowledgements: { _ in [] },
            gate: CodexReloadAttemptGate()
        )
        #expect(execution.operationFailed)
        #expect(signaledPIDs.isEmpty)

        let artifacts = artifactSnapshots(binding: oldBinding)
        let startupAcknowledgement = SwapEngine.validatedReloadAcknowledgement(
            request: artifacts.0,
            acknowledgement: artifacts.1,
            currentBinding: currentBinding,
            expectedBinding: nil,
            nowUnixMilliseconds: 1_500_200
        )
        let responseAcknowledgement = SwapEngine.validatedReloadAcknowledgement(
            request: artifacts.0,
            acknowledgement: artifacts.1,
            currentBinding: currentBinding,
            expectedBinding: oldBinding,
            nowUnixMilliseconds: 1_500_200
        )
        #expect(startupAcknowledgement == nil)
        #expect(responseAcknowledgement == nil)

        let oldObservation = CodexRuntimeObservation(
            target: target,
            authFileIdentity: oldAuth
        )
        let evidence = SwapEngine.localRuntimeEvidenceSnapshot(
            discoverySnapshot: CodexRuntimeDiscoverySnapshot(
                targets: [target],
                isComplete: true
            ),
            observationProvider: { _ in oldObservation },
            startupAcknowledgementProvider: { _ in self.acknowledgement(binding: oldBinding) },
            observationIsCurrent: { observation in
                SwapEngine.runtimeObservationIsCurrent(
                    observation,
                    requiredOwnerUID: ownerUID,
                    identityProvider: { _ in observation.target.process.identity },
                    argumentProvider: { _ in observation.target.process.arguments },
                    kernelExecutableIdentityProvider: { _ in
                        observation.target.process.kernelExecutableIdentity
                    },
                    authFileIdentityProvider: { path, ownerUID in
                        SwapEngine.authFileIdentity(
                            at: URL(fileURLWithPath: path),
                            requiredOwnerUID: ownerUID
                        )
                    }
                )
            }
        )
        #expect(!evidence.isComplete)
        #expect(evidence.runtimes.isEmpty)
    }

    @Test("Reload gate excludes same-PID overlap and permits disjoint PIDs")
    func reloadGateSerializesPerPID() {
        let gate = CodexReloadAttemptGate()
        let firstPID = Set<Int32>([41])
        let secondPID = Set<Int32>([42])

        #expect(gate.tryAcquire(firstPID))
        #expect(!gate.tryAcquire(firstPID))
        #expect(gate.tryAcquire(secondPID))
        gate.release(firstPID)
        #expect(gate.tryAcquire(firstPID))
        gate.release(firstPID.union(secondPID))
    }

    @Test("Same-PID admission blocks competing discovery through ACK completion")
    func overlappingReloadBatchesSerializeSamePIDThroughAck() {
        let target = runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI)
        let discovery = CodexRuntimeDiscoverySnapshot(targets: [target], isComplete: true)
        let firstBinding = reloadBinding(target: target, requestNonce: "first")
        let secondBinding = reloadBinding(target: target, requestNonce: "second")
        let firstEnteredACK = TestSemaphore()
        let releaseFirstACK = TestSemaphore()
        let secondContended = TestSemaphore()
        let firstFinished = TestSemaphore()
        let secondFinished = TestSemaphore()
        let secondEvents = LockedTestState<[String]>([])
        let firstResult = LockedTestState<CodexReloadExecutionResult?>(nil)
        let secondResult = LockedTestState<CodexReloadExecutionResult?>(nil)
        let gate = CodexReloadAttemptGate { _ in secondContended.signal() }

        DispatchQueue(label: "SwapEngineTests.samePID.first").async {
            let result = SwapEngine.executeReloadBatch(
                preliminaryPIDs: [41],
                discoveryProvider: { discovery },
                requiredOwnerUID: 501,
                candidateIsEligible: { _ in true },
                makeBinding: { _ in firstBinding },
                hotSwapSupport: { _ in true },
                bindingIsCurrent: { _ in true },
                persistRequest: { _ in true },
                signal: { _ in true },
                awaitAcknowledgements: { bindings in
                    firstEnteredACK.signal()
                    releaseFirstACK.wait()
                    return Set(bindings.map { $0.processIdentity.pid })
                },
                gate: gate
            )
            firstResult.update { $0 = result }
            firstFinished.signal()
        }

        #expect(firstEnteredACK.wait(timeout: .now() + 2) == .success)
        DispatchQueue(label: "SwapEngineTests.samePID.second").async {
            let result = SwapEngine.executeReloadBatch(
                preliminaryPIDs: [41],
                discoveryProvider: {
                    secondEvents.update { $0.append("discovery") }
                    return discovery
                },
                requiredOwnerUID: 501,
                candidateIsEligible: { _ in true },
                makeBinding: { _ in
                    secondEvents.update { $0.append("binding") }
                    return secondBinding
                },
                hotSwapSupport: { _ in true },
                bindingIsCurrent: { _ in true },
                persistRequest: { _ in
                    secondEvents.update { $0.append("request") }
                    return true
                },
                signal: { _ in
                    secondEvents.update { $0.append("signal") }
                    return true
                },
                awaitAcknowledgements: { bindings in
                    secondEvents.update { $0.append("ack") }
                    return Set(bindings.map { $0.processIdentity.pid })
                },
                gate: gate
            )
            secondResult.update { $0 = result }
            secondFinished.signal()
        }

        #expect(secondContended.wait(timeout: .now() + 2) == .success)
        #expect(secondEvents.read().isEmpty)
        releaseFirstACK.signal()
        #expect(firstFinished.wait(timeout: .now() + 2) == .success)
        #expect(secondFinished.wait(timeout: .now() + 2) == .success)
        #expect(firstResult.read()?.acknowledgedPIDs == [41])
        #expect(secondResult.read()?.acknowledgedPIDs == [41])
        #expect(secondEvents.read() == ["discovery", "binding", "request", "signal", "ack"])
    }

    @Test("Partially overlapping PID sets remain serialized through ACK completion")
    func overlappingReloadBatchesSerializeSharedPIDThroughAck() {
        let firstTargets = [
            runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI),
            runtimeTarget(pid: 42, runtimeKind: .localInteractiveCLI),
        ]
        let secondTargets = [
            runtimeTarget(pid: 42, runtimeKind: .localInteractiveCLI),
            runtimeTarget(pid: 43, runtimeKind: .localInteractiveCLI),
        ]
        let firstBindings = Dictionary(uniqueKeysWithValues: firstTargets.map {
            ($0.process.identity.pid, reloadBinding(target: $0, requestNonce: "first-\($0.process.identity.pid)"))
        })
        let secondBindings = Dictionary(uniqueKeysWithValues: secondTargets.map {
            ($0.process.identity.pid, reloadBinding(target: $0, requestNonce: "second-\($0.process.identity.pid)"))
        })
        let firstEnteredACK = TestSemaphore()
        let releaseFirstACK = TestSemaphore()
        let secondContended = TestSemaphore()
        let firstFinished = TestSemaphore()
        let secondFinished = TestSemaphore()
        let firstSignals = LockedTestState<[Int32]>([])
        let secondSignals = LockedTestState<[Int32]>([])
        let gate = CodexReloadAttemptGate { pids in
            if pids == Set<Int32>([42, 43]) { secondContended.signal() }
        }

        DispatchQueue(label: "SwapEngineTests.sharedPID.first").async {
            _ = SwapEngine.executeReloadBatch(
                preliminaryPIDs: [41, 42],
                discoveryProvider: {
                    CodexRuntimeDiscoverySnapshot(
                        targets: firstTargets,
                        isComplete: true
                    )
                },
                requiredOwnerUID: 501,
                candidateIsEligible: { _ in true },
                makeBinding: { firstBindings[$0.process.identity.pid] },
                hotSwapSupport: { _ in true },
                bindingIsCurrent: { _ in true },
                persistRequest: { _ in true },
                signal: { pid in
                    firstSignals.update { $0.append(pid) }
                    return true
                },
                awaitAcknowledgements: { bindings in
                    firstEnteredACK.signal()
                    releaseFirstACK.wait()
                    return Set(bindings.map { $0.processIdentity.pid })
                },
                gate: gate
            )
            firstFinished.signal()
        }

        #expect(firstEnteredACK.wait(timeout: .now() + 2) == .success)
        DispatchQueue(label: "SwapEngineTests.sharedPID.second").async {
            _ = SwapEngine.executeReloadBatch(
                preliminaryPIDs: [42, 43],
                discoveryProvider: {
                    CodexRuntimeDiscoverySnapshot(
                        targets: secondTargets,
                        isComplete: true
                    )
                },
                requiredOwnerUID: 501,
                candidateIsEligible: { _ in true },
                makeBinding: { secondBindings[$0.process.identity.pid] },
                hotSwapSupport: { _ in true },
                bindingIsCurrent: { _ in true },
                persistRequest: { _ in true },
                signal: { pid in
                    secondSignals.update { $0.append(pid) }
                    return true
                },
                awaitAcknowledgements: { bindings in
                    Set(bindings.map { $0.processIdentity.pid })
                },
                gate: gate
            )
            secondFinished.signal()
        }

        #expect(secondContended.wait(timeout: .now() + 2) == .success)
        #expect(firstSignals.read() == [41, 42])
        #expect(secondSignals.read().isEmpty)
        releaseFirstACK.signal()
        #expect(firstFinished.wait(timeout: .now() + 2) == .success)
        #expect(secondFinished.wait(timeout: .now() + 2) == .success)
        #expect(secondSignals.read() == [42, 43])
    }

    @Test("All verified targets are signaled before one aggregate ACK wait")
    func reloadBatchSignalsAllTargetsBeforeWaiting() {
        let targets = [
            runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI),
            runtimeTarget(pid: 42, runtimeKind: .localInteractiveCLI),
        ]
        let discovery = CodexRuntimeDiscoverySnapshot(targets: targets, isComplete: true)
        let gate = CodexReloadAttemptGate()
        var signaledPIDs: [Int32] = []
        var waitCalls = 0

        let execution = SwapEngine.executeReloadBatch(
            preliminaryPIDs: [41, 42],
            discoveryProvider: { discovery },
            requiredOwnerUID: 501,
            candidateIsEligible: { _ in true },
            makeBinding: { reloadBinding(target: $0) },
            hotSwapSupport: { $0.runtimeKind == .localInteractiveCLI },
            bindingIsCurrent: { _ in true },
            persistRequest: { _ in true },
            signal: { pid in
                signaledPIDs.append(pid)
                return true
            },
            awaitAcknowledgements: { pending in
                waitCalls += 1
                #expect(signaledPIDs == [41, 42])
                #expect(pending.map { $0.processIdentity.pid } == [41, 42])
                return [41]
            },
            gate: gate
        )

        #expect(waitCalls == 1)
        #expect(signaledPIDs == [41, 42])
        #expect(execution.acknowledgedPIDs == [41])
        #expect(execution.operationFailed)

        let summary = SwapEngine.codexReloadSummary(
            from: discovery,
            acknowledgedPIDs: execution.acknowledgedPIDs,
            operationFailed: execution.operationFailed
        )
        #expect(summary.discoveredRuntimeCount == 2)
        #expect(summary.acknowledgedRuntimeCount == 1)
        #expect(summary.operationFailed)
        #expect(summary.outcome == .restartRequiredOrFailed)
        #expect(gate.tryAcquire(Set<Int32>([41, 42])))
        gate.release(Set<Int32>([41, 42]))
    }

    @Test("ACK polling uses one aggregate monotonic deadline")
    func ackPollingUsesOneAggregateDeadline() {
        let bindings = [
            reloadBinding(target: runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI)),
            reloadBinding(target: runtimeTarget(pid: 42, runtimeKind: .localInteractiveCLI)),
        ]
        var monotonicTime: UInt64 = 0
        var sleptNanoseconds: UInt64 = 0

        let acknowledged = SwapEngine.acknowledgedPIDsBeforeDeadline(
            pendingBindings: bindings,
            timeoutNanoseconds: 5,
            pollIntervalNanoseconds: 1,
            monotonicNow: { monotonicTime },
            sleep: { duration in
                sleptNanoseconds += duration
                monotonicTime += duration
            },
            bindingIsCurrent: { _ in true },
            ackExists: { binding in
                binding.processIdentity.pid == 41 && monotonicTime >= 2
            }
        )

        #expect(acknowledged == [41])
        #expect(monotonicTime == 5)
        #expect(sleptNanoseconds == 5)
    }

    @Test("An ACK cannot authorize an identity changed during validation")
    func ackValidationRechecksExactIdentity() {
        let binding = reloadBinding(
            target: runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI)
        )
        var bindingReads = 0

        let acknowledged = SwapEngine.acknowledgedPIDsBeforeDeadline(
            pendingBindings: [binding],
            timeoutNanoseconds: 5,
            pollIntervalNanoseconds: 1,
            monotonicNow: { 0 },
            sleep: { _ in },
            bindingIsCurrent: { _ in
                bindingReads += 1
                return bindingReads == 1
            },
            ackExists: { $0 == binding }
        )

        #expect(bindingReads == 2)
        #expect(acknowledged.isEmpty)
    }

    @Test("Identity change after capability proof prevents the signal")
    func identityChangeImmediatelyBeforeSignalFailsClosed() {
        let discovery = CodexRuntimeDiscoverySnapshot(
            targets: [runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI)],
            isComplete: true
        )
        var currentBindingChecks = 0
        var persistedRequests = 0
        var signaledPIDs: [Int32] = []

        let execution = SwapEngine.executeReloadBatch(
            preliminaryPIDs: [41],
            discoveryProvider: { discovery },
            requiredOwnerUID: 501,
            candidateIsEligible: { _ in true },
            makeBinding: { reloadBinding(target: $0) },
            hotSwapSupport: { _ in true },
            bindingIsCurrent: { _ in
                currentBindingChecks += 1
                return currentBindingChecks == 1
            },
            persistRequest: { _ in
                persistedRequests += 1
                return true
            },
            signal: { pid in
                signaledPIDs.append(pid)
                return true
            },
            awaitAcknowledgements: { _ in [] },
            gate: CodexReloadAttemptGate()
        )

        #expect(currentBindingChecks == 2)
        #expect(persistedRequests == 1)
        #expect(signaledPIDs.isEmpty)
        #expect(execution.acknowledgedPIDs.isEmpty)
        #expect(execution.operationFailed)
    }

    @Test("Argv runtime-kind drift after capability proof prevents the signal")
    func argvRuntimeDriftImmediatelyBeforeSignalFailsClosed() {
        let target = runtimeTarget(pid: 41, runtimeKind: .localInteractiveCLI)
        let discovery = CodexRuntimeDiscoverySnapshot(targets: [target], isComplete: true)
        let binding = reloadBinding(target: target)
        var bindingChecks = 0
        var persistedRequests = 0
        var signaledPIDs: [Int32] = []

        let execution = SwapEngine.executeReloadBatch(
            preliminaryPIDs: [41],
            discoveryProvider: { discovery },
            requiredOwnerUID: 501,
            candidateIsEligible: { _ in true },
            makeBinding: { _ in binding },
            hotSwapSupport: { _ in true },
            bindingIsCurrent: { candidate in
                bindingChecks += 1
                let arguments = bindingChecks == 1
                    ? ["codex", "resume", "thread-41"]
                    : ["codex", "app-server"]
                return SwapEngine.reloadBindingIsCurrent(
                    candidate,
                    identityProvider: { _ in candidate.processIdentity },
                    argumentProvider: { _ in arguments },
                    kernelExecutableIdentityProvider: { _ in
                        candidate.kernelExecutableIdentity
                    },
                    authFileIdentityProvider: { _, _ in candidate.authFileIdentity }
                )
            },
            persistRequest: { _ in
                persistedRequests += 1
                return true
            },
            signal: { pid in
                signaledPIDs.append(pid)
                return true
            },
            awaitAcknowledgements: { _ in [] },
            gate: CodexReloadAttemptGate()
        )

        #expect(bindingChecks == 2)
        #expect(persistedRequests == 1)
        #expect(signaledPIDs.isEmpty)
        #expect(execution.acknowledgedPIDs.isEmpty)
        #expect(execution.operationFailed)
    }

    @Test("SIGHUP target identity rejects PID reuse, owner drift, and executable drift")
    func sighupTargetIdentityMustRemainStable() {
        let expected = CodexSignalProcessIdentity(
            pid: 41,
            ownerUID: 501,
            executablePath: "/opt/homebrew/bin/codex",
            startSeconds: 1_000,
            startMicroseconds: 12
        )

        #expect(SwapEngine.signalIdentityMatches(
            expected: expected,
            current: expected,
            requiredOwnerUID: 501
        ))
        #expect(!SwapEngine.signalIdentityMatches(
            expected: expected,
            current: CodexSignalProcessIdentity(
                pid: 41,
                ownerUID: 501,
                executablePath: "/opt/homebrew/bin/codex",
                startSeconds: 1_001,
                startMicroseconds: 12
            ),
            requiredOwnerUID: 501
        ))
        #expect(!SwapEngine.signalIdentityMatches(
            expected: expected,
            current: CodexSignalProcessIdentity(
                pid: 41,
                ownerUID: 502,
                executablePath: "/opt/homebrew/bin/codex",
                startSeconds: 1_000,
                startMicroseconds: 12
            ),
            requiredOwnerUID: 501
        ))
        #expect(!SwapEngine.signalIdentityMatches(
            expected: expected,
            current: CodexSignalProcessIdentity(
                pid: 41,
                ownerUID: 501,
                executablePath: "/tmp/codex",
                startSeconds: 1_000,
                startMicroseconds: 12
            ),
            requiredOwnerUID: 501
        ))
        #expect(!SwapEngine.signalIdentityMatches(
            expected: expected,
            current: nil,
            requiredOwnerUID: 501
        ))
    }
}
