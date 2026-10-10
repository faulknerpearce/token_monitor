import SwiftUI

/// Equal-width tab grid at the top of the menu dropdown.
///
/// Tabs flow into rows capped at `maxPerRow` columns; with more enabled
/// providers than fit on one row, extra tabs wrap onto rows below. Every row
/// holds `maxPerRow` equal flexible cells (empty slots included), so each row
/// spans exactly the container width and columns line up across rows. Grid
/// lines are overlays outside the layout, so the outer border matches the
/// edges of the panel cards for any provider count.
struct ProviderSwitcherView: View {
    var providers: [MonitorProvider]
    @Binding var selection: MonitorProvider

    static let maxPerRow = 4
    private static let rowHeight: CGFloat = 28
    private static let lineColor = Color.primary.opacity(0.12)

    /// Providers chunked into rows of `maxPerRow`, padding the last row with nil.
    static func rows(for providers: [MonitorProvider]) -> [[MonitorProvider?]] {
        stride(from: 0, to: providers.count, by: maxPerRow).map { start in
            let row = Array(providers[start..<min(start + maxPerRow, providers.count)])
            var padded = row.map(Optional.init)
            padded.append(contentsOf: Array(repeating: nil, count: maxPerRow - row.count))
            return padded
        }
    }

    var body: some View {
        let rows = Self.rows(for: providers)
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 0) {
                    ForEach(rows[rowIndex].indices, id: \.self) { index in
                        cell(rows[rowIndex][index])
                            .overlay(alignment: .leading) {
                                // Divider only between two real tabs.
                                if index > 0, rows[rowIndex][index - 1] != nil {
                                    Self.lineColor.frame(width: 1)
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) {
                    if rowIndex > 0 {
                        Self.lineColor.frame(height: 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Self.lineColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func cell(_ provider: MonitorProvider?) -> some View {
        if let provider {
            tabButton(provider)
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight)
        }
    }

    private func tabButton(_ provider: MonitorProvider) -> some View {
        Button {
            selection = provider
        } label: {
            HStack(spacing: 4) {
                if provider != .overview {
                    Image(nsImage: ProviderLogo.image(for: provider))
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                }
                Text(provider.switcherLabel)
                    // Keep label geometry identical when selection changes.
                    .font(PanelTypography.caption)
                    .foregroundStyle(selection == provider ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(
                selection == provider
                    ? Color.primary.opacity(0.08)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
