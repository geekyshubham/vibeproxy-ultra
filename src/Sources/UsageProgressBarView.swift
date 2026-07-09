import SwiftUI

struct UsageQuotaRow: View {
    let title: String
    let remainingPercent: Double
    let resetText: String?
    let tint: Color

    private var clampedRemaining: Double {
        min(100, max(0, remainingPercent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(clampedRemaining.rounded()))% left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MenuBarDesign.usageTint(remainingPercent: clampedRemaining))
            }

            UsageProgressBarView(percent: clampedRemaining, tint: MenuBarDesign.usageTint(remainingPercent: clampedRemaining))

            if let resetText, !resetText.isEmpty {
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct UsageProgressBarView: View {
    let percent: Double
    let tint: Color

    private var clamped: Double {
        min(100, max(0, percent))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.95), tint.opacity(0.65)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, proxy.size.width * clamped / 100))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Usage \(Int(clamped)) percent remaining")
    }
}