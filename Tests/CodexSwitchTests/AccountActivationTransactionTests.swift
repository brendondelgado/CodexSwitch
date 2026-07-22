import Foundation
import Testing
@testable import CodexSwitch

private enum ActivationRevocationBoundary: CaseIterable, Sendable {
    case credentialMutation
    case accountStore
    case authFile
    case durableReadback
    case journal
    case convergence

    var expectedFailure: AccountActivationCommitFailureStage {
        switch self {
        case .credentialMutation: .credentialMutation
        case .accountStore: .accountStorePersistence
        case .authFile: .authPersistence
        case .durableReadback: .durableReadback
        case .journal: .journalPersistence
        case .convergence: .convergence
        }
    }
}

private final class ActivationEffectRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var effects: [String] = []

    func record(_ effect: String) {
        lock.lock()
        effects.append(effect)
        lock.unlock()
    }

    func contains(_ effect: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return effects.contains(effect)
    }
}

private actor DurableConfirmationGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func verifyAfterSuspension() async -> Bool {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func reportChangedDurableFiles() {
        continuation?.resume(returning: false)
        continuation = nil
    }
}

@Suite("Account activation transaction")
struct AccountActivationTransactionTests {
    @MainActor
    @Test("Revocation after every preparatory suspension stops the next effect")
    func revocationStopsEveryCredentialCommitBoundary() async throws {
        for boundary in ActivationRevocationBoundary.allCases {
            let target = Self.account()
            let activationGeneration = UUID()
            let journalURL = makeSecureTestFileURL(
                prefix: "codexswitch-activation-transaction",
                fileName: "activation.json"
            )
            let authURL = makeSecureTestFileURL(
                prefix: "codexswitch-activation-auth",
                fileName: "auth.json"
            )
            let coordinator = AccountActivationCoordinator(url: journalURL)
            let transaction = AccountActivationTransaction()
            let credentialCommitter = AccountActivationCredentialCommitter()
            let effects = ActivationEffectRecorder()
            let persistence = AccountPersistenceCoordinator(
                load: { [] },
                save: { _ in effects.record("account-store") },
                deleteAll: {}
            )

            let result = try await transaction.withActivationLease(
                targetAccountId: target.id,
                activationGeneration: activationGeneration
            ) { lease -> AccountActivationCommitResult in
                let decision = try await coordinator.beginAuthorizedCredentialMutation(
                    targetAccountId: target.id,
                    kind: .automatic,
                    requestedActivationGeneration: activationGeneration,
                    authorizeEffect: { _ in
                        transaction.leaseAuthorizes(
                            lease,
                            targetAccountId: target.id,
                            activationGeneration: activationGeneration
                        )
                    }
                )
                guard case .prepared(let preparing, previousState: _) = decision else {
                    return .failed(.mutationAuthorization)
                }

                return await transaction.commitConfiguredCredentials(
                    AccountActivationCommitOperations(
                        authorizeMutation: {
                            guard let effectPermit = transaction.makeEffectPermit(
                                lease: lease,
                                targetAccountId: target.id,
                                activationGeneration: activationGeneration,
                                requiredPhase: .preparing,
                                runtimePermit: nil,
                                journal: coordinator
                            ) else {
                                return nil
                            }
                            return AccountCredentialMutationPermit(
                                effectPermit: effectPermit,
                                requiresRuntimeEvidence: false,
                                expectedRuntimeCurrentAccountId: nil
                            )
                        },
                        mutateCredentials: { permit in
                            if boundary == .credentialMutation {
                                transaction.invalidateCurrentActivationSynchronously()
                            }
                            guard permit.authorizes(state: preparing, at: Date()) else {
                                return false
                            }
                            effects.record("credentials")
                            return true
                        },
                        authorizePreparingEffect: {
                            transaction.makeEffectPermit(
                                lease: lease,
                                targetAccountId: target.id,
                                activationGeneration: activationGeneration,
                                requiredPhase: .preparing,
                                runtimePermit: nil,
                                journal: coordinator
                            )
                        },
                        persistAccountStore: { permit in
                            if boundary == .accountStore {
                                transaction.invalidateCurrentActivationSynchronously()
                            }
                            do {
                                try await persistence.persistDurably(
                                    [target],
                                    revision: 1,
                                    authorizeEffect: { permit.isCurrentlyAuthorized() }
                                )
                                return true
                            } catch {
                                return false
                            }
                        },
                        persistAuth: { permit in
                            if boundary == .authFile {
                                transaction.invalidateCurrentActivationSynchronously()
                            }
                            let authResult = await credentialCommitter.persistAuth(
                                for: target,
                                path: authURL.path,
                                permit: permit
                            )
                            if authResult == .committed {
                                effects.record("auth-file")
                                return true
                            }
                            return false
                        },
                        verifyDurableFiles: { permit in
                            await Task.yield()
                            if boundary == .durableReadback {
                                transaction.invalidateCurrentActivationSynchronously()
                            }
                            return permit.isCurrentlyAuthorized()
                                && effects.contains("account-store")
                                && AppDelegate.authFileMatches(
                                    account: target,
                                    atPath: authURL.path
                                )
                        },
                        markCommittedDegraded: { permit in
                            if boundary == .journal {
                                transaction.invalidateCurrentActivationSynchronously()
                            }
                            do {
                                _ = try await coordinator.markCommittedDegraded(
                                    targetAccountId: target.id,
                                    expectedActivationGeneration: activationGeneration,
                                    discoveredRuntimeCount: 0,
                                    acknowledgedRuntimeCount: 0,
                                    detail: .runtimeConfirmationPending,
                                    authorizeEffect: { state in
                                        permit.authorizes(state: state, at: Date())
                                    }
                                )
                                effects.record("journal")
                                return true
                            } catch {
                                return false
                            }
                        },
                        authorizeConvergence: {
                            transaction.makeEffectPermit(
                                lease: lease,
                                targetAccountId: target.id,
                                activationGeneration: activationGeneration,
                                requiredPhase: .committedDegraded,
                                runtimePermit: nil,
                                journal: coordinator
                            )
                        },
                        convergeRuntime: { permit in
                            await Task.yield()
                            if boundary == .convergence {
                                transaction.invalidateCurrentActivationSynchronously()
                            }
                            guard permit.isCurrentlyAuthorized() else { return false }
                            effects.record("convergence")
                            return true
                        }
                    )
                )
            }

            #expect(result == .failed(boundary.expectedFailure))
            if boundary != .convergence {
                #expect(!effects.contains("convergence"))
            }
            try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: authURL.deletingLastPathComponent())
        }
    }

    @Test("Invalidation revokes ownership but holds exclusion until the owner unwinds")
    func observerInvalidationDoesNotReleaseOwnerLease() async {
        let transaction = AccountActivationTransaction()
        let target = UUID()
        let generation = UUID()
        let entered = AsyncStream.makeStream(of: Void.self)
        let unwind = AsyncStream.makeStream(of: Void.self)
        let owner = Task {
            await transaction.withActivationLease(
                targetAccountId: target,
                activationGeneration: generation
            ) { lease in
                entered.continuation.yield()
                _ = await nextElement(from: unwind.stream)
                return transaction.ownsSynchronously(lease)
            }
        }
        _ = await nextElement(from: entered.stream)

        transaction.invalidateCurrentActivationSynchronously(targetAccountId: target)
        let overlappingReset = await transaction.withResetLease(
            accountId: target,
            activationGeneration: generation
        ) { _ in true }
        #expect(overlappingReset == nil)

        unwind.continuation.yield()
        #expect(await owner.value == false)
        let afterUnwind = await transaction.withResetLease(
            accountId: target,
            activationGeneration: generation
        ) { _ in true }
        #expect(afterUnwind == true)
    }

    @MainActor
    @Test("Swap refresh reauthentication and plan-upgrade submissions revalidate after suspension")
    func activeCredentialRoutesStopBeforeSubmissionAfterRevocation() async throws {
        let routes: [AccountCredentialMutationRoute] = [
            .swap,
            .tokenRefresh,
            .activeReauthentication,
            .planUpgrade,
        ]
        for route in routes {
            let target = Self.account()
            let generation = UUID()
            let journalURL = makeSecureTestFileURL(
                prefix: "codexswitch-route-authorization",
                fileName: "activation.json"
            )
            let coordinator = AccountActivationCoordinator(url: journalURL)
            let transaction = AccountActivationTransaction()
            let entered = AsyncStream.makeStream(of: Void.self)
            let resume = AsyncStream.makeStream(of: Void.self)
            let effects = ActivationEffectRecorder()

            let owner = Task { @MainActor in
                try await transaction.withActivationLease(
                    targetAccountId: target.id,
                    activationGeneration: generation
                ) { lease in
                    _ = try await coordinator.beginAuthorizedCredentialMutation(
                        targetAccountId: target.id,
                        kind: .automatic,
                        requestedActivationGeneration: generation,
                        authorizeEffect: { _ in
                            transaction.leaseAuthorizes(
                                lease,
                                targetAccountId: target.id,
                                activationGeneration: generation
                            )
                        }
                    )
                    return await AccountCredentialMutationBoundary.performAsync(
                        route: route,
                        authorize: {
                            entered.continuation.yield()
                            _ = await nextElement(from: resume.stream)
                            guard let effectPermit = transaction.makeEffectPermit(
                                lease: lease,
                                targetAccountId: target.id,
                                activationGeneration: generation,
                                requiredPhase: .preparing,
                                runtimePermit: nil,
                                journal: coordinator
                            ) else {
                                return nil
                            }
                            return AccountCredentialMutationPermit(
                                effectPermit: effectPermit,
                                requiresRuntimeEvidence: false,
                                expectedRuntimeCurrentAccountId: nil
                            )
                        },
                        mutation: { _ in
                            effects.record(route.rawValue)
                            return true
                        }
                    )
                }
            }
            _ = await nextElement(from: entered.stream)
            transaction.invalidateCurrentActivationSynchronously(targetAccountId: target.id)
            resume.continuation.yield()

            let leaseResult = try await owner.value
            let mutationResult = try #require(leaseResult)
            #expect(mutationResult == nil)
            #expect(!effects.contains(route.rawValue))
            try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent())
        }
    }

    @Test("Every automatic entry requires a fresh confirmed permit for its configured account")
    func automaticEntryGateFailsClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accountId = UUID()
        let generation = UUID()
        let evidence = AccountActivationRuntimeEvidence(
            generation: UUID(),
            runtimeCurrentAccountId: accountId,
            observedAt: now,
            expiresAt: now.addingTimeInterval(10),
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1
        )
        let confirmed = AccountActivationState(
            version: AccountActivationState.currentVersion,
            phase: .confirmed,
            activationGeneration: generation,
            configuredAccountId: accountId,
            runtimeCurrentAccountId: accountId,
            updatedAt: now,
            retryAttempt: 0,
            nextRetryAt: nil,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1,
            detail: nil,
            runtimeEvidenceGeneration: evidence.generation,
            runtimeEvidenceObservedAt: evidence.observedAt,
            runtimeEvidenceExpiresAt: evidence.expiresAt
        )
        let permit = AccountActivationRuntimePermit(
            targetAccountId: accountId,
            activationGeneration: generation,
            requiredPhase: .confirmed,
            evidence: evidence
        )
        let triggers: [AccountAutomaticPolicyTrigger] = [
            .routine,
            .usageUnavailable(accountId: accountId),
            .tokenInvalidated(accountId: accountId),
        ]
        for trigger in triggers {
            #expect(AccountAutomaticPolicyGate.authorizes(
                trigger: trigger,
                configuredAccountId: accountId,
                state: confirmed,
                permit: permit,
                at: now
            ))
        }

        let degraded = AccountActivationState.committedDegraded(
            targetAccountId: accountId,
            detail: .runtimeEvidenceExpired,
            activationGeneration: generation,
            retryAttempt: 1,
            nextRetryAt: now,
            at: now
        )
        for trigger in triggers {
            #expect(!AccountAutomaticPolicyGate.authorizes(
                trigger: trigger,
                configuredAccountId: accountId,
                state: degraded,
                permit: permit,
                at: now
            ))
        }
        #expect(!AccountAutomaticPolicyGate.authorizes(
            trigger: .usageUnavailable(accountId: UUID()),
            configuredAccountId: accountId,
            state: confirmed,
            permit: permit,
            at: now
        ))

        let relabeledRuntimePermit = AccountActivationRuntimePermit(
            targetAccountId: accountId,
            activationGeneration: generation,
            requiredPhase: .confirmed,
            evidence: AccountActivationRuntimeEvidence(
                generation: evidence.generation,
                runtimeCurrentAccountId: UUID(),
                observedAt: evidence.observedAt,
                expiresAt: evidence.expiresAt,
                discoveredRuntimeCount: 1,
                acknowledgedRuntimeCount: 1
            )
        )
        #expect(!AccountAutomaticPolicyGate.authorizes(
            trigger: .routine,
            configuredAccountId: accountId,
            state: confirmed,
            permit: relabeledRuntimePermit,
            at: now
        ))
    }

    @Test("Automatic policy lease expires and stale completion cannot clear replacement")
    func automaticPolicyLeaseIsGenerationOwned() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let started: UInt64 = 1_000_000_000
        var state = AccountAutomaticPolicyLeaseState()
        let first = try #require(state.begin(
            at: now,
            uptimeNanoseconds: started,
            timeout: 30
        ))
        #expect(state.begin(
            at: now,
            uptimeNanoseconds: started,
            timeout: 30
        ) == nil)

        #expect(state.authorizes(
            first,
            uptimeNanoseconds: started + 29_000_000_000
        ))
        #expect(!state.expire(
            first,
            uptimeNanoseconds: started + 29_000_000_000
        ))
        #expect(state.expire(
            first,
            uptimeNanoseconds: started + 30_000_000_000
        ))
        #expect(!first.authority.authorizes(
            uptimeNanoseconds: started + 29_000_000_000
        ))

        let replacement = try #require(
            state.begin(
                at: now.addingTimeInterval(-3_600),
                uptimeNanoseconds: started + 31_000_000_000,
                timeout: 30
            )
        )
        #expect(state.finish(
            first,
            uptimeNanoseconds: started + 32_000_000_000
        ) == .stale)
        #expect(state.current == replacement)
        #expect(state.authorizes(
            replacement,
            uptimeNanoseconds: started + 32_000_000_000
        ))
        #expect(state.finish(
            replacement,
            uptimeNanoseconds: started + 32_000_000_000
        ) == .completed)
        #expect(state.current == nil)
        #expect(replacement.authority.authorizes(
            uptimeNanoseconds: started + 33_000_000_000
        ))
        #expect(!replacement.authority.authorizes(
            uptimeNanoseconds: started + 61_000_000_000
        ))

        let late = try #require(state.begin(
            at: now,
            uptimeNanoseconds: started + 70_000_000_000,
            timeout: 1
        ))
        #expect(state.finish(
            late,
            uptimeNanoseconds: started + 71_000_000_000
        ) == .expired)
        #expect(!late.authority.authorizes(
            uptimeNanoseconds: started + 70_500_000_000
        ))

        let cancelled = try #require(state.begin(
            at: now,
            uptimeNanoseconds: started + 80_000_000_000,
            timeout: 30
        ))
        #expect(state.cancel(cancelled))
        #expect(state.current == nil)
        #expect(!cancelled.authority.authorizes(
            uptimeNanoseconds: started + 81_000_000_000
        ))
    }

    @MainActor
    @Test("Durable credential drift during final readback never reaches confirmation persistence")
    func durableDriftStopsConfirmationJournalEffect() async {
        let gate = DurableConfirmationGate()
        let effects = ActivationEffectRecorder()
        let transaction = AccountActivationConfirmationTransaction()
        let confirmation = Task { @MainActor in
            await transaction.confirm(AccountActivationConfirmationOperations(
                verifyDurableFiles: {
                    await gate.verifyAfterSuspension()
                },
                authorizeConfirmation: {
                    effects.record("authorization")
                    return nil
                },
                persistConfirmation: { _ in
                    effects.record("confirmation-journal")
                    return nil
                }
            ))
        }
        await gate.waitUntilStarted()
        await gate.reportChangedDurableFiles()

        #expect(await confirmation.value == .blocked(.durableReadback))
        #expect(!effects.contains("authorization"))
        #expect(!effects.contains("confirmation-journal"))
    }

    private static func account() -> CodexAccount {
        CodexAccount(
            email: "activation-transaction@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "provider-activation-transaction"
        )
    }
}
