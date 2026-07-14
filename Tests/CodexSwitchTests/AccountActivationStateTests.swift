import Foundation
import Testing
@testable import CodexSwitch

@Suite("Mac account activation state")
struct AccountActivationStateTests {
    @Test("Zero ACK and no runtime remain degraded across restart")
    func zeroAckSurvivesRestart() async throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = AccountActivationCoordinator(
            url: url,
            baseRetryInterval: 10,
            maximumRetryInterval: 40
        )

        _ = try await coordinator.beginPreparing(targetAccountId: target, kind: .automatic, at: now)
        _ = try await coordinator.markCommittedDegraded(
            targetAccountId: target,
            discoveredRuntimeCount: 0,
            acknowledgedRuntimeCount: 0,
            detail: .runtimeConfirmationPending,
            at: now
        )
        let degraded = try await coordinator.recordConvergenceFailure(
            targetAccountId: target,
            discoveredRuntimeCount: 0,
            acknowledgedRuntimeCount: 0,
            detail: .noLocalRuntime,
            at: now
        )

        #expect(degraded.phase == .committedDegraded)
        #expect(degraded.configuredAccountId == target)
        #expect(degraded.runtimeCurrentAccountId == nil)
        #expect(degraded.blocksAutomaticMutations)
        #expect(degraded.automaticRetryTarget(at: now.addingTimeInterval(9)) == nil)
        #expect(degraded.automaticRetryTarget(at: now.addingTimeInterval(10)) == target)

        let restarted = AccountActivationCoordinator(
            url: url,
            baseRetryInterval: 10,
            maximumRetryInterval: 40
        )
        #expect(try await restarted.load() == degraded)
    }

    @Test("Partial ACK keeps the committed target behind the barrier")
    func partialAckRemainsDegraded() async throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let coordinator = AccountActivationCoordinator(url: url)

        _ = try await coordinator.beginPreparing(targetAccountId: target, kind: .automatic, at: now)
        _ = try await coordinator.markCommittedDegraded(
            targetAccountId: target,
            discoveredRuntimeCount: 0,
            acknowledgedRuntimeCount: 0,
            detail: .runtimeConfirmationPending,
            at: now
        )
        let partial = try await coordinator.recordConvergenceFailure(
            targetAccountId: target,
            discoveredRuntimeCount: 2,
            acknowledgedRuntimeCount: 1,
            detail: .runtimeAcknowledgementIncomplete,
            at: now.addingTimeInterval(1)
        )

        #expect(partial.phase == .committedDegraded)
        #expect(partial.discoveredRuntimeCount == 2)
        #expect(partial.acknowledgedRuntimeCount == 1)
        #expect(partial.runtimeCurrentAccountId == nil)
        #expect(partial.retryAttempt == 1)
    }

    @Test("A missing journal bootstraps a durable configured-only barrier")
    func missingJournalBootstrapsBarrier() async throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_150)
        let coordinator = AccountActivationCoordinator(url: url)

        #expect(try await coordinator.load() == nil)
        let bootstrapped = try await coordinator.bootstrapCommittedDegraded(
            targetAccountId: target,
            detail: .launchRuntimeEvidenceExpired,
            at: now
        )

        #expect(bootstrapped.phase == .committedDegraded)
        #expect(bootstrapped.blocksAutomaticMutations)
        #expect(bootstrapped.automaticRetryTarget(at: now) == target)
        #expect(try await AccountActivationCoordinator(url: url).load() == bootstrapped)
    }

    @Test("Barrier blocks automatic and cross-target requests but permits explicit same-target retry")
    func barrierPolicyAllowsOnlySameTargetRetry() async throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = UUID()
        let other = UUID()
        let coordinator = AccountActivationCoordinator(url: url)

        _ = try await coordinator.beginPreparing(targetAccountId: target, kind: .automatic)
        let degraded = try await coordinator.markCommittedDegraded(
            targetAccountId: target,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0,
            detail: .runtimeAcknowledgementIncomplete
        )

        guard case .blocked = degraded.decision(
            forRequestedTarget: target,
            kind: .automatic
        ) else {
            Issue.record("Automatic swaps must remain blocked")
            return
        }
        guard case .blocked = degraded.decision(
            forRequestedTarget: other,
            kind: .manual
        ) else {
            Issue.record("Manual cross-target swaps must remain blocked")
            return
        }
        #expect(degraded.decision(
            forRequestedTarget: target,
            kind: .manual
        ) == .retrySameTarget)

        let automatic = try await coordinator.beginAuthorizedCredentialMutation(
            targetAccountId: target,
            kind: .automatic
        )
        guard case .blocked = automatic else {
            Issue.record("Automatic mutation must not re-enter Preparing")
            return
        }
        let crossTarget = try await coordinator.beginAuthorizedCredentialMutation(
            targetAccountId: other,
            kind: .manual
        )
        guard case .blocked = crossTarget else {
            Issue.record("Manual cross-target mutation must remain blocked")
            return
        }
        #expect(try await coordinator.load() == degraded)
    }

    @Test("Full ACK durably confirms runtime and clears the barrier")
    func confirmationClearsBarrier() async throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = UUID()
        let coordinator = AccountActivationCoordinator(url: url)

        _ = try await coordinator.beginPreparing(targetAccountId: target, kind: .automatic)
        _ = try await coordinator.markCommittedDegraded(
            targetAccountId: target,
            discoveredRuntimeCount: 2,
            acknowledgedRuntimeCount: 1,
            detail: .runtimeAcknowledgementIncomplete
        )
        let confirmed = try await confirm(
            coordinator,
            targetAccountId: target,
            runtimeCount: 2
        )

        #expect(confirmed.phase == .confirmed)
        #expect(!confirmed.blocksAutomaticMutations)
        #expect(confirmed.runtimeIsCurrent(for: target))
        #expect(confirmed.nextRetryAt == nil)
        #expect(try await AccountActivationCoordinator(url: url).load() == confirmed)
    }

    @Test("Confirmed runtime evidence becomes provisional on every launch")
    func confirmedStateDemotesOnLaunch() async throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_300)
        let coordinator = AccountActivationCoordinator(url: url)

        _ = try await coordinator.beginPreparing(targetAccountId: target, kind: .automatic, at: now)
        _ = try await coordinator.markCommittedDegraded(
            targetAccountId: target,
            discoveredRuntimeCount: 0,
            acknowledgedRuntimeCount: 0,
            detail: .runtimeConfirmationPending,
            at: now
        )
        _ = try await confirm(
            coordinator,
            targetAccountId: target,
            runtimeCount: 2,
            at: now
        )
        let provisional = try await coordinator.demoteConfirmedForLaunch(
            targetAccountId: target,
            at: now.addingTimeInterval(1)
        )

        #expect(provisional.phase == .committedDegraded)
        #expect(provisional.detail == .launchRuntimeEvidenceExpired)
        #expect(provisional.runtimeCurrentAccountId == nil)
        #expect(provisional.automaticRetryTarget(at: now.addingTimeInterval(1)) == target)
    }

    @Test("Active credential mutation invalidates confirmed runtime evidence")
    func activeCredentialMutationReturnsToPreparing() async throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = UUID()
        let externalTarget = UUID()
        let coordinator = AccountActivationCoordinator(url: url)

        _ = try await coordinator.beginPreparing(targetAccountId: target, kind: .automatic)
        _ = try await coordinator.markCommittedDegraded(
            targetAccountId: target,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            detail: .runtimeConfirmationPending
        )
        _ = try await confirm(
            coordinator,
            targetAccountId: target,
            runtimeCount: 1
        )

        let preparing = try await coordinator.beginCredentialMutation(
            targetAccountId: externalTarget,
            kind: .automatic
        )
        #expect(preparing.phase == .preparing)
        #expect(preparing.configuredAccountId == externalTarget)
        #expect(preparing.runtimeCurrentAccountId == nil)
        #expect(preparing.blocksAutomaticMutations)
    }

    @Test("Automatic retries stop at the ceiling and manual same-target retry resets them")
    func retryCeilingRequiresManualSameTargetReset() async throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = UUID()
        let other = UUID()
        let coordinator = AccountActivationCoordinator(url: url)

        _ = try await coordinator.beginPreparing(targetAccountId: target, kind: .automatic)
        _ = try await coordinator.markCommittedDegraded(
            targetAccountId: target,
            discoveredRuntimeCount: 0,
            acknowledgedRuntimeCount: 0,
            detail: .runtimeConfirmationPending
        )

        var state = try await coordinator.load()!
        for _ in 0..<AccountActivationCoordinator.maximumAutomaticRetryAttempts {
            state = try await coordinator.recordConvergenceFailure(
                targetAccountId: target,
                discoveredRuntimeCount: 1,
                acknowledgedRuntimeCount: 0,
                detail: .runtimeAcknowledgementIncomplete
            )
        }

        #expect(state.phase == .manualReview)
        #expect(state.detail == .automaticRetryLimitReached)
        #expect(state.automaticRetryTarget(at: .distantFuture) == nil)
        #expect(state.decision(
            forRequestedTarget: target,
            kind: .manual
        ) == .retrySameTarget)
        guard case .blocked = state.decision(
            forRequestedTarget: other,
            kind: .manual
        ) else {
            Issue.record("Retry exhaustion must not authorize another target")
            return
        }

        let reset = try await coordinator.resetForManualSameTargetRetry(
            targetAccountId: target
        )
        #expect(reset.phase == .committedDegraded)
        #expect(reset.retryAttempt == 0)
        #expect(reset.automaticRetryTarget(at: reset.updatedAt) == target)
    }

    @Test("Corrupt journal fails closed without replacing evidence")
    func corruptJournalFailsClosed() async throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = AccountActivationCoordinator(url: url)
        _ = try await coordinator.beginPreparing(targetAccountId: UUID(), kind: .automatic)
        let corrupt = Data("not-json".utf8)
        try overwriteSecureTestFile(corrupt, atPath: url.path)

        do {
            _ = try await coordinator.load()
            Issue.record("Expected corrupt activation journal rejection")
        } catch {
            #expect(error is AccountActivationCoordinatorError)
        }
        #expect(try Data(contentsOf: url) == corrupt)

        let failClosed = AccountActivationState.manualReview(
            targetAccountId: nil,
            detail: .journalUnavailable,
            at: Date()
        )
        #expect(failClosed.blocksAutomaticMutations)
    }

    @Test("Journal is bounded, mode 0600, and has no token fields")
    func journalIsSecureAndTokenFree() async throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = AccountActivationCoordinator(url: url)
        _ = try await coordinator.beginPreparing(targetAccountId: UUID(), kind: .automatic)

        let data = try Data(contentsOf: url)
        let json = try #require(String(data: data, encoding: .utf8)).lowercased()
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        ).intValue

        #expect(data.count <= AccountActivationCoordinator.maximumJournalBytes)
        #expect(mode & 0o777 == 0o600)
        #expect(!json.contains("token"))
        #expect(!json.contains("email"))
        #expect(!json.contains("access"))
        #expect(!json.contains("refresh"))

        var taintedObject = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        taintedObject["accessToken"] = "must-not-be-accepted"
        let tainted = try JSONSerialization.data(withJSONObject: taintedObject)
        try overwriteSecureTestFile(tainted, atPath: url.path)
        do {
            _ = try await coordinator.load()
            Issue.record("Expected unknown credential field rejection")
        } catch {
            #expect(error is AccountActivationCoordinatorError)
        }
        #expect(try Data(contentsOf: url) == tainted)
    }

    @Test("Retry backoff is bounded")
    func retryBackoffIsBounded() {
        #expect(AccountActivationCoordinator.retryDelay(attempt: 1) == 30)
        #expect(AccountActivationCoordinator.retryDelay(attempt: 2) == 60)
        #expect(AccountActivationCoordinator.retryDelay(attempt: 20) == 300)
    }

    @Test("Generic observation failures preserve the monotonic retry count")
    func manualReviewObservationFailureKeepsRetryCount() async throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = UUID()
        let now = Date(timeIntervalSince1970: 1_800_001_000)
        let coordinator = AccountActivationCoordinator(url: url, baseRetryInterval: 1)

        _ = try await coordinator.beginPreparing(
            targetAccountId: target,
            kind: .automatic,
            at: now
        )
        _ = try await coordinator.markCommittedDegraded(
            targetAccountId: target,
            discoveredRuntimeCount: 0,
            acknowledgedRuntimeCount: 0,
            detail: .runtimeConfirmationPending,
            at: now
        )
        let firstFailure = try await coordinator.recordConvergenceFailure(
            targetAccountId: target,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0,
            detail: .runtimeAcknowledgementIncomplete,
            at: now
        )
        let review = try await coordinator.markManualReview(
            targetAccountId: target,
            detail: .externalAuthInvalid,
            at: now.addingTimeInterval(1)
        )

        #expect(firstFailure.retryAttempt == 1)
        #expect(review.phase == .manualReview)
        #expect(review.retryAttempt == 1)
        #expect(review.activationGeneration == firstFailure.activationGeneration)
        #expect(try await coordinator.load() == review)
    }

    @Test("Request evaluation durably demotes expired evidence before policy")
    func expiredEvidenceDemotesBeforeRequestDecision() async throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = UUID()
        let now = Date(timeIntervalSince1970: 1_800_002_000)
        let coordinator = AccountActivationCoordinator(url: url)

        _ = try await coordinator.beginPreparing(
            targetAccountId: target,
            kind: .automatic,
            at: now
        )
        _ = try await coordinator.markCommittedDegraded(
            targetAccountId: target,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            detail: .runtimeConfirmationPending,
            at: now
        )
        let confirmed = try await confirm(
            coordinator,
            targetAccountId: target,
            runtimeCount: 1,
            at: now
        )

        #expect(confirmed.authorizesAutomaticMutations(at: now.addingTimeInterval(9)))
        #expect(!confirmed.authorizesAutomaticMutations(at: now.addingTimeInterval(10)))
        #expect(!confirmed.runtimeIsCurrent(for: target, at: now.addingTimeInterval(10)))

        let other = UUID()
        let decision = try await coordinator.beginAuthorizedCredentialMutation(
            targetAccountId: other,
            kind: .automatic,
            at: now.addingTimeInterval(10)
        )
        guard case .blocked(let degraded?, _) = decision else {
            Issue.record("Expected expired confirmation to block and demote")
            return
        }
        #expect(degraded.phase == .committedDegraded)
        #expect(degraded.runtimeCurrentAccountId == nil)
        #expect(try await AccountActivationCoordinator(url: url).load() == degraded)

        let crossTarget = try await coordinator.beginAuthorizedCredentialMutation(
            targetAccountId: other,
            kind: .manual,
            at: now.addingTimeInterval(11)
        )
        guard case .blocked = crossTarget else {
            Issue.record("Manual cross-target activation must remain blocked")
            return
        }
        let sameTarget = try await coordinator.beginAuthorizedCredentialMutation(
            targetAccountId: target,
            kind: .manual,
            at: now.addingTimeInterval(11)
        )
        guard case .retrySameTarget(let retryState) = sameTarget else {
            Issue.record("Only same-target reconciliation should remain available")
            return
        }
        #expect(retryState.activationGeneration == confirmed.activationGeneration)
    }

    @Test("Desktop runtime exit immediately demotes confirmed Mac ownership")
    func desktopExitDemotesConfirmedState() async throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = UUID()
        let now = Date(timeIntervalSince1970: 1_800_003_000)
        let coordinator = AccountActivationCoordinator(url: url)

        _ = try await coordinator.beginPreparing(
            targetAccountId: target,
            kind: .automatic,
            at: now
        )
        _ = try await coordinator.markCommittedDegraded(
            targetAccountId: target,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            detail: .runtimeConfirmationPending,
            at: now
        )
        let confirmed = try await confirm(
            coordinator,
            targetAccountId: target,
            runtimeCount: 1,
            at: now
        )
        let degraded = try await coordinator.demoteForRuntimeEvidenceLoss(
            targetAccountId: target,
            expectedActivationGeneration: confirmed.activationGeneration,
            detail: .desktopRuntimeExited,
            at: now.addingTimeInterval(1)
        )

        #expect(degraded.phase == .committedDegraded)
        #expect(degraded.detail == .desktopRuntimeExited)
        #expect(degraded.runtimeCurrentAccountId == nil)
        #expect(degraded.blocksAutomaticMutations)
    }

    private func confirm(
        _ coordinator: AccountActivationCoordinator,
        targetAccountId: UUID,
        runtimeCount: Int,
        at date: Date = Date()
    ) async throws -> AccountActivationState {
        let current = try #require(try await coordinator.load())
        return try await coordinator.markConfirmed(
            targetAccountId: targetAccountId,
            expectedActivationGeneration: current.activationGeneration,
            discoveredRuntimeCount: runtimeCount,
            acknowledgedRuntimeCount: runtimeCount,
            evidenceGeneration: UUID(),
            evidenceObservedAt: date,
            evidenceExpiresAt: date.addingTimeInterval(10),
            at: date
        )
    }

    private func temporaryJournalURL() -> URL {
        makeSecureTestFileURL(
            prefix: "codexswitch-account-activation",
            fileName: "account-activation.json"
        )
    }
}
