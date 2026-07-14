import Foundation
import Testing
@testable import CodexSwitch

private actor LeaseSuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func wait() async {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Account mutation lease")
struct AccountMutationLeaseCoordinatorTests {
    @Test("Activation and reset cannot overlap across a suspended await")
    func suspendedOwnerExcludesSecondMutation() async throws {
        let coordinator = AccountMutationLeaseCoordinator()
        let activationGeneration = UUID()
        let activationStarted = AsyncStream.makeStream(of: Void.self)
        let releaseActivation = AsyncStream.makeStream(of: Void.self)

        let activation = Task {
            try await coordinator.withLease(
                .activation(
                    targetAccountId: UUID(),
                    activationGeneration: activationGeneration
                )
            ) { _ in
                activationStarted.continuation.yield()
                _ = await releaseActivation.stream.first(where: { _ in true })
                return true
            }
        }
        _ = await activationStarted.stream.first(where: { _ in true })

        let reset = await coordinator.withLease(
            .resetRedemption(
                accountId: UUID(),
                activationGeneration: activationGeneration
            )
        ) { _ in true }
        #expect(reset == nil)

        releaseActivation.continuation.yield()
        #expect(try await activation.value == true)
        let afterRelease = await coordinator.withLease(
            .resetRedemption(
                accountId: UUID(),
                activationGeneration: activationGeneration
            )
        ) { _ in true }
        #expect(afterRelease == true)
    }

    @Test("A stale generation cannot own the next lexical lease")
    func staleLeaseLosesGeneration() async throws {
        let coordinator = AccountMutationLeaseCoordinator()
        let first = try #require(await coordinator.withLease(
            .activation(targetAccountId: UUID(), activationGeneration: UUID())
        ) { lease in
            #expect(await coordinator.owns(lease))
            return lease
        })
        let second = try #require(await coordinator.withLease(
            .activation(targetAccountId: UUID(), activationGeneration: UUID())
        ) { lease in
            #expect(await coordinator.owns(lease))
            return lease
        })

        #expect(second.generation > first.generation)
        #expect(!(await coordinator.owns(first)))
        #expect(!(await coordinator.owns(second)))
    }

    @Test("Cancellation releases only the cancelled owner")
    func cancellationReleasesLease() async throws {
        let coordinator = AccountMutationLeaseCoordinator()
        let generation = UUID()
        let started = AsyncStream.makeStream(of: Void.self)
        let owner = Task {
            try await coordinator.withLease(
                .resetRedemption(accountId: UUID(), activationGeneration: generation)
            ) { _ in
                started.continuation.yield()
                try await Task.sleep(for: .seconds(30))
                return true
            }
        }
        _ = await started.stream.first(where: { _ in true })
        owner.cancel()
        do {
            _ = try await owner.value
        } catch is CancellationError {
            // Expected.
        }

        let next = await coordinator.withLease(
            .activation(targetAccountId: UUID(), activationGeneration: UUID())
        ) { _ in true }
        #expect(next == true)
    }

    @Test("Cancelled suspended convergence excludes reset and activation until it unwinds")
    func cancelledSuspendedConvergenceKeepsLeaseUntilExit() async {
        let coordinator = AccountMutationLeaseCoordinator()
        let gate = LeaseSuspensionGate()
        let owner = Task<Void, Never> {
            _ = await coordinator.withLease(.activation(
                targetAccountId: UUID(),
                activationGeneration: UUID()
            )) { _ in
                await gate.wait()
            }
        }
        await gate.waitUntilStarted()
        AppDelegate.requestOwnedMutationTaskCancellation(owner)

        let overlappingReset = await coordinator.withLease(
            .resetRedemption(accountId: UUID(), activationGeneration: UUID())
        ) { _ in true }
        let overlappingActivation = await coordinator.withLease(
            .activation(targetAccountId: UUID(), activationGeneration: UUID())
        ) { _ in true }
        #expect(overlappingReset == nil)
        #expect(overlappingActivation == nil)

        await gate.resume()
        _ = await owner.value
        let next = await coordinator.withLease(
            .resetRedemption(accountId: UUID(), activationGeneration: UUID())
        ) { _ in true }
        #expect(next == true)
    }
}
