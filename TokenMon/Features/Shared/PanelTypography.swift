import SwiftUI

/// Shared type scale for menu-panel surfaces.
enum PanelTypography {
    /// Panel and major section titles.
    static let title = Font.system(size: 13, weight: .semibold)
    /// Primary body copy and list rows.
    static let body = Font.system(size: 12)
    static let bodySemibold = Font.system(size: 12, weight: .semibold)
    static let bodyDigit = Font.system(size: 12, weight: .semibold).monospacedDigit()
    /// Secondary captions, tags, resets, source labels.
    static let caption = Font.system(size: 11)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let captionSemibold = Font.system(size: 11, weight: .semibold)
    /// Chart axis / dense tertiary marks.
    static let micro = Font.system(size: 10)
    /// Stats-sheet label and value.
    static let metricLabel = Font.system(size: 14)
    static let metricValue = Font.system(size: 26, weight: .semibold)
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
            .foregroundStyle(.tertiary)
    }
}

/// A section header with an optional trailing usage figure, shown as plain
/// text (the bars carry the detail; the Overview cards keep `PanelPill`).
struct PanelSectionHeaderRow: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PanelSectionHeader(title: title)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(PanelTypography.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
