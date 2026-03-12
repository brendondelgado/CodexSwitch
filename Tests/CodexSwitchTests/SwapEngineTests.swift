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

    @Test("Tiebreaker uses weekly remaining")
    func tiebreaker() {
        let a = makeAccount(fiveHourRemaining: 50, weeklyRemaining: 30)
        let b = makeAccount(fiveHourRemaining: 50, weeklyRemaining: 80)
        let best = SwapEngine.selectOptimalAccount(from: [a, b])
        #expect(best?.id == b.id)
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
}
