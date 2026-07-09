import SwiftUI

enum MenuBarDesign {
    static let panelWidth: CGFloat = 360
    static let panelMaxHeight: CGFloat = 720
    static let cornerRadius: CGFloat = 14
    static let cardCornerRadius: CGFloat = 10
    static let cardPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 10

    static let accent = Color(red: 0.35, green: 0.55, blue: 1.0)
    static let success = Color(red: 0.22, green: 0.78, blue: 0.45)
    static let warning = Color(red: 0.95, green: 0.62, blue: 0.18)
    static let danger = Color(red: 0.92, green: 0.28, blue: 0.28)

    static func providerTint(for serviceType: ServiceType) -> Color {
        switch serviceType {
        case .claude: return Color(red: 0.87, green: 0.52, blue: 0.33)
        case .codex: return Color(red: 0.16, green: 0.67, blue: 0.49)
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .copilot: return Color(red: 0.35, green: 0.35, blue: 0.95)
        case .antigravity: return Color(red: 0.55, green: 0.36, blue: 0.96)
        case .kimi: return Color(red: 0.42, green: 0.56, blue: 0.98)
        case .kiro: return Color(red: 0.98, green: 0.45, blue: 0.22)
        case .grok: return Color(red: 0.15, green: 0.15, blue: 0.18)
        case .qwen: return Color(red: 0.45, green: 0.25, blue: 0.95)
        case .zai: return Color(red: 0.18, green: 0.72, blue: 0.62)
        case .cursor: return Color(red: 0.95, green: 0.75, blue: 0.20)
        case .codebuddy: return Color(red: 0.10, green: 0.55, blue: 0.95)
        case .gitlab: return Color(red: 0.88, green: 0.30, blue: 0.22)
        case .kilo: return Color(red: 0.35, green: 0.75, blue: 0.45)
        }
    }

    static func usageTint(remainingPercent: Double) -> Color {
        if remainingPercent > 50 { return success }
        if remainingPercent > 20 { return warning }
        return danger
    }
}

struct GlassPanelBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: MenuBarDesign.cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: MenuBarDesign.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

struct GlassCardBackground: View {
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: MenuBarDesign.cardCornerRadius, style: .continuous)
            .fill(tint.opacity(0.08))
            .background(
                RoundedRectangle(cornerRadius: MenuBarDesign.cardCornerRadius, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MenuBarDesign.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            )
    }
}