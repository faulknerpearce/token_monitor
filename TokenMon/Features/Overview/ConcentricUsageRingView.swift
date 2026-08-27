import SwiftUI

/// Thin concentric usage rings with a quiet percent list beside them.
/// Outer → inner: Grok, Cursor, OpenCode.
struct ConcentricUsageRingView: View {
    let grokPercent: Double?
    let openCodePercent: Double?
    let cursorPercent: Double?

    static let grokColor = SRGB(red: 0.11, green: 0.38, blue: 0.82).color.opacity(0.85)
    static let openCodeColor = ModelPalette.orange.color.opacity(0.78)
    /// Canonical Cursor sRGB — expose the raw components (not just the blended `Color`)
    /// so other renderers (e.g. the menu bar icon) derive from one source instead of
    /// hand-typing a second literal that can drift out of sync.
    static let cursorSRGB = SRGB(red: 0.18, green: 0.53, blue: 0.38)
    static let cursorColor = cursorSRGB.color.opacity(0.85)
    static let claudeSRGB = SRGB(red: 0.85, green: 0.47, blue: 0.34)
    static let claudeColor = claudeSRGB.color.opacity(0.85)
    static let chatgptColor = SRGB(red: 0.16, green: 0.52, blue: 0.46).color.opacity(0.85)
    static let openRouterColor = SRGB(red: 0.45, green: 0.36, blue: 0.90).color.opacity(0.85)
    /// Grok Bot is a monochrome brand; a graphite that stays legible as a bar fill
    /// and does not collide with Grok navy or Cursor green.
    static let grokbotSRGB = SRGB(red: 0.38, green: 0.42, blue: 0.50)
    static let grokbotColor = grokbotSRGB.color.opacity(0.85)

    private let size: CGFloat = 112
    private let lineWidth: CGFloat = 8
    private let ringGap: CGFloat = 5

    private var pitch: CGFloat { lineWidth + ringGap }
    private var outerDiameter: CGFloat { size - 10 }
    private var middleDiameter: CGFloat { outerDiameter - 2 * pitch }
    private var innerDiameter: CGFloat { outerDiameter - 4 * pitch }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Spacer(minLength: 0)
            ZStack {
                ring(percent: grokPercent, color: Self.grokColor, diameter: outerDiameter)
                ring(percent: cursorPercent, color: Self.cursorColor, diameter: middleDiameter)
                ring(percent: openCodePercent, color: Self.openCodeColor, diameter: innerDiameter)
            }
            .frame(width: size, height: size)

            VStack(alignment: .leading, spacing: 12) {
                quietStat(name: "Grok", value: percentText(grokPercent), color: Self.grokColor)
                quietStat(name: "Cursor", value: percentText(cursorPercent), color: Self.cursorColor)
                quietStat(name: "OpenCode", value: percentText(openCodePercent), color: Self.openCodeColor)
            }
            .frame(minWidth: 120)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func quietStat(name: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .font(PanelTypography.caption)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(value)
                    .font(PanelTypography.captionSemibold)
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
        }
    }

    private func ring(percent: Double?, color: Color, diameter: CGFloat) -> some View {
        let trimmed = Percent.clamp(percent ?? 0) / 100
        return ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(trimmed))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.35), value: trimmed)
        }
        .frame(width: diameter, height: diameter)
    }

    private func percentText(_ percent: Double?) -> String {
        if let percent {
            return "\(Int(percent.rounded()))%"
        }
        return "—"
    }
}
