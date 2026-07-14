import Foundation
import Testing
@testable import CodexSwitch

private final class ResetTransportCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func record() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@Suite("AppDelegate rate-limit reset guard")
struct AppDelegateRateLimitResetGuardTests {
    @Test("A same-generation phase demotion revokes the reset permit before POST")
    func resetSubmissionRevalidatesPhaseImmediatelyBeforeTransport() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let activationGeneration = UUID()
        let account = Self.makeResetAccount()
        let activationURL = makeSecureTestFileURL(
            prefix: "codexswitch-reset-activation",
            fileName: "activation.json"
        )
        let resetURL = makeSecureTestFileURL(
            prefix: "codexswitch-reset-journal",
            fileName: "reset.json"
        )
        defer {
            try? FileManager.default.removeItem(at: activationURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: resetURL.deletingLastPathComponent())
        }

        let coordinator = AccountActivationCoordinator(url: activationURL)
        _ = try await coordinator.beginPreparing(
            targetAccountId: account.id,
            kind: .automatic,
            requestedActivationGeneration: activationGeneration,
            at: now
        )
        _ = try await coordinator.markCommittedDegraded(
            targetAccountId: account.id,
            expectedActivationGeneration: activationGeneration,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            detail: .runtimeConfirmationPending,
            at: now
        )
        let evidence = AccountActivationRuntimeEvidence(
            generation: UUID(),
            runtimeCurrentAccountId: account.id,
            observedAt: now,
            expiresAt: now.addingTimeInterval(60),
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1
        )
        _ = try await coordinator.markConfirmed(
            targetAccountId: account.id,
            expectedActivationGeneration: activationGeneration,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            evidenceGeneration: evidence.generation,
            evidenceObservedAt: evidence.observedAt,
            evidenceExpiresAt: evidence.expiresAt,
            at: now
        )
        let runtimePermit = AccountActivationRuntimePermit(
            targetAccountId: account.id,
            activationGeneration: activationGeneration,
            requiredPhase: .confirmed,
            evidence: evidence
        )
        let transportCalls = ResetTransportCounter()
        let service = RateLimitResetService(
            transport: { _ in
                transportCalls.record()
                return RateLimitResetHTTPResponse(statusCode: 200, data: Data())
            },
            journalURL: resetURL
        )
        let transaction = AccountActivationTransaction()

        let submissionWasDenied = try await transaction.withResetLease(
            accountId: account.id,
            activationGeneration: activationGeneration
        ) { lease in
            let effectPermit = try #require(transaction.makeEffectPermit(
                lease: lease,
                targetAccountId: account.id,
                activationGeneration: activationGeneration,
                requiredPhase: .confirmed,
                runtimePermit: runtimePermit,
                journal: coordinator,
                at: now
            ))
            do {
                _ = try await service.consume(
                    for: account,
                    bank: Self.makeResetBank(now: now),
                    now: now,
                    authorizeSubmission: { attempt in
                        _ = try? await coordinator.demoteForRuntimeEvidenceLoss(
                            targetAccountId: account.id,
                            expectedActivationGeneration: activationGeneration,
                            detail: .runtimeEvidenceExpired,
                            at: now.addingTimeInterval(1)
                        )
                        return RateLimitResetSubmissionPermit(
                            attemptId: attempt.id,
                            providerAccountId: attempt.providerAccountId,
                            creditId: attempt.creditId,
                            targetAccountId: account.id,
                            activationGeneration: activationGeneration,
                            leaseGeneration: lease.generation,
                            runtimePermit: runtimePermit,
                            activationEffectPermit: effectPermit,
                            issuedAt: now.addingTimeInterval(1)
                        )
                    }
                )
                return false
            } catch RateLimitResetServiceError.submissionUnauthorized {
                return true
            }
        }

        #expect(submissionWasDenied == true)
        #expect(transportCalls.read() == 0)
    }

    @Test("External bank drop blocks same-refresh redemption for fifteen minutes")
    func externalBankDropBlocksSameRefreshRedemption() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let blockedUntil = AppDelegate.externalRateLimitResetRedemptionBlockUntil(
            previousAvailableCount: 3,
            refreshedAvailableCount: 2,
            localRedemptionProviderAccountId: nil,
            observedProviderAccountId: "provider-account-1",
            now: now
        )

        #expect(blockedUntil == now.addingTimeInterval(15 * 60))
        #expect(AppDelegate.rateLimitResetRedemptionIsBlocked(until: blockedUntil, at: now))
        #expect(!AppDelegate.rateLimitResetRedemptionIsBlocked(
            until: blockedUntil,
            at: now.addingTimeInterval(900)
        ))
    }

    @Test("A local redemption owns only its matching provider account bank drop")
    func localRedemptionIsAccountSpecific() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AppDelegate.externalRateLimitResetRedemptionBlockUntil(
            previousAvailableCount: 3,
            refreshedAvailableCount: 2,
            localRedemptionProviderAccountId: "provider-account-1",
            observedProviderAccountId: "provider-account-1",
            now: now
        ) == nil)
        #expect(AppDelegate.externalRateLimitResetRedemptionBlockUntil(
            previousAvailableCount: 3,
            refreshedAvailableCount: 2,
            localRedemptionProviderAccountId: "provider-account-1",
            observedProviderAccountId: "provider-account-2",
            now: now
        ) == now.addingTimeInterval(15 * 60))
    }

    @Test("Unreadable external hold state disables automatic redemption")
    func externalHoldStateFailsClosed() {
        #expect(AppDelegate.automaticRateLimitResetRedemptionIsEnabled(
            preferenceEnabled: true,
            externalHoldStateIsReadable: true
        ))
        #expect(!AppDelegate.automaticRateLimitResetRedemptionIsEnabled(
            preferenceEnabled: true,
            externalHoldStateIsReadable: false
        ))
    }

    private static func makeResetAccount() -> CodexAccount {
        CodexAccount(
            email: "reset-guard@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "provider-reset-guard"
        )
    }

    private static func makeResetBank(now: Date) -> RateLimitResetBank {
        RateLimitResetBank(
            availableCount: 1,
            totalEarnedCount: 1,
            credits: [
                RateLimitResetCredit(
                    id: "credit-1",
                    resetType: "weekly",
                    status: "available",
                    grantedAt: now.addingTimeInterval(-60),
                    expiresAt: now.addingTimeInterval(3_600),
                    redeemedAt: nil,
                    title: nil,
                    description: nil
                )
            ],
            fetchedAt: now
        )
    }
}
