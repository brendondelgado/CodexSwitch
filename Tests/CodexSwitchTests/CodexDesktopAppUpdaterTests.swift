import Darwin
import CryptoKit
import Foundation
import Testing
@testable import CodexSwitch

private actor AppcastTransportFake: DesktopAppcastHTTPTransport {
    private var responses: [DesktopAppcastHTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [DesktopAppcastHTTPResponse]) {
        self.responses = responses
    }

    func send(
        _ request: URLRequest,
        maximumBytes: Int
    ) async throws -> DesktopAppcastHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw NSError(domain: "AppcastTransportFake", code: 1)
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private actor ArchiveTransportFake: DesktopArchiveHTTPTransport {
    let bytes: Data
    let finalURL: URL
    private var requestCount = 0

    init(bytes: Data, finalURL: URL) {
        self.bytes = bytes
        self.finalURL = finalURL
    }

    func download(
        _ request: URLRequest,
        to destination: URL,
        maximumBytes: Int64
    ) async throws -> DesktopArchiveHTTPResponse {
        requestCount += 1
        guard Int64(bytes.count) <= maximumBytes else {
            throw NSError(domain: "ArchiveTransportFake", code: 1)
        }
        try bytes.write(to: destination, options: .withoutOverwriting)
        var info = stat()
        guard lstat(destination.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: "ArchiveTransportFake", code: 2)
        }
        return DesktopArchiveHTTPResponse(
            statusCode: 200,
            finalURL: finalURL,
            byteCount: Int64(bytes.count),
            fileIdentity: DesktopInstallPathIdentity(
                device: UInt64(bitPattern: Int64(info.st_dev)),
                inode: UInt64(info.st_ino)
            )
        )
    }

    func downloads() -> Int { requestCount }
}

private final class ConcurrentBundlePathProbe: @unchecked Sendable {
    private var process: Process?
    private var observationsURL: URL?
    private var stopURL: URL?

    func start(destination: URL) -> Bool {
        let root = destination.deletingLastPathComponent()
        let marker = destination.appendingPathComponent("marker")
        let identifier = UUID().uuidString
        let observations = root.appendingPathComponent("probe-\(identifier).observations")
        let ready = root.appendingPathComponent("probe-\(identifier).ready")
        let stopSignal = root.appendingPathComponent("probe-\(identifier).stop")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = [
            "-c",
            #"""
            marker="$1"
            observations="$2"
            ready="$3"
            stop="$4"
            while [ ! -e "$stop" ]; do
              if value="$(/bin/cat "$marker" 2>/dev/null)"; then
                printf '%s\n' "$value" >> "$observations"
              else
                printf '%s\n' '__missing__' >> "$observations"
              fi
              if [ ! -e "$ready" ]; then
                : > "$ready"
              fi
            done
            """#,
            "codexswitch-bundle-probe",
            marker.path,
            observations.path,
            ready.path,
            stopSignal.path,
        ]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice

        do {
            try Data().write(to: observations, options: .withoutOverwriting)
            try child.run()
        } catch {
            try? FileManager.default.removeItem(at: observations)
            return false
        }
        process = child
        observationsURL = observations
        stopURL = stopSignal

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path),
              child.isRunning,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let readyWasObserved = FileManager.default.fileExists(atPath: ready.path)
        if !readyWasObserved { _ = stop() }
        return readyWasObserved
    }

    func stop() -> Bool {
        guard let process else { return true }
        if let stopURL { try? Data().write(to: stopURL, options: .withoutOverwriting) }

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            self.process = nil
            return false
        }
        self.process = nil
        return process.terminationStatus == 0
    }

    var sawInvalidPathState: Bool {
        !observedValues.isSubset(of: ["old", "new"])
    }

    var observedValues: Set<String> {
        guard let observationsURL,
              let data = try? Data(contentsOf: observationsURL) else {
            return []
        }
        return Set(
            String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        )
    }
}

private final class NeverTerminatingProcessFake: DesktopUpdaterTerminableProcess {
    private(set) var gracefulRequests = 0
    private(set) var forcedRequests = 0
    private(set) var detachedReaperRequests = 0

    func requestGracefulTermination() { gracefulRequests += 1 }
    func requestForcedTermination() { forcedRequests += 1 }
    func detachReaper() { detachedReaperRequests += 1 }
}

private final class RunningApplicationObserverFake: DesktopApplicationRuntimeObserving {
    let running: Bool
    private(set) var terminationRequestCount = 0

    init(running: Bool) {
        self.running = running
    }

    func isRunning() -> Bool { running }
    func requestTermination() { terminationRequestCount += 1 }
}

private final class InMemoryUserDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }

    override func synchronize() -> Bool {
        true
    }
}

private struct TestDesktopUpdateOperationScope {
    let stateMachine: CodexDesktopUpdateStateMachine
    let owner: DesktopUpdateOperationOwner
    let lifetime: DesktopUpdateOperationLifetime
}

private func makeTestOperationScope(
    root: URL,
    allowedDestinations: [URL],
    leaseURL: URL? = nil,
    operation: CodexDesktopUpdateOperation = .installingStagedUpdate
) async throws -> TestDesktopUpdateOperationScope {
    let stateMachine = CodexDesktopUpdateStateMachine()
    let owner = DesktopUpdateOperationOwner(
        stateMachine: stateMachine,
        leaseURL: leaseURL ?? root.appendingPathComponent("desktop-update-test.lock"),
        updateRoot: root,
        allowedDestinations: allowedDestinations
    )
    switch await owner.acquire(operation, epoch: .standalone()) {
    case .acquired(let lifetime):
        return TestDesktopUpdateOperationScope(
            stateMachine: stateMachine,
            owner: owner,
            lifetime: lifetime
        )
    case .busy:
        throw NSError(domain: "TestDesktopUpdateOperationScope", code: 1)
    case .cancelled:
        throw CancellationError()
    case .failed(let message):
        throw NSError(
            domain: "TestDesktopUpdateOperationScope",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private func makeDesktopUpdaterTestSubprocess(
    filter: String,
    environment additions: [String: String]
) throws -> Process {
    let process = Process()
    try configureSwiftTestingSubprocess(process, filter: filter)
    process.environment = ProcessInfo.processInfo.environment.merging(additions) {
        _, childValue in childValue
    }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    return process
}

private actor SuspendedDesktopUpdateExecutor: CodexDesktopUpdateExecuting {
    private var maintenanceStarted = false
    private var maintenanceFinished = false

    func performStartupMaintenance(
        temporaryRoot: URL,
        now: Date,
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopStartupMaintenanceReport {
        maintenanceStarted = true
        while !Task.isCancelled, epoch.isCurrent() {
            await Task.yield()
        }
        maintenanceFinished = true
        return .empty
    }

    func prepareLatestUpdate(
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopUpdatePreparationResult {
        .failed("Unexpected update preparation")
    }

    func installStagedUpdateIfReady(
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopStagedInstallResult {
        .failed("Unexpected staged installation")
    }

    func didStartMaintenance() -> Bool {
        maintenanceStarted
    }

    func didFinishMaintenance() -> Bool {
        maintenanceFinished
    }
}

private actor EpochDesktopUpdateExecutor: CodexDesktopUpdateExecuting {
    private var installContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var installStartCount = 0
    private var installFinishCount = 0
    private var committedInstallCount = 0

    func performStartupMaintenance(
        temporaryRoot: URL,
        now: Date,
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopStartupMaintenanceReport {
        .empty
    }

    func prepareLatestUpdate(
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopUpdatePreparationResult {
        .upToDate("test")
    }

    func installStagedUpdateIfReady(
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopStagedInstallResult {
        let identifier = installStartCount
        installStartCount += 1
        await withCheckedContinuation { continuation in
            installContinuations[identifier] = continuation
        }
        installFinishCount += 1
        if Task.isCancelled || !epoch.isCurrent() { return .deferred("cancelled") }
        committedInstallCount += 1
        return .none
    }

    func resumeInstall(_ identifier: Int) {
        installContinuations.removeValue(forKey: identifier)?.resume()
    }

    func counts() -> (started: Int, finished: Int, committed: Int) {
        (installStartCount, installFinishCount, committedInstallCount)
    }
}

private actor CleanupRetryDesktopUpdateExecutor: CodexDesktopUpdateExecuting {
    private var installIssued = false
    private var cleanupPending = false
    private var prepareCount = 0
    private var recoveryCallCount = 0
    private var completedCleanupCount = 0

    func recoverInterruptedInstall(
        epoch: DesktopUpdateRunEpoch
    ) async throws -> DesktopInstallRecoveryResult {
        recoveryCallCount += 1
        guard cleanupPending else { return .none }
        cleanupPending = false
        completedCleanupCount += 1
        return .completedCommit
    }

    func performStartupMaintenance(
        temporaryRoot: URL,
        now: Date,
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopStartupMaintenanceReport {
        .empty
    }

    func prepareLatestUpdate(
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopUpdatePreparationResult {
        prepareCount += 1
        return .upToDate("test")
    }

    func installStagedUpdateIfReady(
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopStagedInstallResult {
        guard !installIssued else { return .none }
        installIssued = true
        cleanupPending = true
        let release = CodexDesktopAppRelease(
            shortVersion: "26.707.62119",
            bundleVersion: "5211",
            downloadURL: URL(
                string: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-5211.zip"
            )!,
            archiveSHA256: String(repeating: "f", count: 64)
        )
        let transaction = CodexDesktopInstallationTransactionCompletion(
            identifier: 1,
            kind: .stagedUpdate,
            committed: true,
            cleanupPending: true
        )
        return .installed(
            path: "/Applications/ChatGPT.app",
            release: release,
            transaction: transaction,
            cleanupPending: true
        )
    }

    func counts() -> (
        prepared: Int,
        recoveries: Int,
        completedCleanups: Int
    ) {
        (prepareCount, recoveryCallCount, completedCleanupCount)
    }
}

@Suite("Codex desktop app updater")
struct CodexDesktopAppUpdaterTests {
    @Test("Updater acquisition is serialized without queuing continuations")
    func updaterAcquisitionIsNonQueuing() async throws {
        let stateMachine = CodexDesktopUpdateStateMachine()
        let firstPermit = try #require(await stateMachine.acquire(.checking))
        let secondPermit = await stateMachine.acquire(.installingStagedUpdate)

        #expect(await stateMachine.currentOperation() == .checking)
        #expect(await stateMachine.queuedOperationCount() == 0)
        #expect(secondPermit == nil)

        await stateMachine.release(firstPermit)
        let nextPermit = try #require(
            await stateMachine.acquire(.installingStagedUpdate)
        )
        #expect(await stateMachine.currentOperation() == .installingStagedUpdate)
        await stateMachine.release(nextPermit)
        #expect(await stateMachine.currentOperation() == nil)
    }

    @Test("Operation lease remains single-flight through the download phase")
    func operationLeaseCoversDownloadAndPublication() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let leaseURL = root.appendingPathComponent("shared-update-operation.lock")
        let first = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination],
            leaseURL: leaseURL,
            operation: .staging
        )
        try first.lifetime.enter(.download)

        let child = try makeDesktopUpdaterTestSubprocess(
            filter: "operationLeaseDownloadChildProcess",
            environment: [
                "CODEXSWITCH_DOWNLOAD_LEASE_CHILD": "contender",
                "CODEXSWITCH_DOWNLOAD_LEASE_ROOT": root.path,
                "CODEXSWITCH_DOWNLOAD_LEASE_DESTINATION": destination.path,
                "CODEXSWITCH_DOWNLOAD_LEASE_PATH": leaseURL.path,
            ]
        )
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
        }
        let exitDeadline = ContinuousClock.now + .seconds(10)
        while child.isRunning, ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!child.isRunning)
        #expect(child.terminationStatus == 0)

        _ = await first.owner.finish(first.lifetime)
        let secondOwner = DesktopUpdateOperationOwner(
            stateMachine: CodexDesktopUpdateStateMachine(),
            leaseURL: leaseURL,
            updateRoot: root,
            allowedDestinations: [destination]
        )
        let next = await secondOwner.acquire(.staging, epoch: .standalone())
        guard case .acquired(let nextLifetime) = next else {
            Issue.record("The operation lease must become available after completion")
            return
        }
        _ = await secondOwner.finish(nextLifetime)
    }

    @Test("A second updater process is busy while download owns the operation lease")
    func operationLeaseBlocksSecondProcessDuringDownload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let leaseURL = root.appendingPathComponent("shared-download-operation.lock")
        let ready = root.appendingPathComponent("download-child-ready")
        let release = root.appendingPathComponent("download-child-release")
        let child = try makeDesktopUpdaterTestSubprocess(
            filter: "operationLeaseDownloadChildProcess",
            environment: [
                "CODEXSWITCH_DOWNLOAD_LEASE_CHILD": "holder",
                "CODEXSWITCH_DOWNLOAD_LEASE_ROOT": root.path,
                "CODEXSWITCH_DOWNLOAD_LEASE_DESTINATION": destination.path,
                "CODEXSWITCH_DOWNLOAD_LEASE_PATH": leaseURL.path,
                "CODEXSWITCH_DOWNLOAD_LEASE_READY": ready.path,
                "CODEXSWITCH_DOWNLOAD_LEASE_RELEASE": release.path,
            ]
        )
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
            }
        }

        let readyDeadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: ready.path),
              child.isRunning,
              ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))

        let competingOwner = DesktopUpdateOperationOwner(
            stateMachine: CodexDesktopUpdateStateMachine(),
            leaseURL: leaseURL,
            updateRoot: root,
            allowedDestinations: [destination]
        )
        let collision = await competingOwner.acquire(.staging, epoch: .standalone())
        guard case .busy = collision else {
            Issue.record("A second process must not enter staging during download")
            return
        }

        try Data().write(to: release)
        let exitDeadline = ContinuousClock.now + .seconds(10)
        while child.isRunning, ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!child.isRunning)
        #expect(child.terminationStatus == 0)
    }

    @Test("Download lease child process helper")
    func operationLeaseDownloadChildProcess() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let role = environment["CODEXSWITCH_DOWNLOAD_LEASE_CHILD"] else { return }
        let root = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_DOWNLOAD_LEASE_ROOT"])
        )
        let destination = URL(
            fileURLWithPath: try #require(
                environment["CODEXSWITCH_DOWNLOAD_LEASE_DESTINATION"]
            )
        )
        let leaseURL = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_DOWNLOAD_LEASE_PATH"])
        )
        let owner = DesktopUpdateOperationOwner(
            stateMachine: CodexDesktopUpdateStateMachine(),
            leaseURL: leaseURL,
            updateRoot: root,
            allowedDestinations: [destination]
        )
        let acquisition = await owner.acquire(.staging, epoch: .standalone())
        if role == "contender" {
            guard case .busy = acquisition else {
                Issue.record("A competing updater must remain busy during download")
                return
            }
            return
        }
        guard role == "holder" else {
            Issue.record("Unknown download lease child role: \(role)")
            return
        }
        guard case .acquired(let lifetime) = acquisition else {
            Issue.record("Download child could not acquire the operation lease")
            return
        }
        let ready = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_DOWNLOAD_LEASE_READY"])
        )
        let release = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_DOWNLOAD_LEASE_RELEASE"])
        )
        try lifetime.enter(.download)
        try Data().write(to: ready)
        while !FileManager.default.fileExists(atPath: release.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await owner.finish(lifetime)
    }

    @Test("A competing process is busy after actual authoritative publication")
    func operationLeaseCoversAuthoritativePublication() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let leaseURL = root.appendingPathComponent("shared-publication-operation.lock")
        let ready = root.appendingPathComponent("publication-child-ready")
        let release = root.appendingPathComponent("publication-child-release")
        let child = try makeDesktopUpdaterTestSubprocess(
            filter: "operationLeasePublicationChildProcess",
            environment: [
                "CODEXSWITCH_PUBLICATION_LEASE_CHILD": "1",
                "CODEXSWITCH_PUBLICATION_LEASE_ROOT": root.path,
                "CODEXSWITCH_PUBLICATION_LEASE_DESTINATION": destination.path,
                "CODEXSWITCH_PUBLICATION_LEASE_PATH": leaseURL.path,
                "CODEXSWITCH_PUBLICATION_LEASE_READY": ready.path,
                "CODEXSWITCH_PUBLICATION_LEASE_RELEASE": release.path,
            ]
        )
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
        }

        let readyDeadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: ready.path),
              child.isRunning,
              ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        #expect(CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: root) != nil)

        let competingOwner = DesktopUpdateOperationOwner(
            stateMachine: CodexDesktopUpdateStateMachine(),
            leaseURL: leaseURL,
            updateRoot: root,
            allowedDestinations: [destination]
        )
        let collision = await competingOwner.acquire(.staging, epoch: .standalone())
        guard case .busy = collision else {
            Issue.record("Published work must retain the cross-process lease until completion")
            return
        }

        try Data().write(to: release)
        let exitDeadline = ContinuousClock.now + .seconds(10)
        while child.isRunning, ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!child.isRunning)
        #expect(child.terminationStatus == 0)
    }

    @Test("Authoritative publication lease child process helper")
    func operationLeasePublicationChildProcess() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEXSWITCH_PUBLICATION_LEASE_CHILD"] == "1" else { return }
        let root = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_PUBLICATION_LEASE_ROOT"])
        )
        let destination = URL(
            fileURLWithPath: try #require(
                environment["CODEXSWITCH_PUBLICATION_LEASE_DESTINATION"]
            )
        )
        let leaseURL = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_PUBLICATION_LEASE_PATH"])
        )
        let ready = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_PUBLICATION_LEASE_READY"])
        )
        let releaseSignal = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_PUBLICATION_LEASE_RELEASE"])
        )
        let scope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination],
            leaseURL: leaseURL,
            operation: .staging
        )
        let digest = String(repeating: "1", count: 64)
        let appcastRelease = CodexDesktopAppRelease(
            shortVersion: "26.707.62119",
            bundleVersion: "5211",
            downloadURL: URL(
                string: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-5211.zip"
            )!,
            archiveSHA256: digest
        )
        let result = await DesktopUpdateStagingService(root: root).prepare(
            release: appcastRelease,
            installed: nil,
            lifetime: scope.lifetime,
            fullValidation: { _, _, _ in .valid },
            download: {
                try scope.lifetime.enter(.download)
                return try writeFakeStagedUpdate(
                    in: root,
                    bundleVersion: appcastRelease.bundleVersion,
                    legacyLayout: false,
                    includeSeal: false,
                    persistAuthoritative: false,
                    downloadURL: appcastRelease.downloadURL,
                    archiveSHA256: digest
                )
            }
        )
        guard case .staged = result else {
            Issue.record("Publication child did not publish an authoritative generation")
            return
        }
        try Data().write(to: ready)
        while !FileManager.default.fileExists(atPath: releaseSignal.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await scope.owner.finish(scope.lifetime)
    }

    @Test("Applications watcher returns immediately and coalesces transaction callbacks")
    func applicationsWatcherDoesNotQueueAContinuation() async throws {
        let stateMachine = CodexDesktopUpdateStateMachine()
        let permit = try #require(
            await stateMachine.acquire(.installingStagedUpdate)
        )
        let identifier = try await stateMachine.beginInstallationTransaction(
            for: permit,
            kind: .stagedUpdate
        ).get()
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(
            await stateMachine.applicationsDirectoryChangeDisposition(now: now)
                == .internalTransactionChangeSuppressed(identifier: identifier)
        )

        let completion = try await stateMachine.finishInstallationTransaction(
            identifier: identifier,
            permit: permit,
            committed: true,
            now: now
        ).get()
        #expect(
            await stateMachine.applicationsDirectoryChangeDisposition(
                now: now.addingTimeInterval(0.05)
            ) == .internalTransactionCompleted(completion)
        )
        #expect(
            await stateMachine.applicationsDirectoryChangeDisposition(
                now: now.addingTimeInterval(0.1)
            ) == .internalTransactionChangeSuppressed(identifier: identifier)
        )
        #expect(
            await stateMachine.applicationsDirectoryChangeDisposition(
                now: now.addingTimeInterval(
                    CodexDesktopUpdateStateMachine.watcherCompletionGracePeriod + 1
                )
            ) == .externalChange
        )

        await stateMachine.release(permit)
    }

    @Test("Failed update checks use bounded exponential backoff")
    func failedChecksUseBoundedExponentialBackoff() {
        var backoff = CodexDesktopUpdateBackoff()
        let now = Date(timeIntervalSince1970: 10_000)
        let expectedDelays: [TimeInterval] = [60, 120, 240, 480, 960, 1_920, 3_600, 3_600]

        for expectedDelay in expectedDelays {
            #expect(backoff.recordFailure(at: now) == expectedDelay)
            #expect(!backoff.permitsAttempt(at: now.addingTimeInterval(expectedDelay - 0.1)))
            #expect(backoff.permitsAttempt(at: now.addingTimeInterval(expectedDelay)))
        }

        backoff.recordSuccess()
        #expect(backoff.consecutiveFailureCount == 0)
        #expect(backoff.retryNotBefore == nil)
        #expect(backoff.permitsAttempt(at: now))
    }

    @Test("A 304 without cache retries once without validators")
    func appcast304WithoutCacheRetriesUnconditionally() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("appcast-cache.json")
        let body = appcastData(shortVersion: "26.707.62119", bundleVersion: "5211")
        let transport = AppcastTransportFake(responses: [
            DesktopAppcastHTTPResponse(
                statusCode: 304,
                body: Data(),
                etag: nil,
                lastModified: nil,
                finalURL: URL(string: "https://example.test/appcast.xml")!
            ),
            DesktopAppcastHTTPResponse(
                statusCode: 200,
                body: body,
                etag: "fresh-etag",
                lastModified: "Mon, 13 Jul 2026 12:00:00 GMT",
                finalURL: URL(string: "https://example.test/appcast.xml")!
            ),
        ])
        let client = DesktopAppcastClient(
            appcastURL: URL(string: "https://example.test/appcast.xml")!,
            cacheURL: cache,
            transport: transport
        )

        let release = try await client.fetchLatestRelease()
        let requests = await transport.recordedRequests()

        #expect(release.bundleVersion == "5211")
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == nil)
        let envelope = try JSONDecoder().decode(
            DesktopAppcastCacheEnvelope.self,
            from: Data(contentsOf: cache)
        )
        #expect(envelope.appcastBytes == body)
        #expect(envelope.etag == "fresh-etag")
    }

    @Test("A 304 with malformed cache clears stale state and retries once")
    func appcast304WithMalformedCacheRetriesUnconditionally() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("appcast-cache.json")
        let malformed = DesktopAppcastCacheEnvelope(
            appcastBytes: Data("not-an-appcast".utf8),
            etag: "stale-etag",
            lastModified: "stale-date"
        )
        try JSONEncoder().encode(malformed).write(to: cache)
        let body = appcastData(shortVersion: "26.707.62120", bundleVersion: "5212")
        let transport = AppcastTransportFake(responses: [
            DesktopAppcastHTTPResponse(
                statusCode: 304,
                body: Data(),
                etag: nil,
                lastModified: nil,
                finalURL: URL(string: "https://example.test/appcast.xml")!
            ),
            DesktopAppcastHTTPResponse(
                statusCode: 200,
                body: body,
                etag: "new-etag",
                lastModified: nil,
                finalURL: URL(string: "https://example.test/appcast.xml")!
            ),
        ])
        let client = DesktopAppcastClient(
            appcastURL: URL(string: "https://example.test/appcast.xml")!,
            cacheURL: cache,
            transport: transport
        )

        let release = try await client.fetchLatestRelease()
        let requests = await transport.recordedRequests()

        #expect(release.bundleVersion == "5212")
        #expect(requests.count == 2)
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "If-None-Match") == nil
                && $0.value(forHTTPHeaderField: "If-Modified-Since") == nil
        })
        let envelope = try JSONDecoder().decode(
            DesktopAppcastCacheEnvelope.self,
            from: Data(contentsOf: cache)
        )
        #expect(envelope.appcastBytes == body)
        #expect(envelope.etag == "new-etag")
    }

    @Test("An oversized appcast is rejected before parsing or cache commit")
    func oversizedAppcastIsRejected() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appcastURL = URL(string: "https://example.test/appcast.xml")!
        let transport = AppcastTransportFake(responses: [
            DesktopAppcastHTTPResponse(
                statusCode: 200,
                body: Data(
                    repeating: 0x41,
                    count: DesktopAppcastClient.maximumResponseBytes + 1
                ),
                etag: "oversized",
                lastModified: nil,
                finalURL: appcastURL
            ),
        ])
        let cache = root.appendingPathComponent("appcast-cache.json")
        let client = DesktopAppcastClient(
            appcastURL: appcastURL,
            cacheURL: cache,
            transport: transport
        )

        await #expect(throws: (any Error).self) {
            _ = try await client.fetchLatestRelease()
        }
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("Gatekeeper beta subsystem error after strict success preserves the stage")
    func gatekeeperSubsystemErrorPreservesStage() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = try writeFakeStagedUpdate(
            in: root,
            bundleVersion: "5211",
            legacyLayout: true,
            includeSeal: false
        )
        let exactError = CodexDesktopCodeSignatureValidation.transientAssessmentSubsystemError
        var assessmentCallCount = 0

        let resolution = CodexDesktopUpdateStorage.resolveAuthoritativeGeneration(
            staged,
            in: root
        ) { _, _, _ in
            CodexDesktopCodeSignatureValidation.validateTrust(
                strictVerification: {
                    CodexDesktopTrustCommandResult(terminationStatus: 0)
                },
                gatekeeperAssessment: {
                    assessmentCallCount += 1
                    return CodexDesktopTrustCommandResult(
                        terminationStatus: 1,
                        standardError: exactError + "\n"
                    )
                }
            )
        }

        #expect(assessmentCallCount == 1)
        #expect(resolution == .preserveForRetry(exactError))
        #expect(CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: root) == staged)
        #expect(FileManager.default.fileExists(atPath: staged.appPath))
    }

    @Test("Strict failure with subsystem text revokes staging and skips Gatekeeper")
    func strictFailureWithSubsystemTextRevokesStage() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = try writeFakeStagedUpdate(
            in: root,
            bundleVersion: "5211",
            legacyLayout: false,
            includeSeal: false
        )
        var assessmentCallCount = 0

        let resolution = CodexDesktopUpdateStorage.resolveAuthoritativeGeneration(
            staged,
            in: root
        ) { _, _, _ in
            CodexDesktopCodeSignatureValidation.validateTrust(
                strictVerification: {
                    CodexDesktopTrustCommandResult(
                        terminationStatus: 1,
                        standardError: CodexDesktopCodeSignatureValidation
                            .transientAssessmentSubsystemError
                    )
                },
                gatekeeperAssessment: {
                    assessmentCallCount += 1
                    return CodexDesktopTrustCommandResult(terminationStatus: 0)
                }
            )
        }

        #expect(resolution == .revoke("codesign verification exited with status 1"))
        #expect(assessmentCallCount == 0)

        let quarantined = try CodexDesktopUpdateStorage.quarantineAuthoritativeUpdate(
            staged,
            in: root,
            identifier: "00000000-0000-0000-0000-000000000004"
        )
        #expect(
            quarantined?.lastPathComponent
                == ".quarantine-00000000-0000-0000-0000-000000000004"
        )
        #expect(!FileManager.default.fileExists(atPath: staged.appPath))
        #expect(CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: root) == nil)
    }

    @Test("Other strict failures are invalid and skip Gatekeeper")
    func otherStrictFailureIsInvalid() {
        var assessmentCallCount = 0
        let result = CodexDesktopCodeSignatureValidation.validateTrust(
            strictVerification: {
                CodexDesktopTrustCommandResult(
                    terminationStatus: 2,
                    standardError: "code object is not signed at all"
                )
            },
            gatekeeperAssessment: {
                assessmentCallCount += 1
                return CodexDesktopTrustCommandResult(terminationStatus: 0)
            }
        )

        #expect(result == .invalid("codesign verification exited with status 2"))
        #expect(assessmentCallCount == 0)
    }

    @Test("Strict success and Gatekeeper success are valid")
    func strictAndGatekeeperSuccessAreValid() {
        var assessmentCallCount = 0
        let result = CodexDesktopCodeSignatureValidation.validateTrust(
            strictVerification: {
                CodexDesktopTrustCommandResult(terminationStatus: 0)
            },
            gatekeeperAssessment: {
                assessmentCallCount += 1
                return CodexDesktopTrustCommandResult(terminationStatus: 0)
            }
        )

        #expect(result == .valid)
        #expect(assessmentCallCount == 1)
    }

    @Test("Gatekeeper subsystem text on stdout does not weaken a rejection")
    func gatekeeperSubsystemTextOnStdoutIsInvalid() {
        let result = CodexDesktopCodeSignatureValidation.validateTrust(
            strictVerification: {
                CodexDesktopTrustCommandResult(terminationStatus: 0)
            },
            gatekeeperAssessment: {
                CodexDesktopTrustCommandResult(
                    terminationStatus: 3,
                    standardOutput: CodexDesktopCodeSignatureValidation
                        .transientAssessmentSubsystemError
                )
            }
        )

        #expect(result == .invalid("Gatekeeper assessment rejected bundle with status 3"))
    }

    @Test("Successful strict and Gatekeeper stages still enforce OpenAI identity")
    func successfulTrustStagesEnforceOpenAIIdentity() {
        var wrongIdentityStages: [String] = []
        let wrongIdentity = CodexDesktopCodeSignatureValidation.validateOfficialBundleTrust(
            strictVerification: {
                wrongIdentityStages.append("strict")
                return CodexDesktopTrustCommandResult(terminationStatus: 0)
            },
            gatekeeperAssessment: {
                wrongIdentityStages.append("assessment")
                return CodexDesktopTrustCommandResult(terminationStatus: 0)
            },
            identityInspection: {
                wrongIdentityStages.append("identity")
                return CodexDesktopCodeSignatureValidation.classifySigningIdentity(
                    DesktopSigningIdentityEvidence(
                        appleAnchorSatisfied: true,
                        teamIdentifiers: ["NOTOPENAI"],
                        bundleIdentifiers: ["com.openai.codex"]
                    )
                )
            }
        )

        var expectedIdentityStages: [String] = []
        let expectedIdentity = CodexDesktopCodeSignatureValidation.validateOfficialBundleTrust(
            strictVerification: {
                expectedIdentityStages.append("strict")
                return CodexDesktopTrustCommandResult(terminationStatus: 0)
            },
            gatekeeperAssessment: {
                expectedIdentityStages.append("assessment")
                return CodexDesktopTrustCommandResult(terminationStatus: 0)
            },
            identityInspection: {
                expectedIdentityStages.append("identity")
                return CodexDesktopCodeSignatureValidation.classifySigningIdentity(
                    DesktopSigningIdentityEvidence(
                        appleAnchorSatisfied: true,
                        teamIdentifiers: ["2DC432GLL2"],
                        bundleIdentifiers: ["com.openai.codex"]
                    )
                )
            }
        )

        #expect(
            wrongIdentity
                == .invalid("bundle signing Team ID did not exactly match OpenAI")
        )
        #expect(wrongIdentityStages == ["strict", "assessment", "identity"])
        #expect(expectedIdentity == .valid)
        #expect(expectedIdentityStages == ["strict", "assessment", "identity"])
    }

    @Test("Gatekeeper status zero wins even when advisory stderr is present")
    func gatekeeperSuccessWinsOverAdvisoryText() {
        let result = CodexDesktopCodeSignatureValidation.classifyGatekeeperAssessment(
            CodexDesktopTrustCommandResult(
                terminationStatus: 0,
                standardError: CodexDesktopCodeSignatureValidation
                    .transientAssessmentSubsystemError
            )
        )

        #expect(result == .valid)
    }

    @Test("Signing identity requires one exact team and bundle identifier")
    func signingIdentityRejectsDuplicateConflictingAndSubstringFields() {
        let classify: ([String], [String]) -> CodexDesktopBundleValidationResult = {
            teams, identifiers in
            CodexDesktopCodeSignatureValidation.classifySigningIdentity(
                DesktopSigningIdentityEvidence(
                    appleAnchorSatisfied: true,
                    teamIdentifiers: teams,
                    bundleIdentifiers: identifiers
                )
            )
        }

        #expect(classify(["2DC432GLL2", "EVILTEAM"], ["com.openai.codex"]) != .valid)
        #expect(classify(["2DC432GLL2", "2DC432GLL2"], ["com.openai.codex"]) != .valid)
        #expect(classify(["prefix-2DC432GLL2-suffix"], ["com.openai.codex"]) != .valid)
        #expect(classify(["2DC432GLL2"], ["com.openai.chat"]) != .valid)
        #expect(classify(["2DC432GLL2"], ["prefix.com.openai.codex.suffix"]) != .valid)
        #expect(classify(["2DC432GLL2"], ["com.openai.codex"]) == .valid)
        #expect(
            CodexDesktopCodeSignatureValidation.classifySigningIdentity(
                DesktopSigningIdentityEvidence(
                    appleAnchorSatisfied: false,
                    teamIdentifiers: ["2DC432GLL2"],
                    bundleIdentifiers: ["com.openai.codex"]
                )
            ) != .valid
        )
    }

    @Test("Advisory assessment preserves a download and reuses it without redownloading")
    func advisoryAssessmentReusesDownloadedGeneration() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = CodexDesktopAppRelease(
            shortVersion: "26.707.62119",
            bundleVersion: "5211",
            downloadURL: URL(
                string: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-test.zip"
            )!
        )
        let advisory = CodexDesktopCodeSignatureValidation.transientAssessmentSubsystemError
        var downloadCount = 0
        var validationCount = 0

        let first = try await CodexDesktopDownloadedGenerationCoordinator.prepare(
            release: release,
            in: root,
            fullValidation: { _, _, _ in
                validationCount += 1
                return .unavailable(advisory)
            },
            download: {
                downloadCount += 1
                return try writeFakeStagedUpdate(
                    in: root,
                    bundleVersion: release.bundleVersion,
                    legacyLayout: false,
                    includeSeal: false,
                    persistAuthoritative: false
                )
            }
        )
        let pending: CodexDesktopStagedUpdate
        switch first {
        case .pendingAssessment(let update, let reason):
            pending = update
            #expect(reason == advisory)
        case .staged:
            Issue.record("Advisory assessment must not authorize the generation")
            return
        }

        #expect(downloadCount == 1)
        #expect(validationCount == 1)
        #expect(CodexDesktopUpdateStorage.loadPendingUpdate(in: root) == pending)
        #expect(CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: root) == nil)
        #expect(FileManager.default.fileExists(atPath: pending.appPath))

        let cleanup = try CodexDesktopUpdateStorage.cleanupNonAuthoritativeArtifacts(
            in: root,
            installedBundleVersion: nil,
            now: Date().addingTimeInterval(
                CodexDesktopUpdateStorage.retainedArtifactMaximumAge + 60
            ),
            maximumRetainedCount: 0,
            maximumRetainedBytes: 0
        )
        #expect(cleanup.removedArtifactCount == 0)
        #expect(FileManager.default.fileExists(atPath: pending.appPath))

        let second = try await CodexDesktopDownloadedGenerationCoordinator.prepare(
            release: release,
            in: root,
            fullValidation: { _, _, _ in
                validationCount += 1
                return .valid
            },
            download: {
                downloadCount += 1
                throw NSError(domain: "UpdaterTest", code: 2)
            }
        )
        let staged: CodexDesktopStagedUpdate
        switch second {
        case .staged(let update):
            staged = update
        case .pendingAssessment:
            Issue.record("Successful reassessment must promote the pending generation")
            return
        }

        #expect(downloadCount == 1)
        #expect(validationCount == 2)
        #expect(staged.appPath == pending.appPath)
        #expect(staged.validationSeal != nil)
        #expect(CodexDesktopUpdateStorage.loadPendingUpdate(in: root) == nil)
        #expect(CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: root) == staged)
        #expect(FileManager.default.fileExists(atPath: staged.appPath))
    }

    @Test("Periodic checks reuse the same authoritative payload and build")
    func periodicCheckDoesNotRestageSamePayload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = String(repeating: "a", count: 64)
        let release = CodexDesktopAppRelease(
            shortVersion: "26.707.62119",
            bundleVersion: "5211",
            downloadURL: URL(
                string: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-test.zip"
            )!,
            archiveSHA256: digest,
            archiveLength: 123
        )
        let staged = try writeFakeStagedUpdate(
            in: root,
            bundleVersion: release.bundleVersion,
            legacyLayout: false,
            includeSeal: true,
            archiveSHA256: digest,
            archiveLength: 123
        )
        #expect(staged.matches(release))
        #expect(CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: root) == staged)
        let service = DesktopUpdateStagingService(root: root)
        var downloadCount = 0
        var validationCount = 0
        let checkTime = try #require(staged.validationSeal).validatedAt
            .addingTimeInterval(1)

        for _ in 0..<2 {
            let result = await service.prepare(
                release: release,
                installed: nil,
                now: checkTime,
                fullValidation: { _, _, _ in
                    validationCount += 1
                    return .valid
                },
                download: {
                    downloadCount += 1
                    throw NSError(domain: "UnexpectedDesktopRedownload", code: 1)
                }
            )
            guard case .alreadyStaged(let reused) = result else {
                Issue.record("An unchanged authoritative payload must be reused")
                return
            }
            #expect(reused.archiveSHA256 == digest)
        }

        #expect(downloadCount == 0)
        #expect(validationCount == 0)
    }

    @Test("Definitive validation quarantines a newly downloaded pending generation")
    func definitiveValidationQuarantinesDownloadedGeneration() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = CodexDesktopAppRelease(
            shortVersion: "26.707.62119",
            bundleVersion: "5211",
            downloadURL: URL(
                string: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-test.zip"
            )!
        )
        var downloadedPath: String?

        do {
            _ = try await CodexDesktopDownloadedGenerationCoordinator.prepare(
                release: release,
                in: root,
                fullValidation: { _, _, _ in
                    .invalid("Gatekeeper assessment rejected bundle with status 3")
                },
                download: {
                    let downloaded = try writeFakeStagedUpdate(
                        in: root,
                        bundleVersion: release.bundleVersion,
                        legacyLayout: false,
                        includeSeal: false,
                        persistAuthoritative: false
                    )
                    downloadedPath = downloaded.appPath
                    return downloaded
                }
            )
            Issue.record("Definitive validation failure must reject the pending generation")
        } catch {
            // Expected: the coordinator quarantines before surfacing the failure.
        }

        let appPath = try #require(downloadedPath)
        let quarantineCount = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(CodexDesktopUpdateStorage.quarantinePrefix) }
            .count
        #expect(quarantineCount == 1)
        #expect(!FileManager.default.fileExists(atPath: appPath))
        #expect(CodexDesktopUpdateStorage.loadPendingUpdate(in: root) == nil)
        #expect(CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: root) == nil)
    }

    @Test("An unchanged definitively rejected release is not downloaded twice")
    func rejectedReleaseFingerprintPreventsRedownload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rejectedDigest = String(repeating: "a", count: 64)
        let release = CodexDesktopAppRelease(
            shortVersion: "26.707.62119",
            bundleVersion: "5211",
            downloadURL: URL(
                string: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-test.zip"
            )!,
            archiveSHA256: rejectedDigest
        )
        let service = DesktopUpdateStagingService(root: root)
        var downloadCount = 0

        let first = await service.prepare(
            release: release,
            installed: nil,
            fullValidation: { _, _, _ in
                .invalid("codesign verification exited with status 1")
            },
            download: {
                downloadCount += 1
                return try writeFakeStagedUpdate(
                    in: root,
                    bundleVersion: release.bundleVersion,
                    legacyLayout: false,
                    includeSeal: false,
                    persistAuthoritative: false,
                    archiveSHA256: rejectedDigest
                )
            }
        )
        guard case .failed = first else {
            Issue.record("A definitive validation failure must fail staging")
            return
        }
        #expect(downloadCount == 1)
        #expect(CodexDesktopUpdateStorage.isRejectedRelease(release, in: root))

        let second = await service.prepare(
            release: release,
            installed: nil,
            fullValidation: { _, _, _ in .valid },
            download: {
                downloadCount += 1
                throw NSError(domain: "UpdaterTest", code: 99)
            }
        )
        guard case .failed = second else {
            Issue.record("The unchanged rejected release must stay rejected")
            return
        }
        #expect(downloadCount == 1)
        let quarantines = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(CodexDesktopUpdateStorage.quarantinePrefix) }
        #expect(quarantines.count == 1)

        let newerRelease = CodexDesktopAppRelease(
            shortVersion: release.shortVersion,
            bundleVersion: "5212",
            downloadURL: URL(
                string: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-5212.zip"
            )!,
            archiveSHA256: String(repeating: "b", count: 64)
        )
        let third = await service.prepare(
            release: newerRelease,
            installed: nil,
            fullValidation: { _, _, _ in .valid },
            download: {
                downloadCount += 1
                return try writeFakeStagedUpdate(
                    in: root,
                    bundleVersion: newerRelease.bundleVersion,
                    legacyLayout: false,
                    includeSeal: false,
                    persistAuthoritative: false,
                    downloadURL: newerRelease.downloadURL,
                    archiveSHA256: newerRelease.archiveSHA256
                )
            }
        )
        guard case .staged(let newerStage) = third else {
            Issue.record("A new release fingerprint must be eligible for download")
            return
        }
        #expect(downloadCount == 2)
        #expect(newerStage.bundleVersion == newerRelease.bundleVersion)
    }

    @Test("A rotated URL for identical rejected bytes remains suppressed")
    func rejectedPayloadFingerprintIgnoresRotatedURL() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = String(repeating: "c", count: 64)
        let firstURL = URL(
            string: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-5211-a.zip"
        )!
        let rotatedURL = URL(
            string: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-5211-b.zip"
        )!
        let firstRelease = CodexDesktopAppRelease(
            shortVersion: "26.707.62119",
            bundleVersion: "5211",
            downloadURL: firstURL,
            archiveSHA256: digest
        )
        let service = DesktopUpdateStagingService(root: root)
        var downloadCount = 0

        _ = await service.prepare(
            release: firstRelease,
            installed: nil,
            fullValidation: { _, _, _ in .invalid("definitive rejection") },
            download: {
                downloadCount += 1
                return try writeFakeStagedUpdate(
                    in: root,
                    bundleVersion: firstRelease.bundleVersion,
                    legacyLayout: false,
                    includeSeal: false,
                    persistAuthoritative: false,
                    downloadURL: firstURL,
                    archiveSHA256: digest
                )
            }
        )

        let rotatedRelease = CodexDesktopAppRelease(
            shortVersion: firstRelease.shortVersion,
            bundleVersion: firstRelease.bundleVersion,
            downloadURL: rotatedURL,
            archiveSHA256: digest
        )
        let second = await service.prepare(
            release: rotatedRelease,
            installed: nil,
            fullValidation: { _, _, _ in .valid },
            download: {
                downloadCount += 1
                throw NSError(domain: "UnexpectedRotatedURLDownload", code: 1)
            }
        )

        guard case .failed = second else {
            Issue.record("Identical rejected bytes must remain suppressed after URL rotation")
            return
        }
        #expect(downloadCount == 1)
        #expect(CodexDesktopUpdateStorage.isRejectedRelease(rotatedRelease, in: root))
        let records = try JSONDecoder().decode(
            [DesktopRejectedReleaseFingerprint].self,
            from: Data(
                contentsOf: CodexDesktopUpdateStorage.rejectedReleasesURL(in: root)
            )
        )
        #expect(records.count == 1)
        #expect(records[0].archiveSHA256 == digest)
        #expect(records[0].downloadURL == firstURL)
    }

    @Test("A corrected payload for the same build is eligible after rejection")
    func correctedPayloadForRejectedBuildCanStage() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rejectedDigest = String(repeating: "d", count: 64)
        let correctedDigest = String(repeating: "e", count: 64)
        let downloadURL = URL(
            string: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-5211.zip"
        )!
        let rejectedRelease = CodexDesktopAppRelease(
            shortVersion: "26.707.62119",
            bundleVersion: "5211",
            downloadURL: downloadURL,
            archiveSHA256: rejectedDigest
        )
        let service = DesktopUpdateStagingService(root: root)
        var downloadCount = 0

        _ = await service.prepare(
            release: rejectedRelease,
            installed: nil,
            fullValidation: { _, _, _ in .invalid("definitive rejection") },
            download: {
                downloadCount += 1
                return try writeFakeStagedUpdate(
                    in: root,
                    bundleVersion: rejectedRelease.bundleVersion,
                    legacyLayout: false,
                    includeSeal: false,
                    persistAuthoritative: false,
                    downloadURL: downloadURL,
                    archiveSHA256: rejectedDigest
                )
            }
        )

        let correctedRelease = CodexDesktopAppRelease(
            shortVersion: rejectedRelease.shortVersion,
            bundleVersion: rejectedRelease.bundleVersion,
            downloadURL: downloadURL,
            archiveSHA256: correctedDigest
        )
        let corrected = await service.prepare(
            release: correctedRelease,
            installed: nil,
            fullValidation: { _, _, _ in .valid },
            download: {
                downloadCount += 1
                return try writeFakeStagedUpdate(
                    in: root,
                    bundleVersion: correctedRelease.bundleVersion,
                    legacyLayout: false,
                    includeSeal: false,
                    persistAuthoritative: false,
                    downloadURL: downloadURL,
                    archiveSHA256: correctedDigest
                )
            }
        )

        guard case .staged(let staged) = corrected else {
            Issue.record("A new payload digest for the same build must be eligible")
            return
        }
        #expect(downloadCount == 2)
        #expect(staged.archiveSHA256 == correctedDigest)
        #expect(!CodexDesktopUpdateStorage.isRejectedRelease(correctedRelease, in: root))
    }

    @Test("Installed newer build reports its installed bundle version label")
    func installedNewerBuildReportsInstalledLabel() {
        let release = CodexDesktopAppRelease(
            shortVersion: "26.707.5211",
            bundleVersion: "5211",
            downloadURL: URL(string: "https://persistent.oaistatic.com/ChatGPT-5211.zip")!
        )
        let installed = CodexDesktopAppInstall(
            appPath: "/Applications/ChatGPT.app",
            asarPath: "/Applications/ChatGPT.app/Contents/Resources/app.asar",
            bundleVersion: "5300",
            shortVersion: "26.707.5300"
        )

        #expect(
            CodexDesktopAppUpdater.versionDisposition(
                release: release,
                installed: installed
            ) == .current("26.707.5300 (5300)")
        )
    }

    @Test("Stock restore defers without quit requests or destination mutation")
    func stockRestoreGateOnlyObservesRunningState() throws {
        let observer = RunningApplicationObserverFake(running: true)
        var destinationMutationCount = 0
        let result: String? = DesktopStockRestoreSafety.performIfRuntimeStopped(
            observer: observer,
            operation: {
                destinationMutationCount += 1
                return "mutated"
            }
        )

        #expect(observer.terminationRequestCount == 0)
        #expect(destinationMutationCount == 0)
        #expect(result == nil)
    }

    @Test("Downloaded metadata rejects a short version mismatch")
    func downloadedMetadataRejectsShortVersionMismatch() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = CodexDesktopAppRelease(
            shortVersion: "26.707.5211",
            bundleVersion: "5211",
            downloadURL: URL(string: "https://persistent.oaistatic.com/ChatGPT-5211.zip")!
        )
        let app = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        try writeFakeApp(
            at: app,
            bundleVersion: "5211",
            shortVersion: "26.707.5200",
            marker: "candidate"
        )

        do {
            _ = try DesktopUpdateDownloader.verifiedInstall(for: release, appURL: app)
            Issue.record("The downloader must reject the bundle short-version mismatch")
        } catch let rejection as DesktopDefinitiveReleaseRejection {
            #expect(rejection.reasonClass == .releaseMetadata)
        }
    }

    @Test("Downloaded metadata rejects a bundle version mismatch")
    func downloadedMetadataRejectsBundleVersionMismatch() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = CodexDesktopAppRelease(
            shortVersion: "26.707.5211",
            bundleVersion: "5211",
            downloadURL: URL(string: "https://persistent.oaistatic.com/ChatGPT-5211.zip")!
        )
        let app = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        try writeFakeApp(
            at: app,
            bundleVersion: "5200",
            shortVersion: "26.707.5211",
            marker: "candidate"
        )

        do {
            _ = try DesktopUpdateDownloader.verifiedInstall(for: release, appURL: app)
            Issue.record("The downloader must reject the bundle-build mismatch")
        } catch let rejection as DesktopDefinitiveReleaseRejection {
            #expect(rejection.reasonClass == .releaseMetadata)
        }
    }

    @Test("Unsafe ZIP entries are rejected before archive extraction")
    func unsafeArchivesAreRejectedBeforeExtraction() async throws {
        let fixtures: [(String, Data)] = [
            (
                "symlink",
                makeZIPArchive(entries: [
                    ZIPTestEntry(
                        path: "ChatGPT.app/Contents/link",
                        compressedBytes: 1,
                        expandedBytes: 8,
                        unixMode: UInt32(S_IFLNK | 0o777)
                    ),
                ])
            ),
            (
                "traversal",
                makeZIPArchive(entries: [
                    ZIPTestEntry(
                        path: "../escaped.app",
                        compressedBytes: 1,
                        expandedBytes: 1,
                        unixMode: UInt32(S_IFREG | 0o644)
                    ),
                ])
            ),
            (
                "zip-bomb",
                makeZIPArchive(entries: (0..<3).map {
                    ZIPTestEntry(
                        path: "ChatGPT.app/Contents/Resources/bomb-\($0)",
                        compressedBytes: 1,
                        expandedBytes: UInt32.max - 1,
                        unixMode: UInt32(S_IFREG | 0o644)
                    )
                })
            ),
        ]

        for (name, archiveBytes) in fixtures {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let downloadURL = URL(
                string: "https://persistent.oaistatic.com/codex-app-prod/\(name).zip"
            )!
            let transport = ArchiveTransportFake(bytes: archiveBytes, finalURL: downloadURL)
            var extractionCount = 0
            let downloader = DesktopUpdateDownloader(
                updateRoot: root.appendingPathComponent("updates", isDirectory: true),
                temporaryRoot: root.appendingPathComponent("temporary", isDirectory: true),
                transport: transport,
                availableCapacity: { 20 * 1024 * 1024 * 1024 },
                extractArchive: { _, _, _ in extractionCount += 1 }
            )
            let release = CodexDesktopAppRelease(
                shortVersion: "26.707.62119",
                bundleVersion: "5211",
                downloadURL: downloadURL,
                archiveSHA256: sha256(archiveBytes),
                archiveLength: Int64(archiveBytes.count)
            )

            await #expect(throws: (any Error).self) {
                _ = try await downloader.downloadGeneration(release)
            }
            #expect(extractionCount == 0)
            #expect(await transport.downloads() == 1)
        }
    }

    @Test("An unpinned archive release is rejected before download")
    func unpinnedArchiveIsRejectedBeforeDownload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloadURL = URL(
            string: "https://persistent.oaistatic.com/codex-app-prod/unpinned.zip"
        )!
        let transport = ArchiveTransportFake(bytes: Data(), finalURL: downloadURL)
        var extractionCount = 0
        let downloader = DesktopUpdateDownloader(
            updateRoot: root.appendingPathComponent("updates", isDirectory: true),
            temporaryRoot: root.appendingPathComponent("temporary", isDirectory: true),
            transport: transport,
            availableCapacity: { 20 * 1024 * 1024 * 1024 },
            extractArchive: { _, _, _ in extractionCount += 1 }
        )
        let release = CodexDesktopAppRelease(
            shortVersion: "26.707.62119",
            bundleVersion: "5211",
            downloadURL: downloadURL
        )

        await #expect(throws: DesktopDefinitiveReleaseRejection.self) {
            _ = try await downloader.downloadGeneration(release)
        }
        #expect(await transport.downloads() == 0)
        #expect(extractionCount == 0)
    }

    @Test("Staged install retry delays are bounded")
    func stagedInstallRetryDelaysAreBounded() {
        let delays = (0..<CodexDesktopInstallRetryPolicy.maximumAttempts).map {
            CodexDesktopInstallRetryPolicy.delayBeforeAttempt($0)
        }

        #expect(delays == [0, 0.25, 0.5, 1, 2, 4, 5, 5, 5, 5])
        #expect(delays.max() == CodexDesktopInstallRetryPolicy.maximumDelay)
    }

    @Test("Failed staging removes its temporary staging directory")
    func failedStagingRemovesTemporaryDirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var stagingDirectory: URL?

        do {
            let _: Void = try CodexDesktopStagingWorkspace.withTemporaryDirectory(in: root) { directory in
                stagingDirectory = directory
                try Data("partial".utf8).write(
                    to: directory.appendingPathComponent("partial-download")
                )
                throw NSError(domain: "UpdaterTest", code: 1)
            }
            Issue.record("Expected staging operation to fail")
        } catch {
            // Expected failure exercises the workspace defer cleanup.
        }

        let directory = try #require(stagingDirectory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Legacy authoritative stage is sealed once and then reused cheaply")
    func legacyAuthoritativeStageIsSealedOnceAndReused() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = try writeFakeStagedUpdate(
            in: root,
            bundleVersion: "5211",
            legacyLayout: true,
            includeSeal: false
        )
        var fullValidationCount = 0
        let validationTime = Date(timeIntervalSince1970: 10_000)

        let first = CodexDesktopUpdateStorage.resolveAuthoritativeGeneration(
            staged,
            in: root,
            now: validationTime
        ) { _, _, _ in
            fullValidationCount += 1
            return .valid
        }
        let sealed: CodexDesktopStagedUpdate
        switch first {
        case .reuse(let update):
            sealed = update
        default:
            Issue.record("Expected the legacy stage to be reused")
            return
        }
        #expect(fullValidationCount == 1)
        #expect(sealed.validationSeal != nil)
        #expect(sealed.generationIdentifier == nil)
        let reloaded = try #require(
            CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: root)
        )

        let second = CodexDesktopUpdateStorage.resolveAuthoritativeGeneration(
            reloaded,
            in: root,
            now: validationTime.addingTimeInterval(1)
        ) { _, _, _ in
            fullValidationCount += 1
            return .invalid("should not run")
        }

        #expect(second == .reuse(reloaded))
        #expect(fullValidationCount == 1)
    }

    @Test("Cancellation during full validation preserves the pending generation")
    func cancellationDuringValidationPreservesGeneration() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try writeFakeStagedUpdate(
            in: root,
            bundleVersion: "5211",
            legacyLayout: false,
            includeSeal: false,
            persistAuthoritative: false
        )
        try CodexDesktopUpdateStorage.savePendingUpdate(pending, in: root)
        var cancelled = false

        let resolution = CodexDesktopUpdateStorage.resolvePendingGeneration(
            pending,
            in: root,
            isCancelled: { cancelled },
            fullValidation: { _, _, _ in
                cancelled = true
                return .valid
            }
        )

        #expect(resolution == .cancelled)
        #expect(CodexDesktopUpdateStorage.loadPendingUpdate(in: root) == pending)
        #expect(FileManager.default.fileExists(atPath: pending.appPath))
        #expect(CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: root) == nil)
    }

    @Test("Cancellation after generation commit leaves no unreferenced generation")
    func cancellationAfterGenerationCommitCompletesPublicationBoundary() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var cancelled = false
        var validationCount = 0

        for build in ["5211", "5212", "5213"] {
            let release = CodexDesktopAppRelease(
                shortVersion: "26.707.62119",
                bundleVersion: build,
                downloadURL: URL(
                    string: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-test.zip"
                )!
            )
            cancelled = false
            await #expect(throws: CancellationError.self) {
                _ = try await CodexDesktopDownloadedGenerationCoordinator.prepare(
                    release: release,
                    in: root,
                    isCancelled: { cancelled },
                    fullValidation: { _, _, _ in
                        validationCount += 1
                        return .valid
                    },
                    download: {
                        let generation = try writeFakeStagedUpdate(
                            in: root,
                            bundleVersion: build,
                            legacyLayout: false,
                            includeSeal: false,
                            persistAuthoritative: false
                        )
                        cancelled = true
                        return generation
                    }
                )
            }

            let pending = try #require(CodexDesktopUpdateStorage.loadPendingUpdate(in: root))
            let generations = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasPrefix(CodexDesktopUpdateStorage.generationPrefix) }
            #expect(generations.count == 1)
            #expect(
                generations.first
                    == URL(fileURLWithPath: pending.appPath)
                        .deletingLastPathComponent()
                        .lastPathComponent
            )
        }
        #expect(validationCount == 0)
    }

    @Test("A symlinked staged-generation component is rejected")
    func symlinkedGenerationAncestorIsRejected() throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identifier = "00000000-0000-0000-0000-000000000211"
        let outsideApp = outside.appendingPathComponent("ChatGPT.app", isDirectory: true)
        try writeFakeApp(
            at: outsideApp,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "candidate"
        )
        let generation = CodexDesktopUpdateStorage.generationDirectory(
            in: root,
            identifier: identifier
        )
        try FileManager.default.createSymbolicLink(
            at: generation,
            withDestinationURL: outside
        )
        let pending = CodexDesktopStagedUpdate(
            shortVersion: "26.707.62119",
            bundleVersion: "5211",
            downloadURL: URL(string: "https://persistent.oaistatic.com/ChatGPT-test.zip")!,
            appPath: generation.appendingPathComponent("ChatGPT.app").path,
            stagedAt: Date(timeIntervalSince1970: 10_000),
            generationIdentifier: identifier
        )

        #expect(throws: (any Error).self) {
            try CodexDesktopUpdateStorage.savePendingUpdate(pending, in: root)
        }
        #expect(CodexDesktopUpdateStorage.makeValidationSeal(for: pending, in: root) == nil)
    }

    @Test("Staging creation rejects a symlinked root before creating outside it")
    func stagingCreationRejectsSymlinkedRootWithoutMutation() throws {
        let container = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: container)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedRoot = container.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: outside
        )
        let stagedRoot = linkedRoot.appendingPathComponent("desktop-updates", isDirectory: true)

        #expect(throws: (any Error).self) {
            let _: Void = try CodexDesktopStagingWorkspace.withTemporaryDirectory(
                in: stagedRoot
            ) { _ in }
        }
        #expect(!FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("desktop-updates").path
        ))
    }

    @Test("Content digest detects same-size tampering with restored mtime")
    func digestSealDetectsRestoredMetadataTamper() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = try writeFakeStagedUpdate(
            in: root,
            bundleVersion: "5211",
            legacyLayout: false,
            includeSeal: true,
            asarModificationDate: Date(timeIntervalSince1970: 10_000)
        )
        let seal = try #require(staged.validationSeal)
        let asarSeal = try #require(
            seal.files.first { $0.relativePath == "Contents/Resources/app.asar" }
        )
        let asar = URL(fileURLWithPath: staged.appPath)
            .appendingPathComponent(asarSeal.relativePath)
        try Data("evil".utf8).write(to: asar)
        try FileManager.default.setAttributes(
            [.modificationDate: asarSeal.modificationDate],
            ofItemAtPath: asar.path
        )
        var fullValidationCount = 0

        let resolution = CodexDesktopUpdateStorage.resolveAuthoritativeGeneration(
            staged,
            in: root,
            now: seal.validatedAt.addingTimeInterval(
                CodexDesktopUpdateStorage.validationSealRecheckInterval + 1
            )
        ) { _, _, _ in
            fullValidationCount += 1
            return .invalid("content changed")
        }

        #expect(resolution == .revoke("content changed"))
        #expect(fullValidationCount == 1)
        #expect(Int64((try Data(contentsOf: asar)).count) == asarSeal.byteCount)
        #expect(
            (try asar.resourceValues(forKeys: [.contentModificationDateKey]))
                .contentModificationDate == asarSeal.modificationDate
        )
    }

    @Test("Trust publication rejects same-size mutation during validation")
    func trustSealRejectsMutationDuringValidation() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try writeFakeStagedUpdate(
            in: root,
            bundleVersion: "5211",
            legacyLayout: false,
            includeSeal: false,
            persistAuthoritative: false
        )
        try CodexDesktopUpdateStorage.savePendingUpdate(pending, in: root)
        let asar = URL(fileURLWithPath: pending.appPath)
            .appendingPathComponent("Contents/Resources/app.asar")
        let originalDate = try #require(
            asar.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        )

        let resolution = CodexDesktopUpdateStorage.resolvePendingGeneration(
            pending,
            in: root,
            fullValidation: { _, _, _ in
                do {
                    try Data("evil".utf8).write(to: asar)
                    try FileManager.default.setAttributes(
                        [.modificationDate: originalDate],
                        ofItemAtPath: asar.path
                    )
                    return .valid
                } catch {
                    return .invalid("test fixture mutation failed")
                }
            }
        )

        guard case .revoke(let reason) = resolution else {
            Issue.record("Mutation during trust must revoke the pending generation")
            return
        }
        #expect(reason.contains("changed"))
        #expect(CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: root) == nil)
        #expect(CodexDesktopUpdateStorage.loadPendingUpdate(in: root) == pending)
    }

    @Test("Complete trust seal detects mutation of an unlisted helper")
    func completeTrustSealDetectsHelperMutation() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try writeFakeStagedUpdate(
            in: root,
            bundleVersion: "5211",
            legacyLayout: false,
            includeSeal: false,
            persistAuthoritative: false
        )
        let helper = URL(fileURLWithPath: pending.appPath)
            .appendingPathComponent("Contents/Helpers/worker")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("trusted-helper".utf8).write(to: helper)
        try CodexDesktopUpdateStorage.savePendingUpdate(pending, in: root)

        let resolution = CodexDesktopUpdateStorage.resolvePendingGeneration(
            pending,
            in: root,
            fullValidation: { _, _, _ in
                do {
                    try Data("mutated-helper".utf8).write(to: helper)
                    return .valid
                } catch {
                    return .invalid("fixture mutation failed")
                }
            }
        )

        guard case .revoke = resolution else {
            Issue.record("An unlisted helper mutation must revoke trust")
            return
        }
    }

    @Test("Trust detects staged ancestor replacement")
    func trustDetectsAncestorReplacement() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try writeFakeStagedUpdate(
            in: root,
            bundleVersion: "5211",
            legacyLayout: false,
            includeSeal: false,
            persistAuthoritative: false
        )
        try CodexDesktopUpdateStorage.savePendingUpdate(pending, in: root)
        let generation = URL(fileURLWithPath: pending.appPath).deletingLastPathComponent()
        let displaced = root.appendingPathComponent("displaced-generation", isDirectory: true)

        let resolution = CodexDesktopUpdateStorage.resolvePendingGeneration(
            pending,
            in: root,
            fullValidation: { _, _, _ in
                do {
                    try FileManager.default.moveItem(at: generation, to: displaced)
                    try FileManager.default.createDirectory(
                        at: generation,
                        withIntermediateDirectories: true
                    )
                    return .valid
                } catch {
                    return .invalid("fixture replacement failed")
                }
            }
        )

        guard case .revoke(let reason) = resolution else {
            Issue.record("Ancestor replacement must revoke trust")
            return
        }
        #expect(reason.contains("path identity changed"))
    }

    @Test("Trust detects whole-bundle replace-and-restore ABA")
    func trustDetectsWholeBundleABA() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try writeFakeStagedUpdate(
            in: root,
            bundleVersion: "5211",
            legacyLayout: false,
            includeSeal: false,
            persistAuthoritative: false
        )
        try CodexDesktopUpdateStorage.savePendingUpdate(pending, in: root)
        let app = URL(fileURLWithPath: pending.appPath)
        let backup = app.deletingLastPathComponent().appendingPathComponent("original.app")

        let resolution = CodexDesktopUpdateStorage.resolvePendingGeneration(
            pending,
            in: root,
            fullValidation: { _, _, _ in
                do {
                    try FileManager.default.moveItem(at: app, to: backup)
                    try FileManager.default.copyItem(at: backup, to: app)
                    try FileManager.default.removeItem(at: app)
                    try FileManager.default.moveItem(at: backup, to: app)
                    return .valid
                } catch {
                    return .invalid("fixture ABA failed")
                }
            }
        )

        guard case .revoke(let reason) = resolution else {
            Issue.record("Whole-bundle ABA must revoke trust")
            return
        }
        #expect(reason.contains("path identity changed"))
    }

    @Test("Transient validation failure preserves the authoritative generation")
    func transientValidationFailurePreservesStage() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = try writeFakeStagedUpdate(
            in: root,
            bundleVersion: "5211",
            legacyLayout: true,
            includeSeal: false
        )

        let resolution = CodexDesktopUpdateStorage.resolveAuthoritativeGeneration(
            staged,
            in: root
        ) { _, _, _ in
            .unavailable("Gatekeeper assessment did not complete")
        }

        #expect(resolution == .preserveForRetry("Gatekeeper assessment did not complete"))
        #expect(CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: root) == staged)
        #expect(FileManager.default.fileExists(atPath: staged.appPath))
    }

    @Test("Gatekeeper rejection after strict success moves the generation to quarantine")
    func gatekeeperRejectionIsQuarantined() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = try writeFakeStagedUpdate(
            in: root,
            bundleVersion: "5211",
            legacyLayout: false,
            includeSeal: false
        )
        var assessmentCallCount = 0

        let resolution = CodexDesktopUpdateStorage.resolveAuthoritativeGeneration(
            staged,
            in: root
        ) { _, _, _ in
            CodexDesktopCodeSignatureValidation.validateTrust(
                strictVerification: {
                    CodexDesktopTrustCommandResult(terminationStatus: 0)
                },
                gatekeeperAssessment: {
                    assessmentCallCount += 1
                    return CodexDesktopTrustCommandResult(
                        terminationStatus: 3,
                        standardError: "rejected"
                    )
                }
            )
        }
        #expect(assessmentCallCount == 1)
        #expect(
            resolution == .revoke("Gatekeeper assessment rejected bundle with status 3")
        )

        let quarantined = try CodexDesktopUpdateStorage.quarantineAuthoritativeUpdate(
            staged,
            in: root,
            identifier: "00000000-0000-0000-0000-000000000001"
        )
        let quarantine = try #require(quarantined)
        #expect(quarantine.lastPathComponent == ".quarantine-00000000-0000-0000-0000-000000000001")
        #expect(FileManager.default.fileExists(atPath: quarantine.path))
        #expect(!FileManager.default.fileExists(atPath: staged.appPath))
        #expect(CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: root) == nil)
    }

    @Test("Manifest paths outside the update root are rejected")
    func manifestPathOutsideRootIsRejected() throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let staged = try writeFakeStagedUpdate(
            in: outside,
            bundleVersion: "5211",
            legacyLayout: true,
            includeSeal: false
        )

        #expect(throws: (any Error).self) {
            try CodexDesktopUpdateStorage.saveAuthoritativeUpdate(staged, in: root)
        }
    }

    @Test("Storage cleanup protects the stage and removes only obsolete owned artifacts")
    func storageCleanupProtectsStageAndRemovesOwnedArtifacts() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = try writeFakeStagedUpdate(
            in: root,
            bundleVersion: "5211",
            legacyLayout: false,
            includeSeal: true
        )
        let manual = root.appendingPathComponent("manual-5103", isDirectory: true)
        let manualPayload = manual.appendingPathComponent("payload", isDirectory: true)
        try writeMarker("legacy", to: manualPayload)
        try FileManager.default.createSymbolicLink(
            at: manual.appendingPathComponent("payload-link"),
            withDestinationURL: URL(fileURLWithPath: "payload", relativeTo: manual)
        )
        let partial = root.appendingPathComponent(
            ".staging-00000000-0000-0000-0000-000000000002",
            isDirectory: true
        )
        try writeMarker("partial", to: partial)
        let unrelated = root.appendingPathComponent("manual-current", isDirectory: true)
        try writeMarker("keep", to: unrelated)

        let report = try CodexDesktopUpdateStorage.cleanupNonAuthoritativeArtifacts(
            in: root,
            installedBundleVersion: "5103",
            now: Date().addingTimeInterval(
                CodexDesktopUpdateStorage.partialArtifactRetentionAge + 60
            )
        )

        #expect(report.removedArtifactCount == 2)
        #expect(FileManager.default.fileExists(atPath: staged.appPath))
        #expect(CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: root) == staged)
        #expect(!FileManager.default.fileExists(atPath: manual.path))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("Storage cleanup bounds removals per run")
    func storageCleanupBoundsRemovals() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let quarantines = (1...3).map { index in
            root.appendingPathComponent(
                ".quarantine-00000000-0000-0000-0000-00000000000\(index)",
                isDirectory: true
            )
        }
        for quarantine in quarantines {
            try writeMarker("stale", to: quarantine)
        }

        let report = try CodexDesktopUpdateStorage.cleanupNonAuthoritativeArtifacts(
            in: root,
            installedBundleVersion: nil,
            now: Date().addingTimeInterval(
                CodexDesktopUpdateStorage.retainedArtifactMaximumAge + 60
            ),
            maximumRemovals: 1
        )

        #expect(report.removedArtifactCount == 1)
        #expect(quarantines.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 2)
    }

    @Test("Storage cleanup enforces the retained byte limit")
    func storageCleanupEnforcesRetainedByteLimit() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let quarantines = (4...6).map { index in
            root.appendingPathComponent(
                ".quarantine-00000000-0000-0000-0000-00000000000\(index)",
                isDirectory: true
            )
        }
        for quarantine in quarantines {
            try writeMarker("12345", to: quarantine)
        }

        let report = try CodexDesktopUpdateStorage.cleanupNonAuthoritativeArtifacts(
            in: root,
            installedBundleVersion: nil,
            now: Date(),
            maximumRetainedCount: 10,
            maximumRetainedBytes: 6
        )

        #expect(report.removedArtifactCount == 2)
        #expect(report.reclaimedBytes == 10)
        #expect(quarantines.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 1)
    }

    @Test("Rollback retention protects one verified generation and bounds temporary bundles")
    func rollbackRetentionProtectsAuthoritativeGeneration() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rollbackIdentifier = "00000000-0000-0000-0000-000000000010"
        let rollbackDirectory = root.appendingPathComponent(
            "\(CodexDesktopUpdateStorage.previousPrefix)\(rollbackIdentifier)",
            isDirectory: true
        )
        let rollbackApp = rollbackDirectory.appendingPathComponent(
            "ChatGPT.app",
            isDirectory: true
        )
        try writeFakeApp(
            at: rollbackApp,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "rollback"
        )
        let rollbackIdentity = try #require(
            DesktopBundleTreeIntegrity.makeBundleIdentity(
                appURL: rollbackApp,
                isCancelled: { false }
            )
        )
        let rollback = CodexDesktopRollbackGeneration(
            formatVersion: CodexDesktopUpdateStorage.rollbackFormatVersion,
            generationIdentifier: rollbackIdentifier,
            appPath: rollbackApp.path,
            sourceDestinationPath: "/Applications/ChatGPT.app",
            shortVersion: "26.707.5103",
            bundleVersion: "5103",
            preservedAt: Date(),
            bundleIdentity: rollbackIdentity
        )
        try CodexDesktopUpdateStorage.saveRollbackGeneration(rollback, in: root)

        let temporary = (11...13).map { index in
            root.appendingPathComponent(
                ".previous-00000000-0000-0000-0000-0000000000\(index)",
                isDirectory: true
            )
        }
        for directory in temporary {
            try writeMarker("12345", to: directory)
        }
        let capacity = try CodexDesktopUpdateStorage.cleanupNonAuthoritativeArtifacts(
            in: root,
            installedBundleVersion: nil,
            now: Date(),
            maximumRemovals: 10,
            maximumRetainedCount: 1,
            maximumRetainedBytes: 5
        )
        #expect(capacity.removedArtifactCount == 2)
        #expect(FileManager.default.fileExists(atPath: rollbackApp.path))
        #expect(CodexDesktopUpdateStorage.loadRollbackGeneration(in: root) == rollback)

        let age = try CodexDesktopUpdateStorage.cleanupNonAuthoritativeArtifacts(
            in: root,
            installedBundleVersion: nil,
            now: Date().addingTimeInterval(
                CodexDesktopUpdateStorage.retainedArtifactMaximumAge + 60
            ),
            maximumRemovals: 10,
            maximumRetainedCount: 10,
            maximumRetainedBytes: .max
        )
        #expect(age.removedArtifactCount == 1)
        #expect(FileManager.default.fileExists(atPath: rollbackApp.path))
        let remainingRollbackDirectories = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        ).filter { $0.hasPrefix(CodexDesktopUpdateStorage.previousPrefix) }
        #expect(remainingRollbackDirectories == [rollbackDirectory.lastPathComponent])
    }

    @Test("Storage cleanup fails closed at the top-level scan bound")
    func storageCleanupBoundsTopLevelScan() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent(
            ".quarantine-00000000-0000-0000-0000-000000000041",
            isDirectory: true
        )
        let second = root.appendingPathComponent(
            ".quarantine-00000000-0000-0000-0000-000000000042",
            isDirectory: true
        )
        try writeMarker("first", to: first)
        try writeMarker("second", to: second)

        #expect(throws: (any Error).self) {
            try CodexDesktopUpdateStorage.cleanupNonAuthoritativeArtifacts(
                in: root,
                installedBundleVersion: nil,
                maximumTopLevelEntries: 1
            )
        }
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("Desktop temp cleanup removes only stale owned directories")
    func desktopTempCleanupRemovesOnlyStaleOwnedDirectories() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let staleStage = root.appendingPathComponent(
            "\(CodexDesktopTemporaryWorkspace.stagePrefix)stale",
            isDirectory: true
        )
        let staleUpdate = root.appendingPathComponent(
            "\(CodexDesktopTemporaryWorkspace.updatePrefix)stale",
            isDirectory: true
        )
        let freshStage = root.appendingPathComponent(
            "\(CodexDesktopTemporaryWorkspace.stagePrefix)fresh",
            isDirectory: true
        )
        let lookalike = root.appendingPathComponent(
            "CodexSwitch-DesktopStageish-stale",
            isDirectory: true
        )
        let emptySuffix = root.appendingPathComponent(
            CodexDesktopTemporaryWorkspace.updatePrefix,
            isDirectory: true
        )
        let matchingFile = root.appendingPathComponent(
            "\(CodexDesktopTemporaryWorkspace.stagePrefix)regular-file"
        )

        try writeMarker("stage", to: staleStage)
        try writeMarker("update", to: staleUpdate)
        try writeMarker("fresh", to: freshStage)
        try writeMarker("keep", to: lookalike)
        try writeMarker("keep", to: emptySuffix)
        try Data("keep".utf8).write(to: matchingFile)

        let now = Date().addingTimeInterval(CodexDesktopTemporaryWorkspace.staleAge + 60)
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: freshStage.path
        )

        let report = try CodexDesktopTemporaryWorkspace.cleanupStaleDirectories(
            in: root,
            now: now,
            processIsAlive: { _ in false }
        )

        #expect(report.removedDirectoryCount == 2)
        #expect(report.reclaimedBytes == UInt64("stage".utf8.count + "update".utf8.count))
        #expect(!FileManager.default.fileExists(atPath: staleStage.path))
        #expect(!FileManager.default.fileExists(atPath: staleUpdate.path))
        #expect(FileManager.default.fileExists(atPath: freshStage.path))
        #expect(FileManager.default.fileExists(atPath: lookalike.path))
        #expect(FileManager.default.fileExists(atPath: emptySuffix.path))
        #expect(FileManager.default.fileExists(atPath: matchingFile.path))
    }

    @Test("Desktop temp cleanup preserves a live owner regardless of age")
    func desktopTempCleanupPreservesLiveOwner() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let startedAt = Date()
        let live = try CodexDesktopTemporaryWorkspace.create(
            in: root,
            prefix: CodexDesktopTemporaryWorkspace.stagePrefix,
            processIdentifier: 4_242,
            now: startedAt
        )
        let abandoned = try CodexDesktopTemporaryWorkspace.create(
            in: root,
            prefix: CodexDesktopTemporaryWorkspace.updatePrefix,
            processIdentifier: 4_243,
            now: startedAt
        )

        let report = try CodexDesktopTemporaryWorkspace.cleanupStaleDirectories(
            in: root,
            now: startedAt.addingTimeInterval(CodexDesktopTemporaryWorkspace.staleAge + 60),
            processIsAlive: { $0 == 4_242 }
        )

        #expect(report.removedDirectoryCount == 1)
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    }

    @Test("Desktop temp cleanup caps removals per startup")
    func desktopTempCleanupCapsRemovals() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let candidates = (0..<3).map {
            root.appendingPathComponent(
                "\(CodexDesktopTemporaryWorkspace.stagePrefix)\($0)",
                isDirectory: true
            )
        }
        for candidate in candidates {
            try writeMarker("stale", to: candidate)
        }

        let report = try CodexDesktopTemporaryWorkspace.cleanupStaleDirectories(
            in: root,
            now: Date().addingTimeInterval(CodexDesktopTemporaryWorkspace.staleAge + 60),
            maximumDirectories: 1,
            processIsAlive: { _ in false }
        )

        #expect(report.removedDirectoryCount == 1)
        #expect(candidates.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 2)
    }

    @Test("Desktop temp cleanup refuses directories containing symlinks")
    func desktopTempCleanupRefusesSymlinks() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent(
            "\(CodexDesktopTemporaryWorkspace.stagePrefix)symlink",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: candidate.appendingPathComponent("outside"),
            withDestinationURL: root
        )

        let report = try CodexDesktopTemporaryWorkspace.cleanupStaleDirectories(
            in: root,
            now: Date().addingTimeInterval(CodexDesktopTemporaryWorkspace.staleAge + 60),
            processIsAlive: { _ in false }
        )

        #expect(report.removedDirectoryCount == 0)
        #expect(FileManager.default.fileExists(atPath: candidate.path))
    }

    @Test("Coordinator owns both Sparkle defaults suites and restores prior values")
    func coordinatorOwnsAndRestoresSparkleDefaults() throws {
        #expect(
            Set(CodexDesktopNativeUpdateOwnershipLease.bundleIdentifiers)
                == ["com.openai.chat", "com.openai.codex"]
        )
        let suites = Dictionary(uniqueKeysWithValues:
            CodexDesktopNativeUpdateOwnershipLease.bundleIdentifiers.map {
                ($0, InMemoryUserDefaults())
            }
        )
        let chat = try #require(suites["com.openai.chat"])
        let codex = try #require(suites["com.openai.codex"])
        chat.set(true, forKey: "SUEnableAutomaticChecks")
        chat.set("chat-keep", forKey: "UnrelatedDesktopDefault")
        codex.set(false, forKey: "SUEnableAutomaticChecks")
        codex.set(true, forKey: "SUAutomaticallyUpdate")
        codex.set("codex-keep", forKey: "UnrelatedDesktopDefault")

        let lease = CodexDesktopAppUpdater.assumeNativeUpdateOwnership {
            suites[$0]
        }

        for defaults in suites.values {
            #expect(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool == false)
            #expect(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool == false)
        }
        #expect(chat.string(forKey: "UnrelatedDesktopDefault") == "chat-keep")
        #expect(codex.string(forKey: "UnrelatedDesktopDefault") == "codex-keep")

        lease.restore()

        #expect(chat.object(forKey: "SUEnableAutomaticChecks") as? Bool == true)
        #expect(chat.object(forKey: "SUAutomaticallyUpdate") == nil)
        #expect(codex.object(forKey: "SUEnableAutomaticChecks") as? Bool == false)
        #expect(codex.object(forKey: "SUAutomaticallyUpdate") as? Bool == true)
        #expect(chat.string(forKey: "UnrelatedDesktopDefault") == "chat-keep")
        #expect(codex.string(forKey: "UnrelatedDesktopDefault") == "codex-keep")
    }

    @MainActor
    @Test("Coordinator start schedules maintenance without synchronous cleanup")
    func coordinatorStartReturnsBeforeCleanupCompletes() async {
        let executor = SuspendedDesktopUpdateExecutor()
        let coordinator = CodexDesktopUpdateCoordinator(
            temporaryRoot: temporaryDirectory(),
            currentDate: { Date(timeIntervalSince1970: 10_000) },
            executor: executor,
            nativeUpdateOwnershipProvider: { nil }
        )

        coordinator.start()

        var maintenanceStarted = false
        for _ in 0..<1_000 {
            if await executor.didStartMaintenance() {
                maintenanceStarted = true
                break
            }
            await Task.yield()
        }
        #expect(maintenanceStarted)
        #expect(!(await executor.didFinishMaintenance()))

        coordinator.stop()

        var maintenanceFinished = false
        for _ in 0..<1_000 {
            if await executor.didFinishMaintenance() {
                maintenanceFinished = true
                break
            }
            await Task.yield()
        }
        #expect(maintenanceFinished)
    }

    @MainActor
    @Test("A stale task cannot clear a replacement task after stop and restart")
    func coordinatorTaskEpochSurvivesStaleCompletion() async {
        let executor = EpochDesktopUpdateExecutor()
        let coordinator = CodexDesktopUpdateCoordinator(
            temporaryRoot: temporaryDirectory(),
            executor: executor,
            nativeUpdateOwnershipProvider: { nil }
        )

        coordinator.start()
        coordinator.desktopAppDidTerminate { _, _ in }
        for _ in 0..<1_000 {
            if await executor.counts().started >= 1 { break }
            await Task.yield()
        }
        #expect(await executor.counts().started == 1)

        coordinator.stop()
        coordinator.start()
        coordinator.desktopAppDidTerminate { _, _ in }
        for _ in 0..<1_000 {
            if await executor.counts().started >= 2 { break }
            await Task.yield()
        }
        #expect(await executor.counts().started == 2)

        await executor.resumeInstall(0)
        for _ in 0..<1_000 {
            if await executor.counts().finished >= 1 { break }
            await Task.yield()
        }
        coordinator.stop()
        await executor.resumeInstall(1)
        for _ in 0..<1_000 {
            if await executor.counts().finished >= 2 { break }
            await Task.yield()
        }

        let counts = await executor.counts()
        #expect(counts.finished == 2)
        #expect(counts.committed == 0)
    }

    @MainActor
    @Test("Coordinator retries surfaced committed cleanup during later scheduling")
    func coordinatorRetriesCommittedCleanupInSameRun() async {
        let executor = CleanupRetryDesktopUpdateExecutor()
        let coordinator = CodexDesktopUpdateCoordinator(
            temporaryRoot: temporaryDirectory(),
            executor: executor,
            nativeUpdateOwnershipProvider: { nil }
        )
        coordinator.start()
        defer { coordinator.stop() }

        for _ in 0..<1_000 {
            if await executor.counts().prepared >= 1 { break }
            await Task.yield()
        }

        var installed = false
        var completion: CodexDesktopInstallationTransactionCompletion?
        coordinator.desktopAppDidTerminate { didInstall, transaction in
            installed = didInstall
            completion = transaction
        }
        for _ in 0..<1_000 {
            if installed { break }
            await Task.yield()
        }
        #expect(installed)
        #expect(completion?.committed == true)
        #expect(completion?.cleanupPending == true)
        #expect(await executor.counts().completedCleanups == 0)

        coordinator.checkNow(reason: "cleanup-retry")
        for _ in 0..<1_000 {
            if await executor.counts().completedCleanups == 1 { break }
            await Task.yield()
        }
        #expect(await executor.counts().completedCleanups == 1)
    }

    @Test("Sparkle ownership restore preserves a newer external value")
    func sparkleOwnershipRestorePreservesNewerExternalValue() throws {
        let suites = Dictionary(uniqueKeysWithValues:
            CodexDesktopNativeUpdateOwnershipLease.bundleIdentifiers.map {
                ($0, InMemoryUserDefaults())
            }
        )
        let chat = try #require(suites["com.openai.chat"])
        let lease = CodexDesktopAppUpdater.assumeNativeUpdateOwnership {
            suites[$0]
        }
        chat.set(true, forKey: "SUEnableAutomaticChecks")

        lease.restore()

        #expect(chat.object(forKey: "SUEnableAutomaticChecks") as? Bool == true)
    }

    @Test("Runtime activation gate fails closed and recognizes host or app-server")
    func runtimeActivationGateClassification() {
        let absent = CodexDesktopTrustCommandResult(terminationStatus: 1)
        #expect(DesktopUpdateRuntimeGate.classify(host: absent, appServer: absent) == .ready)

        let host = CodexDesktopTrustCommandResult(
            terminationStatus: 0,
            standardOutput: "42 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
        )
        #expect(DesktopUpdateRuntimeGate.classify(host: host, appServer: absent) == .running)

        let appServer = CodexDesktopTrustCommandResult(
            terminationStatus: 0,
            standardOutput: "43 /Applications/ChatGPT.app/Contents/Resources/codex app-server"
        )
        #expect(DesktopUpdateRuntimeGate.classify(host: absent, appServer: appServer) == .running)

        let appServerExecutable = CodexDesktopTrustCommandResult(
            terminationStatus: 0,
            standardOutput: "44 /opt/codex/bin/codex-app-server --listen stdio"
        )
        #expect(
            DesktopUpdateRuntimeGate.classify(
                host: absent,
                appServer: appServerExecutable
            ) == .running
        )

        let ambiguousSuccess = CodexDesktopTrustCommandResult(
            terminationStatus: 0,
            standardOutput: "45 unexpected-successful-probe-output"
        )
        #expect(
            DesktopUpdateRuntimeGate.classify(
                host: absent,
                appServer: ambiguousSuccess
            ) == .unavailable
        )
        #expect(
            DesktopUpdateRuntimeGate.classify(
                host: absent,
                appServer: CodexDesktopTrustCommandResult(terminationStatus: 0)
            ) == .unavailable
        )

        let truncatedSuccess = CodexDesktopTrustCommandResult(
            terminationStatus: 0,
            standardOutput: "46 /opt/codex/bin/codex-app-server",
            stdoutTruncated: true
        )
        #expect(
            DesktopUpdateRuntimeGate.classify(
                host: absent,
                appServer: truncatedSuccess
            ) == .unavailable
        )

        let timeout = CodexDesktopTrustCommandResult(
            timedOut: true,
            terminationStatus: -1
        )
        #expect(
            DesktopUpdateRuntimeGate.classify(host: timeout, appServer: absent) == .unavailable
        )
    }

    @Test("Cancellation immediately before atomic commit leaves the destination untouched")
    func cancellationBeforeAtomicCommitPreservesDestination() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transactionRoot = root.appendingPathComponent("transactions", isDirectory: true)
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let source = root.appendingPathComponent("source.app", isDirectory: true)
        try writeFakeApp(
            at: destination,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "old"
        )
        try writeFakeApp(
            at: source,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "new"
        )
        var cancelled = false
        let installer = DesktopBundleInstaller(
            transactionRoot: transactionRoot,
            allowedDestinations: [destination]
        )
        let scope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination]
        )

        let result = try installer.install(
            lifetime: scope.lifetime,
            sourceApp: source,
            destination: destination,
            expectedBundleVersion: "5211",
            expectedShortVersion: "26.707.62119",
            kind: .stagedUpdate,
            desktopRuntimeRunning: { false },
            isCancelled: { cancelled },
            beforeAtomicCommit: { cancelled = true },
            validate: { _, _, _, isCancelled in
                isCancelled() ? .cancelled : .valid
            }
        )

        #expect(result == .cancelledBeforeCommit)
        #expect(try readMarker(from: destination) == "old")
        #expect(
            !FileManager.default.fileExists(
                atPath: transactionRoot
                    .appendingPathComponent(DesktopBundleInstaller.journalFileName)
                    .path
            )
        )
    }

    @Test("Cancellation observed after commit is deferred until a complete install")
    func cancellationAfterCommitCompletesTransaction() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let source = root.appendingPathComponent("source.app", isDirectory: true)
        try writeFakeApp(
            at: destination,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "old"
        )
        try writeFakeApp(
            at: source,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "new"
        )
        var cancelled = false
        let installer = DesktopBundleInstaller(
            transactionRoot: root.appendingPathComponent("transactions", isDirectory: true),
            allowedDestinations: [destination]
        )
        let scope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination]
        )

        let result = try installer.install(
            lifetime: scope.lifetime,
            sourceApp: source,
            destination: destination,
            expectedBundleVersion: "5211",
            expectedShortVersion: "26.707.62119",
            kind: .stagedUpdate,
            desktopRuntimeRunning: { false },
            isCancelled: { cancelled },
            validate: { candidate, bundleVersion, _, _ in
                if candidate == destination, bundleVersion == "5211" { cancelled = true }
                return .valid
            }
        )

        #expect(result == .installed(cancellationDeferred: true, cleanupDeferred: true))
        #expect(try readMarker(from: destination) == "new")
    }

    @Test("A post-probe concurrent launch observes only complete old or new bundles")
    func postProbeLaunchSeesAtomicDestination() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let source = root.appendingPathComponent("source.app", isDirectory: true)
        try writeFakeApp(
            at: destination,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "old"
        )
        try writeFakeApp(
            at: source,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "new"
        )
        let probe = ConcurrentBundlePathProbe()
        var simulatedLaunchAfterFinalProbe = false
        let installer = DesktopBundleInstaller(
            transactionRoot: root.appendingPathComponent("transactions", isDirectory: true),
            allowedDestinations: [destination]
        )
        let scope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination]
        )

        let result = try installer.install(
            lifetime: scope.lifetime,
            sourceApp: source,
            destination: destination,
            expectedBundleVersion: "5211",
            expectedShortVersion: "26.707.62119",
            kind: .stagedUpdate,
            desktopRuntimeRunning: { false },
            beforeAtomicCommit: {
                simulatedLaunchAfterFinalProbe = true
                #expect(probe.start(destination: destination))
            },
            validate: { _, _, _, _ in .valid }
        )
        #expect(probe.stop())

        #expect(result == .installed(cancellationDeferred: false, cleanupDeferred: false))
        #expect(simulatedLaunchAfterFinalProbe)
        #expect(!probe.sawInvalidPathState)
        #expect(!probe.observedValues.isEmpty)
        #expect(probe.observedValues.isSubset(of: ["old", "new"]))
        #expect(try readMarker(from: destination) == "new")
    }

    @Test("Committed cleanup failure is cleanup-only and never rolls back")
    func committedCleanupFailureLeavesCleanupPending() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transactionRoot = root.appendingPathComponent("transactions", isDirectory: true)
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let source = root.appendingPathComponent("source.app", isDirectory: true)
        try writeFakeApp(
            at: destination,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "old"
        )
        try writeFakeApp(
            at: source,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "new"
        )
        let scope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination]
        )
        var cleanupAttempts = 0
        let installer = DesktopBundleInstaller(
            transactionRoot: transactionRoot,
            allowedDestinations: [destination],
            beforeCommittedCleanup: {
                cleanupAttempts += 1
                if cleanupAttempts == 1 {
                    throw NSError(domain: "InjectedCommittedCleanupFailure", code: 1)
                }
            }
        )

        let result = try installer.install(
            lifetime: scope.lifetime,
            sourceApp: source,
            destination: destination,
            expectedBundleVersion: "5211",
            expectedShortVersion: "26.707.62119",
            kind: .stagedUpdate,
            desktopRuntimeRunning: { false },
            validate: { _, _, _, _ in .valid }
        )

        #expect(result == .installed(cancellationDeferred: false, cleanupDeferred: true))
        #expect(cleanupAttempts == 1)
        #expect(try readMarker(from: destination) == "new")
        let journalURL = transactionRoot.appendingPathComponent(
            DesktopBundleInstaller.journalFileName
        )
        let journal = try JSONDecoder().decode(
            DesktopInstallJournal.self,
            from: Data(contentsOf: journalURL)
        )
        #expect(journal.phase == .cleanupPending)

        let recoveryScope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination],
            leaseURL: root.appendingPathComponent("recovery-operation.lock"),
            operation: .recovering
        )
        let recovery = try installer.recover(
            lifetime: recoveryScope.lifetime,
            desktopRuntimeRunning: { false },
            validate: metadataValidation
        )
        #expect(recovery == .completedCommit)
        #expect(cleanupAttempts == 2)
        #expect(try readMarker(from: destination) == "new")
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("Production updater surfaces committed cleanup and later recovery completes it")
    func updaterPropagatesAndRecoversCommittedCleanup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        try writeFakeApp(
            at: destination,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "old"
        )
        _ = try writeFakeStagedUpdate(
            in: root,
            bundleVersion: "5211",
            legacyLayout: false,
            includeSeal: true,
            marker: "new"
        )
        var cleanupAttempts = 0
        let installer = DesktopBundleInstaller(
            transactionRoot: root,
            allowedDestinations: [destination],
            beforeCommittedCleanup: {
                cleanupAttempts += 1
                if cleanupAttempts == 1 {
                    throw NSError(domain: "InjectedUpdaterCleanupFailure", code: 1)
                }
            }
        )
        let installScope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination]
        )

        let result = await CodexDesktopAppUpdater.performStagedInstallHoldingLifetime(
            installScope.lifetime,
            updateRoot: root,
            stateMachine: installScope.stateMachine,
            locateInstalled: { CodexDesktopAppLocator.locate(appPath: destination.path) },
            installer: installer,
            desktopRuntimeRunning: { false },
            validateOfficialBundle: { _, _, _, isCancelled in
                isCancelled() ? .cancelled : .valid
            }
        )
        _ = await installScope.owner.finish(installScope.lifetime)

        guard case .installed(_, _, let transaction, let cleanupPending) = result else {
            Issue.record("Committed cleanup failure must remain an updater install success")
            return
        }
        #expect(transaction.committed)
        #expect(transaction.cleanupPending)
        #expect(cleanupPending)
        #expect(try readMarker(from: destination) == "new")
        #expect(CodexDesktopUpdateStorage.loadAuthoritativeUpdate(in: root) == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    DesktopBundleInstaller.journalFileName
                ).path
            )
        )

        let recoveryScope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination],
            operation: .recovering
        )
        let recovery = try CodexDesktopAppUpdater.performInstallRecoveryHoldingLifetime(
            lifetime: recoveryScope.lifetime,
            installer: installer,
            desktopRuntimeRunning: { false },
            validateOfficialBundle: metadataValidation
        )
        _ = await recoveryScope.owner.finish(recoveryScope.lifetime)

        #expect(recovery == .completedCommit)
        #expect(cleanupAttempts == 2)
        #expect(try readMarker(from: destination) == "new")
        let rollback = try #require(CodexDesktopUpdateStorage.loadRollbackGeneration(in: root))
        #expect(rollback.bundleVersion == "5103")
        #expect(try readMarker(from: URL(fileURLWithPath: rollback.appPath)) == "old")
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    DesktopBundleInstaller.journalFileName
                ).path
            )
        )
    }

    @Test("Only the newest verified rollback generation remains authoritative")
    func newestRollbackGenerationReplacesPreviousRollback() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let second = root.appendingPathComponent("second.app", isDirectory: true)
        let third = root.appendingPathComponent("third.app", isDirectory: true)
        try writeFakeApp(
            at: destination,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "first"
        )
        try writeFakeApp(
            at: second,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "second"
        )
        try writeFakeApp(
            at: third,
            bundleVersion: "5300",
            shortVersion: "26.708.63000",
            marker: "third"
        )
        let installer = DesktopBundleInstaller(
            transactionRoot: root,
            allowedDestinations: [destination]
        )

        let firstScope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination]
        )
        let firstInstall = try installer.install(
            lifetime: firstScope.lifetime,
            sourceApp: second,
            destination: destination,
            expectedBundleVersion: "5211",
            expectedShortVersion: "26.707.62119",
            kind: .stagedUpdate,
            desktopRuntimeRunning: { false },
            validate: { _, _, _, _ in .valid }
        )
        _ = await firstScope.owner.finish(firstScope.lifetime)
        #expect(firstInstall == .installed(cancellationDeferred: false, cleanupDeferred: false))
        let firstRollback = try #require(
            CodexDesktopUpdateStorage.loadRollbackGeneration(in: root)
        )
        #expect(firstRollback.bundleVersion == "5103")
        #expect(try readMarker(from: URL(fileURLWithPath: firstRollback.appPath)) == "first")

        let secondScope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination]
        )
        let secondInstall = try installer.install(
            lifetime: secondScope.lifetime,
            sourceApp: third,
            destination: destination,
            expectedBundleVersion: "5300",
            expectedShortVersion: "26.708.63000",
            kind: .stagedUpdate,
            desktopRuntimeRunning: { false },
            validate: { _, _, _, _ in .valid }
        )
        _ = await secondScope.owner.finish(secondScope.lifetime)
        #expect(secondInstall == .installed(cancellationDeferred: false, cleanupDeferred: false))

        let newestRollback = try #require(
            CodexDesktopUpdateStorage.loadRollbackGeneration(in: root)
        )
        #expect(newestRollback.bundleVersion == "5211")
        #expect(try readMarker(from: URL(fileURLWithPath: newestRollback.appPath)) == "second")
        #expect(newestRollback.generationIdentifier != firstRollback.generationIdentifier)
        let rollbackDirectories = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(CodexDesktopUpdateStorage.previousPrefix) }
        #expect(rollbackDirectories.count == 1)
        #expect(
            DesktopBundleTreeIntegrity.makeBundleIdentity(
                appURL: URL(fileURLWithPath: newestRollback.appPath),
                isCancelled: { false }
            ) == newestRollback.bundleIdentity
        )
    }

    @Test("Rollback identity covers directories, contained symlinks, xattrs, and ACLs")
    func rollbackIdentitySealsCompleteBundleMetadata() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        try writeFakeApp(
            at: app,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "sealed"
        )
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let emptyDirectory = resources.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        let link = resources.appendingPathComponent("CurrentPayload")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "app.asar"
        )

        let initial = try #require(
            DesktopBundleTreeIntegrity.makeBundleIdentity(
                appURL: app,
                isCancelled: { false }
            )
        )

        #expect(chmod(emptyDirectory.path, 0o700) == 0)
        let directoryChanged = try #require(
            DesktopBundleTreeIntegrity.makeBundleIdentity(
                appURL: app,
                isCancelled: { false }
            )
        )
        #expect(directoryChanged.contentSHA256 != initial.contentSHA256)

        let marker = app.appendingPathComponent("marker")
        let attribute = Data("sealed-xattr".utf8)
        let setAttributeResult = attribute.withUnsafeBytes { bytes in
            setxattr(
                marker.path,
                "com.codexswitch.rollback-test",
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        try #require(setAttributeResult == 0)
        let attributeChanged = try #require(
            DesktopBundleTreeIntegrity.makeBundleIdentity(
                appURL: app,
                isCancelled: { false }
            )
        )
        #expect(attributeChanged.contentSHA256 != directoryChanged.contentSHA256)

        try addReadACL(to: marker)
        let aclChanged = try #require(
            DesktopBundleTreeIntegrity.makeBundleIdentity(
                appURL: app,
                isCancelled: { false }
            )
        )
        #expect(aclChanged.contentSHA256 != attributeChanged.contentSHA256)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "../_CodeSignature/CodeResources"
        )
        let linkChanged = try #require(
            DesktopBundleTreeIntegrity.makeBundleIdentity(
                appURL: app,
                isCancelled: { false }
            )
        )
        #expect(linkChanged.contentSHA256 != aclChanged.contentSHA256)
    }

    @Test("Staged validation seal covers the root, directories, and contained symlinks")
    func stagedValidationSealUsesCompleteDescriptorRootedTree() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        try writeFakeApp(
            at: app,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "sealed"
        )
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let emptyDirectory = resources.appendingPathComponent("Empty", isDirectory: true)
        let link = resources.appendingPathComponent("CurrentPayload")
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "app.asar"
        )
        let framework = app.appendingPathComponent(
            "Contents/Frameworks/Test.framework",
            isDirectory: true
        )
        let frameworkResources = framework.appendingPathComponent(
            "Versions/A/Resources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: frameworkResources,
            withIntermediateDirectories: true
        )
        try Data("framework".utf8).write(
            to: frameworkResources.appendingPathComponent("payload")
        )
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Versions/Current").path,
            withDestinationPath: "A"
        )
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Resources").path,
            withDestinationPath: "Versions/Current/Resources"
        )

        let initial = try #require(
            DesktopBundleTreeIntegrity.makeSeal(
                appURL: app,
                validatedAt: Date(timeIntervalSince1970: 1),
                isCancelled: { false }
            )
        )
        #expect(initial.formatVersion == DesktopBundleTreeIntegrity.sealFormatVersion)
        #expect(initial.files.contains { $0.relativePath == "." })
        #expect(initial.files.contains { $0.relativePath == "Contents/Resources/Empty" })
        #expect(initial.files.contains { $0.relativePath == "Contents/Resources/CurrentPayload" })
        #expect(initial.files.contains {
            $0.relativePath == "Contents/Frameworks/Test.framework/Versions/Current"
        })
        #expect(initial.files.contains {
            $0.relativePath == "Contents/Frameworks/Test.framework/Resources"
        })

        #expect(chmod(emptyDirectory.path, 0o700) == 0)
        let changed = try #require(
            DesktopBundleTreeIntegrity.makeSeal(
                appURL: app,
                validatedAt: Date(timeIntervalSince1970: 2),
                isCancelled: { false }
            )
        )
        #expect(changed.files != initial.files)
    }

    @Test("Security path normalization preserves the non-symlink private namespace")
    func securityPathNormalizationIsLexicalOnly() {
        let privatePath = URL(
            fileURLWithPath: "/private/tmp/codexswitch/../updater",
            isDirectory: true
        )
        #expect(
            CodexDesktopPathSecurity.lexicallyStandardized(privatePath).path
                == "/private/tmp/updater"
        )
        #expect(CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(
            URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        ))
        #expect(!CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(
            URL(fileURLWithPath: "/tmp", isDirectory: true)
        ))
    }

    @Test("System temporary roots are canonicalized before no-follow traversal")
    func systemTemporaryRootCanonicalizationResolvesCompatibilitySymlinks() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("private-target", isDirectory: true)
        let alias = root.appendingPathComponent("compatibility-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: target.path
        )

        let canonical = try #require(CodexDesktopPathSecurity.canonicalExistingPath(alias))
        #expect(canonical.path == target.path)
        #expect(CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(canonical))
        let systemTemporary = CodexDesktopPathSecurity.canonicalSystemTemporaryDirectory()
        #expect(CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(systemTemporary))

        let leaseURL = systemTemporary.appendingPathComponent(
            "codexswitch-temp-root-regression-\(UUID().uuidString).lock"
        )
        defer { try? FileManager.default.removeItem(at: leaseURL) }
        let acquiredLease = try DesktopUpdateCrossProcessLease.acquire(
            at: leaseURL,
            isCancelled: { false }
        )
        let lease = try #require(acquiredLease)
        lease.release()

        let downloader = DesktopUpdateDownloader(
            updateRoot: root.appendingPathComponent("updates", isDirectory: true)
        )
        #expect(CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(
            downloader.temporaryRoot
        ))
    }

    @Test("Bound rollback identity rejects same-inode mutate-and-restore ABA")
    func rollbackIdentityBindsChildLiveStateAcrossABA() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        try writeFakeApp(
            at: app,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "original"
        )
        let marker = app.appendingPathComponent("marker")
        let originalBytes = try Data(contentsOf: marker)
        let originalDate = try #require(
            marker.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        let retained = try #require(DesktopRetainedBundleTree(appURL: app))
        let initial = try #require(
            DesktopBundleTreeIntegrity.makeBundleIdentities(
                retained: retained,
                isCancelled: { false }
            )
        )

        usleep(10_000)
        try Data("temporary-mutation".utf8).write(to: marker)
        try originalBytes.write(to: marker)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: marker.path
        )

        let afterABA = try #require(
            DesktopBundleTreeIntegrity.makeBundleIdentities(
                retained: retained,
                isCancelled: { false }
            )
        )
        #expect(afterABA.portable.hasSameContent(as: initial.portable))
        #expect(afterABA.bound != initial.bound)
        #expect(afterABA.bound.root == initial.bound.root)
    }

    @Test("Install freshly validates the previous bundle, moved source, and rollback copy")
    func rollbackSourceAndCopyReceiveFreshOfficialTrust() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let source = root.appendingPathComponent("source.app", isDirectory: true)
        try writeFakeApp(
            at: destination,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "old"
        )
        try writeFakeApp(
            at: source,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "new"
        )
        var validatedVersions: [String] = []
        let scope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination]
        )
        let installer = DesktopBundleInstaller(
            transactionRoot: root,
            allowedDestinations: [destination]
        )

        let result = try installer.install(
            lifetime: scope.lifetime,
            sourceApp: source,
            destination: destination,
            expectedBundleVersion: "5211",
            expectedShortVersion: "26.707.62119",
            kind: .stagedUpdate,
            desktopRuntimeRunning: { false },
            validate: { candidate, bundleVersion, shortVersion, cancelled in
                validatedVersions.append(bundleVersion)
                return metadataValidation(candidate, bundleVersion, shortVersion, cancelled)
            }
        )

        #expect(result == .installed(cancellationDeferred: false, cleanupDeferred: false))
        #expect(validatedVersions.filter { $0 == "5103" }.count == 3)
        #expect(validatedVersions.filter { $0 == "5211" }.count == 2)
        #expect(CodexDesktopUpdateStorage.loadRollbackGeneration(in: root) != nil)
    }

    @Test("A failed previous-bundle trust check leaves the installed app untouched")
    func previousBundleTrustFailurePreventsActivation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transactionRoot = root.appendingPathComponent("transactions", isDirectory: true)
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let source = root.appendingPathComponent("source.app", isDirectory: true)
        try writeFakeApp(
            at: destination,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "old"
        )
        try writeFakeApp(
            at: source,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "new"
        )
        let scope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination]
        )

        #expect(throws: (any Error).self) {
            try DesktopBundleInstaller(
                transactionRoot: transactionRoot,
                allowedDestinations: [destination]
            ).install(
                lifetime: scope.lifetime,
                sourceApp: source,
                destination: destination,
                expectedBundleVersion: "5211",
                expectedShortVersion: "26.707.62119",
                kind: .stagedUpdate,
                desktopRuntimeRunning: { false },
                validate: { _, bundleVersion, _, _ in
                    bundleVersion == "5103" ? .invalid("old trust rejected") : .valid
                }
            )
        }
        #expect(try readMarker(from: destination) == "old")
        #expect(!FileManager.default.fileExists(
            atPath: transactionRoot.appendingPathComponent(
                DesktopBundleInstaller.journalFileName
            ).path
        ))
    }

    @Test("Rollback pointer faults preserve the former authoritative generation")
    func rollbackPointerPublicationIsDurableBeforeRetirement() throws {
        for injectedCheckpoint in [
            DesktopRollbackPointerPublicationCheckpoint.afterFileSyncBeforeRename,
            .afterRenameBeforeDirectorySync,
            .afterDirectorySync,
        ] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let oldIdentifier = UUID().uuidString
            let oldDirectory = root.appendingPathComponent(
                "\(CodexDesktopUpdateStorage.previousPrefix)\(oldIdentifier)",
                isDirectory: true
            )
            let oldApp = oldDirectory.appendingPathComponent("ChatGPT.app", isDirectory: true)
            try writeFakeApp(
                at: oldApp,
                bundleVersion: "5103",
                shortVersion: "26.707.5103",
                marker: "old"
            )
            let oldIdentity = try #require(
                DesktopBundleTreeIntegrity.makeBundleIdentity(
                    appURL: oldApp,
                    isCancelled: { false }
                )
            )
            let oldRollback = CodexDesktopRollbackGeneration(
                formatVersion: CodexDesktopUpdateStorage.rollbackFormatVersion,
                generationIdentifier: oldIdentifier,
                appPath: oldApp.path,
                sourceDestinationPath: root.appendingPathComponent("ChatGPT.app").path,
                shortVersion: "26.707.5103",
                bundleVersion: "5103",
                preservedAt: Date(timeIntervalSince1970: 1),
                bundleIdentity: oldIdentity
            )
            try CodexDesktopUpdateStorage.saveRollbackGeneration(oldRollback, in: root)

            let newIdentifier = UUID().uuidString
            let newDirectory = root.appendingPathComponent(
                "\(CodexDesktopUpdateStorage.previousPrefix)\(newIdentifier)",
                isDirectory: true
            )
            let newApp = newDirectory.appendingPathComponent("ChatGPT.app", isDirectory: true)
            try writeFakeApp(
                at: newApp,
                bundleVersion: "5211",
                shortVersion: "26.707.62119",
                marker: "new"
            )
            let newIdentity = try #require(
                DesktopBundleTreeIntegrity.makeBundleIdentity(
                    appURL: newApp,
                    isCancelled: { false }
                )
            )
            let newRollback = CodexDesktopRollbackGeneration(
                formatVersion: CodexDesktopUpdateStorage.rollbackFormatVersion,
                generationIdentifier: newIdentifier,
                appPath: newApp.path,
                sourceDestinationPath: root.appendingPathComponent("ChatGPT.app").path,
                shortVersion: "26.707.62119",
                bundleVersion: "5211",
                preservedAt: Date(timeIntervalSince1970: 2),
                bundleIdentity: newIdentity
            )

            #expect(throws: (any Error).self) {
                try CodexDesktopUpdateStorage.saveRollbackGeneration(
                    newRollback,
                    in: root,
                    publicationCheckpoint: { checkpoint in
                        if checkpoint == injectedCheckpoint {
                            throw NSError(domain: "InjectedRollbackPointerFault", code: 1)
                        }
                    }
                )
            }
            #expect(FileManager.default.fileExists(atPath: oldDirectory.path))
            #expect(FileManager.default.fileExists(atPath: newDirectory.path))
            let published = try #require(
                CodexDesktopUpdateStorage.loadRollbackGeneration(in: root)
            )
            if injectedCheckpoint == .afterFileSyncBeforeRename {
                #expect(published.generationIdentifier == oldIdentifier)
            } else {
                #expect(published.generationIdentifier == newIdentifier)
            }
        }
    }

    @Test("Rollback pointer publication rejects update-root replacement before rename")
    func rollbackPointerRetainsAncestorBindingThroughRename() throws {
        let container = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("updates", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = try writeRollbackGeneration(
            in: root,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "old"
        )
        try CodexDesktopUpdateStorage.saveRollbackGeneration(old.rollback, in: root)
        let new = try writeRollbackGeneration(
            in: root,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "new"
        )
        let displaced = container.appendingPathComponent("displaced", isDirectory: true)
        let replacementMarker = root.appendingPathComponent("replacement-marker")

        #expect(throws: (any Error).self) {
            try CodexDesktopUpdateStorage.saveRollbackGeneration(
                new.rollback,
                in: root,
                publicationCheckpoint: { checkpoint in
                    guard checkpoint == .afterFileSyncBeforeRename else { return }
                    try FileManager.default.moveItem(at: root, to: displaced)
                    try FileManager.default.createDirectory(
                        at: root,
                        withIntermediateDirectories: true
                    )
                    try Data("replacement".utf8).write(to: replacementMarker)
                }
            )
        }

        #expect(try Data(contentsOf: replacementMarker) == Data("replacement".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                CodexDesktopUpdateStorage.rollbackManifestName
            ).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: displaced.appendingPathComponent(old.directory.lastPathComponent).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: displaced.appendingPathComponent(new.directory.lastPathComponent).path
        ))
        let pointerData = try Data(contentsOf: displaced.appendingPathComponent(
            CodexDesktopUpdateStorage.rollbackManifestName
        ))
        let pointer = try JSONDecoder().decode(
            CodexDesktopRollbackGeneration.self,
            from: pointerData
        )
        #expect(pointer.generationIdentifier == old.rollback.generationIdentifier)
        let displacedNames = try FileManager.default.contentsOfDirectory(atPath: displaced.path)
        #expect(!displacedNames.contains {
            $0.hasPrefix(".\(CodexDesktopUpdateStorage.rollbackManifestName)-")
                && $0.hasSuffix(".tmp")
        })
    }

    @Test("Rollback publication preserves a substituted former generation")
    func rollbackRetirementRequiresRetainedFormerBinding() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = try writeRollbackGeneration(
            in: root,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "old"
        )
        try CodexDesktopUpdateStorage.saveRollbackGeneration(old.rollback, in: root)
        let new = try writeRollbackGeneration(
            in: root,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "new"
        )
        let displacedOld = root.appendingPathComponent(
            ".displaced-former-rollback",
            isDirectory: true
        )
        let replacementMarker = old.directory.appendingPathComponent("replacement-marker")

        try CodexDesktopUpdateStorage.saveRollbackGeneration(
            new.rollback,
            in: root,
            publicationCheckpoint: { checkpoint in
                guard checkpoint == .afterDirectorySync else { return }
                try FileManager.default.moveItem(at: old.directory, to: displacedOld)
                try FileManager.default.createDirectory(
                    at: old.directory,
                    withIntermediateDirectories: true
                )
                try Data("replacement".utf8).write(to: replacementMarker)
            }
        )

        let published = try #require(
            CodexDesktopUpdateStorage.loadRollbackGeneration(in: root)
        )
        #expect(published.generationIdentifier == new.rollback.generationIdentifier)
        #expect(try Data(contentsOf: replacementMarker) == Data("replacement".utf8))
        #expect(FileManager.default.fileExists(atPath: displacedOld.path))
    }

    @Test("Two installer processes hold the lease through a paused transaction")
    func twoProcessInstallerLeaseCollisionIsBusyUntilCompletion() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transactionRoot = root.appendingPathComponent("transactions", isDirectory: true)
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let source = root.appendingPathComponent("source.app", isDirectory: true)
        let ready = root.appendingPathComponent("child-ready")
        let release = root.appendingPathComponent("child-release")
        let leaseURL = root.appendingPathComponent("shared-operation.lock")
        try writeFakeApp(
            at: destination,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "old"
        )
        try writeFakeApp(
            at: source,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "new"
        )

        let child = try makeDesktopUpdaterTestSubprocess(
            filter: "installerLeaseChildProcess",
            environment: [
                "CODEXSWITCH_INSTALLER_CHILD": "1",
                "CODEXSWITCH_INSTALLER_TRANSACTION_ROOT": transactionRoot.path,
                "CODEXSWITCH_INSTALLER_DESTINATION": destination.path,
                "CODEXSWITCH_INSTALLER_SOURCE": source.path,
                "CODEXSWITCH_INSTALLER_READY": ready.path,
                "CODEXSWITCH_INSTALLER_RELEASE": release.path,
                "CODEXSWITCH_INSTALLER_LEASE": leaseURL.path,
            ]
        )
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
            }
        }

        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            usleep(10_000)
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))

        let secondOwner = DesktopUpdateOperationOwner(
            stateMachine: CodexDesktopUpdateStateMachine(),
            leaseURL: leaseURL,
            updateRoot: root,
            allowedDestinations: [destination]
        )
        let second = await secondOwner.acquire(
            .installingStagedUpdate,
            epoch: .standalone()
        )
        guard case .busy = second else {
            Issue.record("A second process must not acquire the operation lease")
            return
        }
        try Data().write(to: release)
        let exitDeadline = ContinuousClock.now + .seconds(10)
        while child.isRunning, ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!child.isRunning)
        #expect(child.terminationStatus == 0)
        #expect(try readMarker(from: destination) == "new")
    }

    @Test("Installer lease child process helper")
    func installerLeaseChildProcess() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEXSWITCH_INSTALLER_CHILD"] == "1" else { return }
        let transactionRoot = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_INSTALLER_TRANSACTION_ROOT"])
        )
        let destination = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_INSTALLER_DESTINATION"])
        )
        let source = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_INSTALLER_SOURCE"])
        )
        let ready = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_INSTALLER_READY"])
        )
        let release = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_INSTALLER_RELEASE"])
        )
        let leaseURL = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_INSTALLER_LEASE"])
        )
        let scope = try await makeTestOperationScope(
            root: transactionRoot.deletingLastPathComponent(),
            allowedDestinations: [destination],
            leaseURL: leaseURL
        )

        let result = try DesktopBundleInstaller(
            transactionRoot: transactionRoot,
            allowedDestinations: [destination]
        ).install(
            lifetime: scope.lifetime,
            sourceApp: source,
            destination: destination,
            expectedBundleVersion: "5211",
            expectedShortVersion: "26.707.62119",
            kind: .stagedUpdate,
            desktopRuntimeRunning: { false },
            beforeAtomicCommit: {
                try? Data().write(to: ready)
                while !FileManager.default.fileExists(atPath: release.path) {
                    usleep(10_000)
                }
            },
            validate: metadataValidation
        )
        #expect(result == .installed(cancellationDeferred: false, cleanupDeferred: false))
    }

    @Test("Startup recovery removes a prepared incoming bundle")
    func preparedJournalRecoveryLeavesOldDestination() async throws {
        let fixture = try makeInstallJournalFixture(phase: .prepared, destinationIsNew: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try await recover(fixture: fixture, validate: metadataValidation)

        #expect(result == .removedPrepared)
        #expect(try readMarker(from: fixture.destination) == "old")
        #expect(!FileManager.default.fileExists(atPath: fixture.incoming.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Startup recovery performs no mutation while the desktop runtime is live")
    func recoveryDefersAllMutationWhileRuntimeIsLive() async throws {
        let fixture = try makeInstallJournalFixture(phase: .prepared, destinationIsNew: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try await recover(
            fixture: fixture,
            desktopRuntimeRunning: { true },
            validate: metadataValidation
        )

        guard case .deferred = result else {
            Issue.record("Live runtime evidence must defer recovery")
            return
        }
        #expect(try readMarker(from: fixture.destination) == "old")
        #expect(try readMarker(from: fixture.incoming) == "new")
        #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Startup recovery completes a valid swapped journal")
    func swappedJournalRecoveryCompletesCommit() async throws {
        let fixture = try makeInstallJournalFixture(phase: .swapped, destinationIsNew: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try await recover(fixture: fixture, validate: metadataValidation)

        #expect(result == .completedCommit)
        #expect(try readMarker(from: fixture.destination) == "new")
        #expect(!FileManager.default.fileExists(atPath: fixture.incoming.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Startup recovery atomically rolls back an invalid swapped journal")
    func invalidSwappedJournalRecoveryRollsBack() async throws {
        let fixture = try makeInstallJournalFixture(phase: .validating, destinationIsNew: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try await recover(fixture: fixture) { candidate, _, _, _ in
            candidate == fixture.destination ? .invalid("postflight failed") : .valid
        }

        #expect(result == .rolledBack)
        #expect(try readMarker(from: fixture.destination) == "old")
        #expect(!FileManager.default.fileExists(atPath: fixture.incoming.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Recovery refuses rollback after in-place mutation of the previous bundle")
    func recoverySealsRollbackChildContent() async throws {
        let fixture = try makeInstallJournalFixture(
            phase: .validating,
            destinationIsNew: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let marker = fixture.incoming.appendingPathComponent("marker")
        let originalDate = try marker.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        try Data("bad".utf8).write(to: marker)
        if let originalDate {
            try FileManager.default.setAttributes(
                [.modificationDate: originalDate],
                ofItemAtPath: marker.path
            )
        }

        let result = try await recover(fixture: fixture) { _, _, _, _ in
            .invalid("postflight failed")
        }

        guard case .deferred(let reason) = result else {
            Issue.record("Mutated rollback bytes must fail closed without a swap")
            return
        }
        #expect(reason.contains("content identity changed"))
        #expect(try readMarker(from: fixture.destination) == "new")
        #expect(try readMarker(from: fixture.incoming) == "bad")
        #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Recovery rejects a child mutation after classification but before rollback")
    func recoveryRetainsRollbackAuthorityThroughAtomicSwap() async throws {
        let fixture = try makeInstallJournalFixture(
            phase: .validating,
            destinationIsNew: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installer = DesktopBundleInstaller(
            transactionRoot: fixture.journalURL.deletingLastPathComponent(),
            allowedDestinations: [fixture.destination],
            beforeRollbackCommit: {
                try Data("mutated-during-recovery".utf8).write(
                    to: fixture.incoming.appendingPathComponent("marker")
                )
            }
        )
        let scope = try await makeTestOperationScope(
            root: fixture.root,
            allowedDestinations: [fixture.destination],
            operation: .recovering
        )

        let result = try installer.recover(
            lifetime: scope.lifetime,
            desktopRuntimeRunning: { false },
            validate: { _, _, _, _ in .invalid("postflight failed") }
        )

        guard case .deferred(let reason) = result else {
            Issue.record("Mutation during recovery must defer without swapping")
            return
        }
        #expect(reason.contains("Descriptor-rooted rollback evidence changed"))
        #expect(try readMarker(from: fixture.destination) == "new")
        #expect(try readMarker(from: fixture.incoming) == "mutated-during-recovery")
        #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Recovery rejects same-inode rollback ABA after classification")
    func recoveryRejectsRollbackChildABA() async throws {
        let fixture = try makeInstallJournalFixture(
            phase: .validating,
            destinationIsNew: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let marker = fixture.incoming.appendingPathComponent("marker")
        let originalBytes = try Data(contentsOf: marker)
        let originalDate = try #require(
            marker.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        let installer = DesktopBundleInstaller(
            transactionRoot: fixture.journalURL.deletingLastPathComponent(),
            allowedDestinations: [fixture.destination],
            beforeRollbackCommit: {
                usleep(10_000)
                try Data("mutated-during-recovery".utf8).write(to: marker)
                try originalBytes.write(to: marker)
                try FileManager.default.setAttributes(
                    [.modificationDate: originalDate],
                    ofItemAtPath: marker.path
                )
            }
        )
        let scope = try await makeTestOperationScope(
            root: fixture.root,
            allowedDestinations: [fixture.destination],
            operation: .recovering
        )

        let result = try installer.recover(
            lifetime: scope.lifetime,
            desktopRuntimeRunning: { false },
            validate: { _, _, _, _ in .invalid("postflight failed") }
        )

        guard case .deferred(let reason) = result else {
            Issue.record("Same-inode rollback ABA must defer without swapping")
            return
        }
        #expect(reason.contains("Descriptor-rooted rollback evidence changed"))
        #expect(try readMarker(from: fixture.destination) == "new")
        #expect(try readMarker(from: fixture.incoming) == "old")
        #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Recovery rejects same-inode rollback ABA after the atomic swap")
    func recoveryRejectsPostSwapRollbackChildABA() async throws {
        let fixture = try makeInstallJournalFixture(
            phase: .validating,
            destinationIsNew: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalMarker = fixture.incoming.appendingPathComponent("marker")
        let originalBytes = try Data(contentsOf: originalMarker)
        let originalDate = try #require(
            originalMarker.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
        )
        let installer = DesktopBundleInstaller(
            transactionRoot: fixture.journalURL.deletingLastPathComponent(),
            allowedDestinations: [fixture.destination],
            afterRollbackSwapBeforeVerification: {
                let movedMarker = fixture.destination.appendingPathComponent("marker")
                usleep(10_000)
                try Data("post-swap-mutation".utf8).write(to: movedMarker)
                try originalBytes.write(to: movedMarker)
                try FileManager.default.setAttributes(
                    [.modificationDate: originalDate],
                    ofItemAtPath: movedMarker.path
                )
            }
        )
        let scope = try await makeTestOperationScope(
            root: fixture.root,
            allowedDestinations: [fixture.destination],
            operation: .recovering
        )

        let result = try installer.recover(
            lifetime: scope.lifetime,
            desktopRuntimeRunning: { false },
            validate: { _, _, _, _ in .invalid("postflight failed") }
        )

        guard case .deferred(let reason) = result else {
            Issue.record("Post-swap rollback ABA must restore the activated layout and defer")
            return
        }
        #expect(reason.contains("Descriptor-rooted rollback evidence changed"))
        #expect(try readMarker(from: fixture.destination) == "new")
        #expect(try readMarker(from: fixture.incoming) == "old")
        #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Recovery refuses whole-bundle replacement of recorded rollback evidence")
    func recoveryRejectsRollbackBundleReplacement() async throws {
        let fixture = try makeInstallJournalFixture(
            phase: .validating,
            destinationIsNew: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.incoming)
        try writeFakeApp(
            at: fixture.incoming,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "old"
        )

        let result = try await recover(fixture: fixture) { _, _, _, _ in
            .invalid("postflight failed")
        }

        guard case .deferred = result else {
            Issue.record("A replacement root must not inherit journal rollback authority")
            return
        }
        #expect(try readMarker(from: fixture.destination) == "new")
        #expect(try readMarker(from: fixture.incoming) == "old")
        #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Recovery rejects a journal copied into a replacement transaction root")
    func recoveryRejectsJournalRootReplacement() async throws {
        let fixture = try makeInstallJournalFixture(
            phase: .prepared,
            destinationIsNew: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transactionRoot = fixture.journalURL.deletingLastPathComponent()
        let displacedRoot = fixture.root.appendingPathComponent(
            "transactions-displaced",
            isDirectory: true
        )
        let journalData = try Data(contentsOf: fixture.journalURL)
        try FileManager.default.moveItem(at: transactionRoot, to: displacedRoot)
        try FileManager.default.createDirectory(
            at: transactionRoot,
            withIntermediateDirectories: true
        )
        try journalData.write(to: fixture.journalURL)

        let result = try await recover(fixture: fixture, validate: metadataValidation)

        guard case .deferred = result else {
            Issue.record("A replacement journal root must not inherit recovery authority")
            return
        }
        #expect(try readMarker(from: fixture.destination) == "old")
        #expect(try readMarker(from: fixture.incoming) == "new")
        #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("A competing process is busy during actual journal recovery")
    func operationLeaseCoversJournalRecovery() async throws {
        let fixture = try makeInstallJournalFixture(
            phase: .swapped,
            destinationIsNew: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let leaseURL = fixture.root.appendingPathComponent("shared-recovery-operation.lock")
        let ready = fixture.root.appendingPathComponent("recovery-child-ready")
        let release = fixture.root.appendingPathComponent("recovery-child-release")
        let child = try makeDesktopUpdaterTestSubprocess(
            filter: "operationLeaseRecoveryChildProcess",
            environment: [
                "CODEXSWITCH_RECOVERY_LEASE_CHILD": "1",
                "CODEXSWITCH_RECOVERY_LEASE_ROOT": fixture.root.path,
                "CODEXSWITCH_RECOVERY_LEASE_DESTINATION": fixture.destination.path,
                "CODEXSWITCH_RECOVERY_LEASE_PATH": leaseURL.path,
                "CODEXSWITCH_RECOVERY_LEASE_READY": ready.path,
                "CODEXSWITCH_RECOVERY_LEASE_RELEASE": release.path,
            ]
        )
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
        }

        let readyDeadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: ready.path),
              child.isRunning,
              ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))

        let competingOwner = DesktopUpdateOperationOwner(
            stateMachine: CodexDesktopUpdateStateMachine(),
            leaseURL: leaseURL,
            updateRoot: fixture.root,
            allowedDestinations: [fixture.destination]
        )
        let collision = await competingOwner.acquire(.recovering, epoch: .standalone())
        guard case .busy = collision else {
            Issue.record("A second process must not enter active journal recovery")
            return
        }

        try Data().write(to: release)
        let exitDeadline = ContinuousClock.now + .seconds(10)
        while child.isRunning, ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!child.isRunning)
        #expect(child.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
        #expect(try readMarker(from: fixture.destination) == "new")
    }

    @Test("Journal recovery lease child process helper")
    func operationLeaseRecoveryChildProcess() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEXSWITCH_RECOVERY_LEASE_CHILD"] == "1" else { return }
        let root = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_RECOVERY_LEASE_ROOT"])
        )
        let destination = URL(
            fileURLWithPath: try #require(
                environment["CODEXSWITCH_RECOVERY_LEASE_DESTINATION"]
            )
        )
        let leaseURL = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_RECOVERY_LEASE_PATH"])
        )
        let ready = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_RECOVERY_LEASE_READY"])
        )
        let release = URL(
            fileURLWithPath: try #require(environment["CODEXSWITCH_RECOVERY_LEASE_RELEASE"])
        )
        let scope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination],
            leaseURL: leaseURL,
            operation: .recovering
        )
        let installer = DesktopBundleInstaller(
            transactionRoot: root.appendingPathComponent("transactions", isDirectory: true),
            allowedDestinations: [destination]
        )
        let result = try CodexDesktopAppUpdater.performInstallRecoveryHoldingLifetime(
            lifetime: scope.lifetime,
            installer: installer,
            desktopRuntimeRunning: { false },
            validateOfficialBundle: { _, _, _, isCancelled in
                if isCancelled() { return .cancelled }
                do {
                    try Data().write(to: ready)
                } catch {
                    return .unavailable(error.localizedDescription)
                }
                while !FileManager.default.fileExists(atPath: release.path) {
                    usleep(10_000)
                }
                return .valid
            }
        )
        #expect(result == .completedCommit)
        _ = await scope.owner.finish(scope.lifetime)
    }

    @Test("Rollback-phase recovery recognizes an already restored destination")
    func rollbackJournalRecoveryFinishesCleanup() async throws {
        let fixture = try makeInstallJournalFixture(phase: .rollback, destinationIsNew: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try await recover(fixture: fixture, validate: metadataValidation)

        #expect(result == .rolledBack)
        #expect(try readMarker(from: fixture.destination) == "old")
        #expect(!FileManager.default.fileExists(atPath: fixture.incoming.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Prepared same-build recovery uses identities instead of version labels")
    func preparedSameBuildRecoveryUsesPathIdentities() async throws {
        let fixture = try makeInstallJournalFixture(
            phase: .prepared,
            destinationIsNew: false,
            sameVersion: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var validationCount = 0

        let result = try await recover(fixture: fixture) { _, _, _, _ in
            validationCount += 1
            return .valid
        }

        #expect(result == .removedPrepared)
        #expect(validationCount == 0)
        #expect(try readMarker(from: fixture.destination) == "old")
        #expect(!FileManager.default.fileExists(atPath: fixture.incoming.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("A lagging validating journal finishes an already completed rollback")
    func validatingJournalRecognizesCompletedRollback() async throws {
        let fixture = try makeInstallJournalFixture(
            phase: .validating,
            destinationIsNew: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try await recover(fixture: fixture) { _, _, _, _ in
            Issue.record("Completed rollback recovery must not revalidate the old destination")
            return .valid
        }

        #expect(result == .rolledBack)
        #expect(try readMarker(from: fixture.destination) == "old")
        #expect(!FileManager.default.fileExists(atPath: fixture.incoming.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Committed recovery defers cleanup when fresh rollback trust is unavailable")
    func committedJournalRecoveryRequiresFreshRollbackTrust() async throws {
        let fixture = try makeInstallJournalFixture(phase: .committed, destinationIsNew: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var validationCount = 0

        let result = try await recover(fixture: fixture) { _, _, _, _ in
            validationCount += 1
            return .unavailable("Gatekeeper assessment did not complete")
        }

        guard case .deferred = result else {
            Issue.record("Unavailable rollback trust must preserve cleanup recovery state")
            return
        }
        #expect(validationCount == 1)
        #expect(try readMarker(from: fixture.destination) == "new")
        #expect(FileManager.default.fileExists(atPath: fixture.incoming.path))
        #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test("Recovery defers an out-of-bound journal and preserves every path")
    func outOfBoundJournalIsPreserved() async throws {
        let fixture = try makeInstallJournalFixture(
            phase: .prepared,
            destinationIsNew: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unrelatedAllowedPath = fixture.root.appendingPathComponent(
            "Different.app",
            isDirectory: true
        )
        let restrictedInstaller = DesktopBundleInstaller(
            transactionRoot: fixture.journalURL.deletingLastPathComponent(),
            allowedDestinations: [unrelatedAllowedPath]
        )

        let scope = try await makeTestOperationScope(
            root: fixture.root,
            allowedDestinations: [unrelatedAllowedPath],
            operation: .recovering
        )
        let result = try restrictedInstaller.recover(
            lifetime: scope.lifetime,
            desktopRuntimeRunning: { false },
            validate: metadataValidation
        )

        guard case .deferred = result else {
            Issue.record("Out-of-bound journal recovery must defer")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(FileManager.default.fileExists(atPath: fixture.incoming.path))
        #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))
        #expect(try readMarker(from: fixture.destination) == "old")
        #expect(try readMarker(from: fixture.incoming) == "new")
    }

    @Test("Updater subprocess draining is bounded under stderr saturation")
    func subprocessStderrSaturationDoesNotDeadlock() {
        let runner = DesktopUpdaterProcessRunner()
        let result = runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "i=0; while [ $i -lt 20000 ]; do "
                    + "printf '012345678901234567890123456789\\n' >&2; "
                    + "i=$((i+1)); done",
            ],
            timeout: 10,
            outputLimit: 4_096
        )

        #expect(!result.timedOut)
        #expect(!result.cancelled)
        #expect(result.terminationStatus == 0)
        #expect(result.stderrTruncated)
        #expect(result.standardError.utf8.count <= 4_096)
    }

    @Test("Updater subprocess timeout kills and reaps the child")
    func subprocessTimeoutReapsChild() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pidURL = root.appendingPathComponent("pid")
        let runner = DesktopUpdaterProcessRunner()
        let started = Date()

        let result = runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "echo $$ > '\(pidURL.path)'; trap '' TERM; while :; do :; done",
            ],
            timeout: 0.1,
            outputLimit: 1_024
        )

        #expect(result.timedOut)
        #expect(!result.cancelled)
        #expect(result.reaped)
        #expect(Date().timeIntervalSince(started) < 3)
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))
        let probeResult = kill(pid, 0)
        let probeError = errno
        #expect(probeResult == -1)
        #expect(probeError == ESRCH)
    }

    @Test("Updater subprocess cancellation terminates and reaps the child")
    func subprocessCancellationReapsChild() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pidURL = root.appendingPathComponent("pid")
        var cancellationPolls = 0

        let result = DesktopUpdaterProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "echo $$ > '\(pidURL.path)'; trap '' TERM; while :; do :; done",
            ],
            timeout: 10,
            outputLimit: 1_024,
            isCancelled: {
                cancellationPolls += 1
                return cancellationPolls >= 5
            }
        )

        #expect(result.cancelled)
        #expect(!result.timedOut)
        #expect(result.reaped)
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))
        let probeResult = kill(pid, 0)
        let probeError = errno
        #expect(probeResult == -1)
        #expect(probeError == ESRCH)
    }

    @Test("A never-terminating process is handed to a detached reaper without blocking")
    func neverTerminatingProcessHasBoundedCallerWait() {
        let process = NeverTerminatingProcessFake()
        var waits: [TimeInterval] = []

        let reaped = DesktopUpdaterTerminationController(
            gracefulWait: 0.1,
            forcedWait: 0.2
        ).stop(process) { interval in
            waits.append(interval)
            return false
        }

        #expect(!reaped)
        #expect(waits == [0.1, 0.2])
        #expect(process.gracefulRequests == 1)
        #expect(process.forcedRequests == 1)
        #expect(process.detachedReaperRequests == 1)
    }

    @Test("Atomic install validates incoming bundle before moving working app")
    func atomicInstallValidatesBeforeMovingWorkingApp() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let source = root.appendingPathComponent("source.app", isDirectory: true)
        let transactionRoot = root.appendingPathComponent("transactions", isDirectory: true)
        try writeFakeApp(
            at: destination,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "working"
        )
        try writeFakeApp(
            at: source,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "invalid"
        )
        let scope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination]
        )

        #expect(throws: (any Error).self) {
            try DesktopBundleInstaller(
                transactionRoot: transactionRoot,
                allowedDestinations: [destination]
            ).install(
                lifetime: scope.lifetime,
                sourceApp: source,
                destination: destination,
                expectedBundleVersion: "5211",
                expectedShortVersion: "26.707.62119",
                kind: .stagedUpdate,
                desktopRuntimeRunning: { false },
                validate: { _, _, _, _ in .invalid("strict signature rejected") }
            )
        }

        #expect(try readMarker(from: destination) == "working")
        #expect(try readMarker(from: source) == "invalid")
        #expect(!FileManager.default.fileExists(
            atPath: transactionRoot.appendingPathComponent(
                DesktopBundleInstaller.journalFileName
            ).path
        ))
    }

    @Test("Atomic install never mutates the destination while ChatGPT is running")
    func atomicInstallRefusesRunningDesktop() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let source = root.appendingPathComponent("source.app", isDirectory: true)
        let transactionRoot = root.appendingPathComponent("transactions", isDirectory: true)
        try writeFakeApp(
            at: destination,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "working"
        )
        try writeFakeApp(
            at: source,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "candidate"
        )
        var validationRan = false
        let scope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination]
        )

        let result = try DesktopBundleInstaller(
            transactionRoot: transactionRoot,
            allowedDestinations: [destination]
        ).install(
            lifetime: scope.lifetime,
            sourceApp: source,
            destination: destination,
            expectedBundleVersion: "5211",
            expectedShortVersion: "26.707.62119",
            kind: .stagedUpdate,
            desktopRuntimeRunning: { true },
            validate: { _, _, _, _ in
                validationRan = true
                return .valid
            }
        )

        #expect(result == .runtimeRunning)
        #expect(!validationRan)
        #expect(try readMarker(from: destination) == "working")
        #expect(try readMarker(from: source) == "candidate")
    }

    @Test("Atomic install rechecks ChatGPT after incoming validation")
    func atomicInstallRechecksRuntimeAfterValidation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let source = root.appendingPathComponent("source.app", isDirectory: true)
        let transactionRoot = root.appendingPathComponent("transactions", isDirectory: true)
        try writeFakeApp(
            at: destination,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "working"
        )
        try writeFakeApp(
            at: source,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "candidate"
        )
        var runtimeProbeCount = 0
        var validationRan = false
        let scope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination]
        )

        let result = try DesktopBundleInstaller(
            transactionRoot: transactionRoot,
            allowedDestinations: [destination]
        ).install(
            lifetime: scope.lifetime,
            sourceApp: source,
            destination: destination,
            expectedBundleVersion: "5211",
            expectedShortVersion: "26.707.62119",
            kind: .stagedUpdate,
            desktopRuntimeRunning: {
                runtimeProbeCount += 1
                return runtimeProbeCount >= 3
            },
            validate: { _, _, _, _ in
                validationRan = true
                return .valid
            }
        )

        #expect(result == .runtimeRunning)
        #expect(runtimeProbeCount == 3)
        #expect(validationRan)
        #expect(try readMarker(from: destination) == "working")
        #expect(try readMarker(from: source) == "candidate")
    }

    @Test("Atomic install restores previous app when post-move validation fails")
    func atomicInstallRollsBackFailedReplacement() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let source = root.appendingPathComponent("source.app", isDirectory: true)
        let transactionRoot = root.appendingPathComponent("transactions", isDirectory: true)
        try writeFakeApp(
            at: destination,
            bundleVersion: "5103",
            shortVersion: "26.707.5103",
            marker: "working"
        )
        try writeFakeApp(
            at: source,
            bundleVersion: "5211",
            shortVersion: "26.707.62119",
            marker: "candidate"
        )
        let scope = try await makeTestOperationScope(
            root: root,
            allowedDestinations: [destination]
        )

        #expect(throws: (any Error).self) {
            try DesktopBundleInstaller(
                transactionRoot: transactionRoot,
                allowedDestinations: [destination]
            ).install(
                lifetime: scope.lifetime,
                sourceApp: source,
                destination: destination,
                expectedBundleVersion: "5211",
                expectedShortVersion: "26.707.62119",
                kind: .stagedUpdate,
                desktopRuntimeRunning: { false },
                validate: { candidate, bundleVersion, _, _ in
                    CodexDesktopPathSecurity.lexicallyStandardized(candidate)
                        == CodexDesktopPathSecurity.lexicallyStandardized(destination)
                        && bundleVersion == "5211"
                        ? .invalid("post-install identity changed")
                        : .valid
                }
            )
        }

        #expect(try readMarker(from: destination) == "working")
        #expect(try readMarker(from: source) == "candidate")
        #expect(!FileManager.default.fileExists(
            atPath: transactionRoot.appendingPathComponent(
                DesktopBundleInstaller.journalFileName
            ).path
        ))
    }

    private struct InstallJournalFixture {
        let root: URL
        let destination: URL
        let incoming: URL
        let journalURL: URL
        let installer: DesktopBundleInstaller
    }

    private func recover(
        fixture: InstallJournalFixture,
        desktopRuntimeRunning: () -> Bool = { false },
        validate: (URL, String, String, () -> Bool) -> CodexDesktopBundleValidationResult
    ) async throws -> DesktopInstallRecoveryResult {
        let scope = try await makeTestOperationScope(
            root: fixture.root,
            allowedDestinations: [fixture.destination],
            operation: .recovering
        )
        return try fixture.installer.recover(
            lifetime: scope.lifetime,
            desktopRuntimeRunning: desktopRuntimeRunning,
            validate: validate
        )
    }

    private func makeInstallJournalFixture(
        phase: DesktopInstallJournalPhase,
        destinationIsNew: Bool,
        sameVersion: Bool = false
    ) throws -> InstallJournalFixture {
        let root = temporaryDirectory()
        let transactionRoot = root.appendingPathComponent("transactions", isDirectory: true)
        let destination = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let transactionIdentifier = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000301")
        )
        let incoming = root.appendingPathComponent(
            ".codexswitch-incoming-\(transactionIdentifier.uuidString).app",
            isDirectory: true
        )
        let oldBundleVersion = sameVersion ? "5211" : "5103"
        let oldShortVersion = sameVersion ? "26.707.62119" : "26.707.5103"
        if destinationIsNew {
            try writeFakeApp(
                at: destination,
                bundleVersion: "5211",
                shortVersion: "26.707.62119",
                marker: "new"
            )
            try writeFakeApp(
                at: incoming,
                bundleVersion: oldBundleVersion,
                shortVersion: oldShortVersion,
                marker: "old"
            )
        } else {
            try writeFakeApp(
                at: destination,
                bundleVersion: oldBundleVersion,
                shortVersion: oldShortVersion,
                marker: "old"
            )
            try writeFakeApp(
                at: incoming,
                bundleVersion: "5211",
                shortVersion: "26.707.62119",
                marker: "new"
            )
        }
        try FileManager.default.createDirectory(
            at: transactionRoot,
            withIntermediateDirectories: true
        )
        let incomingIdentity = try #require(
            DesktopBundleInstaller.pathIdentity(
                at: destinationIsNew ? destination : incoming
            )
        )
        let previousDestinationIdentity = try #require(
            DesktopBundleInstaller.pathIdentity(
                at: destinationIsNew ? incoming : destination
            )
        )
        let incomingBundleIdentity = try #require(
            DesktopBundleTreeIntegrity.makeBundleIdentity(
                appURL: destinationIsNew ? destination : incoming,
                isCancelled: { false }
            )
        )
        let previousDestinationBundleIdentity = try #require(
            DesktopBundleTreeIntegrity.makeBundleIdentity(
                appURL: destinationIsNew ? incoming : destination,
                isCancelled: { false }
            )
        )
        let journal = DesktopInstallJournal(
            version: DesktopBundleInstaller.journalVersion,
            transactionIdentifier: transactionIdentifier,
            kind: .stagedUpdate,
            destinationPath: destination.path,
            incomingPath: incoming.path,
            transactionRootIdentity: DesktopBundleInstaller.pathIdentity(at: transactionRoot),
            destinationDirectoryIdentity: DesktopBundleInstaller.pathIdentity(at: root),
            destinationExisted: true,
            incomingIdentity: incomingIdentity,
            previousDestinationIdentity: previousDestinationIdentity,
            incomingBundleIdentity: incomingBundleIdentity,
            previousDestinationBundleIdentity: previousDestinationBundleIdentity,
            previousBundleVersion: oldBundleVersion,
            previousShortVersion: oldShortVersion,
            expectedBundleVersion: "5211",
            expectedShortVersion: "26.707.62119",
            phase: phase,
            createdAt: Date(timeIntervalSince1970: 10_000)
        )
        let journalURL = transactionRoot.appendingPathComponent(
            DesktopBundleInstaller.journalFileName
        )
        try JSONEncoder().encode(journal).write(to: journalURL)
        return InstallJournalFixture(
            root: root,
            destination: destination,
            incoming: incoming,
            journalURL: journalURL,
            installer: DesktopBundleInstaller(
                transactionRoot: transactionRoot,
                allowedDestinations: [destination]
            )
        )
    }

    private func metadataValidation(
        _ candidate: URL,
        _ expectedBundleVersion: String,
        _ expectedShortVersion: String,
        _ isCancelled: () -> Bool
    ) -> CodexDesktopBundleValidationResult {
        if isCancelled() { return .cancelled }
        guard let install = CodexDesktopAppLocator.locate(appPath: candidate.path),
              install.bundleVersion == expectedBundleVersion,
              install.shortVersion == expectedShortVersion else {
            return .invalid("metadata mismatch")
        }
        return .valid
    }

    private func addReadACL(to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CodexDesktopAppUpdaterTests.ACL", code: 1)
        }
    }

    private func appcastData(shortVersion: String, bundleVersion: String) -> Data {
        let digest = String(repeating: "a", count: 64)
        return Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel><item>
                <sparkle:shortVersionString>\(shortVersion)</sparkle:shortVersionString>
                <sparkle:version>\(bundleVersion)</sparkle:version>
                <enclosure url="https://persistent.oaistatic.com/ChatGPT-\(bundleVersion).zip"
                  sparkle:version="\(bundleVersion)"
                  sparkle:shortVersionString="\(shortVersion)"
                  sparkle:sha256="\(digest)" />
              </item></channel>
            </rss>
            """.utf8
        )
    }

    private func writeFakeApp(
        at app: URL,
        bundleVersion: String,
        shortVersion: String,
        marker: String
    ) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let signature = contents.appendingPathComponent("_CodeSignature", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.openai.codex",
            "CFBundleVersion": bundleVersion,
            "CFBundleShortVersionString": shortVersion,
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("asar".utf8).write(to: resources.appendingPathComponent("app.asar"))
        try Data("signature".utf8).write(to: signature.appendingPathComponent("CodeResources"))
        try Data(marker.utf8).write(to: app.appendingPathComponent("marker"))
    }

    private func writeRollbackGeneration(
        in root: URL,
        bundleVersion: String,
        shortVersion: String,
        marker: String
    ) throws -> (rollback: CodexDesktopRollbackGeneration, directory: URL) {
        let identifier = UUID().uuidString
        let directory = root.appendingPathComponent(
            "\(CodexDesktopUpdateStorage.previousPrefix)\(identifier)",
            isDirectory: true
        )
        let app = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
        try writeFakeApp(
            at: app,
            bundleVersion: bundleVersion,
            shortVersion: shortVersion,
            marker: marker
        )
        let identity = try #require(
            DesktopBundleTreeIntegrity.makeBundleIdentity(
                appURL: app,
                isCancelled: { false }
            )
        )
        return (
            CodexDesktopRollbackGeneration(
                formatVersion: CodexDesktopUpdateStorage.rollbackFormatVersion,
                generationIdentifier: identifier,
                appPath: app.path,
                sourceDestinationPath: root.appendingPathComponent("ChatGPT.app").path,
                shortVersion: shortVersion,
                bundleVersion: bundleVersion,
                preservedAt: Date(),
                bundleIdentity: identity
            ),
            directory
        )
    }

    private func writeFakeStagedUpdate(
        in root: URL,
        bundleVersion: String,
        legacyLayout: Bool,
        includeSeal: Bool,
        persistAuthoritative: Bool = true,
        downloadURL: URL = URL(
            string: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-test.zip"
        )!,
        archiveSHA256: String? = nil,
        archiveLength: Int64? = nil,
        marker: String? = nil,
        asarModificationDate: Date? = nil
    ) throws -> CodexDesktopStagedUpdate {
        let generationIdentifier = legacyLayout ? nil : UUID().uuidString
        let generationDirectory = generationIdentifier.map {
            CodexDesktopUpdateStorage.generationDirectory(in: root, identifier: $0)
        } ?? root.appendingPathComponent(
            CodexDesktopUpdateStorage.legacyStagedDirectoryName,
            isDirectory: true
        )
        let app = generationDirectory.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let signature = contents.appendingPathComponent("_CodeSignature", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.openai.codex",
            "CFBundleVersion": bundleVersion,
            "CFBundleShortVersionString": "26.707.62119",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        let asar = resources.appendingPathComponent("app.asar")
        try Data("asar".utf8).write(to: asar)
        if let asarModificationDate {
            try FileManager.default.setAttributes(
                [.modificationDate: asarModificationDate],
                ofItemAtPath: asar.path
            )
        }
        try Data("signature".utf8).write(to: signature.appendingPathComponent("CodeResources"))
        if let marker {
            try Data(marker.utf8).write(to: app.appendingPathComponent("marker"))
        }

        let unsealed = CodexDesktopStagedUpdate(
            shortVersion: "26.707.62119",
            bundleVersion: bundleVersion,
            downloadURL: downloadURL,
            appPath: app.path,
            stagedAt: Date(timeIntervalSince1970: 9_000),
            generationIdentifier: generationIdentifier,
            archiveSHA256: archiveSHA256,
            archiveLength: archiveLength
        )
        let seal = includeSeal
            ? CodexDesktopUpdateStorage.makeValidationSeal(for: unsealed, in: root)
            : nil
        let staged = CodexDesktopStagedUpdate(
            shortVersion: unsealed.shortVersion,
            bundleVersion: unsealed.bundleVersion,
            downloadURL: unsealed.downloadURL,
            appPath: unsealed.appPath,
            stagedAt: unsealed.stagedAt,
            generationIdentifier: unsealed.generationIdentifier,
            validationSeal: seal,
            archiveSHA256: unsealed.archiveSHA256,
            archiveLength: unsealed.archiveLength
        )
        if persistAuthoritative {
            if includeSeal {
                try CodexDesktopUpdateStorage.saveAuthoritativeUpdate(staged, in: root)
            } else {
                try CodexDesktopUpdateStorage.saveUnsealedAuthoritativeUpdateForMigration(
                    staged,
                    in: root
                )
            }
        }
        return staged
    }

    private struct ZIPTestEntry {
        let path: String
        let compressedBytes: UInt32
        let expandedBytes: UInt32
        let unixMode: UInt32
    }

    private func makeZIPArchive(entries: [ZIPTestEntry]) -> Data {
        var central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            appendUInt32(0x02014b50, to: &central)
            appendUInt16(0x0314, to: &central)
            appendUInt16(20, to: &central)
            appendUInt16(0x0800, to: &central)
            appendUInt16(8, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt32(0, to: &central)
            appendUInt32(entry.compressedBytes, to: &central)
            appendUInt32(entry.expandedBytes, to: &central)
            appendUInt16(UInt16(name.count), to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt32(entry.unixMode << 16, to: &central)
            appendUInt32(0, to: &central)
            central.append(name)
        }

        var archive = Data([0])
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        appendUInt32(0x06054b50, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(UInt16(entries.count), to: &archive)
        appendUInt16(UInt16(entries.count), to: &archive)
        appendUInt32(UInt32(central.count), to: &archive)
        appendUInt32(centralOffset, to: &archive)
        appendUInt16(0, to: &archive)
        return archive
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryDirectory() -> URL {
        let configuredRoot = ProcessInfo.processInfo.environment["CODEXSWITCH_TEST_TMPDIR"]
        let rootPath = configuredRoot.flatMap { $0.isEmpty ? nil : $0 } ?? "/private/tmp"
        return URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent(
            "CodexDesktopAppUpdaterTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func writeMarker(_ value: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(value.utf8).write(to: directory.appendingPathComponent("marker"))
    }

    private func readMarker(from directory: URL) throws -> String {
        let data = try Data(contentsOf: directory.appendingPathComponent("marker"))
        return String(decoding: data, as: UTF8.self)
    }
}
