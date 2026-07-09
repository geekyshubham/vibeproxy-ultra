import SwiftUI

struct UsageQuotaRow: View {
    let title: String
    let usedPercent: Double
    let resetText: String?
    let tint: Color
    /// When set, overrides percent-only headline (e.g. "10,000 credits left").
    var metricText: String? = nil
    /// When true, show used% primary (CodexBar-style); otherwise remaining.
    var showUsedPrimary: Bool = true

    private var clampedUsed: Double {
        min(100, max(0, usedPercent))
    }

    private var remaining: Double {
        max(0, 100 - clampedUsed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(metricText ?? percentLabel)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(MenuBarDesign.usageTint(remainingPercent: remaining))
                    .multilineTextAlignment(.trailing)
            }

            // Fill represents *used* (grows as you burn quota) — CodexBar convention.
            UsageProgressBarView(
                percent: clampedUsed,
                tint: MenuBarDesign.usageTint(remainingPercent: remaining),
                fillRepresentsUsed: true
            )

            if let resetText, !resetText.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9, weight: .semibold))
                    Text(resetText)
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var percentLabel: String {
        let usedText: String
        if clampedUsed > 0, clampedUsed < 1 {
            usedText = "<1% used"
        } else {
            usedText = "\(Int(clampedUsed.rounded()))% used"
        }
        let leftText: String
        if remaining > 0, remaining < 1 {
            leftText = "<1% left"
        } else {
            leftText = "\(Int(remaining.rounded()))% left"
        }
        if showUsedPrimary {
            return "\(usedText) · \(leftText)"
        }
        return "\(leftText) · \(usedText)"
    }
}

struct UsageProgressBarView: View {
    let percent: Double
    let tint: Color
    var fillRepresentsUsed: Bool = true

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
                            colors: [tint.opacity(0.95), tint.opacity(0.55)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, proxy.size.width * clamped / 100))
                    .animation(.easeOut(duration: 0.35), value: clamped)
            }
        }
        .frame(height: 7)
        .accessibilityLabel(
            fillRepresentsUsed
                ? "Usage \(Int(clamped)) percent used"
                : "Usage \(Int(clamped)) percent remaining"
        )
    }
}
