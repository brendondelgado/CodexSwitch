import Foundation
import Testing
@testable import CodexSwitch

@Suite("Exhausted pool alert gate")
struct ExhaustedPoolAlertGateTests {
    @Test("No-candidate alerts are coalesced until cooldown")
    func coalescesNoCandidateAlertsUntilCooldown() {
        var gate = ExhaustedPoolAlertGate(cooldown: 60)
        let start = Date(timeIntervalSince1970: 1_000)

        let first = gate.shouldNotifyNoCandidate(now: start)
        let afterFiveSeconds = gate.shouldNotifyNoCandidate(now: start.addingTimeInterval(5))
        let beforeCooldown = gate.shouldNotifyNoCandidate(now: start.addingTimeInterval(59))
        let afterCooldown = gate.shouldNotifyNoCandidate(now: start.addingTimeInterval(60))

        #expect(first)
        #expect(!afterFiveSeconds)
        #expect(!beforeCooldown)
        #expect(afterCooldown)
    }

    @Test("Recovery allows the next exhausted state to notify")
    func recoveryAllowsNextExhaustedStateToNotify() {
        var gate = ExhaustedPoolAlertGate(cooldown: 60)
        let start = Date(timeIntervalSince1970: 2_000)

        let first = gate.shouldNotifyNoCandidate(now: start)
        let suppressed = gate.shouldNotifyNoCandidate(now: start.addingTimeInterval(5))

        gate.markRecovered()

        let afterRecovery = gate.shouldNotifyNoCandidate(now: start.addingTimeInterval(6))

        #expect(first)
        #expect(!suppressed)
        #expect(afterRecovery)
    }
}
