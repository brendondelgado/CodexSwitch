import Foundation

/// Orders main-actor telemetry submissions before durable persistence revisions.
@MainActor
final class AccountPersistenceSubmissionQueue {
    private var tail: Task<Void, Never>?
    private var generation: UInt64 = 0

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = tail
        generation &+= 1
        tail = Task {
            await previous?.value
            await operation()
        }
    }

    func drain() async {
        while let pending = tail {
            let observedGeneration = generation
            await pending.value
            if observedGeneration == generation {
                tail = nil
                return
            }
        }
    }
}
