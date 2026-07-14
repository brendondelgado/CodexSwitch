import Darwin
import Foundation

private enum HarnessError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private enum TransportStep: Sendable {
    case fail
    case response(RateLimitResetHTTPResponse)
}

private struct TransportFailure: Error {}

private final class TransportHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [TransportStep]
    private var bodies: [Data] = []

    init(_ steps: [TransportStep]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) throws -> RateLimitResetHTTPResponse {
        try lock.withLock {
            bodies.append(request.httpBody ?? Data())
            guard !steps.isEmpty else { throw TransportFailure() }
            switch steps.removeFirst() {
            case .fail: throw TransportFailure()
            case .response(let response): return response
            }
        }
    }

    func requestBodies() -> [Data] {
        lock.withLock { bodies }
    }
}

@main
private enum BankedResetHarness {
    static func main() async throws {
        try await inventoryReplay()
        try policyReplay()
        try weeklyOnlyResponseReplay()
        try quotaWindowMigrationReplay()
        try await exactlyOnceReplay()
        try persistenceReplay()
        print("banked reset harness: PASS")
    }

    private static func weeklyOnlyResponseReplay() throws {
        let response = Data(
            """
            {
              "plan_type": "pro",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 6,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 400000,
                  "reset_at": 1777400000
                },
                "secondary_window": null
              },
              "additional_rate_limits": []
            }
            """.utf8
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let result = try UsageResponseParser.parse(response, fetchedAt: fetchedAt)

        try require(result.planType == "pro", "weekly-only response lost plan type")
        try require(result.snapshot.fiveHour == nil, "weekly primary window was mislabeled five-hour")
        try require(result.snapshot.windows.count == 1, "weekly-only response invented another window")
        try require(result.snapshot.weekly?.usedPercent == 6, "weekly primary usage did not survive parsing")
        try require(result.snapshot.isImmediatelyUsable, "healthy weekly-only account became unavailable")
    }

    private static func quotaWindowMigrationReplay() throws {
        let legacy = Data(
            """
            {
              "fetchedAt": 1000,
              "fiveHour": {"usedPercent":6,"windowDurationMins":10080,"resetsAt":2000,"hardLimitReached":false},
              "weekly": {"usedPercent":0,"windowDurationMins":10080,"resetsAt":3000,"hardLimitReached":false}
            }
            """.utf8
        )
        let legacySnapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: legacy)
        try require(legacySnapshot.fiveHour == nil, "mislabeled legacy weekly window remained five-hour")
        try require(legacySnapshot.windows.count == 1, "duplicate legacy weekly windows were not collapsed")
        try require(legacySnapshot.weekly?.usedPercent == 6, "restrictive legacy weekly observation was not retained")

        let contradictoryV2 = Data(
            """
            {
              "version": 2,
              "allowed": true,
              "limitReached": false,
              "fetchedAt": 1000,
              "windows": [
                {"kind":"fiveHour","durationSeconds":604800,"usedPercent":19,"resetsAt":2000},
                {"kind":"weekly","durationSeconds":18000,"usedPercent":23,"resetsAt":2000}
              ]
            }
            """.utf8
        )
        let v2Snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: contradictoryV2)
        try require(v2Snapshot.weekly?.usedPercent == 19, "v2 weekly duration did not override its stale kind")
        try require(v2Snapshot.fiveHour?.usedPercent == 23, "v2 five-hour duration did not override its stale kind")
    }

    private static func inventoryReplay() async throws {
        let fixture = Data(
            """
            {
              "available_count": 2,
              "total_earned_count": 3,
              "credits": [
                {
                  "id": "later",
                  "reset_type": "full",
                  "status": "available",
                  "granted_at": "2026-07-01T12:00:00.123Z",
                  "expires_at": "2026-07-31T12:00:00.456Z",
                  "redeemed_at": null,
                  "title": "Full reset (Weekly + 5 hr)",
                  "description": null
                },
                {
                  "id": "earlier",
                  "reset_type": "full",
                  "status": "available",
                  "granted_at": "2026-07-01T12:00:00Z",
                  "expires_at": "2026-07-18T12:00:00Z",
                  "redeemed_at": null,
                  "title": "Full reset (Weekly + 5 hr)",
                  "description": null
                }
              ]
            }
            """.utf8
        )
        let service = RateLimitResetService { _ in
            RateLimitResetHTTPResponse(statusCode: 200, data: fixture)
        }
        let now = try date("2026-07-12T12:00:00Z")
        let bank = try await service.fetchBank(for: account(), force: true, now: now)
        try require(bank.availableCount == 2, "inventory count did not parse")
        try require(
            bank.oldestExpiringCredit(at: now)?.id == "earlier",
            "oldest-expiring credit was not selected"
        )
    }

    private static func policyReplay() throws {
        let now = try date("2026-07-12T12:00:00Z")
        let normalBank = bank(now: now, expiresIn: 7 * 86_400)
        let ready = account(
            email: "ready@example.com",
            snapshot: snapshot(fiveHourUsed: 10, weeklyUsed: 10, now: now)
        )
        let weekly = account(
            snapshot: snapshot(fiveHourUsed: 20, weeklyUsed: 100, now: now)
        )
        try require(
            RateLimitResetPolicy.redemptionReason(
                for: weekly,
                allAccounts: [weekly, ready],
                bank: normalBank,
                now: now
            ) == nil,
            "same-tier capacity did not preserve the reset"
        )

        var activePlus = account(
            email: "plus@example.com",
            snapshot: snapshot(fiveHourUsed: 10, weeklyUsed: 10, now: now),
            planType: "plus"
        )
        activePlus.isActive = true
        var resettablePro = weekly
        resettablePro.isActive = false
        resettablePro.rateLimitResetBank = normalBank
        try require(
            RateLimitResetPolicy.selectRedemptionCandidate(
                from: [activePlus, resettablePro],
                now: now
            ) == RateLimitResetRedemptionCandidate(
                accountId: resettablePro.id,
                bank: normalBank,
                reason: .preserveFasterTier
            ),
            "pool selector did not redeem inactive Pro before active usable Plus"
        )
        try require(
            RateLimitResetPolicy.redemptionReason(
                for: resettablePro,
                allAccounts: [activePlus, resettablePro],
                bank: normalBank,
                now: now
            ) == .preserveFasterTier,
            "inactive Pro reset was not preferred over active usable Plus"
        )

        var activePro = account(
            email: "active-pro@example.com",
            snapshot: snapshot(fiveHourUsed: 10, weeklyUsed: 10, now: now),
            planType: "pro"
        )
        activePro.isActive = true
        var resettablePlus = account(
            email: "exhausted-plus@example.com",
            snapshot: snapshot(fiveHourUsed: 20, weeklyUsed: 100, now: now),
            planType: "plus"
        )
        resettablePlus.isActive = false
        resettablePlus.rateLimitResetBank = normalBank
        try require(
            RateLimitResetPolicy.redemptionReason(
                for: resettablePlus,
                allAccounts: [activePro, resettablePlus],
                bank: normalBank,
                now: now
            ) == nil,
            "active usable Pro did not suppress inactive Plus redemption"
        )
        try require(
            RateLimitResetPolicy.selectRedemptionCandidate(
                from: [activePro, resettablePlus],
                now: now
            ) == nil,
            "pool selector spent an inactive Plus reset while active Pro was usable"
        )

        let plus = account(
            email: "plus@example.com",
            snapshot: snapshot(fiveHourUsed: 10, weeklyUsed: 10, now: now),
            planType: "plus"
        )
        let nearNaturalReset = account(
            snapshot: snapshot(
                fiveHourUsed: 20,
                weeklyUsed: 100,
                now: now,
                weeklyResetAfter: 12 * 60 * 60
            )
        )
        try require(
            RateLimitResetPolicy.redemptionReason(
                for: nearNaturalReset,
                allAccounts: [nearNaturalReset, plus],
                bank: normalBank,
                now: now
            ) == nil,
            "near natural reset did not preserve the banked credit"
        )
        try require(
            RateLimitResetPolicy.redemptionReason(
                for: nearNaturalReset,
                allAccounts: [nearNaturalReset],
                bank: normalBank,
                now: now
            ) == .weeklyPressure,
            "pool exhaustion did not override near-reset protection"
        )

        let fiveHour = account(
            snapshot: snapshot(fiveHourUsed: 100, weeklyUsed: 20, now: now)
        )
        try require(
            RateLimitResetPolicy.redemptionReason(
                for: fiveHour,
                allAccounts: [fiveHour, ready],
                bank: normalBank,
                now: now
            ) == nil,
            "five-hour-only pressure spent a reset despite a ready alternative"
        )
        try require(
            RateLimitResetPolicy.redemptionReason(
                for: fiveHour,
                allAccounts: [fiveHour],
                bank: normalBank,
                now: now
            ) == .poolExhausted,
            "empty pool did not trigger redemption"
        )

        let expiringBank = bank(now: now, expiresIn: 60 * 60)
        try require(
            RateLimitResetPolicy.redemptionReason(
                for: fiveHour,
                allAccounts: [fiveHour, ready],
                bank: expiringBank,
                now: now
            ) == nil,
            "same-tier capacity did not preserve an expiring reset"
        )
        try require(
            RateLimitResetPolicy.redemptionReason(
                for: fiveHour,
                allAccounts: [fiveHour],
                bank: expiringBank,
                now: now
            ) == .expiringSoon,
            "expiring reset was not used when the pool had no alternative"
        )
    }

    private static func exactlyOnceReplay() async throws {
        let journalDirectory = try canonicalTemporaryDirectory()
            .appendingPathComponent("codexswitch-reset-harness-\(UUID().uuidString)", isDirectory: true)
        let journalURL = journalDirectory.appendingPathComponent("reset-attempts.json")
        defer { try? FileManager.default.removeItem(at: journalDirectory) }
        let harness = TransportHarness([
            .fail,
        ])
        let service = RateLimitResetService(
            transport: { request in try harness.send(request) },
            journalURL: journalURL
        )
        let now = try date("2026-07-12T12:00:00Z")
        let blocked = account(
            snapshot: snapshot(fiveHourUsed: 20, weeklyUsed: 100, now: now.addingTimeInterval(-60))
        )
        let requestId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        do {
            _ = try await service.consume(
                for: blocked,
                bank: bank(now: now, expiresIn: 86_400),
                now: now,
                redeemRequestId: requestId
            )
            throw HarnessError.failed("uncertain POST unexpectedly completed")
        } catch is TransportFailure {
            throw HarnessError.failed("transport errors must be normalized")
        } catch let error as RateLimitResetServiceError {
            guard case .transport = error else { throw error }
        }

        let bodies = harness.requestBodies()
        try require(bodies.count == 1, "uncertain consume POST was retried")
        let payload = try JSONSerialization.jsonObject(with: bodies[0]) as? [String: String]
        try require(
            payload?["redeem_request_id"] == "11111111-2222-3333-4444-555555555555",
            "journaled request identifier was not sent"
        )

        let restartedHarness = TransportHarness([
            .response(RateLimitResetHTTPResponse(
                statusCode: 200,
                data: Data("{\"code\":\"reset\"}".utf8)
            )),
        ])
        let restarted = RateLimitResetService(
            transport: { request in try restartedHarness.send(request) },
            journalURL: journalURL
        )
        do {
            _ = try await restarted.consume(
                for: blocked,
                bank: bank(now: now.addingTimeInterval(60), expiresIn: 86_400),
                now: now.addingTimeInterval(60)
            )
            throw HarnessError.failed("restart allowed a second unresolved POST")
        } catch let error as RateLimitResetServiceError {
            guard case .unresolvedAttempt(let unresolvedId) = error,
                  unresolvedId == requestId else {
                throw error
            }
        }
        try require(restartedHarness.requestBodies().isEmpty, "restart sent a duplicate POST")

        let consumedBank = RateLimitResetBank(
            availableCount: 0,
            totalEarnedCount: 1,
            credits: [],
            fetchedAt: now.addingTimeInterval(90)
        )
        let healthy = snapshot(
            fiveHourUsed: 10,
            weeklyUsed: 10,
            now: now.addingTimeInterval(90)
        )
        let outcome = try await restarted.reconcile(
            for: blocked,
            bank: consumedBank,
            snapshot: healthy,
            now: now.addingTimeInterval(90)
        )
        guard case .pendingPersistence(let attempt) = outcome,
              attempt.id == requestId else {
            throw HarnessError.failed("new inventory and quota did not reach the persistence boundary")
        }
        let finalized = try await restarted.finalizeReconciliationAfterPersistence(
            attemptId: attempt.id,
            now: now.addingTimeInterval(91)
        )
        try require(finalized.state == .succeeded, "persisted reconciliation was not finalized")
        let unresolvedAfterFinalization = try await restarted.unresolvedAttempt(
            for: blocked.accountId
        )
        try require(
            unresolvedAfterFinalization == nil,
            "finalized reconciliation remained unresolved"
        )
    }

    private static func canonicalTemporaryDirectory() throws -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        guard let resolvedPath = realpath(temporaryPath, nil) else {
            throw HarnessError.failed("could not resolve temporary directory: \(temporaryPath)")
        }
        defer { free(resolvedPath) }
        return URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
    }

    private static func persistenceReplay() throws {
        let now = try date("2026-07-12T12:00:00Z")
        var stored = account()
        stored.rateLimitResetBank = bank(now: now, expiresIn: 86_400)
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(CodexAccount.self, from: data)
        try require(
            decoded.rateLimitResetBank == stored.rateLimitResetBank,
            "account JSON did not preserve reset bank state"
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HarnessError.failed(message) }
    }

    private static func date(_ value: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw HarnessError.failed("invalid harness date: \(value)")
        }
        return date
    }

    private static func account(
        email: String = "active@example.com",
        snapshot: QuotaSnapshot? = nil,
        planType: String = "pro"
    ) -> CodexAccount {
        CodexAccount(
            email: email,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: "id-token",
            accountId: "account-id-\(email)",
            quotaSnapshot: snapshot,
            planType: planType,
            isActive: email == "active@example.com"
        )
    }

    private static func snapshot(
        fiveHourUsed: Double,
        weeklyUsed: Double,
        now: Date,
        fiveHourResetAfter: TimeInterval = 5 * 60 * 60,
        weeklyResetAfter: TimeInterval = 7 * 86_400
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: fiveHourUsed,
                windowDurationMins: 300,
                resetsAt: now.addingTimeInterval(fiveHourResetAfter),
                hardLimitReached: fiveHourUsed >= 100
            ),
            weekly: QuotaWindow(
                usedPercent: weeklyUsed,
                windowDurationMins: 10_080,
                resetsAt: now.addingTimeInterval(weeklyResetAfter),
                hardLimitReached: weeklyUsed >= 100
            ),
            fetchedAt: now
        )
    }

    private static func bank(now: Date, expiresIn: TimeInterval) -> RateLimitResetBank {
        RateLimitResetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [
                RateLimitResetCredit(
                    id: "credit-1",
                    resetType: "full",
                    status: "available",
                    grantedAt: now,
                    expiresAt: now.addingTimeInterval(expiresIn),
                    redeemedAt: nil,
                    title: "Full reset (Weekly + 5 hr)",
                    description: nil
                ),
            ],
            fetchedAt: now
        )
    }
}
