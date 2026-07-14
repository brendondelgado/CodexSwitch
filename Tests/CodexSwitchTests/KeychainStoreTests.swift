import Darwin
import Foundation
import Security
import Testing
@testable import CodexSwitch

private func secureWrite(_ data: Data, to path: String) throws {
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    guard chmod(path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private func makeStorePath() -> String {
    (resolvedTemporaryDirectory() as NSString)
        .appendingPathComponent("CodexSwitchTests-\(UUID().uuidString)/accounts.json")
}

private func resolvedTemporaryDirectory() -> String {
    guard let resolved = Darwin.realpath(NSTemporaryDirectory(), nil) else {
        return NSTemporaryDirectory()
    }
    defer { Darwin.free(resolved) }
    return String(cString: resolved)
}

private final class LegacyDeletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var fileMissingObservations: [Bool] = []

    func recordDeletion(fileWasMissing: Bool) {
        lock.withLock { fileMissingObservations.append(fileWasMissing) }
    }

    var count: Int {
        lock.withLock { fileMissingObservations.count }
    }

    var observations: [Bool] {
        lock.withLock { fileMissingObservations }
    }
}

private func fileIsMissing(at path: String) -> Bool {
    var metadata = stat()
    return lstat(path, &metadata) == -1 && errno == ENOENT
}

private func lockIsHeldByAnotherProcess(at path: String) throws -> Bool {
    let descriptor = Darwin.open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }

    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
        _ = flock(descriptor, LOCK_UN)
        return false
    }
    guard errno == EWOULDBLOCK || errno == EAGAIN else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return true
}

private func waitForPath(_ path: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: path) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return FileManager.default.fileExists(atPath: path)
}

private func waitForProcessExit(_ process: Process, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard !process.isRunning else {
        return false
    }
    process.waitUntilExit()
    return true
}

private func terminateIfRunning(_ process: Process) {
    guard process.isRunning else {
        return
    }
    _ = Darwin.kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
}

private func makeTestSubprocess(
    filter: String,
    environment additions: [String: String]
) throws -> (process: Process, output: Pipe) {
    let process = Process()
    let output = Pipe()
    try configureSwiftTestingSubprocess(process, filter: filter)
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in additions {
        environment[key] = value
    }
    process.environment = environment
    process.standardOutput = output
    process.standardError = output
    return (process, output)
}

private func subprocessOutput(_ pipe: Pipe) -> String {
    String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        ?? "No subprocess output"
}

private func testFailure(_ message: String) -> NSError {
    NSError(domain: "CodexSwitch.KeychainStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

@Suite("KeychainStore")
struct KeychainStoreTests {
    // Use unique service names per test to avoid polluting real Keychain
    private func isolatedStore() -> KeychainStore {
        KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: makeStorePath()
        )
    }

    @Test("Store and retrieve account credentials")
    func storeAndRetrieve() throws {
        let store = isolatedStore()
        let account = CodexAccount(
            email: "test@example.com",
            accessToken: "access_123",
            refreshToken: "refresh_456",
            idToken: "id_789",
            accountId: "acc-test",
            isActive: true
        )
        try store.saveAll([])
        try store.save(account)
        let loaded = try store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].email == "test@example.com")
        #expect(loaded[0].accessToken == "access_123")
        #expect(loaded[0].accountId == "acc-test")
    }

    @Test("Update existing account")
    func updateAccount() throws {
        let store = isolatedStore()
        var account = CodexAccount(
            email: "test@example.com",
            accessToken: "old_token",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "acc-1",
            isActive: true
        )
        try store.saveAll([])
        try store.save(account)
        account.accessToken = "new_token"
        try store.save(account)
        let loaded = try store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].accessToken == "new_token")
    }

    @Test("Delete account")
    func deleteAccount() throws {
        let path = makeStorePath()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(data: Data(), delete: {}))
        )
        let account = CodexAccount(
            email: "test@example.com",
            accessToken: "t",
            refreshToken: "r",
            idToken: "i",
            accountId: "acc-del",
            isActive: true
        )
        try store.saveAll([account])
        try store.delete(account.id)
        #expect(fileIsMissing(at: path))
    }

    @Test("Import from auth.json format")
    func importFromAuthJson() throws {
        let json = """
        {
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": null,
            "tokens": {
                "id_token": "idt_abc",
                "access_token": "act_def",
                "refresh_token": "rft_ghi",
                "account_id": "df3c3241-56e1-4dfb-b6aa-dd0f6e3286a1"
            },
            "last_refresh": "2026-03-12T08:44:18.860111Z"
        }
        """
        let account = try AccountImporter.accountFromAuthJSON(json.data(using: .utf8)!)
        #expect(account.accessToken == "act_def")
        #expect(account.accountId == "df3c3241-56e1-4dfb-b6aa-dd0f6e3286a1")
        #expect(account.email.contains("@")) // Extracted from JWT or fallback
    }

    @Test("Load accounts tolerates ISO date strings")
    func loadAccountsToleratesISODateStrings() throws {
        let path = makeStorePath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)
        let json = """
        [
          {
            "id": "6632BCE7-FD12-4A87-A074-A5E3767C51CC",
            "email": "bd7349@me.com",
            "accessToken": "access",
            "refreshToken": "refresh",
            "idToken": "id-token",
            "accountId": "6632bce7-fd12-4a87-a074-a5e3767c51cc",
            "lastRefreshed": "2026-06-01T02:38:38Z",
            "isActive": true
          }
        ]
        """
        try secureWrite(json.data(using: .utf8)!, to: path)

        let loaded = try store.loadAll()

        #expect(loaded.count == 1)
        #expect(loaded[0].email == "bd7349@me.com")
        #expect(loaded[0].lastRefreshed != nil)
        #expect(loaded[0].isActive)
    }

    @Test("Load accounts treats numeric date values as Apple reference seconds")
    func loadAccountsTreatsNumericDatesAsAppleReferenceSeconds() throws {
        let path = makeStorePath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)
        let referenceSeconds = 802_157_341.0
        let json = """
        [
          {
            "id": "6632BCE7-FD12-4A87-A074-A5E3767C51CC",
            "email": "reference@example.com",
            "accessToken": "access",
            "refreshToken": "refresh",
            "idToken": "id-token",
            "accountId": "reference-account",
            "lastRefreshed": \(referenceSeconds),
            "isActive": true
          }
        ]
        """
        try secureWrite(json.data(using: .utf8)!, to: path)

        let loaded = try store.loadAll()

        #expect(loaded[0].lastRefreshed == Date(timeIntervalSinceReferenceDate: referenceSeconds))
    }

    @Test("Load accounts treats numeric date strings as Unix epoch seconds")
    func loadAccountsTreatsNumericDateStringsAsUnixSeconds() throws {
        let path = makeStorePath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)
        let unixSeconds = 1_767_225_600.0
        let json = """
        [
          {
            "id": "6632BCE7-FD12-4A87-A074-A5E3767C51CC",
            "email": "unix@example.com",
            "accessToken": "access",
            "refreshToken": "refresh",
            "idToken": "id-token",
            "accountId": "unix-account",
            "lastRefreshed": "\(unixSeconds)",
            "isActive": true
          }
        ]
        """
        try secureWrite(json.data(using: .utf8)!, to: path)

        let loaded = try store.loadAll()
        let decoded = try #require(loaded[0].lastRefreshed)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        #expect(decoded == Date(timeIntervalSince1970: unixSeconds))
        #expect(calendar.component(.year, from: decoded) == 2026)
    }

    @Test("Load accounts removes placeholder quota snapshots")
    func loadAccountsRemovesPlaceholderQuotaSnapshots() throws {
        let store = isolatedStore()
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 802_157_341)
        let account = CodexAccount(
            email: "brenchat7795@gmail.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id-token",
            accountId: "acc-brenchat",
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
            planType: "pro",
            lastRefreshed: fetchedAt,
            isActive: true
        )
        try store.saveAll([account])

        let loaded = try store.loadAll()

        #expect(loaded.count == 1)
        #expect(loaded[0].quotaSnapshot == nil)
        #expect(loaded[0].lastRefreshed == nil)
        #expect(loaded[0].planType == "pro")
        #expect(loaded[0].isActive)
    }

    @Test("Save accounts removes placeholder quota snapshots before writing")
    func saveAccountsRemovesPlaceholderQuotaSnapshotsBeforeWriting() throws {
        let path = makeStorePath()
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 802_157_341)
        let account = CodexAccount(
            email: "placeholder@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id-token",
            accountId: "acc-placeholder",
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
            planType: "pro",
            lastRefreshed: fetchedAt,
            isActive: true
        )

        try store.saveAll([account])

        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))
        ) as? [[String: Any]]
        #expect(raw?.first?["quotaSnapshot"] == nil)
        #expect(raw?.first?["lastRefreshed"] == nil)
    }

    @Test("Weekly-only quota snapshots survive persistence and sanitization exactly")
    func weeklyOnlyQuotaSnapshotSurvivesPersistence() throws {
        let path = makeStorePath()
        let fetchedAt = Date(timeIntervalSince1970: 1_767_225_600)
        let weekly = QuotaWindow(
            kind: .weekly,
            durationSeconds: 7 * 24 * 60 * 60,
            usedPercent: 37.5,
            resetsAt: fetchedAt.addingTimeInterval(3 * 24 * 60 * 60),
            source: QuotaWindowSourceMetadata(
                rateLimit: .additional,
                slot: .secondary,
                limitName: "codex_weekly",
                meteredFeature: "codex"
            )
        )
        let snapshot = QuotaSnapshot(
            allowed: true,
            limitReached: false,
            fetchedAt: fetchedAt,
            windows: [weekly]
        )
        let account = CodexAccount(
            email: "weekly-only@example.com",
            accessToken: "weekly-access",
            refreshToken: "weekly-refresh",
            idToken: "weekly-id",
            accountId: "weekly-only",
            quotaSnapshot: snapshot,
            isActive: true
        )
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)

        try store.saveAll([account])

        let accounts = try store.loadAll()
        let loaded = try #require(accounts.first?.quotaSnapshot)
        #expect(loaded == snapshot)
        #expect(loaded.windows == [weekly])
        #expect(loaded.weekly == weekly)
        #expect(loaded.fiveHour == nil)
    }

    @Test("Save uses the Rust lock path and secure permissions")
    func saveUsesRustLockPathAndSecurePermissions() throws {
        let path = makeStorePath()
        let directory = (path as NSString).deletingLastPathComponent
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)
        let account = CodexAccount(
            email: "active@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id-token",
            accountId: "active-account",
            isActive: true
        )

        try store.saveAll([account])

        let lockPath = (directory as NSString).appendingPathComponent("accounts.json.lock")
        #expect(FileManager.default.fileExists(atPath: lockPath))
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? Int
        let storeMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        let lockMode = try FileManager.default.attributesOfItem(atPath: lockPath)[.posixPermissions] as? Int
        #expect(directoryMode == 0o700)
        #expect(storeMode == 0o600)
        #expect(lockMode == 0o600)
    }

    @Test("Hostile umask cannot make the committed store unreadable")
    func hostileUmaskStillCommitsModeSixHundred() throws {
        if ProcessInfo.processInfo.environment["CODEXSWITCH_HOSTILE_UMASK_CHILD"] == "1" {
            try verifyHostileUmaskInChildProcess()
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            "umask 0777; exec \"$1\" --filter hostileUmaskStillCommitsModeSixHundred",
            "codexswitch-umask-test",
            CommandLine.arguments[0],
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEXSWITCH_HOSTILE_UMASK_CHILD"] = "1"
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let message = String(data: output, encoding: .utf8) ?? "No subprocess output"
            Issue.record("Hostile-umask subprocess failed: \(message)")
            return
        }
    }

    private func verifyHostileUmaskInChildProcess() throws {
        let inheritedMask = Darwin.umask(0o777)
        _ = Darwin.umask(inheritedMask)
        #expect(inheritedMask == 0o777)

        let path = makeStorePath()
        let directory = (path as NSString).deletingLastPathComponent
        #expect(fileIsMissing(at: directory))
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)

        try store.saveAll([activeAccount(accountId: "hostile-umask")])

        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? Int
        let storeMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(directoryMode == 0o700)
        #expect(storeMode == 0o600)
        #expect(try store.loadAll().map(\.accountId) == ["hostile-umask"])
    }

    @Test("Save rejects duplicate accountId identities")
    func saveRejectsDuplicateAccountIds() throws {
        let store = isolatedStore()
        let first = CodexAccount(
            email: "first@example.com",
            accessToken: "access-1",
            refreshToken: "refresh-1",
            idToken: "id-1",
            accountId: "duplicate-account",
            isActive: true
        )
        let duplicate = CodexAccount(
            email: "second@example.com",
            accessToken: "access-2",
            refreshToken: "refresh-2",
            idToken: "id-2",
            accountId: "duplicate-account"
        )

        #expect(throws: KeychainError.duplicateAccountId("duplicate-account")) {
            try store.saveAll([first, duplicate])
        }
    }

    @Test("Save rejects duplicate local id identities")
    func saveRejectsDuplicateLocalIds() throws {
        let localId = UUID()
        let store = isolatedStore()
        let first = CodexAccount(
            id: localId,
            email: "first@example.com",
            accessToken: "access-1",
            refreshToken: "refresh-1",
            idToken: "id-1",
            accountId: "account-1",
            isActive: true
        )
        let duplicate = CodexAccount(
            id: localId,
            email: "second@example.com",
            accessToken: "access-2",
            refreshToken: "refresh-2",
            idToken: "id-2",
            accountId: "account-2"
        )

        #expect(throws: KeychainError.duplicateLocalId(localId)) {
            try store.saveAll([first, duplicate])
        }
    }

    @Test("Save rejects multiple active accounts")
    func saveRejectsMultipleActiveAccounts() throws {
        let store = isolatedStore()
        let first = CodexAccount(
            email: "first@example.com",
            accessToken: "access-1",
            refreshToken: "refresh-1",
            idToken: "id-1",
            accountId: "account-1",
            isActive: true
        )
        let second = CodexAccount(
            email: "second@example.com",
            accessToken: "access-2",
            refreshToken: "refresh-2",
            idToken: "id-2",
            accountId: "account-2",
            isActive: true
        )

        #expect(throws: KeychainError.invalidActiveAccountCount(2)) {
            try store.saveAll([first, second])
        }
    }

    @Test("Save rejects a nonempty store without an active account")
    func saveRejectsMissingActiveAccount() throws {
        let store = isolatedStore()
        let account = CodexAccount(
            email: "inactive@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id-token",
            accountId: "inactive-account"
        )

        #expect(throws: KeychainError.invalidActiveAccountCount(0)) {
            try store.saveAll([account])
        }
    }

    @Test("Concurrent writers preserve every account")
    func concurrentWritersPreserveEveryAccount() async throws {
        let store = isolatedStore()
        let active = CodexAccount(
            email: "active@example.com",
            accessToken: "active-access",
            refreshToken: "active-refresh",
            idToken: "active-id",
            accountId: "active-account",
            isActive: true
        )
        try store.saveAll([active])

        let writerCount = 16
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<writerCount {
                group.addTask {
                    let account = CodexAccount(
                        email: "writer-\(index)@example.com",
                        accessToken: "access-\(index)",
                        refreshToken: "refresh-\(index)",
                        idToken: "id-\(index)",
                        accountId: "writer-account-\(index)"
                    )
                    try store.save(account)
                }
            }
            try await group.waitForAll()
        }

        let loaded = try store.loadAll()
        #expect(loaded.count == writerCount + 1)
        #expect(loaded.filter(\.isActive).map(\.accountId) == ["active-account"])
        #expect(Set(loaded.map(\.accountId)).count == writerCount + 1)
    }

    @Test("Independent processes serialize on the accounts.json lock")
    func independentProcessesSerializeOnStoreLock() throws {
        let environment = ProcessInfo.processInfo.environment
        if let role = environment["CODEXSWITCH_LOCK_TEST_ROLE"] {
            try runIndependentProcessLockChild(role: role, environment: environment)
            return
        }

        let path = makeStorePath()
        let directory = (path as NSString).deletingLastPathComponent
        let readyPath = (directory as NSString).appendingPathComponent("holder-ready")
        let releasePath = (directory as NSString).appendingPathComponent("holder-release")
        let writerStartedPath = (directory as NSString).appendingPathComponent("writer-started")
        let writerEnteredPath = (directory as NSString).appendingPathComponent("writer-entered")
        let writerDonePath = (directory as NSString).appendingPathComponent("writer-done")
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)
        try store.saveAll([activeAccount(accountId: "process-active")])

        let commonEnvironment = [
            "CODEXSWITCH_LOCK_TEST_STORE": path,
            "CODEXSWITCH_LOCK_TEST_READY": readyPath,
            "CODEXSWITCH_LOCK_TEST_RELEASE": releasePath,
            "CODEXSWITCH_LOCK_TEST_WRITER_STARTED": writerStartedPath,
            "CODEXSWITCH_LOCK_TEST_WRITER_ENTERED": writerEnteredPath,
            "CODEXSWITCH_LOCK_TEST_WRITER_DONE": writerDonePath,
        ]
        var holderEnvironment = commonEnvironment
        holderEnvironment["CODEXSWITCH_LOCK_TEST_ROLE"] = "holder"
        var writerEnvironment = commonEnvironment
        writerEnvironment["CODEXSWITCH_LOCK_TEST_ROLE"] = "writer"
        let holder = try makeTestSubprocess(
            filter: "independentProcessesSerializeOnStoreLock",
            environment: holderEnvironment
        )
        let writer = try makeTestSubprocess(
            filter: "independentProcessesSerializeOnStoreLock",
            environment: writerEnvironment
        )

        try holder.process.run()
        defer {
            try? secureWrite(Data(), to: releasePath)
            terminateIfRunning(holder.process)
            terminateIfRunning(writer.process)
        }
        guard waitForPath(readyPath, timeout: 5) else {
            terminateIfRunning(holder.process)
            Issue.record(
                "Lock holder did not reach its locked checkpoint: \(subprocessOutput(holder.output))"
            )
            return
        }
        let lockPath = (directory as NSString).appendingPathComponent("accounts.json.lock")
        #expect(try lockIsHeldByAnotherProcess(at: lockPath))

        try writer.process.run()
        guard waitForPath(writerStartedPath, timeout: 5) else {
            Issue.record("Independent writer did not start")
            return
        }
        Thread.sleep(forTimeInterval: 0.5)
        #expect(fileIsMissing(at: writerEnteredPath))
        #expect(fileIsMissing(at: writerDonePath))

        try secureWrite(Data(), to: releasePath)
        guard waitForProcessExit(holder.process, timeout: 5) else {
            Issue.record("Lock holder did not exit within five seconds")
            return
        }
        guard waitForProcessExit(writer.process, timeout: 5) else {
            Issue.record("Independent writer did not exit within five seconds")
            return
        }

        let holderOutput = subprocessOutput(holder.output)
        let writerOutput = subprocessOutput(writer.output)
        guard holder.process.terminationReason == .exit, holder.process.terminationStatus == 0 else {
            Issue.record("Lock holder failed: \(holderOutput)")
            return
        }
        guard writer.process.terminationReason == .exit, writer.process.terminationStatus == 0 else {
            Issue.record("Independent writer failed: \(writerOutput)")
            return
        }

        #expect(FileManager.default.fileExists(atPath: writerEnteredPath))
        #expect(FileManager.default.fileExists(atPath: writerDonePath))
        let loaded = try store.loadAll()
        #expect(Set(loaded.map(\.accountId)) == ["process-active", "process-holder", "process-writer"])
        #expect(loaded.filter(\.isActive).map(\.accountId) == ["process-active"])
    }

    private func runIndependentProcessLockChild(
        role: String,
        environment: [String: String]
    ) throws {
        guard let path = environment["CODEXSWITCH_LOCK_TEST_STORE"],
              let readyPath = environment["CODEXSWITCH_LOCK_TEST_READY"],
              let releasePath = environment["CODEXSWITCH_LOCK_TEST_RELEASE"],
              let writerStartedPath = environment["CODEXSWITCH_LOCK_TEST_WRITER_STARTED"],
              let writerEnteredPath = environment["CODEXSWITCH_LOCK_TEST_WRITER_ENTERED"],
              let writerDonePath = environment["CODEXSWITCH_LOCK_TEST_WRITER_DONE"] else {
            throw testFailure("Independent-process lock test environment is incomplete")
        }

        switch role {
        case "holder":
            let store = KeychainStore(
                service: "CodexSwitch-Test-\(UUID().uuidString)",
                storePath: path,
                testHooks: .init(beforeGenerationCheck: {
                    try secureWrite(Data(), to: readyPath)
                    guard waitForPath(releasePath, timeout: 5) else {
                        throw testFailure("Timed out waiting to release the held account-store lock")
                    }
                })
            )
            try store.save(CodexAccount(
                email: "process-holder@example.com",
                accessToken: "process-holder-access",
                refreshToken: "process-holder-refresh",
                idToken: "process-holder-id",
                accountId: "process-holder"
            ))
        case "writer":
            try secureWrite(Data(), to: writerStartedPath)
            let store = KeychainStore(
                service: "CodexSwitch-Test-\(UUID().uuidString)",
                storePath: path,
                testHooks: .init(beforeGenerationCheck: {
                    try secureWrite(Data(), to: writerEnteredPath)
                })
            )
            try store.save(CodexAccount(
                email: "process-writer@example.com",
                accessToken: "process-writer-access",
                refreshToken: "process-writer-refresh",
                idToken: "process-writer-id",
                accountId: "process-writer"
            ))
            try secureWrite(Data(), to: writerDonePath)
        default:
            throw testFailure("Unknown independent-process lock role: \(role)")
        }
    }

    @Test("Lock open rejects a symlink")
    func lockSymlinkIsRejected() throws {
        let path = makeStorePath()
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let outside = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("CodexSwitchTests-lock-target-\(UUID().uuidString)")
        let sentinel = Data("lock-target-sentinel".utf8)
        try secureWrite(sentinel, to: outside)
        let lockPath = (directory as NSString).appendingPathComponent("accounts.json.lock")
        guard symlink(outside, lockPath) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)

        do {
            try store.saveAll([activeAccount(accountId: "lock-symlink")])
            Issue.record("Expected the lock symlink to be rejected")
        } catch let error as KeychainError {
            guard case .lockFailed(_, "open", _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(try Data(contentsOf: URL(fileURLWithPath: outside)) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("Store reads reject a symlink without replacing its target")
    func storeSymlinkIsRejected() throws {
        let path = makeStorePath()
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let outside = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("CodexSwitchTests-store-target-\(UUID().uuidString)")
        let sentinel = Data("store-target-sentinel".utf8)
        try secureWrite(sentinel, to: outside)
        guard symlink(outside, path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)

        do {
            try store.saveAll([activeAccount(accountId: "store-symlink")])
            Issue.record("Expected the store symlink to be rejected")
        } catch let error as KeychainError {
            guard case .fileOperationFailed(_, "open store", _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(try Data(contentsOf: URL(fileURLWithPath: outside)) == sentinel)
    }

    @Test("Store parent rejects symlink traversal")
    func storeParentSymlinkIsRejected() throws {
        let actualDirectory = (resolvedTemporaryDirectory() as NSString)
            .appendingPathComponent("CodexSwitchTests-parent-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: actualDirectory, withIntermediateDirectories: true)
        let linkedDirectory = (resolvedTemporaryDirectory() as NSString)
            .appendingPathComponent("CodexSwitchTests-parent-link-\(UUID().uuidString)")
        guard symlink(actualDirectory, linkedDirectory) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let path = (linkedDirectory as NSString).appendingPathComponent("accounts.json")
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)

        do {
            try store.saveAll([activeAccount(accountId: "parent-symlink")])
            Issue.record("Expected the parent symlink to be rejected")
        } catch let error as KeychainError {
            guard case .unsafePath = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(!FileManager.default.fileExists(
            atPath: (actualDirectory as NSString).appendingPathComponent("accounts.json")
        ))
    }

    @Test("Root-owned sticky temporary ancestors are accepted")
    func rootOwnedStickyTemporaryAncestorIsAccepted() throws {
        let directory = "/private/tmp/CodexSwitchTests-sticky-\(UUID().uuidString)"
        let path = (directory as NSString).appendingPathComponent("accounts.json")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)

        try store.saveAll([activeAccount(accountId: "sticky-temp")])

        #expect(try store.loadAll().map(\.accountId) == ["sticky-temp"])
    }

    @Test("A writable traversed ancestor is rejected")
    func writableTraversedAncestorIsRejected() throws {
        let unsafeAncestor = (resolvedTemporaryDirectory() as NSString)
            .appendingPathComponent("CodexSwitchTests-unsafe-ancestor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: unsafeAncestor, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: unsafeAncestor) }
        guard chmod(unsafeAncestor, mode_t(0o777)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let storeDirectory = (unsafeAncestor as NSString).appendingPathComponent("store")
        let path = (storeDirectory as NSString).appendingPathComponent("accounts.json")
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)

        do {
            try store.saveAll([activeAccount(accountId: "unsafe-ancestor")])
            Issue.record("Expected the writable traversed ancestor to be rejected")
        } catch let error as KeychainError {
            guard case .unsafePath(let rejectedPath, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(rejectedPath == unsafeAncestor)
        }

        #expect(fileIsMissing(at: storeDirectory))
    }

    @Test("Commit rejects byte tampering after its initial snapshot")
    func staleGenerationTamperingIsRejected() throws {
        let path = makeStorePath()
        let initialStore = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path
        )
        let account = activeAccount(accountId: "stale-generation")
        try initialStore.saveAll([account])
        var tamperedBytes = try Data(contentsOf: URL(fileURLWithPath: path))
        tamperedBytes.append(contentsOf: Data("\n".utf8))
        let tampered = tamperedBytes

        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(beforeGenerationCheck: {
                try secureWrite(tampered, to: path)
            })
        )

        do {
            try store.saveAll([account])
            Issue.record("Expected stale generation rejection")
        } catch let error as KeychainError {
            guard case .staleGeneration = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == tampered)
    }

    @Test("Commit readback proves exact bytes and generation")
    func commitReadbackRejectsPostRenameTampering() throws {
        let path = makeStorePath()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(beforeReadback: {
                var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                bytes.append(contentsOf: Data("\n".utf8))
                try secureWrite(bytes, to: path)
            })
        )

        do {
            try store.saveAll([activeAccount(accountId: "readback-tamper")])
            Issue.record("Expected readback proof to reject tampering")
        } catch let error as KeychainError {
            guard case .readbackMismatch = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test("Legacy Keychain status failures propagate during migration")
    func legacyReadStatusFailureIsNotCredentialAbsence() throws {
        let path = makeStorePath()
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                read: { .failure(errSecInteractionNotAllowed) },
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                }
            ))
        )

        do {
            _ = try store.loadAll()
            Issue.record("Expected the legacy Keychain status failure to propagate")
        } catch let error as KeychainError {
            #expect(error == .loadFailed(errSecInteractionNotAllowed))
        }

        #expect(fileIsMissing(at: path))
        #expect(deletionRecorder.count == 0)
    }

    @Test("Legacy Keychain non-data success propagates during explicit delete")
    func legacyReadInvalidTypeIsNotCredentialAbsence() throws {
        let path = makeStorePath()
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                read: { .invalidType },
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                }
            ))
        )

        do {
            try store.delete(UUID())
            Issue.record("Expected the non-data legacy result to propagate")
        } catch let error as KeychainError {
            #expect(error == .invalidLegacyCredentialResult)
        }

        #expect(fileIsMissing(at: path))
        #expect(deletionRecorder.count == 0)
    }

    @Test("Malformed legacy credential data is not treated as missing")
    func malformedLegacyCredentialDataIsNotMissing() throws {
        let path = makeStorePath()
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                data: Data("not-json".utf8),
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                }
            ))
        )

        do {
            _ = try store.loadAll()
            Issue.record("Expected malformed legacy credentials to fail decoding")
        } catch is DecodingError {
            // Expected: corrupt credential data is distinct from absence.
        }

        #expect(fileIsMissing(at: path))
        #expect(deletionRecorder.count == 0)
    }

    @Test("Legacy item-not-found is represented as missing")
    func legacyItemNotFoundIsCredentialAbsence() throws {
        let path = makeStorePath()
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                read: { .missing },
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                }
            ))
        )

        #expect(try store.loadAll().isEmpty)
        #expect(fileIsMissing(at: path))
        #expect(deletionRecorder.count == 0)
    }

    @Test("Failed migration readback preserves legacy credentials")
    func failedMigrationReadbackDoesNotDeleteLegacyCredentials() throws {
        let path = makeStorePath()
        let account = activeAccount(accountId: "legacy-readback-failure")
        let legacyData = try JSONEncoder().encode([account])
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(
                beforeReadback: {
                    var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                    bytes.append(contentsOf: Data("\n".utf8))
                    try secureWrite(bytes, to: path)
                },
                legacyCredentials: .init(
                    data: legacyData,
                    delete: {
                        deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                    }
                )
            )
        )

        do {
            _ = try store.loadAll()
            Issue.record("Expected migration readback proof to fail")
        } catch let error as KeychainError {
            guard case .readbackMismatch = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(deletionRecorder.count == 0)
    }

    @Test("Migration cleanup failure reports error and leaves the committed file authoritative")
    func migrationCleanupFailureLeavesCommittedFileAuthoritative() throws {
        let path = makeStorePath()
        let account = activeAccount(accountId: "legacy-cleanup-failure")
        let legacyData = try JSONEncoder().encode([account])
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                data: legacyData,
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                    throw KeychainError.deleteFailed(errSecInteractionNotAllowed)
                }
            ))
        )

        do {
            _ = try store.loadAll()
            Issue.record("Expected migration cleanup failure to propagate")
        } catch let error as KeychainError {
            #expect(error == .deleteFailed(errSecInteractionNotAllowed))
        }

        #expect(deletionRecorder.observations == [false])
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try store.loadAll().map(\.accountId) == ["legacy-cleanup-failure"])
        #expect(deletionRecorder.count == 1)
    }

    @Test("Partial file-backed delete after migration cleanup failure requires cleanup")
    func partialFileDeleteAfterMigrationCleanupFailureRequiresCleanup() throws {
        let path = makeStorePath()
        let active = activeAccount(accountId: "prior-cleanup-partial-active")
        let deleted = CodexAccount(
            email: "prior-cleanup-partial-deleted@example.com",
            accessToken: "deleted-access",
            refreshToken: "deleted-refresh",
            idToken: "deleted-id",
            accountId: "prior-cleanup-partial-deleted"
        )
        let legacyData = try JSONEncoder().encode([active, deleted])
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                data: legacyData,
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                    throw KeychainError.deleteFailed(errSecInteractionNotAllowed)
                }
            ))
        )

        do {
            _ = try store.loadAll()
            Issue.record("Expected initial migration cleanup failure")
        } catch let error as KeychainError {
            #expect(error == .deleteFailed(errSecInteractionNotAllowed))
        }
        do {
            try store.delete(deleted.id)
            Issue.record("Expected partial file delete cleanup failure")
        } catch let error as KeychainError {
            #expect(error == .deleteFailed(errSecInteractionNotAllowed))
        }

        #expect(deletionRecorder.observations == [false, false])
        #expect(try store.loadAll().map(\.accountId) == ["prior-cleanup-partial-active"])
    }

    @Test("Last file-backed delete after migration cleanup failure remains recoverable")
    func lastFileDeleteAfterMigrationCleanupFailureIsRecoverable() throws {
        let path = makeStorePath()
        let account = activeAccount(accountId: "prior-cleanup-last")
        let legacyData = try JSONEncoder().encode([account])
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                data: legacyData,
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                    throw KeychainError.deleteFailed(errSecInteractionNotAllowed)
                }
            ))
        )

        do {
            _ = try store.loadAll()
            Issue.record("Expected initial migration cleanup failure")
        } catch let error as KeychainError {
            #expect(error == .deleteFailed(errSecInteractionNotAllowed))
        }
        do {
            try store.delete(account.id)
            Issue.record("Expected last file delete cleanup failure")
        } catch let error as KeychainError {
            #expect(error == .deleteFailed(errSecInteractionNotAllowed))
        }

        #expect(fileIsMissing(at: path))
        #expect(deletionRecorder.observations == [false, true])
        let recoveryStore = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(data: legacyData, delete: {}))
        )
        #expect(try recoveryStore.loadAll().map(\.accountId) == ["prior-cleanup-last"])
    }

    @Test("File-backed deleteAll after migration cleanup failure remains recoverable")
    func fileDeleteAllAfterMigrationCleanupFailureIsRecoverable() throws {
        let path = makeStorePath()
        let account = activeAccount(accountId: "prior-cleanup-delete-all")
        let legacyData = try JSONEncoder().encode([account])
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                data: legacyData,
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                    throw KeychainError.deleteFailed(errSecInteractionNotAllowed)
                }
            ))
        )

        do {
            _ = try store.loadAll()
            Issue.record("Expected initial migration cleanup failure")
        } catch let error as KeychainError {
            #expect(error == .deleteFailed(errSecInteractionNotAllowed))
        }
        do {
            try store.deleteAll()
            Issue.record("Expected file-backed deleteAll cleanup failure")
        } catch let error as KeychainError {
            #expect(error == .deleteFailed(errSecInteractionNotAllowed))
        }

        #expect(fileIsMissing(at: path))
        #expect(deletionRecorder.observations == [false, true])
    }

    @Test("Successful migration deletes legacy credentials after readback")
    func successfulMigrationDeletesLegacyCredentials() throws {
        let path = makeStorePath()
        let account = activeAccount(accountId: "legacy-migration-success")
        let legacyData = try JSONEncoder().encode([account])
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                data: legacyData,
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                }
            ))
        )

        let loaded = try store.loadAll()

        #expect(loaded.map(\.accountId) == ["legacy-migration-success"])
        #expect(deletionRecorder.count == 1)
        #expect(deletionRecorder.observations == [false])
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Legacy-only last-account delete proves absence without creating a replacement")
    func legacyOnlyLastAccountDeleteDoesNotMigrate() throws {
        let path = makeStorePath()
        let account = activeAccount(accountId: "legacy-only-last-account")
        let legacyData = try JSONEncoder().encode([account])
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                data: legacyData,
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                }
            ))
        )

        try store.delete(account.id)

        #expect(fileIsMissing(at: path))
        #expect(deletionRecorder.observations == [true])
    }

    @Test("Legacy-only last-account cleanup failure reports failure and remains recoverable")
    func legacyOnlyLastAccountCleanupFailureIsRecoverable() throws {
        let path = makeStorePath()
        let account = activeAccount(accountId: "legacy-only-cleanup-failure")
        let legacyData = try JSONEncoder().encode([account])
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                data: legacyData,
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                    throw KeychainError.deleteFailed(errSecInteractionNotAllowed)
                }
            ))
        )

        do {
            try store.delete(account.id)
            Issue.record("Expected legacy-only cleanup failure to propagate")
        } catch let error as KeychainError {
            #expect(error == .deleteFailed(errSecInteractionNotAllowed))
        }

        #expect(fileIsMissing(at: path))
        #expect(deletionRecorder.observations == [true])

        let recoveryRecorder = LegacyDeletionRecorder()
        let recoveryStore = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                data: legacyData,
                delete: {
                    recoveryRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                }
            ))
        )
        #expect(try recoveryStore.loadAll().map(\.accountId) == ["legacy-only-cleanup-failure"])
        #expect(recoveryRecorder.observations == [false])
    }

    @Test("Legacy-only delete failure before absence proof preserves credentials")
    func legacyOnlyLastAccountDeleteFailurePreservesCredentials() throws {
        let path = makeStorePath()
        let account = activeAccount(accountId: "legacy-only-absence-failure")
        let legacyData = try JSONEncoder().encode([account])
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(
                beforeReadback: {
                    try secureWrite(legacyData, to: path)
                },
                legacyCredentials: .init(
                    data: legacyData,
                    delete: {
                        deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                    }
                )
            )
        )

        do {
            try store.delete(account.id)
            Issue.record("Expected legacy-only absence proof to fail")
        } catch let error as KeychainError {
            guard case .readbackMismatch = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(deletionRecorder.count == 0)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Legacy-only multi-account delete commits remaining accounts before cleanup")
    func legacyOnlyMultiAccountDeleteCommitsBeforeCleanup() throws {
        let path = makeStorePath()
        let active = activeAccount(accountId: "legacy-only-remaining-active")
        let deleted = CodexAccount(
            email: "legacy-only-deleted@example.com",
            accessToken: "access-deleted",
            refreshToken: "refresh-deleted",
            idToken: "id-deleted",
            accountId: "legacy-only-deleted"
        )
        let legacyData = try JSONEncoder().encode([active, deleted])
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                data: legacyData,
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                }
            ))
        )

        try store.delete(deleted.id)

        let remaining = try store.loadAll()
        #expect(remaining.map(\.accountId) == ["legacy-only-remaining-active"])
        #expect(deletionRecorder.observations == [false])
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Deleting the last account proves absence before deleting legacy credentials")
    func deletingLastAccountDeletesFileThenLegacyCredentials() throws {
        let path = makeStorePath()
        let account = activeAccount(accountId: "explicit-last-account-delete")
        let legacyData = try JSONEncoder().encode([account])
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                data: legacyData,
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                }
            ))
        )
        try store.saveAll([account])

        try store.delete(account.id)

        #expect(fileIsMissing(at: path))
        #expect(deletionRecorder.observations == [true])
    }

    @Test("Explicit deleteAll proves absence before deleting legacy credentials")
    func explicitDeleteAllDeletesFileThenLegacyCredentials() throws {
        let path = makeStorePath()
        let active = activeAccount(accountId: "explicit-delete-all-active")
        let inactive = CodexAccount(
            email: "inactive@example.com",
            accessToken: "access-inactive",
            refreshToken: "refresh-inactive",
            idToken: "id-inactive",
            accountId: "explicit-delete-all-inactive"
        )
        let legacyData = try JSONEncoder().encode([active])
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                data: legacyData,
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                }
            ))
        )
        try store.saveAll([active, inactive])

        try store.deleteAll()

        #expect(fileIsMissing(at: path))
        #expect(deletionRecorder.observations == [true])
    }

    @Test("Legacy-only deleteAll cleanup failure reports failure and remains recoverable")
    func legacyOnlyDeleteAllCleanupFailureIsRecoverable() throws {
        let path = makeStorePath()
        let account = activeAccount(accountId: "legacy-only-delete-all-failure")
        let legacyData = try JSONEncoder().encode([account])
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(
                data: legacyData,
                delete: {
                    deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                    throw KeychainError.deleteFailed(errSecInteractionNotAllowed)
                }
            ))
        )

        do {
            try store.deleteAll()
            Issue.record("Expected deleteAll cleanup failure to propagate")
        } catch let error as KeychainError {
            #expect(error == .deleteFailed(errSecInteractionNotAllowed))
        }

        #expect(fileIsMissing(at: path))
        #expect(deletionRecorder.observations == [true])

        let recoveryStore = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(legacyCredentials: .init(data: legacyData, delete: {}))
        )
        #expect(try recoveryStore.loadAll().map(\.accountId) == ["legacy-only-delete-all-failure"])
    }

    @Test("Commit uses unique temporary names and cleans its temporary file")
    func commitUsesUniqueTemporaryFile() throws {
        let path = makeStorePath()
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let decoyName = ".accounts.json.tmp-\(getpid())-already-present"
        let decoyPath = (directory as NSString).appendingPathComponent(decoyName)
        let sentinel = Data("existing-temporary".utf8)
        try secureWrite(sentinel, to: decoyPath)
        let store = KeychainStore(service: "CodexSwitch-Test-\(UUID().uuidString)", storePath: path)

        try store.saveAll([activeAccount(accountId: "unique-temp")])

        let temporaryNames = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasPrefix(".accounts.json.tmp-") }
        #expect(temporaryNames == [decoyName])
        #expect(try Data(contentsOf: URL(fileURLWithPath: decoyPath)) == sentinel)
    }

    @Test("Deletion readback rejects a recreated store")
    func deletionReadbackRejectsRecreation() throws {
        let path = makeStorePath()
        let initialStore = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path
        )
        try initialStore.saveAll([activeAccount(accountId: "delete-recreation")])
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let deletionRecorder = LegacyDeletionRecorder()
        let store = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: path,
            testHooks: .init(
                beforeReadback: {
                    try secureWrite(original, to: path)
                },
                legacyCredentials: .init(
                    data: original,
                    delete: {
                        deletionRecorder.recordDeletion(fileWasMissing: fileIsMissing(at: path))
                    }
                )
            )
        )

        do {
            try store.deleteAll()
            Issue.record("Expected deletion readback to reject recreation")
        } catch let error as KeychainError {
            guard case .readbackMismatch = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        #expect(deletionRecorder.count == 0)
    }

    @Test("Save rejects missing provider and local identities")
    func saveRejectsMissingIdentities() throws {
        let store = isolatedStore()
        let missingProvider = activeAccount(accountId: "  ")
        let missingLocal = CodexAccount(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            email: "missing-local@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id-token",
            accountId: "missing-local",
            isActive: true
        )

        #expect(throws: KeychainError.missingAccountId) {
            try store.saveAll([missingProvider])
        }
        #expect(throws: KeychainError.missingLocalId) {
            try store.saveAll([missingLocal])
        }
    }

    private func activeAccount(accountId: String) -> CodexAccount {
        CodexAccount(
            email: "\(accountId)@example.com",
            accessToken: "access-\(accountId)",
            refreshToken: "refresh-\(accountId)",
            idToken: "id-\(accountId)",
            accountId: accountId,
            isActive: true
        )
    }
}
