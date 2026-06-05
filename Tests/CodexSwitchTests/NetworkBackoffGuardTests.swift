import Testing
import Foundation
@testable import CodexSwitch

@Suite("NetworkBackoffGuard")
struct NetworkBackoffGuardTests {
    @Test("Classifies transient transport failures")
    func classifiesTransientTransportFailures() {
        #expect(NetworkBackoffGuard.isTransientNetworkError("A TLS error caused the secure connection to fail."))
        #expect(NetworkBackoffGuard.isTransientNetworkError("Connection reset by peer (os error 54)"))
        #expect(NetworkBackoffGuard.isTransientNetworkError("SSH timed out while fetching Linux devbox token usage"))
        #expect(NetworkBackoffGuard.isTransientNetworkError("The Internet connection appears to be offline."))
        #expect(!NetworkBackoffGuard.isTransientNetworkError("HTTP 401 Unauthorized"))
        #expect(!NetworkBackoffGuard.isTransientNetworkError("You have hit your usage limit"))
    }

    @Test("Backoff delay is bounded")
    func delayIsBounded() {
        #expect(NetworkBackoffGuard.delay(forFailureStreak: 1) == 15)
        #expect(NetworkBackoffGuard.delay(forFailureStreak: 2) == 30)
        #expect(NetworkBackoffGuard.delay(forFailureStreak: 3) == 60)
        #expect(NetworkBackoffGuard.delay(forFailureStreak: 4) == 120)
        #expect(NetworkBackoffGuard.delay(forFailureStreak: 8) == 120)
    }
}
