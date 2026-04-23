import Foundation
import Testing
@testable import CodexSwitch

private final class WeeklyPrimerURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var responseBody: Data = Data("ok".utf8)
    nonisolated(unsafe) static var responseDelaySeconds: TimeInterval = 0

    static func reset() {
        lock.lock()
        requests = []
        statusCode = 200
        responseBody = Data("ok".utf8)
        responseDelaySeconds = 0
        lock.unlock()
    }

    static func snapshotRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func snapshotRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let statusCode = Self.statusCode
        let body = Self.responseBody
        let responseDelaySeconds = Self.responseDelaySeconds
        Self.lock.unlock()

        if responseDelaySeconds > 0 {
            Thread.sleep(forTimeInterval: responseDelaySeconds)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("WeeklyPrimer", .serialized)
struct WeeklyPrimerTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WeeklyPrimerURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeAccount(
        id: UUID = UUID(),
        fiveHourRemaining: Double = 100,
        weeklyRemaining: Double = 100,
        isActive: Bool = false
    ) -> CodexAccount {
        CodexAccount(
            id: id,
            email: "test-\(id.uuidString.prefix(4))@example.com",
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: "id-token",
            accountId: "acct-\(id.uuidString.prefix(8))",
            quotaSnapshot: QuotaSnapshot(
                fiveHour: QuotaWindow(
                    usedPercent: 100 - fiveHourRemaining,
                    windowDurationMins: 300,
                    resetsAt: Date().addingTimeInterval(18_000)
                ),
                weekly: QuotaWindow(
                    usedPercent: 100 - weeklyRemaining,
                    windowDurationMins: 10_080,
                    resetsAt: Date().addingTimeInterval(604_800)
                ),
                fetchedAt: Date()
            ),
            planType: "pro",
            lastRefreshed: Date(),
            isActive: isActive
        )
    }

    @Test("Fresh inactive accounts are primed with a minimal Codex request")
    func primesFreshInactiveAccount() async throws {
        WeeklyPrimerURLProtocol.reset()
        let account = makeAccount()
        let primer = WeeklyPrimer(session: makeSession())

        await primer.primeIfNeeded(accounts: [account], accountProvider: { _ in account })

        let requests = WeeklyPrimerURLProtocol.snapshotRequests()

        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(requests.first?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == account.accountId)
    }

    @Test("Active accounts are never primed")
    func skipsActiveAccount() async throws {
        WeeklyPrimerURLProtocol.reset()
        let account = makeAccount(isActive: true)
        let primer = WeeklyPrimer(session: makeSession())

        await primer.primeIfNeeded(accounts: [account], accountProvider: { _ in account })

        let requestCount = WeeklyPrimerURLProtocol.snapshotRequestCount()

        #expect(requestCount == 0)
    }

    @Test("Already-used accounts are not re-primed")
    func skipsAccountWithStartedWindows() async throws {
        WeeklyPrimerURLProtocol.reset()
        let account = makeAccount(fiveHourRemaining: 72, weeklyRemaining: 93)
        let primer = WeeklyPrimer(session: makeSession())

        await primer.primeIfNeeded(accounts: [account], accountProvider: { _ in account })

        let requestCount = WeeklyPrimerURLProtocol.snapshotRequestCount()

        #expect(requestCount == 0)
    }

    @Test("Fresh account is only primed once until its state changes")
    func freshAccountOnlyPrimesOnce() async throws {
        WeeklyPrimerURLProtocol.reset()
        let account = makeAccount()
        let primer = WeeklyPrimer(session: makeSession())

        await primer.primeIfNeeded(accounts: [account], accountProvider: { _ in account })
        await primer.primeIfNeeded(accounts: [account], accountProvider: { _ in account })

        let requestCount = WeeklyPrimerURLProtocol.snapshotRequestCount()

        #expect(requestCount == 1)
    }

    @Test("Concurrent prime checks only send one request per account")
    func concurrentPrimeChecksDoNotDuplicateRequests() async throws {
        WeeklyPrimerURLProtocol.reset()
        WeeklyPrimerURLProtocol.responseDelaySeconds = 0.2
        let account = makeAccount()
        let primer = WeeklyPrimer(session: makeSession())

        async let first: Void = primer.primeIfNeeded(accounts: [account], accountProvider: { _ in account })
        async let second: Void = primer.primeIfNeeded(accounts: [account], accountProvider: { _ in account })
        _ = await (first, second)

        let requestCount = WeeklyPrimerURLProtocol.snapshotRequestCount()

        #expect(requestCount == 1)
    }
}
