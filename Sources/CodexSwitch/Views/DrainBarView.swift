import SwiftUI

struct DrainBarView: View {
    let label: String
    let percent: Double       // 0-100 remaining
    let resetsAt: Date?
    var boostedContrast: Bool = false

    private static let resetFormatter: DateFormatter = {
        let f = DateFormatter()
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

    private var resetText: String {
        guard let resetsAt else { return "" }
        let remaining = resetsAt.timeIntervalSinceNow
        if remaining <= 0 { return "resetting..." }
        let hours = Int(remaining) / 3600
        let mins = (Int(remaining) % 3600) / 60
        let countdown = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        let dateStr = Self.resetFormatter.string(from: resetsAt)
        return "\(dateStr) (\(countdown))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(boostedContrast ? .primary : .secondary)
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
            if resetsAt != nil {
                Text(resetText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(boostedContrast ? .primary : .secondary)
            }
        }
    }
}
