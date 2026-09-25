import SwiftUI

/// Shared type scale for menu-panel surfaces.
enum PanelTypography {
    /// Panel and major section titles.
    static let title = Font.system(size: 13, weight: .semibold)
    /// Primary body copy and list rows.
    static let body = Font.system(size: 12)
    static let bodySemibold = Font.system(size: 12, weight: .semibold)
    static let bodyDigit = Font.system(size: 12, weight: .semibold).monospacedDigit()
    /// Compact chart data label (daily bars): `bodyDigit` treatment at micro size.
    static let microDigit = Font.system(size: 10, weight: .semibold).monospacedDigit()
    /// Secondary captions, tags, resets, source labels.
    static let caption = Font.system(size: 11)
    static let captionSemibold = Font.system(size: 11, weight: .semibold)
    /// Chart axis / dense tertiary marks.
    static let micro = Font.system(size: 10)
    /// Stats-sheet label and value.
    static let metricLabel = Font.system(size: 12)
    static let metricValue = Font.system(size: 18, weight: .semibold)
}

/// Shared vertical-stem size for Grok daily bars and Overview hourly bars.
enum PanelChartStem {
    static let height: CGFloat = 68
    static let width: CGFloat = 12
    static let cornerRadius: CGFloat = 5
}

/// Tracked uppercase section label used on provider panel blocks.
struct PanelSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(PanelTypography.micro)
            .fontWeight(.semibold)
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

/// A section header with an optional trailing usage figure, shown as plain
/// text (the bars carry the detail).
struct PanelSectionHeaderRow: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PanelSectionHeader(title: title)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.primary)
            }
        }
    }
}

/// Small tracked style for card metadata — the billing period
/// ("— WEEKLY" / "— MONTHLY"), the usage figure, and provider plan/source
/// labels. Apply with `Text(...).panelMetaLabel()`.
struct PanelMetaLabelStyle: ViewModifier {
    var uppercased: Bool = false

    func body(content: Content) -> some View {
        content
            .font(PanelTypography.micro)
            .fontWeight(.semibold)
            .tracking(uppercased ? 1.6 : 0)
            .textCase(uppercased ? .uppercase : nil)
            .foregroundStyle(.secondary)
    }
}

extension View {
    func panelMetaLabel(uppercased: Bool = false) -> some View {
        modifier(PanelMetaLabelStyle(uppercased: uppercased))
    }
}

/// Reset / period sub-caption shown under a usage bar. Apply with
/// `Text(...).resetCaption()`.
struct ResetCaptionStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(PanelTypography.metricLabel)
            .foregroundStyle(.tertiary)
    }
}

extension View {
    func resetCaption() -> some View {
        modifier(ResetCaptionStyle())
    }
}
