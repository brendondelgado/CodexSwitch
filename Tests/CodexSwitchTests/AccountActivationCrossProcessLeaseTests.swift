import Foundation
import Testing
@testable import CodexSwitch

@Suite("Account activation cross-process lease")
struct AccountActivationCrossProcessLeaseTests {
    @Test("Lease excludes another owner until release")
    func leaseExcludesConcurrentOwner() throws {
        let url = makeSecureTestFileURL(
            prefix: "codexswitch-account-activation-lease",
            fileName: "accounts.runtime-activation.lock"
        )
        let first = try #require(
            try AccountActivationCrossProcessLease.acquire(at: url)
        )
        #expect(try AccountActivationCrossProcessLease.acquire(at: url) == nil)

        first.release()
        let second = try #require(
            try AccountActivationCrossProcessLease.acquire(at: url)
        )
        second.release()
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("Inherited task-local proof expires when the descriptor is released")
    func inheritedProofRequiresLiveDescriptor() async throws {
        let url = makeSecureTestFileURL(
            prefix: "codexswitch-account-activation-inherited-proof",
            fileName: "accounts.runtime-activation.lock"
        )
        let held = try #require(
            try AccountActivationCrossProcessLease.acquire(at: url)
        )
        let gate = AsyncStream.makeStream(of: Void.self)
        let inherited = AccountActivationCrossProcessLeaseContext.$heldLease.withValue(held) {
            Task {
                _ = await nextElement(from: gate.stream)
                return AccountActivationCrossProcessLeaseContext.holds(url)
            }
        }

        held.release()
        gate.continuation.yield()
        #expect(await inherited.value == false)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("Symlink lease is rejected without touching its target")
    func symlinkLeaseIsRejected() throws {
        let url = makeSecureTestFileURL(
            prefix: "codexswitch-account-activation-symlink",
            fileName: "accounts.runtime-activation.lock"
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let target = url.deletingLastPathComponent().appendingPathComponent("target")
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: url.path,
            withDestinationPath: target.path
        )

        #expect(throws: AccountActivationCrossProcessLeaseError.self) {
            try AccountActivationCrossProcessLease.acquire(at: url)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "sentinel")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("Standalone journal transition fails closed behind another lease owner")
    func journalTransitionRespectsCompetingLease() async throws {
        let journalURL = makeSecureTestFileURL(
            prefix: "codexswitch-account-activation-journal-lease",
            fileName: "account-activation.json"
        )
        let leaseURL = journalURL.deletingLastPathComponent()
            .appendingPathComponent("accounts.runtime-activation.lock")
        let coordinator = AccountActivationCoordinator(
            url: journalURL,
            crossProcessLeaseURL: leaseURL
        )
        let held = try #require(
            try AccountActivationCrossProcessLease.acquire(at: leaseURL)
        )

        do {
            _ = try await coordinator.markManualReview(
                targetAccountId: UUID(),
                detail: .externalAuthInvalid
            )
            Issue.record("Expected competing runtime lease to block the journal write")
        } catch let error as AccountActivationCoordinatorError {
            #expect(error == .authorizationRevoked)
        }
        do {
            _ = try await coordinator.beginAuthorizedCredentialMutation(
                targetAccountId: UUID(),
                kind: .manual
            )
            Issue.record("Expected competing runtime lease to block preparation")
        } catch let error as AccountActivationCoordinatorError {
            #expect(error == .authorizationRevoked)
        }
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))

        held.release()
        let persisted = try await coordinator.markManualReview(
            targetAccountId: UUID(),
            detail: .externalAuthInvalid
        )
        #expect(persisted.phase == .manualReview)
        #expect(try await coordinator.load() == persisted)
        try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent())
    }

    @MainActor
    @Test("Enclosing Swift transaction supplies task-local journal lease proof")
    func transactionLeaseProofIsScopedAndExclusive() async throws {
        let journalURL = makeSecureTestFileURL(
            prefix: "codexswitch-account-activation-task-local",
            fileName: "account-activation.json"
        )
        let leaseURL = journalURL.deletingLastPathComponent()
            .appendingPathComponent("accounts.runtime-activation.lock")
        let coordinator = AccountActivationCoordinator(
            url: journalURL,
            crossProcessLeaseURL: leaseURL
        )
        let transaction = AccountActivationTransaction(
            crossProcessLeaseURL: leaseURL
        )
        let target = UUID()
        let generation = UUID()

        let persisted = try await transaction.withActivationLease(
            targetAccountId: target,
            activationGeneration: generation
        ) { _ in
            #expect(AccountActivationCrossProcessLeaseContext.holds(leaseURL))
            #expect(try AccountActivationCrossProcessLease.acquire(at: leaseURL) == nil)
            return try await coordinator.markManualReview(
                targetAccountId: target,
                detail: .prepareFailed
            )
        }

        #expect(persisted?.phase == .manualReview)
        #expect(AccountActivationCrossProcessLeaseContext.heldLease == nil)
        let after = try #require(
            try AccountActivationCrossProcessLease.acquire(at: leaseURL)
        )
        after.release()
        try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent())
    }
}
