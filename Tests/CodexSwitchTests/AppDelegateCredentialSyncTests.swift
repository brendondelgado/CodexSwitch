import Foundation
import Testing
@testable import CodexSwitch

@Suite("Linux devbox credential-sync lifecycle")
struct AppDelegateCredentialSyncTests {
    @Test("obsolete recovery callback cannot overwrite newer readiness after replace or removal")
    func staleRecoveryPublicationPreservesNewerReadiness() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let journal = LinuxDevboxCredentialSyncJournal(path: fixture.journalPath)
        let old = fixture.operation()
        try journal.begin(old)
        var publicationCount = 0
        var readiness = "newer-ready"
        try journal.clear(operationID: old.operationID)
        let replacement = fixture.operation()
        try journal.begin(replacement)
        #expect(try !journal.withCurrentRecoveryOperation(operation: old) {
            publicationCount += 1
            readiness = "obsolete-held"
        })
        try journal.clear(operationID: replacement.operationID)
        #expect(try !journal.withCurrentRecoveryOperation(operation: old) {
            publicationCount += 1
            readiness = "obsolete-held"
        })
        #expect(publicationCount == 0)
        #expect(readiness == "newer-ready")
    }

    @Test("recovery publication compares complete receipt-bound operation and fails closed on read error")
    func recoveryPublicationRequiresFullReadableOperation() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let journal = LinuxDevboxCredentialSyncJournal(path: fixture.journalPath)
        let operation = fixture.operation()
        let receipt = fixture.receipt(for: operation)
        try journal.begin(operation)
        try journal.recordImportReceipt(operationID: operation.operationID, receipt: receipt)
        var publicationCount = 0
        #expect(try !journal.withCurrentRecoveryOperation(operation: operation) { publicationCount += 1 })
        #expect(try journal.withCurrentRecoveryOperation(operation: operation, receipt: receipt) { publicationCount += 1 })
        #expect(publicationCount == 1)
        try journal.markUnresolved(operationID: operation.operationID, reason: "newer hold")
        #expect(try !journal.withCurrentRecoveryOperation(operation: operation, receipt: receipt) { publicationCount += 1 })
        #expect(publicationCount == 1)
        try FileManager.default.removeItem(atPath: fixture.journalPath)
        try FileManager.default.createSymbolicLink(atPath: fixture.journalPath, withDestinationPath: "/missing-fixture-journal")
        #expect(throws: (any Error).self) {
            try journal.withCurrentRecoveryOperation(operation: operation, receipt: receipt) { publicationCount += 1 }
        }
        #expect(publicationCount == 1)
    }

    @Test("older CLI capability defers before operation journal and staging")
    func olderCLIIsDeferredBeforeJournalCreation() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let settings = LinuxDevboxMonitorSettings(
            enabled: true, host: "fixture.invalid", user: "fixture",
            sshKeyPath: "/fixture/key", port: 22, resetAuthorityMode: .vpsAuthority
        )
        let account = CodexAccount(
            email: "fixture@example.invalid", accessToken: "fixture-access",
            refreshToken: "fixture-refresh", idToken: "fixture-id",
            accountId: "fixture-provider", isActive: true
        )
        var probed = false
        let result = LinuxDevboxMonitor.makeCredentialSyncOperation(
            settings: settings, accounts: [account], credentialFingerprint: String(repeating: "a", count: 64),
            baseline: fixture.operation().baseline, temporaryDirectory: fixture.root,
            protocolProbe: {
                probed = true
                return LinuxDevboxMonitor.credentialImportProtocolReadiness(
                    terminationStatus: 2, timedOut: false, output: ""
                )
            }
        )
        #expect(probed)
        guard case .failure(let failure) = result else {
            Issue.record("Old CLI produced an operation that could be journaled")
            return
        }
        #expect(failure.credentialSyncDisposition == .rejected)
        #expect(!failure.credentialSyncDisposition.requiresPersistentHold)
        #expect(!failure.credentialSyncDisposition.allowsAutomaticRetry)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    @Test("capability requires both commands and baseline guard without attempting mutation")
    func importProtocolCapabilityIsReadOnlyAndStrict() {
        let complete = "credential-import-status --operation-id --baseline-fingerprint --incoming-fingerprint update-bundle --receipt-operation-id --receipt-baseline-fingerprint"
        guard case .success = LinuxDevboxMonitor.credentialImportProtocolReadiness(
            terminationStatus: 0, timedOut: false, output: complete
        ) else {
            Issue.record("Expected advertised durable protocol")
            return
        }
        for help in ["", complete.replacingOccurrences(of: "--receipt-baseline-fingerprint", with: "")] {
            guard case .failure(let failure) = LinuxDevboxMonitor.credentialImportProtocolReadiness(
                terminationStatus: 0, timedOut: false, output: help
            ) else {
                Issue.record("Incomplete protocol was accepted")
                return
            }
            #expect(!failure.credentialSyncDisposition.requiresPersistentHold)
        }
        guard case .failure(let failure) = LinuxDevboxMonitor.credentialImportProtocolReadiness(
            terminationStatus: 255, timedOut: true, output: complete
        ) else {
            Issue.record("Timeout was treated as supported capability")
            return
        }
        #expect(failure.credentialSyncDisposition == .retryablePreExecution)
        let command = LinuxDevboxMonitor.remoteCredentialImportProtocolCommand()
        #expect(command.contains("credential-import-status --help"))
        #expect(command.contains("update-bundle --help"))
        #expect(!command.contains("--receipt-operation-id"))
        #expect(!command.contains("mkdir"))
        #expect(!command.contains("passphrase"))
    }

    @Test("legacy supersession backs up the exact unresolved journal without claiming completion")
    func legacySupersessionPreservesUnknownOutcome() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let journal = LinuxDevboxCredentialSyncJournal(path: fixture.journalPath)
        let operation = fixture.operation()
        try journal.begin(operation)
        try journal.markUnresolved(operationID: operation.operationID, reason: "legacy lost reply")
        let review = try journal.reviewLegacyUnresolved()
        let original = try Data(contentsOf: URL(fileURLWithPath: fixture.journalPath))
        let now = Date(timeIntervalSince1970: 2_000)
        let evidence = try legacyEvidence(operation: operation, now: now)
        var validations = 0
        let result = try journal.supersedeLegacyUnresolved(
            review: review, confirmation: review.confirmation, temporaryDirectory: fixture.root,
            now: { now }, revalidateRemoteGuard: { validations += 1; return evidence }
        )
        #expect(validations == 2)
        #expect(result.disposition == .supersededUnknownOutcome)
        #expect(result.journalGeneration == review.generation)
        #expect(try Data(contentsOf: URL(fileURLWithPath: result.backupPath)) == original)
        #expect(try journal.load() == nil)
        let backupJournal = LinuxDevboxCredentialSyncJournal(path: result.backupPath)
        let backedUp = try #require(try backupJournal.load())
        #expect(backedUp.phase == .unresolved)
        #expect(backedUp.importReceipt == nil)
        #expect(throws: (any Error).self) {
            try journal.supersedeLegacyUnresolved(
                review: review, confirmation: review.confirmation, temporaryDirectory: fixture.root,
                now: { now }, revalidateRemoteGuard: { evidence }
            )
        }
    }

    @Test("legacy supersession rejects missing approval or changed journal before touching backup")
    func legacySupersessionRequiresExactReviewedGeneration() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let journal = LinuxDevboxCredentialSyncJournal(path: fixture.journalPath)
        let operation = fixture.operation()
        try journal.begin(operation)
        #expect(throws: LinuxDevboxCredentialSyncJournalError.self) { try journal.reviewLegacyUnresolved() }
        try journal.markUnresolved(operationID: operation.operationID, reason: "legacy lost reply")
        let review = try journal.reviewLegacyUnresolved()
        let now = Date(timeIntervalSince1970: 2_000)
        let evidence = try legacyEvidence(operation: operation, now: now)
        var validations = 0
        #expect(throws: LinuxDevboxCredentialSyncJournalError.self) {
            try journal.supersedeLegacyUnresolved(
                review: review, confirmation: "yes", temporaryDirectory: fixture.root,
                now: { now }, revalidateRemoteGuard: { validations += 1; return evidence }
            )
        }
        try journal.markUnresolved(operationID: operation.operationID, reason: "changed after review")
        #expect(throws: LinuxDevboxCredentialSyncJournalError.self) {
            try journal.supersedeLegacyUnresolved(
                review: review, confirmation: review.confirmation, temporaryDirectory: fixture.root,
                now: { now }, revalidateRemoteGuard: { validations += 1; return evidence }
            )
        }
        #expect(validations == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.journalPath + ".legacy-unresolved-backup.json"))
        #expect(try journal.load()?.reason == "changed after review")
        try journal.recordImportReceipt(operationID: operation.operationID, receipt: fixture.receipt(for: operation))
        #expect(throws: LinuxDevboxCredentialSyncJournalError.self) { try journal.reviewLegacyUnresolved() }
    }

    @Test("legacy guard loss after backup preserves both backup and unresolved journal")
    func legacySupersessionGuardDriftFailsClosed() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let journal = LinuxDevboxCredentialSyncJournal(path: fixture.journalPath)
        let operation = fixture.operation()
        try journal.begin(operation)
        try journal.markUnresolved(operationID: operation.operationID, reason: "legacy lost reply")
        let review = try journal.reviewLegacyUnresolved()
        let now = Date(timeIntervalSince1970: 2_000)
        let nonce = UUID()
        let initial = try legacyEvidence(operation: operation, now: now, nonce: nonce)
        let changed = try legacyEvidence(operation: operation, now: now, nonce: nonce, epoch: 8)
        let original = try Data(contentsOf: URL(fileURLWithPath: fixture.journalPath))
        var validations = 0
        #expect(throws: LinuxDevboxCredentialSyncJournalError.self) {
            try journal.supersedeLegacyUnresolved(
                review: review, confirmation: review.confirmation, temporaryDirectory: fixture.root,
                now: { now }, revalidateRemoteGuard: {
                    validations += 1
                    return validations == 1 ? initial : changed
                }
            )
        }
        #expect(validations == 2)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.journalPath)) == original)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.journalPath + ".legacy-unresolved-backup.json")) == original)
    }

    @Test("legacy backup capacity and local staging remnants fail closed")
    func legacySupersessionProtectsBackupAndStage() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let journal = LinuxDevboxCredentialSyncJournal(path: fixture.journalPath)
        let operation = fixture.operation()
        try journal.begin(operation)
        try journal.markUnresolved(operationID: operation.operationID, reason: "legacy lost reply")
        let review = try journal.reviewLegacyUnresolved()
        let now = Date(timeIntervalSince1970: 2_000)
        let evidence = try legacyEvidence(operation: operation, now: now)
        try FileManager.default.createSymbolicLink(atPath: operation.localDirectory, withDestinationPath: "/missing-fixture-stage")
        #expect(throws: LinuxDevboxCredentialSyncJournalError.self) {
            try journal.supersedeLegacyUnresolved(
                review: review, confirmation: review.confirmation, temporaryDirectory: fixture.root,
                now: { now }, revalidateRemoteGuard: { evidence }
            )
        }
        try FileManager.default.removeItem(atPath: operation.localDirectory)
        let backupPath = fixture.journalPath + ".legacy-unresolved-backup.json"
        let backup = SecureAtomicFileTransaction(path: backupPath)
        let foreign = Data("other-reviewed-generation".utf8)
        try backup.withExclusiveLock { file in
            _ = try file.replace(foreign, expectedGeneration: file.read().generation)
        }
        #expect(throws: LinuxDevboxCredentialSyncJournalError.self) {
            try journal.supersedeLegacyUnresolved(
                review: review, confirmation: review.confirmation, temporaryDirectory: fixture.root,
                now: { now }, revalidateRemoteGuard: { evidence }
            )
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == foreign)
        #expect(try journal.load() != nil)
    }

    @Test("legacy eligibility requires fresh stable authority auth and continuous import exclusion")
    func legacySupersessionEligibilityIsStrict() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        var operation = fixture.operation()
        operation.phase = .unresolved
        let now = Date(timeIntervalSince1970: 2_000)
        let valid = try legacyEvidence(operation: operation, now: now)
        #expect(LinuxDevboxMonitor.legacyCredentialSupersessionEligible(operation: operation, evidence: valid, now: now))
        let invalid = [
            try legacyEvidence(operation: operation, now: now.addingTimeInterval(-11)),
            try legacyEvidence(operation: operation, now: now.addingTimeInterval(1)),
            try legacyEvidence(operation: operation, now: now, leaseHeld: false),
            try legacyEvidence(operation: operation, now: now, importerAbsent: false),
            try legacyEvidence(operation: operation, now: now, stageAbsent: false),
            try legacyEvidence(operation: operation, now: now, barrierClear: false),
            try legacyEvidence(operation: operation, now: now, localQuiesced: false),
            try legacyEvidence(operation: operation, now: now, phase: .converging),
            try legacyEvidence(operation: operation, now: now, authMatches: false),
        ]
        for evidence in invalid {
            #expect(!LinuxDevboxMonitor.legacyCredentialSupersessionEligible(operation: operation, evidence: evidence, now: now))
        }
        let newLease = try legacyEvidence(operation: operation, now: now)
        #expect(!LinuxDevboxMonitor.legacySupersessionGuardUnchanged(valid, newLease))
    }

    private func legacyEvidence(
        operation: LinuxDevboxCredentialSyncOperation,
        now: Date,
        nonce: UUID = UUID(),
        epoch: UInt64 = 7,
        leaseHeld: Bool = true,
        importerAbsent: Bool = true,
        stageAbsent: Bool = true,
        barrierClear: Bool = true,
        localQuiesced: Bool = true,
        phase: PoolAuthorityPhase = .stable,
        authMatches: Bool = true
    ) throws -> LinuxDevboxLegacySupersessionEvidence {
        let authority = try PoolAuthorityObservation(
            epoch: epoch, phase: phase, desiredProviderAccountId: "current-authority",
            requestId: "11111111-1111-4111-8111-111111111111", reason: "fixture",
            observedAt: now, updatedAt: now, previousProviderAccountId: nil, detail: nil
        )
        return LinuxDevboxLegacySupersessionEvidence(
            operationID: operation.operationID, targetFingerprint: operation.targetFingerprint,
            observedAt: now, authority: authority,
            credentials: LinuxDevboxCredentialStateEvidence(
                accountIdentityFingerprint: String(repeating: "a", count: 64),
                credentialSetFingerprint: String(repeating: "b", count: 64),
                activeProviderAccountId: "current-authority", activeTokenHashPrefix: "cccccccccccc",
                authMatchesActiveStoreToken: authMatches
            ),
            storeGeneration: String(repeating: "d", count: 64), authGeneration: String(repeating: "e", count: 64),
            runtimeLeaseNonce: nonce, runtimeLeaseHeld: leaseHeld, oldImporterAbsent: importerAbsent,
            remoteStageAbsent: stageAbsent, activationBarrierClear: barrierClear, localSyncQuiesced: localQuiesced
        )
    }

    @Test("lost reply replays history without claiming fresh convergence after rotation")
    func lostReplyRecoversHistoryAfterRotation() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let operation = fixture.operation()
        let receipt = fixture.receipt(for: operation)
        let status = try LinuxDevboxMonitor.decodeCredentialImportStatus(
            output: historicalStatus(receipt: receipt), operation: operation
        ).get()
        #expect(operation.importReceipt == nil)
        #expect(LinuxDevboxMonitor.credentialReceiptRecovery(
            operation: operation, remoteStageAbsent: true, status: status, observed: operation.baseline
        ) == .completed(receipt: receipt, matchesCurrentEvidence: false))
        #expect(LinuxDevboxMonitor.credentialReceiptRecovery(
            operation: operation, remoteStageAbsent: true, status: status, observed: nil
        ) == .completed(receipt: receipt, matchesCurrentEvidence: false))
        #expect(LinuxDevboxMonitor.credentialReceiptRecovery(
            operation: operation, remoteStageAbsent: true, status: status, observed: receipt.committedEvidence
        ) == .completed(receipt: receipt, matchesCurrentEvidence: true))

        let journal = LinuxDevboxCredentialSyncJournal(path: fixture.journalPath)
        try journal.begin(operation)
        try journal.recordImportReceipt(operationID: operation.operationID, receipt: receipt)
        #expect(try journal.load()?.importReceipt == receipt)
        // The legacy exact-convergence API remains conservative until James wires history recovery.
        guard case .unresolved = LinuxDevboxMonitor.credentialSyncReconciliation(
            operation: try #require(try journal.load()), remoteStageAbsent: true, observed: operation.baseline
        ) else {
            Issue.record("Historical completion was treated as current convergence")
            return
        }
    }

    @Test("historical recovery clears only an unchanged fully recorded operation")
    func historicalClearRejectsSameIDMutation() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let operation = fixture.operation()
        let receipt = fixture.receipt(for: operation)
        let journal = LinuxDevboxCredentialSyncJournal(path: fixture.journalPath)
        try journal.begin(operation)
        #expect(throws: LinuxDevboxCredentialSyncJournalError.self) {
            try journal.clearRecoveredImport(operation: operation, receipt: receipt)
        }
        try journal.recordImportReceipt(operationID: operation.operationID, receipt: receipt)
        let before = try Data(contentsOf: URL(fileURLWithPath: fixture.journalPath))
        try journal.recordImportReceipt(operationID: operation.operationID, receipt: receipt)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.journalPath)) == before)
        try journal.markUnresolved(operationID: operation.operationID, reason: "new reviewed hold")
        #expect(throws: LinuxDevboxCredentialSyncJournalError.self) {
            try journal.clearRecoveredImport(operation: operation, receipt: receipt)
        }
        let current = try #require(try journal.load())
        #expect(current.reason == "new reviewed hold")
        try journal.clearRecoveredImport(operation: current, receipt: receipt)
        #expect(try journal.load() == nil)
    }

    @Test("pending missing and legacy receipts cannot fabricate historical completion")
    func missingHistoryDoesNotClearLegacyHold() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let operation = fixture.operation()
        for state in ["pending", "missing"] {
            let output = """
            {"version":1,"operationId":"\(operation.operationID)","status":"\(state)","receipt":null}
            """
            let status = try LinuxDevboxMonitor.decodeCredentialImportStatus(output: output, operation: operation).get()
            guard case .unresolved = LinuxDevboxMonitor.credentialReceiptRecovery(
                operation: operation, remoteStageAbsent: true, status: status, observed: operation.expected
            ) else {
                Issue.record("Missing historical evidence was manufactured from current credentials")
                return
            }
        }
    }

    @Test("unrecoverable receipt-less hold is superseded only when it can no longer execute, then a fresh sync can begin")
    func unrecoverableHoldSupersessionReleasesSync() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let journal = LinuxDevboxCredentialSyncJournal(path: fixture.journalPath)
        try journal.begin(fixture.operation())
        let begun = try #require(try journal.load())
        try journal.markUnresolved(operationID: begun.operationID, reason: "legacy baseline mismatch")
        let held = try #require(try journal.load())
        let old = held.createdAt.addingTimeInterval(25 * 60 * 60)
        func status(_ state: String) throws -> LinuxDevboxCredentialImportStatus {
            try LinuxDevboxMonitor.decodeCredentialImportStatus(output: """
            {"version":1,"operationId":"\(held.operationID)","status":"\(state)","receipt":null}
            """, operation: held).get()
        }
        func recovery(
            _ state: String = "missing", stageAbsent: Bool = true, importerAbsent: Bool = true,
            observed: LinuxDevboxCredentialStateEvidence? = nil, now: Date? = nil
        ) throws -> LinuxDevboxCredentialReceiptRecovery {
            LinuxDevboxMonitor.credentialReceiptRecovery(
                operation: held, remoteStageAbsent: stageAbsent, status: try status(state),
                observed: observed ?? held.expected, remoteImporterAbsent: importerAbsent, now: now ?? old
            )
        }
        // Every missing precondition keeps the hold: young, pending intent, live importer,
        // stage remnant, or no fresh remote observation.
        for blocked in [
            try recovery(now: held.createdAt.addingTimeInterval(60 * 60)),
            try recovery("pending"),
            try recovery(importerAbsent: false),
            try recovery(stageAbsent: false),
            LinuxDevboxMonitor.credentialReceiptRecovery(
                operation: held, remoteStageAbsent: true, status: try status("missing"),
                observed: nil, remoteImporterAbsent: true, now: old
            ),
        ] {
            guard case .unresolved = blocked else {
                Issue.record("Supersession was allowed without every precondition: \(blocked)")
                return
            }
        }
        guard case .supersedable(let proof) = try recovery() else {
            Issue.record("An expired, absent, receipt-less hold stayed blocked forever")
            return
        }
        #expect(proof.remoteEvidence == held.expected)

        // A same-ID journal change after observation fails closed and keeps the hold.
        try journal.markUnresolved(operationID: held.operationID, reason: "newer reviewed hold")
        #expect(throws: LinuxDevboxCredentialSyncJournalError.self) {
            try journal.supersedeUnrecoverable(operation: held, proof: proof)
        }
        let current = try #require(try journal.load())
        #expect(current.reason == "newer reviewed hold")

        let bytes = try Data(contentsOf: URL(fileURLWithPath: fixture.journalPath))
        let backupPath = try journal.supersedeUnrecoverable(operation: current, proof: proof)
        #expect(try journal.load() == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == bytes)
        // The fresh operation re-baselines and journals normally.
        let fresh = fixture.operation()
        try journal.begin(fresh)
        #expect(try journal.load()?.operationID == fresh.operationID)
    }

    @Test("importer absence probe detects the operation's process and stage but never itself")
    func importerAbsenceProbeRunsReadOnly() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let operation = fixture.operation()
        let command = try #require(LinuxDevboxMonitor.remoteCredentialImporterAbsenceCommand(operation: operation))
        // Linux pgrep matches its parent shell, whose argv is this command.
        #expect(!command.contains("codexswitch-auto-sync-\(operation.operationID)"))
        func probe() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try probe() == 0)

        let importer = Process()
        importer.executableURL = URL(fileURLWithPath: "/bin/sh")
        importer.arguments = ["-c", "sleep 30; true", "codexswitch-auto-sync-\(operation.operationID)"]
        try importer.run()
        defer { if importer.isRunning { importer.terminate() } }
        #expect(try probe() == 75)
        importer.terminate()
        importer.waitUntilExit()

        try FileManager.default.createDirectory(atPath: operation.remoteDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: operation.remoteDirectory) }
        #expect(try probe() == 75)
        try FileManager.default.removeItem(atPath: operation.remoteDirectory)
        #expect(try probe() == 0)
    }

    @Test("historical receipt requires absence of staging and exact operation binding")
    func historicalRecoveryRequiresBindingAndStageAbsence() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let operation = fixture.operation()
        let receipt = fixture.receipt(for: operation)
        let status = try LinuxDevboxMonitor.decodeCredentialImportStatus(
            output: historicalStatus(receipt: receipt), operation: operation
        ).get()
        guard case .unresolved = LinuxDevboxMonitor.credentialReceiptRecovery(
            operation: operation, remoteStageAbsent: false, status: status, observed: receipt.committedEvidence
        ) else {
            Issue.record("Staging remnant was ignored")
            return
        }
        let other = fixture.operation()
        guard case .failure = LinuxDevboxMonitor.decodeCredentialImportStatus(
            output: try historicalStatus(receipt: receipt), operation: other
        ) else {
            Issue.record("Another operation accepted the historical receipt")
            return
        }
    }

    @Test("historical status parser rejects unknown fields inconsistent states and bindings")
    func historicalStatusIsStrictAndTokenFree() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let operation = fixture.operation()
        let receipt = fixture.receipt(for: operation)
        let valid = try historicalStatus(receipt: receipt)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any])
        var unknown = parsed
        unknown["accessToken"] = "fixture-secret"
        var pendingReceipt = parsed
        pendingReceipt["status"] = "pending"
        var completedWithoutReceipt = parsed
        completedWithoutReceipt["receipt"] = NSNull()
        var badVersion = parsed
        badVersion["version"] = true
        var wrongBaseline = parsed
        var nested = try #require(parsed["receipt"] as? [String: Any])
        nested["baselineCredentialSetFingerprint"] = String(repeating: "f", count: 64)
        wrongBaseline["receipt"] = nested
        for object in [unknown, pendingReceipt, completedWithoutReceipt, badVersion, wrongBaseline] {
            let output = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            guard case .failure(let failure) = LinuxDevboxMonitor.decodeCredentialImportStatus(
                output: output, operation: operation
            ) else {
                Issue.record("Invalid historical status was accepted")
                return
            }
            #expect(!failure.message.contains("fixture-secret"))
            #expect(failure.credentialSyncDisposition == .outcomeUnknown)
        }
        let command = LinuxDevboxMonitor.remoteCredentialImportStatusCommand(operation: operation)
        #expect(command.contains("credential-import-status"))
        #expect(command.contains(operation.operationID))
        #expect(command.contains(operation.baselineCredentialSetFingerprint))
        #expect(command.contains(operation.expectedCredentialSetFingerprint))
        #expect(!command.contains("update-bundle"))
        #expect(!command.contains("passphrase"))
    }

    private func historicalStatus(receipt: LinuxDevboxCredentialImportReceipt) throws -> String {
        let receiptObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt))
        let object: [String: Any] = [
            "version": 1,
            "operationId": receipt.operationId.uuidString.lowercased(),
            "status": "completed",
            "receipt": receiptObject,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

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
