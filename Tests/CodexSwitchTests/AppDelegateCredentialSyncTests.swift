import Foundation
import Testing
@testable import CodexSwitch

@Suite("Linux devbox credential-sync lifecycle")
struct AppDelegateCredentialSyncTests {
    @Test("pending operation survives process replacement without tokens")
    func pendingOperationSurvivesProcessReplacement() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let operation = fixture.operation(reason: "mutation may have started")

        try LinuxDevboxCredentialSyncJournal(path: fixture.journalPath).begin(operation)
        let reloaded = try LinuxDevboxCredentialSyncJournal(path: fixture.journalPath).load()
        let bytes = try Data(contentsOf: URL(fileURLWithPath: fixture.journalPath))
        let serialized = String(decoding: bytes, as: UTF8.self)

        #expect(reloaded == operation)
        #expect(!serialized.contains("access-token"))
        #expect(!serialized.contains("refresh-token"))
        #expect(!serialized.contains("person@example.com"))
    }

    @Test("reconciliation clears only the matching pending operation")
    func reconciliationClearUsesOperationCompareAndDelete() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let operation = fixture.operation()
        let journal = LinuxDevboxCredentialSyncJournal(path: fixture.journalPath)
        try journal.begin(operation)

        do {
            try journal.clear(operationID: UUID().uuidString.lowercased())
            Issue.record("A stale operation identifier cleared the journal")
        } catch let error as LinuxDevboxCredentialSyncJournalError {
            guard case .operationChanged = error else {
                Issue.record("Unexpected journal error: \(error)")
                return
            }
        }
        #expect(try journal.load() == operation)

        let decision = LinuxDevboxMonitor.credentialSyncReconciliation(
            operation: operation,
            remoteStageAbsent: true,
            observed: operation.expected
        )
        #expect(decision == .committed)
        try journal.clear(operationID: operation.operationID)
        #expect(try journal.load() == nil)
    }

    @Test("reconciliation distinguishes committed baseline and ambiguous state")
    func reconciliationIsEvidenceGated() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let operation = fixture.operation()

        #expect(LinuxDevboxMonitor.credentialSyncReconciliation(
            operation: operation,
            remoteStageAbsent: true,
            observed: operation.expected
        ) == .committed)
        #expect(LinuxDevboxMonitor.credentialSyncReconciliation(
            operation: operation,
            remoteStageAbsent: true,
            observed: operation.baseline
        ) == .safeToRetry)

        let unrelated = LinuxDevboxCredentialStateEvidence(
            accountIdentityFingerprint: String(repeating: "9", count: 64),
            credentialSetFingerprint: String(repeating: "8", count: 64),
            activeProviderAccountId: "unrelated",
            activeTokenHashPrefix: "999999999999",
            authMatchesActiveStoreToken: true
        )
        guard case .unresolved = LinuxDevboxMonitor.credentialSyncReconciliation(
            operation: operation,
            remoteStageAbsent: true,
            observed: unrelated
        ) else {
            Issue.record("Unrelated remote state was accepted")
            return
        }
        guard case .unresolved = LinuxDevboxMonitor.credentialSyncReconciliation(
            operation: operation,
            remoteStageAbsent: false,
            observed: operation.expected
        ) else {
            Issue.record("Existing remote staging was accepted")
            return
        }
    }

    @Test("unresolved reason persists and is surfaced")
    func unresolvedReasonPersistsAndIsSurfaced() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let operation = fixture.operation()
        let journal = LinuxDevboxCredentialSyncJournal(path: fixture.journalPath)
        try journal.begin(operation)
        try journal.markUnresolved(
            operationID: operation.operationID,
            reason: "remote staging still exists"
        )

        let held = try #require(try journal.load())
        #expect(held.phase == .unresolved)
        #expect(held.reason == "remote staging still exists")
        #expect(
            AppDelegate.linuxDevboxCredentialSyncHoldSummary(reason: held.reason)
                == "Credential sync paused: remote staging still exists"
        )
    }

    @Test("recovery cleanup accepts only the operation-owned local stage")
    func recoveryCleanupPathIsOperationOwned() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let owned = fixture.operation()
        let foreign = fixture.operation(
            localStageParent: fixture.root.appendingPathComponent("foreign", isDirectory: true)
        )

        #expect(LinuxDevboxMonitor.credentialSyncOwnsLocalStagePath(
            operation: owned,
            temporaryDirectory: fixture.root
        ))
        #expect(!LinuxDevboxMonitor.credentialSyncOwnsLocalStagePath(
            operation: foreign,
            temporaryDirectory: fixture.root
        ))
    }
}

private struct JournalFixture {
    let root: URL
    let journalPath: String

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codexswitch-credential-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        journalPath = root.appendingPathComponent("operation.json").path
    }

    func operation(
        reason: String = "pending fixture",
        localStageParent: URL? = nil
    ) -> LinuxDevboxCredentialSyncOperation {
        let operationID = UUID().uuidString.lowercased()
        let stageParent = localStageParent ?? root
        return LinuxDevboxCredentialSyncOperation(
            operationID: operationID,
            targetFingerprint: String(repeating: "1", count: 64),
            credentialFingerprint: String(repeating: "2", count: 64),
            expectedAccountIdentityFingerprint: String(repeating: "3", count: 64),
            expectedCredentialSetFingerprint: String(repeating: "7", count: 64),
            expectedActiveProviderAccountId: "expected-account",
            expectedActiveTokenHashPrefix: "444444444444",
            baseline: LinuxDevboxCredentialStateEvidence(
                accountIdentityFingerprint: String(repeating: "5", count: 64),
                credentialSetFingerprint: String(repeating: "8", count: 64),
                activeProviderAccountId: "baseline-account",
                activeTokenHashPrefix: "666666666666",
                authMatchesActiveStoreToken: true
            ),
            localDirectory: stageParent
                .appendingPathComponent(
                    "codexswitch-linux-credential-sync-\(operationID)",
                    isDirectory: true
                )
                .path,
            remoteDirectory: "/tmp/codexswitch-auto-sync-\(operationID)",
            createdAt: Date(timeIntervalSince1970: 1_000),
            reason: reason
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
