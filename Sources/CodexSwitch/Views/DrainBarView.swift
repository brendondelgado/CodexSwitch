import SwiftUI

struct QuotaWindowDisplay: Equatable {
    let kind: QuotaWindowKind
    let label: String
    let percent: Double
    let resetsAt: Date

    init(window: QuotaWindow) {
        kind = window.kind
        label = Self.label(for: window)
        percent = window.effectiveRemainingPercent
        resetsAt = window.resetsAt
    }

    static func label(for window: QuotaWindow) -> String {
        switch window.kind {
        case .fiveHour:
            return "5h"
        case .weekly:
            return "Wk"
        case .unknown:
            return neutralDurationLabel(seconds: window.durationSeconds)
        }
    }

    private static func neutralDurationLabel(seconds: Int) -> String {
        guard seconds > 0 else { return "Window" }
        if seconds.isMultiple(of: 86_400) {
            return "\(seconds / 86_400)d"
        }
        if seconds >= 60 {
            return "\((seconds + 59) / 60)m"
        }
        return "\(seconds)s"
    }
}

enum QuotaSnapshotPresentation: Equatable {
    case windows([QuotaWindowDisplay])
    case denied(message: String, windows: [QuotaWindowDisplay])
    case unknown(String)

    init(snapshot: QuotaSnapshot) {
        let rows = snapshot.orderedWindows.map(QuotaWindowDisplay.init)
        if snapshot.isDenied {
            self = .denied(
                message: snapshot.limitReached == true ? "Quota exhausted" : "Quota unavailable",
                windows: rows
            )
            return
        }

        self = rows.isEmpty ? .unknown("Quota unknown") : .windows(rows)
    }
}

struct DrainBarView: View {
    let label: String
    let percent: Double       // 0-100 remaining
    let resetsAt: Date?
    var boostedContrast: Bool = false
    static let countdownRefreshInterval: TimeInterval = 30

    private static let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE M/d @ h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    private var fillFraction: CGFloat { CGFloat(max(0, min(100, percent))) / 100 }

    private var barColor: Color {
        switch percent {
        case 50...: return .green
        case 20..<50: return .yellow
        case 5..<20: return .orange
        default: return .red
        }
    }

    static func resetText(percent: Double, resetsAt: Date?, now: Date = Date()) -> String {
        guard let resetsAt else { return "" }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 {
            return percent <= 1 ? "confirming reset" : ""
        }
        let hours = Int(remaining) / 3600
        let mins = (Int(remaining) % 3600) / 60
        let countdown = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        let dateStr = Self.resetFormatter.string(from: resetsAt)
        return "\(dateStr) (\(countdown))"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.countdownRefreshInterval)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let liveResetText = Self.resetText(percent: percent, resetsAt: resetsAt, now: now)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(boostedContrast ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 34, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor)
                            .frame(width: geo.size.width * fillFraction)
                            .animation(.easeInOut(duration: 0.5), value: fillFraction)
                    }
                }
                .frame(height: 8)
                Text("\(Int(percent))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .frame(width: 32, alignment: .trailing)
            }
            if !liveResetText.isEmpty {
                Text(liveResetText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(boostedContrast ? .primary : .secondary)
            }
        }
    }
}
