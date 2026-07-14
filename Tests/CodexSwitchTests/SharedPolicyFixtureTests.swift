import Foundation
import Testing
@testable import CodexSwitch

@Suite("Shared Swift and Rust policy fixtures")
struct SharedPolicyFixtureTests {
    @Test("Candidate ordering keeps usable Pro ahead of Plus")
    func candidateOrder() throws {
        let fixture: CandidateOrderFixture = try loadFixture("candidate-order")

        let candidates = SwapEngine.rankedEligibleCandidates(
            from: fixture.accounts,
            now: fixture.now
        )

        #expect(fixture.schemaVersion == 1)
        #expect(fixture.caseName == "candidate-order")
        #expect(candidates.map(\.id) == fixture.expectedCandidateOrder)
        #expect(
            SwapEngine.selectAutoSwapCandidate(from: fixture.accounts, now: fixture.now)?.id
                == fixture.expectedCandidateOrder.first
        )
    }

    @Test("Five-hour-only telemetry remains usable without inventing weekly quota")
    func fiveHourOnly() throws {
        let fixture: FiveHourOnlyFixture = try loadFixture("five-hour-only")

        #expect(fixture.schemaVersion == 1)
        #expect(fixture.caseName == "five-hour-only")
        #expect(fixture.expected.availability == "usable")
        #expect(fixture.snapshot.isImmediatelyUsable)
        #expect(fixture.snapshot.weekly == nil)
        #expect(fixture.snapshot.policyWindows.map(\.kind.rawValue) == fixture.expected.windowKinds)
        #expect(fixture.snapshot.minimumRemainingPercent == fixture.expected.minimumRemainingPercent)
    }

    @Test("Natural reset inside 24 hours preserves the Pro credit")
    func naturalResetGuard() throws {
        let fixture: NaturalResetGuardFixture = try loadFixture("natural-reset-guard")
        var active = fixture.active
        active.rateLimitResetBank = fixture.bank
        let accounts = [active, fixture.replacement]

        let selection = RateLimitResetPolicy.selectRedemptionCandidate(
            from: accounts,
            now: fixture.now
        )

        #expect(fixture.schemaVersion == 1)
        #expect(fixture.caseName == "natural-reset-guard")
        #expect(fixture.expected.preserveCredit)
        #expect(fixture.expected.resetReason == nil)
        #expect(selection == nil)
        #expect(active.blockedQuotaRecoveryAt(now: fixture.now) == fixture.now.addingTimeInterval(3_600))
    }

    @Test("Definitive non-consumption is terminal and does not suppress a later reset")
    func terminalNonConsumption() async throws {
        let fixture: TerminalNonConsumptionFixture = try loadFixture("terminal-non-consumption")
        let now = Date(timeIntervalSinceReferenceDate: 805_550_400)

        for code in fixture.consumeCodes {
            let journalURL = makeSecureTestFileURL(
                prefix: "shared-policy-terminal",
                fileName: "reset-attempts.json"
            )
            defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
            let service = RateLimitResetService(
                transport: { _ in
                    RateLimitResetHTTPResponse(
                        statusCode: 200,
                        data: Data("{\"code\":\"\(code)\"}".utf8)
                    )
                },
                journalURL: journalURL
            )
            let account = resetAccount(now: now)
            let bank = resetBank(now: now)

            let result = try await service.consume(for: account, bank: bank, now: now)
            let attempts = try await service.allAttempts()

            switch code {
            case "no_credit":
                #expect(result == .noCredit)
            case "nothing_to_reset":
                #expect(result == .nothingToReset)
            default:
                Issue.record("Unexpected terminal fixture code: \(code)")
            }
            #expect(fixture.expected.state == "terminal_not_applied")
            #expect(!fixture.expected.consumptionObserved)
            #expect(!fixture.expected.quotaReconciled)
            #expect(!fixture.expected.suppressesRedemption)
            #expect(attempts.count == 1)
            #expect(attempts.first?.state == .notApplied)
            #expect(try await service.unresolvedAttempt(for: account.accountId) == nil)
        }
    }

    @Test("Uncertain submission reconciles from fresh inventory and quota without a second POST")
    func uncertainCrashReconciliation() async throws {
        let fixture: UncertainCrashFixture = try loadFixture("uncertain-crash-reconcile")
        let journalURL = makeSecureTestFileURL(
            prefix: "shared-policy-uncertain",
            fileName: "reset-attempts.json"
        )
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let posts = PostCounter()
        let service = RateLimitResetService(
            transport: { _ in
                await posts.increment()
                return RateLimitResetHTTPResponse(
                    statusCode: 200,
                    data: Data(#"{"code":"reset"}"#.utf8)
                )
            },
            journalURL: journalURL
        )
        let account = resetAccount(now: fixture.now)

        let consume = try await service.consume(
            for: account,
            bank: fixture.beforeBank,
            now: fixture.now
        )
        guard case .reconciliationRequired(let attemptId) = consume else {
            Issue.record("Expected reset submission to require reconciliation")
            return
        }
        let snapshot = usableWeeklySnapshot(fetchedAt: fixture.quotaFetchedAt)
        let reconciliation = try await service.reconcile(
            for: account,
            bank: fixture.afterBank,
            snapshot: snapshot,
            now: fixture.quotaFetchedAt
        )

        guard case .pendingPersistence(let pending) = reconciliation else {
            Issue.record("Expected reconciliation to require durable persistence")
            return
        }
        #expect(pending.id == attemptId)
        let finalized = try await service.finalizeReconciliationAfterPersistence(
            attemptId: attemptId,
            now: fixture.quotaFetchedAt
        )

        #expect(fixture.schemaVersion == 1)
        #expect(fixture.caseName == "uncertain-crash-reconcile")
        #expect(fixture.expected.state == "reconciled_usable")
        #expect(fixture.expected.consumptionObserved)
        #expect(fixture.expected.quotaReconciled)
        #expect(await posts.value == fixture.expected.postCount)
        #expect(finalized.state == .succeeded)
        #expect(try await service.unresolvedAttempt(for: account.accountId) == nil)
    }
}

private actor PostCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private struct CandidateOrderFixture: Decodable {
    let schemaVersion: Int
    let caseName: String
    let now: Date
    let accounts: [CodexAccount]
    let expectedCandidateOrder: [UUID]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case caseName = "case"
        case now
        case accounts
        case expectedCandidateOrder
    }
}

private struct FiveHourOnlyFixture: Decodable {
    struct Expected: Decodable {
        let availability: String
        let windowKinds: [String]
        let minimumRemainingPercent: Double
    }

    let schemaVersion: Int
    let caseName: String
    let now: Date
    let snapshot: QuotaSnapshot
    let expected: Expected

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case caseName = "case"
        case now
        case snapshot
        case expected
    }
}

private struct NaturalResetGuardFixture: Decodable {
    struct Expected: Decodable {
        let resetReason: String?
        let preserveCredit: Bool
    }

    let schemaVersion: Int
    let caseName: String
    let now: Date
    let active: CodexAccount
    let replacement: CodexAccount
    let bank: RateLimitResetBank
    let expected: Expected

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case caseName = "case"
        case now
        case active
        case replacement
        case bank
        case expected
    }
}

private struct TerminalNonConsumptionFixture: Decodable {
    struct Expected: Decodable {
        let state: String
        let consumptionObserved: Bool
        let quotaReconciled: Bool
        let suppressesRedemption: Bool
    }

    let schemaVersion: Int
    let caseName: String
    let consumeCodes: [String]
    let expected: Expected

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case caseName = "case"
        case consumeCodes
        case expected
    }
}

private struct UncertainCrashFixture: Decodable {
    struct Expected: Decodable {
        let postCount: Int
        let state: String
        let consumptionObserved: Bool
        let quotaReconciled: Bool
    }

    let schemaVersion: Int
    let caseName: String
    let now: Date
    let beforeBank: RateLimitResetBank
    let afterBank: RateLimitResetBank
    let quotaFetchedAt: Date
    let expected: Expected

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case caseName = "case"
        case now
        case beforeBank
        case afterBank
        case quotaFetchedAt
        case expected
    }
}

private func loadFixture<T: Decodable>(_ name: String) throws -> T {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("Policy", isDirectory: true)
        .appendingPathComponent("\(name).json")
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: fixtureURL))
}

private func resetAccount(now: Date) -> CodexAccount {
    CodexAccount(
        email: "fixture@example.com",
        accessToken: "access-fixture",
        refreshToken: "refresh-fixture",
        idToken: "id-fixture",
        accountId: "provider-fixture",
        quotaSnapshot: QuotaSnapshot(
            allowed: true,
            limitReached: true,
            fetchedAt: now,
            windows: [QuotaWindow(
                kind: .weekly,
                durationSeconds: 7 * 24 * 60 * 60,
                usedPercent: 100,
                resetsAt: now.addingTimeInterval(7 * 24 * 60 * 60),
                source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary),
                hardLimitReached: true
            )]
        ),
        planType: "pro",
        isActive: true
    )
}

private func resetBank(now: Date) -> RateLimitResetBank {
    RateLimitResetBank(
        availableCount: 1,
        totalEarnedCount: 1,
        credits: [RateLimitResetCredit(
            id: "fixture-credit",
            resetType: "full",
            status: "available",
            grantedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(7 * 24 * 60 * 60),
            redeemedAt: nil,
            title: "Full reset",
            description: nil
        )],
        fetchedAt: now
    )
}

private func usableWeeklySnapshot(fetchedAt: Date) -> QuotaSnapshot {
    QuotaSnapshot(
        allowed: true,
        limitReached: false,
        fetchedAt: fetchedAt,
        windows: [QuotaWindow(
            kind: .weekly,
            durationSeconds: 7 * 24 * 60 * 60,
            usedPercent: 0,
            resetsAt: fetchedAt.addingTimeInterval(7 * 24 * 60 * 60),
            source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
        )]
    )
}
