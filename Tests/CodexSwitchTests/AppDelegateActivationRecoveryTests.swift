import Foundation
import Testing
@testable import CodexSwitch

@Suite("AppDelegate activation recovery")
struct AppDelegateActivationRecoveryTests {
    @Test("Pool authority cannot reset or bypass the durable retry budget")
    func poolAuthorityUsesDurableRetryBudget() {
        let target = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let degraded = AccountActivationState.committedDegraded(
            targetAccountId: target,
            detail: .runtimeAcknowledgementIncomplete,
            activationGeneration: UUID(),
            retryAttempt: 2,
            nextRetryAt: now.addingTimeInterval(60),
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0,
            at: now
        )

        #expect(!AccountActivationRetrySource.poolAuthority.resetsRetryBudget)
        #expect(AccountActivationRetrySource.poolAuthority.requiresDurableRetrySchedule)
        #expect(!AccountActivationRetrySource.poolAuthority.permitsRetry(
            state: degraded,
            targetAccountId: target,
            at: now.addingTimeInterval(59)
        ))
        #expect(AccountActivationRetrySource.poolAuthority.permitsRetry(
            state: degraded,
            targetAccountId: target,
            at: now.addingTimeInterval(60)
        ))
        #expect(AccountActivationRetrySource.manual.resetsRetryBudget)
        #expect(!AccountActivationRetrySource.manual.requiresDurableRetrySchedule)
        #expect(AccountActivationRetrySource.manual.permitsRetry(
            state: degraded,
            targetAccountId: target,
            at: now
        ))
    }

    @Test("Journal-free bootstrap discovers auth target without preselecting it")
    func journalFreeBootstrapDiscoveryIsReadOnly() {
        let sourceId = UUID()
        let targetId = UUID()
        let source = CodexAccount(
            id: sourceId,
            email: "source@example.com",
            accessToken: "source-access",
            refreshToken: "source-refresh",
            idToken: "source-id",
            accountId: "source-provider",
            isActive: true
        )
        let target = CodexAccount(
            id: targetId,
            email: "target@example.com",
            accessToken: "target-access",
            refreshToken: "target-refresh",
            idToken: "target-id",
            accountId: "target-provider"
        )
        let accounts = [source, target]

        #expect(AppDelegate.journalFreeBootstrapRecovery(
            accounts: accounts,
            observedProviderAccountId: target.accountId
        ) == .recovered(targetId))
        #expect(accounts.filter(\.isActive).map(\.id) == [sourceId])
        #expect(AppDelegate.journalFreeBootstrapMutationRoute(
            previousConfiguredAccountId: sourceId
        ) == .externalAuthObservation)
        #expect(AppDelegate.journalFreeBootstrapMutationRoute(
            previousConfiguredAccountId: nil
        ) == .firstActivation)
    }

    @Test("Revoked preparation failures cannot enter manual review")
    func revokedPreparationFailureSkipsManualReview() {
        #expect(!AppDelegate.activationPreparationFailureRequiresManualReview(
            AccountActivationCoordinatorError.authorizationRevoked,
            authorizationIsCurrent: true
        ))
        #expect(!AppDelegate.activationPreparationFailureRequiresManualReview(
            AccountActivationCoordinatorError.readbackMismatch,
            authorizationIsCurrent: false
        ))
        #expect(AppDelegate.activationPreparationFailureRequiresManualReview(
            AccountActivationCoordinatorError.readbackMismatch,
            authorizationIsCurrent: true
        ))
    }

    @Test("Desktop update relaunch requires a successful or current patch")
    func desktopUpdateRelaunchRequiresSuccessfulOrCurrentPatch() {
        #expect(AppDelegate.desktopPatchRetryDisposition(
            after: .completed,
            hasRemainingAttempts: false,
            relaunchAfterCompletion: true,
            activationReady: true
        ) == .relaunch)
        #expect(AppDelegate.desktopPatchRetryDisposition(
            after: .notNeeded,
            hasRemainingAttempts: false,
            relaunchAfterCompletion: true,
            activationReady: true
        ) == .relaunch)

        #expect(AppDelegate.desktopPatchRetryDisposition(
            after: .completed,
            hasRemainingAttempts: true,
            relaunchAfterCompletion: true,
            activationReady: false
        ) == .retry)
        #expect(AppDelegate.desktopPatchRetryDisposition(
            after: .notNeeded,
            hasRemainingAttempts: false,
            relaunchAfterCompletion: true,
            activationReady: false
        ) == .stop)

        for outcome in [
            DesktopPatchAttemptOutcome.disabled,
            .missingSigningIdentity,
            .scriptMissing,
        ] {
            #expect(AppDelegate.desktopPatchRetryDisposition(
                after: outcome,
                hasRemainingAttempts: true,
                relaunchAfterCompletion: true,
                activationReady: false
            ) == .stop)
        }

        #expect(AppDelegate.desktopPatchRetryDisposition(
            after: .failed(1),
            hasRemainingAttempts: true,
            relaunchAfterCompletion: true,
            activationReady: false
        ) == .retry)
        #expect(AppDelegate.desktopPatchRetryDisposition(
            after: .failed(1),
            hasRemainingAttempts: false,
            relaunchAfterCompletion: true,
            activationReady: false
        ) == .stop)
        #expect(
            AppDelegate.desktopUpdateRelaunchArguments(
                appPath: "/Applications/ChatGPT.app"
            ) == ["-g", "/Applications/ChatGPT.app"]
        )
    }

    @MainActor
    @Test("Repeated permission denial survives the activation eligibility tick")
    func repeatedPermissionDeniedReachesTerminalPublication() {
        let retryDelays = DesktopPatchManager.postQuitPatchRetryDelaysSeconds
        let attemptTimes = retryDelays.reduce(into: [TimeInterval]()) { times, delay in
            times.append((times.last ?? 0) + delay)
        }
        #expect(attemptTimes == [1, 4, 12, 32, 77])

        var lifecycle = AppDelegateDesktopPatchRetryLifecycle()
        let activeIdentifier = UUID()
        let beganActiveBurst = lifecycle.begin(identifier: activeIdentifier)
        #expect(beganActiveBurst)

        for index in 0..<(retryDelays.count - 1) {
            #expect(AppDelegate.desktopPatchRetryDisposition(
                after: .permissionDenied,
                hasRemainingAttempts: true,
                relaunchAfterCompletion: true,
                activationReady: false
            ) == .retry)
            #expect(attemptTimes[index] < 60)
        }

        let replacementIdentifier = UUID()
        let beganReplacementBurst = lifecycle.begin(identifier: replacementIdentifier)
        #expect(!beganReplacementBurst)
        #expect(lifecycle.activeIdentifier == activeIdentifier)
        #expect(attemptTimes.last == 77)

        let terminalDisposition = AppDelegate.desktopPatchRetryDisposition(
            after: .permissionDenied,
            hasRemainingAttempts: false,
            relaunchAfterCompletion: true,
            activationReady: false
        )
        #expect(terminalDisposition == .stop)

        let coordinator = CodexDesktopUpdateCoordinator(
            nativeUpdateOwnershipProvider: { nil }
        )
        if terminalDisposition == .stop {
            coordinator.desktopActivationFinished(
                success: false,
                message: "Update installed, but hot-swap repair failed (permission_denied)."
            )
            let finishedActiveBurst = lifecycle.finish(identifier: activeIdentifier)
            #expect(finishedActiveBurst)
        }

        #expect(!lifecycle.isActive)
        #expect(coordinator.presentation.phase == .failed)
        #expect(!coordinator.presentation.isBusy)
    }

    @Test("Desktop update activation requires every discovered runtime acknowledgement")
    func desktopUpdateActivationRequiresCompleteRuntimeAcknowledgement() {
        #expect(AppDelegate.desktopReloadConfirmsActivation(
            .reloaded(
                method: "account/login/start",
                discoveredRuntimeCount: 1,
                acknowledgedRuntimeCount: 1
            )
        ))
        #expect(!AppDelegate.desktopReloadConfirmsActivation(
            .reloaded(
                method: "account/login/start",
                discoveredRuntimeCount: 0,
                acknowledgedRuntimeCount: 0
            )
        ))
        #expect(!AppDelegate.desktopReloadConfirmsActivation(
            .reloaded(
                method: "account/login/start",
                discoveredRuntimeCount: 2,
                acknowledgedRuntimeCount: 1
            )
        ))
        #expect(!AppDelegate.desktopReloadConfirmsActivation(
            .failed(
                "runtime unavailable",
                discoveredRuntimeCount: 1,
                acknowledgedRuntimeCount: 0
            )
        ))
    }

    @Test("Durable inspection separates unavailable reads from verified mismatch")
    func durableInspectionSeparatesUnavailableReadsFromMismatch() {
        let account = CodexAccount(
            email: "active@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "identity",
            accountId: "provider-account",
            isActive: true
        )
        var mismatchedAuth = account
        mismatchedAuth.accessToken = "different-access"

        #expect(AppDelegate.durableConfiguredFilesStatus(
            account: account,
            accounts: [account],
            authObservation: .unreadable(.readFailed)
        ) == .unavailable)
        #expect(AppDelegate.durableConfiguredFilesStatus(
            account: account,
            accounts: [account],
            authObservation: .invalid(.changedDuringRead)
        ) == .unavailable)
        #expect(AppDelegate.durableConfiguredFilesStatus(
            account: account,
            accounts: [account],
            authObservation: .valid(mismatchedAuth)
        ) == .mismatch)
    }

    @Test("Transient confirmed durable read failure preserves the journal")
    @MainActor
    func transientConfirmedDurableReadFailurePreservesJournal() async throws {
        let journalURL = makeSecureTestFileURL(
            prefix: "codexswitch-app-delegate-activation-recovery",
            fileName: "account-activation.json"
        )
        defer {
            try? FileManager.default.removeItem(
                at: journalURL.deletingLastPathComponent()
            )
        }
        let coordinator = AccountActivationCoordinator(url: journalURL)
        let target = UUID()
        let now = Date(timeIntervalSince1970: 1_800_100_000)

        _ = try await coordinator.beginPreparing(
            targetAccountId: target,
            kind: .automatic,
            at: now
        )
        let committed = try await coordinator.markCommittedDegraded(
            targetAccountId: target,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            detail: .runtimeConfirmationPending,
            at: now
        )
        let confirmed = try await coordinator.markConfirmed(
            targetAccountId: target,
            expectedActivationGeneration: committed.activationGeneration,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            evidenceGeneration: UUID(),
            evidenceObservedAt: now,
            evidenceExpiresAt: now.addingTimeInterval(10),
            at: now
        )
        let originalJournal = try Data(contentsOf: journalURL)
        var manualReviewWrites = 0

        let unavailableAllowed = await AppDelegate.runtimePermitAllowsDurableConfiguration(
            .unavailable,
            requiredPhase: .confirmed
        ) {
            manualReviewWrites += 1
            _ = try? await coordinator.markManualReview(
                targetAccountId: target,
                detail: .durableConfigurationChanged
            )
        }

        #expect(!unavailableAllowed)
        #expect(manualReviewWrites == 0)
        #expect(try Data(contentsOf: journalURL) == originalJournal)
        #expect(try await coordinator.load() == confirmed)

        let mismatchAllowed = await AppDelegate.runtimePermitAllowsDurableConfiguration(
            .mismatch,
            requiredPhase: .confirmed
        ) {
            manualReviewWrites += 1
            _ = try? await coordinator.markManualReview(
                targetAccountId: target,
                detail: .durableConfigurationChanged
            )
        }

        #expect(!mismatchAllowed)
        #expect(manualReviewWrites == 1)
        #expect(try await coordinator.load()?.phase == .manualReview)
    }

    @Test("Only matching external auth barriers recover from a stable observation")
    func externalAuthRecoveryTargetIsNarrow() {
        let target = UUID()
        let other = UUID()
        let review = AccountActivationState.manualReview(
            targetAccountId: target,
            detail: .externalAuthInvalid,
            at: Date(timeIntervalSince1970: 1_800_100_100)
        )

        #expect(AppDelegate.verifiedExternalAuthRecoveryTarget(
            state: review,
            configuredAccountId: target,
            observedTargetAccountId: target
        ) == target)
        #expect(AppDelegate.verifiedExternalAuthRecoveryTarget(
            state: review,
            configuredAccountId: other,
            observedTargetAccountId: target
        ) == nil)
        #expect(AppDelegate.verifiedExternalAuthRecoveryTarget(
            state: review,
            configuredAccountId: target,
            observedTargetAccountId: other
        ) == nil)

        let inconsistent = AccountActivationState.manualReview(
            targetAccountId: target,
            detail: .configuredFilesInconsistent,
            at: Date(timeIntervalSince1970: 1_800_100_100)
        )
        #expect(AppDelegate.verifiedExternalAuthRecoveryTarget(
            state: inconsistent,
            configuredAccountId: target,
            observedTargetAccountId: target
        ) == nil)

        #expect(AccountAuthObservationFailure.ancestorChanged.isRetryableObservationFailure)
        #expect(AccountAuthObservationFailure.changedDuringRead.isRetryableObservationFailure)
        #expect(AccountAuthObservationFailure.readFailed.isRetryableObservationFailure)
        #expect(!AccountAuthObservationFailure.malformed.isRetryableObservationFailure)
    }

    @Test("Deferred external handoffs remain retryable after launch")
    func externalHandoffFollowUpIsDurable() {
        let original = UUID()
        let target = UUID()
        let date = Date(timeIntervalSince1970: 1_800_100_200)
        let oldState = AccountActivationState.committedDegraded(
            targetAccountId: original,
            detail: .runtimeConfirmationPending,
            activationGeneration: UUID(),
            retryAttempt: 0,
            nextRetryAt: date,
            at: date
        )
        #expect(AppDelegate.externalHandoffFollowUp(
            state: oldState,
            configuredAccountId: target,
            observedTargetAccountId: target
        ) == .adopt)

        let adoptedState = AccountActivationState.committedDegraded(
            targetAccountId: target,
            detail: .externalAuthObserved,
            activationGeneration: UUID(),
            retryAttempt: 0,
            nextRetryAt: date,
            at: date
        )
        #expect(AppDelegate.externalHandoffFollowUp(
            state: adoptedState,
            configuredAccountId: target,
            observedTargetAccountId: target
        ) == .retryRuntime)
        #expect(AppDelegate.externalHandoffFollowUp(
            state: adoptedState,
            configuredAccountId: original,
            observedTargetAccountId: target
        ) == .none)
    }

    @Test("Final handoff revalidation preserves transient observations")
    func finalHandoffObservationClassifiesTransientReads() {
        #expect(AppDelegate.externalHandoffFinalObservationIsTransient(
            .invalid(.ancestorChanged)
        ))
        #expect(AppDelegate.externalHandoffFinalObservationIsTransient(
            .invalid(.changedDuringRead)
        ))
        #expect(AppDelegate.externalHandoffFinalObservationIsTransient(
            .unreadable(.readFailed)
        ))
        #expect(!AppDelegate.externalHandoffFinalObservationIsTransient(
            .invalid(.malformed)
        ))
        #expect(!AppDelegate.externalHandoffFinalObservationIsTransient(.absent))
    }

    @Test("Final handoff store revalidation retries only concurrency failures")
    func finalHandoffStoreErrorClassificationIsNarrow() {
        #expect(AppDelegate.externalHandoffFinalStoreErrorIsTransient(
            AccountPersistenceCoordinatorError.authorizationLost
        ))
        #expect(AppDelegate.externalHandoffFinalStoreErrorIsTransient(
            KeychainError.lockTimedOut(path: "/tmp/accounts.lock", timeout: 1)
        ))
        #expect(AppDelegate.externalHandoffFinalStoreErrorIsTransient(
            KeychainError.staleGeneration(expected: "old", actual: "new")
        ))
        #expect(!AppDelegate.externalHandoffFinalStoreErrorIsTransient(
            KeychainError.invalidActiveAccountCount(2)
        ))
        #expect(!AppDelegate.externalHandoffFinalStoreErrorIsTransient(
            KeychainError.unsafePath(path: "/tmp/accounts.json", reason: "linked")
        ))
        #expect(!AppDelegate.externalHandoffFinalStoreErrorIsTransient(
            KeychainError.readbackMismatch(path: "/tmp/accounts.json")
        ))
    }

    @Test("Launch adopts only a fully matching external handoff")
    func launchExternalHandoffTargetIsExact() {
        let originalId = UUID()
        let targetId = UUID()
        let original = CodexAccount(
            id: originalId,
            email: "original@example.com",
            accessToken: "old-access",
            refreshToken: "old-refresh",
            idToken: "old-id",
            accountId: "old-provider"
        )
        let target = CodexAccount(
            id: targetId,
            email: "target@example.com",
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: "new-id",
            accountId: "new-provider",
            isActive: true
        )

        #expect(AppDelegate.verifiedExternalHandoffTarget(
            accounts: [original, target],
            authObservation: .valid(target)
        )?.id == targetId)

        var tokenMismatch = target
        tokenMismatch.refreshToken = "different-refresh"
        #expect(AppDelegate.verifiedExternalHandoffTarget(
            accounts: [original, target],
            authObservation: .valid(tokenMismatch)
        ) == nil)

        var sourceActive = original
        sourceActive.isActive = true
        var targetInactive = target
        targetInactive.isActive = false
        #expect(AppDelegate.verifiedExternalHandoffTarget(
            accounts: [sourceActive, targetInactive],
            authObservation: .valid(target)
        ) == nil)

        var alsoActive = original
        alsoActive.isActive = true
        #expect(AppDelegate.verifiedExternalHandoffTarget(
            accounts: [alsoActive, target],
            authObservation: .valid(target)
        ) == nil)
    }
}
