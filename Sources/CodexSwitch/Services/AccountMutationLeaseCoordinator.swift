import Foundation

enum AccountMutationPurpose: Equatable, Sendable {
    case activation(targetAccountId: UUID, activationGeneration: UUID)
    case resetRedemption(accountId: UUID, activationGeneration: UUID)

    var accountId: UUID {
        switch self {
        case .activation(let accountId, _), .resetRedemption(let accountId, _):
            accountId
        }
    }

    var activationGeneration: UUID {
        switch self {
        case .activation(_, let generation), .resetRedemption(_, let generation):
            generation
        }
    }
}

struct AccountMutationLease: Equatable, Sendable {
    let generation: UInt64
    let purpose: AccountMutationPurpose
    fileprivate let ownershipToken: UUID
}

actor AccountMutationLeaseCoordinator {
    private final class Storage: @unchecked Sendable {
        private struct HeldLease {
            let lease: AccountMutationLease
            var isInvalidated: Bool
        }

        private let lock = NSLock()
        private var nextGeneration: UInt64 = 0
        private var current: HeldLease?

        func acquire(_ purpose: AccountMutationPurpose) -> AccountMutationLease? {
            lock.lock()
            defer { lock.unlock() }
            guard current == nil else { return nil }
            nextGeneration &+= 1
            let lease = AccountMutationLease(
                generation: nextGeneration,
                purpose: purpose,
                ownershipToken: UUID()
            )
            current = HeldLease(lease: lease, isInvalidated: false)
            return lease
        }

        func owns(_ lease: AccountMutationLease) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return current?.lease == lease && current?.isInvalidated == false
        }

        func holds(_ lease: AccountMutationLease) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return current?.lease == lease
        }

        func invalidateCurrentActivation(targetAccountId: UUID?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard var held = current,
                  case .activation(let currentTarget, _) = held.lease.purpose,
                  targetAccountId.map({ $0 == currentTarget }) ?? true else {
                return false
            }
            held.isInvalidated = true
            current = held
            return true
        }

        func invalidateCurrentLease() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard var held = current else { return false }
            held.isInvalidated = true
            current = held
            return true
        }

        func release(_ lease: AccountMutationLease) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard current?.lease == lease else { return false }
            current = nil
            return true
        }
    }

    nonisolated private let storage = Storage()

    func owns(_ lease: AccountMutationLease) -> Bool {
        storage.owns(lease)
    }

    func holds(_ lease: AccountMutationLease) -> Bool {
        storage.holds(lease)
    }

    @discardableResult
    func invalidateCurrentActivation(targetAccountId: UUID? = nil) -> Bool {
        storage.invalidateCurrentActivation(targetAccountId: targetAccountId)
    }

    nonisolated func ownsSynchronously(_ lease: AccountMutationLease) -> Bool {
        storage.owns(lease)
    }

    nonisolated func holdsSynchronously(_ lease: AccountMutationLease) -> Bool {
        storage.holds(lease)
    }

    @discardableResult
    nonisolated func invalidateCurrentActivationSynchronously(
        targetAccountId: UUID? = nil
    ) -> Bool {
        storage.invalidateCurrentActivation(targetAccountId: targetAccountId)
    }

    @discardableResult
    nonisolated func invalidateCurrentLeaseSynchronously() -> Bool {
        storage.invalidateCurrentLease()
    }

    func withLease<Value: Sendable>(
        _ purpose: AccountMutationPurpose,
        operation: @Sendable (AccountMutationLease) async throws -> Value
    ) async rethrows -> Value? {
        guard let lease = storage.acquire(purpose) else { return nil }
        defer { _ = storage.release(lease) }
        return try await operation(lease)
    }
}
