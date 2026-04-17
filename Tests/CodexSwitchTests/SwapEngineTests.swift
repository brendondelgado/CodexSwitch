import Testing
import Foundation
@testable import CodexSwitch

@Suite("SwapEngine")
struct SwapEngineTests {
    private func makeAccount(
        id: UUID = UUID(),
        fiveHourRemaining: Double,
        weeklyRemaining: Double,
        resetsInSeconds: TimeInterval = 3600,
        isActive: Bool = false
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
                    resetsAt: Date().addingTimeInterval(resetsInSeconds)
                ),
                weekly: QuotaWindow(
                    usedPercent: 100 - weeklyRemaining,
                    windowDurationMins: 10080,
                    resetsAt: Date().addingTimeInterval(resetsInSeconds * 4)
                ),
                fetchedAt: Date()
            ),
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

    @Test("Tiebreaker prefers lower weekly — drain constrained accounts first")
    func tiebreaker() {
        let a = makeAccount(fiveHourRemaining: 50, weeklyRemaining: 30)
        let b = makeAccount(fiveHourRemaining: 50, weeklyRemaining: 80)
        let best = SwapEngine.selectOptimalAccount(from: [a, b])
        // Scoring prefers lower weekly: use constrained accounts first, save fresh ones
        #expect(best?.id == a.id)
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

    @Test("Skips currently active account in selection")
    func skipsActive() {
        let active = makeAccount(fiveHourRemaining: 90, weeklyRemaining: 90, isActive: true)
        let other = makeAccount(fiveHourRemaining: 50, weeklyRemaining: 50)
        let best = SwapEngine.selectOptimalAccount(from: [active, other])
        #expect(best?.id == other.id)
    }

    @Test("SIGHUP candidates include only interactive CLI sessions")
    func sighupCandidatesOnlyIncludeInteractiveCli() {
        let output = """
        2561 node /opt/homebrew/bin/codex resume --yolo
        2562 /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex resume --yolo
        29201 /Applications/Codex.app/Contents/Resources/codex
        29203 /Users/brendondelgado/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Launcher/WgQvClht4/Updater.app/Contents/MacOS/Updater /Applications/Codex.app 0
        """

        let ttyByPid: [Int32: String] = [
            2561: "ttys003",
            2562: "ttys003",
            29201: "??",
            29203: "??"
        ]

        let pids = SwapEngine.signalableCodexProcessIDs(from: output) { pid in
            ttyByPid[pid]
        }

        #expect(pids == [2562])
    }

    @Test("SIGHUP candidates skip detached codex app-server even if command matches")
    func sighupCandidatesSkipDetachedAppServer() {
        let output = """
        99517 /Applications/Codex.app/Contents/Resources/codex
        """

        let pids = SwapEngine.signalableCodexProcessIDs(from: output) { _ in
            "??"
        }

        #expect(pids.isEmpty)
    }

    @Test("SIGHUP candidates skip node launcher even when codex script path is present")
    func sighupCandidatesSkipNodeLauncher() {
        let output = """
        2561 node /opt/homebrew/bin/codex resume --yolo
        """

        let pids = SwapEngine.signalableCodexProcessIDs(from: output) { _ in
            "ttys003"
        }

        #expect(pids.isEmpty)
    }

    @Test("SIGHUP verification requires marker at or after binary update")
    func sighupVerificationRequiresFreshMarker() {
        let binaryDate = Date(timeIntervalSince1970: 200)
        let freshMarkerDate = Date(timeIntervalSince1970: 200)
        let newerMarkerDate = Date(timeIntervalSince1970: 250)
        let staleMarkerDate = Date(timeIntervalSince1970: 150)

        #expect(SwapEngine.isSighupVerificationCurrent(
            markerModificationDate: freshMarkerDate,
            binaryModificationDate: binaryDate
        ))
        #expect(SwapEngine.isSighupVerificationCurrent(
            markerModificationDate: newerMarkerDate,
            binaryModificationDate: binaryDate
        ))
        #expect(!SwapEngine.isSighupVerificationCurrent(
            markerModificationDate: staleMarkerDate,
            binaryModificationDate: binaryDate
        ))
        #expect(!SwapEngine.isSighupVerificationCurrent(
            markerModificationDate: nil,
            binaryModificationDate: binaryDate
        ))
        #expect(!SwapEngine.isSighupVerificationCurrent(
            markerModificationDate: freshMarkerDate,
            binaryModificationDate: nil
        ))
    }
}
