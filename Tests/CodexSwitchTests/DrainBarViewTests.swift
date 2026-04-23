import Foundation
import Testing
@testable import CodexSwitch

@Suite("Drain bar countdown")
struct DrainBarViewTests {
    @Test("Reset text reflects the supplied current time")
    @MainActor
    func resetTextUsesCurrentTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(4 * 3600 + 55 * 60)
        let text = DrainBarView.resetText(now: now, resetsAt: reset)

        #expect(text.contains("1/15"))
        #expect(text.hasSuffix("(4h 55m)"))
        #expect(DrainBarView.resetText(now: reset.addingTimeInterval(1), resetsAt: reset) == "resetting...")
    }
}
