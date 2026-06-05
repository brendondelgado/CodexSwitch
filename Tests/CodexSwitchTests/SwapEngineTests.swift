import Testing
import Foundation
@testable import CodexSwitch

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

        #expect(SwapEngine.earliestUsableReset(from: [exhausted, healthy], now: now) == fiveHourReset)
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
        let tmpDir = FileManager.default.temporaryDirectory.path
        let testPath = tmpDir + "/codexswitch-test-auth-\(UUID().uuidString).json"

        defer {
            try? FileManager.default.removeItem(atPath: testPath)
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

    @Test("Hard rate-limit on active account still triggers fallback scoring")
    func hardRateLimitTreatsAccountAsExhausted() {
        let active = makeAccount(
            fiveHourRemaining: 1.1,
            weeklyRemaining: 90,
            isActive: true,
            fiveHourHardLimitReached: true
        )
        let other = makeAccount(fiveHourRemaining: 5, weeklyRemaining: 90)

        #expect(SwapEngine.score(active) > 0)
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
        #expect(SwapEngine.score(plusResettingSoon) > SwapEngine.score(free))
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

    @Test("Desktop app-server SIGHUP targets managed fork only")
    func desktopAppServerSighupTargetsManagedForkOnly() {
        let output = """
        80379 /Users/brendondelgado/Developer/codex/codex-rs/target/fork-release/codex app-server --analytics-default-enabled
        90722 /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex app-server --analytics-default-enabled
        70001 /Applications/CodexSwitch.app/Contents/MacOS/CodexSwitch
        """

        let pids = SwapEngine.desktopAppServerPIDsToSignal(from: output) { pid in
            pid == 80379
        }

        #expect(pids == [80379])
    }

    @Test("CLI SIGHUP skips wrapper command lines, not Codex binaries")
    func cliSighupSkipsWrappersNotCodexBinaries() {
        #expect(SwapEngine.commandLineIsUnsafeCodexSighupTarget("1234 /bin/zsh -lc codex-vps"))
        #expect(SwapEngine.commandLineIsUnsafeCodexSighupTarget("1235 SIGNUL_CANARY_ACTOR=codex-vps bash -lc codex"))
        #expect(SwapEngine.commandLineIsUnsafeCodexSighupTarget("1236 ssh signul-vps codex"))
        #expect(SwapEngine.commandLineIsUnsafeCodexSighupTarget("1237 /Users/me/Developer/codex/codex-rs/target/fork-release/codex --remote ws://127.0.0.1:18390 resume abc"))
        #expect(!SwapEngine.commandLineIsUnsafeCodexSighupTarget("1237 /opt/homebrew/bin/codex exec --json"))
        #expect(!SwapEngine.commandLineIsUnsafeCodexSighupTarget("1238 /home/signul/.local/share/codexswitch/patched-codex/codex"))
    }
}
