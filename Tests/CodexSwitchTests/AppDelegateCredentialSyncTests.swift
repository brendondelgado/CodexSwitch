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
        let receipt = fixture.receipt(for: operation)
        try journal.recordImportReceipt(operationID: operation.operationID, receipt: receipt)
        let recordedOperation = try #require(try journal.load())

        do {
            try journal.clear(operationID: UUID().uuidString.lowercased())
            Issue.record("A stale operation identifier cleared the journal")
        } catch let error as LinuxDevboxCredentialSyncJournalError {
            guard case .operationChanged = error else {
                Issue.record("Unexpected journal error: \(error)")
                return
            }
        }
        #expect(try journal.load() == recordedOperation)

        let decision = LinuxDevboxMonitor.credentialSyncReconciliation(
            operation: recordedOperation,
            remoteStageAbsent: true,
            observed: receipt.committedEvidence
        )
        #expect(decision == .committed)
        try journal.clear(operationID: operation.operationID)
        #expect(try journal.load() == nil)
    }

    @Test("reconciliation distinguishes exact commit baseline and ambiguous state")
    func reconciliationIsEvidenceGated() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let operation = fixture.operation()

        #expect(LinuxDevboxMonitor.credentialSyncReconciliation(
            operation: operation,
            remoteStageAbsent: true,
            observed: operation.baseline
        ) == .safeToRetry)
        #expect(LinuxDevboxMonitor.credentialSyncReconciliation(
            operation: operation,
            remoteStageAbsent: true,
            observed: operation.expected
        ) == .committed)

        var receipted = operation
        receipted.importReceipt = fixture.receipt(for: operation)
        #expect(LinuxDevboxMonitor.credentialSyncReconciliation(
            operation: receipted,
            remoteStageAbsent: true,
            observed: try #require(receipted.importReceipt).committedEvidence
        ) == .committed)

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

    @Test("successful import requires exact stable post-import evidence")
    func successfulImportRequiresPostImportProof() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let operation = fixture.operation()
        let receipt = fixture.receipt(for: operation)

        let confirmed = LinuxDevboxMonitor.verifiedCredentialSyncPostImportResult(
            receipt: receipt,
            operation: operation,
            observed: .success(receipt.committedEvidence)
        )
        guard case .success(let output) = confirmed else {
            Issue.record("Exact post-import evidence was rejected")
            return
        }
        #expect(output == "credentials synchronized with exact import receipt")

        let stale = LinuxDevboxMonitor.verifiedCredentialSyncPostImportResult(
            receipt: receipt,
            operation: operation,
            observed: .success(operation.baseline)
        )
        guard case .failure(let staleFailure) = stale else {
            Issue.record("Stale post-import generation was reported as synchronized")
            return
        }
        #expect(staleFailure.credentialSyncDisposition == .outcomeUnknown)

        let unavailable = LinuxDevboxMonitor.verifiedCredentialSyncPostImportResult(
            receipt: receipt,
            operation: operation,
            observed: .failure(LinuxDevboxMonitorFailure(message: "observation unavailable"))
        )
        guard case .failure(let unavailableFailure) = unavailable else {
            Issue.record("Unproven post-import outcome was reported as synchronized")
            return
        }
        #expect(unavailableFailure.credentialSyncDisposition == .outcomeUnknown)
    }

    @Test("receipt accepts exact merge that preserves a newer inactive VPS generation")
    func receiptAcceptsNewerInactiveVPSGeneration() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let (operation, receipt) = fixture.inactivePreservationScenario()
        let output = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)

        let decoded = try LinuxDevboxMonitor.decodeCredentialImportReceipt(
            output: output,
            operation: operation
        ).get()
        #expect(decoded == receipt)
        #expect(receipt.committedCredentialSetFingerprint
            != operation.expectedCredentialSetFingerprint)
        #expect(receipt.credentialSelections == [
            .init(providerAccountId: "active-account", generation: .matching),
            .init(providerAccountId: "inactive-account", generation: .current),
        ])
        guard case .success = LinuxDevboxMonitor.verifiedCredentialSyncPostImportResult(
            receipt: receipt,
            operation: operation,
            observed: .success(receipt.committedEvidence)
        ) else {
            Issue.record("Exact merged receipt was rejected")
            return
        }
    }

    @Test("import receipt is strict operation-bound and token-free")
    func importReceiptIsStrictOperationBoundAndTokenFree() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let operation = fixture.operation()
        let receipt = fixture.receipt(for: operation)
        let encoded = try JSONEncoder().encode(receipt)
        let output = String(decoding: encoded, as: UTF8.self)

        let decoded = LinuxDevboxMonitor.decodeCredentialImportReceipt(
            output: output,
            operation: operation
        )
        #expect(try decoded.get() == receipt)
        #expect(!output.contains("accessToken"))
        #expect(!output.contains("refreshToken"))
        #expect(!output.contains("idToken"))
        #expect(!output.contains("@"))

        let injected = String(output.dropLast()) + ",\"accessToken\":\"secret\"}"
        guard case .failure(let injectedFailure) = LinuxDevboxMonitor
            .decodeCredentialImportReceipt(output: String(injected), operation: operation) else {
            Issue.record("Receipt with an unknown credential field was accepted")
            return
        }
        #expect(injectedFailure.credentialSyncDisposition == .outcomeUnknown)

        let otherOperation = fixture.operation()
        guard case .failure = LinuxDevboxMonitor.decodeCredentialImportReceipt(
            output: output,
            operation: otherOperation
        ) else {
            Issue.record("Receipt was accepted for a different operation")
            return
        }
    }

    @Test("journal persists a newer VPS generation receipt without credentials")
    func journalPersistsNewerVPSGenerationReceipt() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let operation = fixture.operation()
        let receipt = fixture.receipt(for: operation)
        let journal = LinuxDevboxCredentialSyncJournal(path: fixture.journalPath)
        try journal.begin(operation)
        try journal.recordImportReceipt(operationID: operation.operationID, receipt: receipt)

        let reloaded = try #require(try journal.load())
        let serialized = String(
            decoding: try Data(contentsOf: URL(fileURLWithPath: fixture.journalPath)),
            as: UTF8.self
        )
        #expect(reloaded.importReceipt == receipt)
        #expect(LinuxDevboxMonitor.credentialSyncReconciliation(
            operation: reloaded,
            remoteStageAbsent: true,
            observed: receipt.committedEvidence
        ) == .committed)
        #expect(!serialized.lowercased().contains("access_token"))
        #expect(!serialized.lowercased().contains("refresh_token"))
        #expect(!serialized.contains("@"))
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
        let providerAccountID = "expected-account"
        let identityFingerprint = LinuxDevboxMonitor.credentialAccountIdentityFingerprint(
            providerAccountIDs: [providerAccountID],
            activeProviderAccountId: providerAccountID
        )
        return LinuxDevboxCredentialSyncOperation(
            operationID: operationID,
            targetFingerprint: String(repeating: "1", count: 64),
            credentialFingerprint: String(repeating: "2", count: 64),
            expectedAccountIdentityFingerprint: identityFingerprint,
            expectedCredentialSetFingerprint: String(repeating: "7", count: 64),
            expectedActiveProviderAccountId: "expected-account",
            expectedActiveTokenHashPrefix: "444444444444",
            baseline: LinuxDevboxCredentialStateEvidence(
                accountIdentityFingerprint: identityFingerprint,
                credentialSetFingerprint: String(repeating: "8", count: 64),
                activeProviderAccountId: providerAccountID,
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

    func receipt(
        for operation: LinuxDevboxCredentialSyncOperation
    ) -> LinuxDevboxCredentialImportReceipt {
        LinuxDevboxCredentialImportReceipt(
            version: LinuxDevboxCredentialImportReceipt.schemaVersion,
            operationId: UUID(uuidString: operation.operationID)!,
            accountCount: 1,
            baselineCredentialSetFingerprint: operation.baselineCredentialSetFingerprint,
            incomingCredentialSetFingerprint: operation.expectedCredentialSetFingerprint,
            committedCredentialSetFingerprint: String(repeating: "9", count: 64),
            committedAccountIdentityFingerprint: operation.expectedAccountIdentityFingerprint,
            activeProviderAccountId: operation.expectedActiveProviderAccountId,
            activeTokenHashPrefix: operation.baselineActiveTokenHashPrefix,
            credentialSelections: [
                LinuxDevboxCredentialImportReceipt.Selection(
                    providerAccountId: operation.expectedActiveProviderAccountId,
                    generation: .current
                )
            ]
        )
    }

    func inactivePreservationScenario() -> (
        LinuxDevboxCredentialSyncOperation,
        LinuxDevboxCredentialImportReceipt
    ) {
        let operationID = UUID().uuidString.lowercased()
        let providerAccountIDs = ["active-account", "inactive-account"]
        let identityFingerprint = LinuxDevboxMonitor.credentialAccountIdentityFingerprint(
            providerAccountIDs: providerAccountIDs,
            activeProviderAccountId: "active-account"
        )
        let operation = LinuxDevboxCredentialSyncOperation(
            operationID: operationID,
            targetFingerprint: String(repeating: "1", count: 64),
            credentialFingerprint: String(repeating: "2", count: 64),
            expectedAccountIdentityFingerprint: identityFingerprint,
            expectedCredentialSetFingerprint: String(repeating: "7", count: 64),
            expectedActiveProviderAccountId: "active-account",
            expectedActiveTokenHashPrefix: "444444444444",
            baseline: LinuxDevboxCredentialStateEvidence(
                accountIdentityFingerprint: identityFingerprint,
                credentialSetFingerprint: String(repeating: "8", count: 64),
                activeProviderAccountId: "active-account",
                activeTokenHashPrefix: "444444444444",
                authMatchesActiveStoreToken: true
            ),
            localDirectory: root
                .appendingPathComponent(
                    "codexswitch-linux-credential-sync-\(operationID)",
                    isDirectory: true
                )
                .path,
            remoteDirectory: "/tmp/codexswitch-auto-sync-\(operationID)",
            createdAt: Date(timeIntervalSince1970: 1_000),
            reason: "pending inactive-generation fixture"
        )
        let receipt = LinuxDevboxCredentialImportReceipt(
            version: LinuxDevboxCredentialImportReceipt.schemaVersion,
            operationId: UUID(uuidString: operationID)!,
            accountCount: providerAccountIDs.count,
            baselineCredentialSetFingerprint: operation.baselineCredentialSetFingerprint,
            incomingCredentialSetFingerprint: operation.expectedCredentialSetFingerprint,
            committedCredentialSetFingerprint: String(repeating: "9", count: 64),
            committedAccountIdentityFingerprint: identityFingerprint,
            activeProviderAccountId: "active-account",
            activeTokenHashPrefix: operation.expectedActiveTokenHashPrefix,
            credentialSelections: [
                .init(providerAccountId: "active-account", generation: .matching),
                .init(providerAccountId: "inactive-account", generation: .current),
            ]
        )
        return (operation, receipt)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
