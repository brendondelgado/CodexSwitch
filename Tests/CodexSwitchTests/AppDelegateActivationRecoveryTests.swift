import Foundation
import Testing
@testable import CodexSwitch

@Suite("AppDelegate activation recovery")
struct AppDelegateActivationRecoveryTests {
    @Test("Desktop update relaunch requires a successful or current patch")
    func desktopUpdateRelaunchRequiresSuccessfulOrCurrentPatch() {
        #expect(AppDelegate.desktopPatchRetryDisposition(
            after: .completed,
            hasRemainingAttempts: false,
            relaunchAfterCompletion: true
        ) == .relaunch)
        #expect(AppDelegate.desktopPatchRetryDisposition(
            after: .notNeeded,
            hasRemainingAttempts: false,
            relaunchAfterCompletion: true
        ) == .relaunch)

        for outcome in [
            DesktopPatchAttemptOutcome.disabled,
            .missingSigningIdentity,
            .scriptMissing,
        ] {
            #expect(AppDelegate.desktopPatchRetryDisposition(
                after: outcome,
                hasRemainingAttempts: true,
                relaunchAfterCompletion: true
            ) == .stop)
        }

        #expect(AppDelegate.desktopPatchRetryDisposition(
            after: .failed(1),
            hasRemainingAttempts: true,
            relaunchAfterCompletion: true
        ) == .retry)
        #expect(AppDelegate.desktopPatchRetryDisposition(
            after: .failed(1),
            hasRemainingAttempts: false,
            relaunchAfterCompletion: true
        ) == .stop)
        #expect(
            AppDelegate.desktopUpdateRelaunchArguments(
                appPath: "/Applications/ChatGPT.app"
            ) == ["-g", "/Applications/ChatGPT.app"]
        )
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
}
