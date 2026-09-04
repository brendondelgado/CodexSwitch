import Foundation
import Testing
@testable import CodexSwitch

private final class ReadinessTestState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func read() -> Value {
        lock.withLock { value }
    }

    func update(_ operation: (inout Value) -> Void) {
        lock.withLock { operation(&value) }
    }
}

@Suite("Local CLI readiness maintainer")
struct LocalCLIReadinessMaintainerTests {
    private let authority = LocalCLIReadinessMaintenanceAuthority(
        accountId: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
        providerAccountId: "account-1",
        activationGeneration: UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
    )

    @Test("Renewal starts with exactly one minute of ACK freshness remaining")
    func renewalCadence() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let observation = readinessObservation(pid: 41, acknowledgedAt: now)
        var maintainer = LocalCLIReadinessMaintainer()

        #expect(maintainer.beginMaintenanceIfNeeded(
            observation: observation,
            authority: authority,
            at: now.addingTimeInterval(239.999)
        ) == nil)
        let attempt = maintainer.beginMaintenanceIfNeeded(
            observation: observation,
            authority: authority,
            at: now.addingTimeInterval(240)
        )
        #expect(try #require(attempt).authority == authority)
        #expect(
            SwapEngine.localCLIReadinessMaximumReusableAcknowledgementAgeMilliseconds
                < SwapEngine.localCLIReadinessRenewalAgeMilliseconds
        )
    }

    @Test("A new unacknowledged CLI topology is immediately eligible")
    func newTopologySchedulesMaintenance() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var maintainer = LocalCLIReadinessMaintainer()

        #expect(maintainer.beginMaintenanceIfNeeded(
            observation: readinessObservation(pid: 41, acknowledgedAt: now),
            authority: authority,
            at: now
        ) == nil)
        #expect(maintainer.beginMaintenanceIfNeeded(
            observation: readinessObservation(pid: 42, acknowledgedAt: nil),
            authority: authority,
            at: now.addingTimeInterval(1)
        ) != nil)
    }

    @Test("Fresh ACK evidence for a different account is immediately renewed")
    func authMismatchSchedulesMaintenance() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var maintainer = LocalCLIReadinessMaintainer()

        #expect(maintainer.beginMaintenanceIfNeeded(
            observation: readinessObservation(
                pid: 41,
                acknowledgedAt: now,
                providerAccountId: "other-account"
            ),
            authority: authority,
            at: now
        ) != nil)
    }

    @Test("Single-flight and bounded backoff prevent maintenance loops")
    func singleFlightAndBackoff() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let observation = readinessObservation(pid: 41, acknowledgedAt: nil)
        var maintainer = LocalCLIReadinessMaintainer()

        let firstCandidate = maintainer.beginMaintenanceIfNeeded(
            observation: observation,
            authority: authority,
            at: now
        )
        let first = try #require(firstCandidate)
        #expect(maintainer.hasInFlightAttempt)
        #expect(maintainer.beginMaintenanceIfNeeded(
            observation: observation,
            authority: authority,
            at: now
        ) == nil)

        maintainer.complete(first, outcome: .failed, at: now)
        #expect(maintainer.beginMaintenanceIfNeeded(
            observation: observation,
            authority: authority,
            at: now.addingTimeInterval(14.999)
        ) == nil)
        let secondCandidate = maintainer.beginMaintenanceIfNeeded(
            observation: observation,
            authority: authority,
            at: now.addingTimeInterval(15)
        )
        let second = try #require(secondCandidate)
        maintainer.complete(second, outcome: .failed, at: now.addingTimeInterval(15))
        #expect(maintainer.beginMaintenanceIfNeeded(
            observation: observation,
            authority: authority,
            at: now.addingTimeInterval(44.999)
        ) == nil)
        #expect(maintainer.beginMaintenanceIfNeeded(
            observation: observation,
            authority: authority,
            at: now.addingTimeInterval(45)
        ) != nil)
    }

    @Test("Cross-process lease contention performs no reload or signal work")
    @MainActor
    func leaseContentionDoesNoWork() async throws {
        let root = try makeSecureTestDirectoryURL(prefix: "codexswitch-readiness-lease")
        defer { try? FileManager.default.removeItem(at: root) }
        let leaseURL = root.appendingPathComponent("activation.lock")
        let heldLease = try #require(
            try AccountActivationCrossProcessLease.acquire(at: leaseURL)
        )
        defer { heldLease.release() }
        let reloadCount = ReadinessTestState(0)

        let outcome = await LocalCLIReadinessMaintenanceRunner.run(
            transaction: AccountActivationTransaction(crossProcessLeaseURL: leaseURL),
            authority: authority,
            makeAuthorization: { _ in { true } },
            reload: { _ in
                reloadCount.update { $0 += 1 }
                return CodexReloadSummary(
                    discoveredRuntimeCount: 1,
                    acknowledgedRuntimeCount: 1
                )
            }
        )

        #expect(outcome == .leaseContended)
        #expect(reloadCount.read() == 0)
    }

    @Test("Revoked activation or auth authorization cannot reach the signal boundary")
    @MainActor
    func revocationStopsEffects() async throws {
        let root = try makeSecureTestDirectoryURL(prefix: "codexswitch-readiness-revocation")
        defer { try? FileManager.default.removeItem(at: root) }
        let authorization = ReadinessTestState(true)
        let signalCount = ReadinessTestState(0)

        let outcome = await LocalCLIReadinessMaintenanceRunner.run(
            transaction: AccountActivationTransaction(
                crossProcessLeaseURL: root.appendingPathComponent("activation.lock")
            ),
            authority: authority,
            makeAuthorization: { _ in { authorization.read() } },
            reload: { effectIsAuthorized in
                authorization.update { $0 = false }
                if effectIsAuthorized() {
                    signalCount.update { $0 += 1 }
                }
                return CodexReloadSummary(
                    discoveredRuntimeCount: 1,
                    acknowledgedRuntimeCount: 0,
                    operationFailed: true
                )
            }
        )

        #expect(outcome == .authorizationRevoked)
        #expect(signalCount.read() == 0)
    }

    @Test("Readiness discovery targets interactive CLI runtimes only")
    func runtimeFiltering() {
        let cli = process(pid: 41, arguments: ["codex", "resume", "thread-41"])
        let appServer = process(pid: 42, arguments: ["codex", "app-server"])
        let processes: [Int32: CodexIdentityBoundProcess] = [41: cli, 42: appServer]
        let discovery = SwapEngine.runtimeDiscoverySnapshot(
            from: CodexPGrepProcessSnapshot(pids: [41, 42], isComplete: true),
            runtimeKind: .localInteractiveCLI,
            requiredOwnerUID: 501,
            identityProvider: { processes[$0]?.identity },
            argumentProvider: { processes[$0]?.arguments },
            kernelExecutableIdentityProvider: { processes[$0]?.kernelExecutableIdentity }
        )

        #expect(discovery.isComplete)
        #expect(discovery.targets.map(\.process.identity.pid) == [41])
        #expect(discovery.targets.allSatisfy { $0.runtimeKind == .localInteractiveCLI })
    }

    private func readinessObservation(
        pid: Int32,
        acknowledgedAt: Date?,
        providerAccountId: String = "account-1"
    ) -> CodexLocalRuntimeReadinessObservation {
        let target = CodexRuntimeTarget(
            process: process(pid: pid, arguments: ["codex", "resume", "thread-\(pid)"]),
            runtimeKind: .localInteractiveCLI
        )
        let discovery = CodexRuntimeDiscoverySnapshot(targets: [target], isComplete: true)
        guard let acknowledgedAt else {
            return CodexLocalRuntimeReadinessObservation(
                discovery: discovery,
                evidence: CodexLocalRuntimeEvidenceSnapshot(runtimes: [], isComplete: false)
            )
        }
        let auth = CodexAuthFileIdentity(
            canonicalPath: "/Users/me/.codex/auth.json",
            device: 8,
            inode: 12_001,
            accountID: providerAccountId,
            completeTokenFingerprint: String(repeating: "a", count: 64)
        )
        let milliseconds = Int64(acknowledgedAt.timeIntervalSince1970 * 1_000)
        let binding = CodexReloadBinding(
            processIdentity: target.process.identity,
            kernelExecutableIdentity: target.process.kernelExecutableIdentity,
            runtimeKind: .localInteractiveCLI,
            authFileIdentity: auth,
            requestNonce: "nonce-\(pid)",
            issuedAtUnixMilliseconds: milliseconds
        )
        let acknowledgement = CodexReloadAcknowledgement(
            binding: binding,
            acknowledgedAtUnixMilliseconds: milliseconds,
            loadedTokenFingerprint: auth.completeTokenFingerprint,
            activeTokenFingerprint: auth.completeTokenFingerprint,
            frontendNotified: false,
            frontendWriteCount: 0,
            authGeneration: 1,
            reconnectReady: true
        )
        return CodexLocalRuntimeReadinessObservation(
            discovery: discovery,
            evidence: CodexLocalRuntimeEvidenceSnapshot(
                runtimes: [CodexLocalRuntimeEvidence(
                    observation: CodexRuntimeObservation(
                        target: target,
                        authFileIdentity: auth
                    ),
                    startupAcknowledgement: acknowledgement
                )],
                isComplete: true
            )
        )
    }

    private func process(
        pid: Int32,
        arguments: [String]
    ) -> CodexIdentityBoundProcess {
        let path = "/Users/me/.local/share/codexswitch/prepared-codex/codex"
        return CodexIdentityBoundProcess(
            identity: CodexSignalProcessIdentity(
                pid: pid,
                ownerUID: 501,
                executablePath: path,
                startSeconds: 1_000,
                startMicroseconds: UInt64(pid)
            ),
            kernelExecutableIdentity: CodexKernelExecutableIdentity(
                canonicalPath: path,
                device: 7,
                inode: UInt64(9_000 + pid)
            ),
            arguments: arguments
        )
    }
}
