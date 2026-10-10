import AppKit
import SwiftUI

/// Quiet label-above-value cell for the 2×2 stats sheet.
struct MetricStat: View {
    let title: String
    let value: String
    var monospaced: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelSectionHeader(title: title)
            Group {
                if monospaced {
                    Text(value).monospacedDigit()
                } else {
                    Text(value)
                }
            }
            .font(PanelTypography.bodyDigit)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Unboxed 2×2 type sheet with a full-height / full-width hairline cross.
struct MetricStatGrid: View {
    let stats: [MetricStat]

    init(_ stats: [MetricStat]) {
        self.stats = stats
    }

    var body: some View {
        let top = Array(stats.prefix(2))
        let bottom = Array(stats.dropFirst(2).prefix(2))
        ZStack {
            VStack(spacing: 0) {
                row(top)
                row(bottom)
            }
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ cells: [MetricStat]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                cell
            }
        }
    }
}
