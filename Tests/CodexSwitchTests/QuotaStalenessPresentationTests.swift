import Foundation
import Testing
@testable import CodexSwitch

@Suite("Stale quota presentation")
struct QuotaStalenessPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Readings within the freshness contract are not labeled stale")
    func freshReadingsHaveNoLabel() {
        #expect(QuotaFreshnessPolicy.staleAgeLabel(fetchedAt: now, now: now) == nil)
        #expect(QuotaFreshnessPolicy.staleAgeLabel(
            fetchedAt: now.addingTimeInterval(-QuotaFreshnessPolicy.maximumSnapshotAge),
            now: now
        ) == nil)
        // Clock skew is not presented as stale.
        #expect(QuotaFreshnessPolicy.staleAgeLabel(
            fetchedAt: now.addingTimeInterval(600),
            now: now
        ) == nil)
    }

    @Test("Stale readings use minutes, hours, then days")
    func staleLabelsScaleUnits() {
        func label(_ age: TimeInterval) -> String? {
            QuotaFreshnessPolicy.staleAgeLabel(fetchedAt: now.addingTimeInterval(-age), now: now)
        }
        #expect(label(QuotaFreshnessPolicy.maximumSnapshotAge + 1) == "as of 15 min ago")
        #expect(label(59 * 60) == "as of 59 min ago")
        #expect(label(3 * 3_600 + 120) == "as of 3 h ago")
        #expect(label(47 * 3_600) == "as of 47 h ago")
        // A months-old "limit reached" snapshot (the reported 2026-06-19 case).
        #expect(label(100 * 86_400) == "as of 100 d ago")
    }

    @Test("Card caption includes the polling error when present")
    func cardCaptionIncludesPollingError() {
        let stale = snapshot(fetchedAt: now.addingTimeInterval(-3 * 3_600))
        #expect(AccountCardView.staleQuotaLabel(for: stale, pollingError: nil, now: now)
            == "Stale usage — as of 3 h ago")
        #expect(AccountCardView.staleQuotaLabel(for: stale, pollingError: "", now: now)
            == "Stale usage — as of 3 h ago")
        #expect(AccountCardView.staleQuotaLabel(
            for: stale,
            pollingError: "Rate limits unavailable — keeping last known usage",
            now: now
        ) == "Stale usage — as of 3 h ago · Rate limits unavailable — keeping last known usage")
        #expect(AccountCardView.staleQuotaLabel(
            for: snapshot(fetchedAt: now.addingTimeInterval(-60)),
            pollingError: "Network error",
            now: now
        ) == nil)
    }

    @Test("Menu-bar tooltip marks stale readings")
    @MainActor
    func tooltipMarksStaleReadings() {
        #expect(StatusBarController.staleQuotaTooltipSuffix(
            for: snapshot(fetchedAt: now.addingTimeInterval(-2 * 3_600)),
            now: now
        ) == " (stale, as of 2 h ago)")
        #expect(StatusBarController.staleQuotaTooltipSuffix(
            for: snapshot(fetchedAt: now),
            now: now
        ).isEmpty)
    }

    private func snapshot(fetchedAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            allowed: false,
            limitReached: true,
            fetchedAt: fetchedAt,
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    durationSeconds: 7 * 24 * 60 * 60,
                    usedPercent: 100,
                    resetsAt: fetchedAt.addingTimeInterval(24 * 60 * 60),
                    source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
                ),
            ]
        )
    }
}
