import SwiftUI

/// Equal-width tab grid at the top of the menu dropdown.
///
/// Tabs flow into rows capped at `maxPerRow` columns; with more enabled
/// providers than fit on one row, extra tabs wrap onto rows below. Every cell
/// is exactly `containerWidth / maxPerRow` wide regardless of label or
/// selection state, so tabs never resize when clicked.
struct ProviderSwitcherView: View {
    var providers: [MonitorProvider]
    @Binding var selection: MonitorProvider

    private static let maxPerRow = 4
    private static let rowHeight: CGFloat = 28

    private var rows: [[MonitorProvider?]] {
        stride(from: 0, to: providers.count, by: Self.maxPerRow).map { start in
            let row = Array(providers[start..<min(start + Self.maxPerRow, providers.count)])
            var padded = row.map(Optional.init)
            padded.append(contentsOf: Array(repeating: nil, count: Self.maxPerRow - row.count))
            return padded
        }
    }

    private var gridHeight: CGFloat {
        CGFloat(rows.count) * Self.rowHeight + CGFloat(rows.count - 1)
    }

    var body: some View {
        GeometryReader { geo in
            // Subtract one point per intra-row divider so columns align across rows.
            let cellWidth = (geo.size.width - CGFloat(Self.maxPerRow - 1)) / CGFloat(Self.maxPerRow)
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { rowIndex in
                    if rowIndex > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(height: 1)
                    }
                    HStack(spacing: 0) {
                        ForEach(rows[rowIndex].indices, id: \.self) { index in
                            if index > 0, rows[rowIndex][index - 1] != nil {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.12))
                                    .frame(width: 1)
                            }
                            if let provider = rows[rowIndex][index] {
                                tabButton(provider)
                                    .frame(width: cellWidth, height: Self.rowHeight)
                            } else {
                                Color.clear
                                    .frame(width: cellWidth, height: Self.rowHeight)
                            }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .frame(height: gridHeight)
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
