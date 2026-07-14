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
        let text = DrainBarView.resetText(percent: 100, resetsAt: reset, now: now)

        #expect(text.contains("1/15"))
        #expect(text.hasSuffix("(4h 55m)"))
        let later = DrainBarView.resetText(
            percent: 100,
            resetsAt: reset,
            now: now.addingTimeInterval(80 * 60)
        )
        #expect(later.hasSuffix("(3h 35m)"))
        #expect(DrainBarView.countdownRefreshInterval <= 60)
        #expect(DrainBarView.resetText(percent: 0, resetsAt: reset, now: reset.addingTimeInterval(1)) == "confirming reset")
    }

    @Test("Weekly-only snapshots render one weekly row")
    func weeklyOnlyPresentation() {
        let presentation = QuotaSnapshotPresentation(
            snapshot: snapshot(windows: [window(kind: .weekly, durationSeconds: 7 * 86_400)])
        )

        guard case .windows(let rows) = presentation else {
            Issue.record("Expected quota window rows")
            return
        }
        #expect(rows.count == 1)
        #expect(rows.map(\.label) == ["Wk"])
        #expect(!rows.map(\.label).contains("5h"))
    }

    @Test("Legacy snapshots retain their two semantic rows")
    func legacyTwoWindowPresentation() {
        let legacy = QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: 25,
                windowDurationMins: 300,
                resetsAt: Date(timeIntervalSince1970: 1_800_018_000)
            ),
            weekly: QuotaWindow(
                usedPercent: 40,
                windowDurationMins: 10_080,
                resetsAt: Date(timeIntervalSince1970: 1_800_604_800)
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        guard case .windows(let rows) = QuotaSnapshotPresentation(snapshot: legacy) else {
            Issue.record("Expected migrated legacy rows")
            return
        }
        #expect(rows.map(\.label) == ["5h", "Wk"])
    }

    @Test("Unknown windows use a neutral duration label")
    func unknownWindowPresentation() {
        let unknown = window(kind: .unknown, durationSeconds: 5 * 3_600)

        #expect(QuotaWindowDisplay.label(for: unknown) == "300m")
        #expect(QuotaWindowDisplay.label(for: unknown) != "5h")
        #expect(QuotaWindowDisplay.label(for: unknown).lowercased() != "weekly")
    }

    @Test("Global denial renders without a synthetic window")
    func deniedPresentation() {
        let denied = snapshot(allowed: false, limitReached: true, windows: [])
        let deniedWithoutLimit = snapshot(allowed: false, limitReached: nil, windows: [])

        #expect(
            QuotaSnapshotPresentation(snapshot: denied)
                == .denied(message: "Quota exhausted", windows: [])
        )
        #expect(
            QuotaSnapshotPresentation(snapshot: deniedWithoutLimit)
                == .denied(message: "Quota unavailable", windows: [])
        )
    }

    @Test("Exhausted weekly snapshot retains its natural reset row")
    func exhaustedWeeklyPresentationRetainsReset() {
        let weekly = window(kind: .weekly, durationSeconds: 7 * 86_400)
        let denied = snapshot(allowed: false, limitReached: true, windows: [weekly])

        guard case .denied(let message, let rows) = QuotaSnapshotPresentation(snapshot: denied) else {
            Issue.record("Expected denied quota presentation")
            return
        }
        #expect(message == "Quota exhausted")
        #expect(rows.count == 1)
        #expect(rows[0].label == "Wk")
        #expect(rows[0].resetsAt == weekly.resetsAt)
    }

    @Test("Successful windowless snapshots render as unknown")
    func windowlessPresentation() {
        let windowless = snapshot(allowed: true, limitReached: false, windows: [])

        #expect(QuotaSnapshotPresentation(snapshot: windowless) == .unknown("Quota unknown"))
    }

    private func snapshot(
        allowed: Bool? = true,
        limitReached: Bool? = false,
        windows: [QuotaWindow]
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            allowed: allowed,
            limitReached: limitReached,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            windows: windows
        )
    }

    private func window(kind: QuotaWindowKind, durationSeconds: Int) -> QuotaWindow {
        QuotaWindow(
            kind: kind,
            durationSeconds: durationSeconds,
            usedPercent: 25,
            resetsAt: Date(timeIntervalSince1970: 1_800_100_000),
            source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
        )
    }
}
