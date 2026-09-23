import SwiftUI

extension Color {
    static func product(_ token: ProductColor) -> Color {
        token.sRGB.color
    }

    static let usageRemainingTrack = Color.primary.opacity(0.12)
}

/// Weekly pool bar: label row above, gapped rounded segments, muted remainder track.
struct SegmentedUsageBar: View {
    let products: [ProductUsage]
    var height: CGFloat = 8

    private let segmentGap: CGFloat = 2
    private let minSegmentWidth: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let visible = products.filter { $0.percentOfPool > 0.05 }
            let used = min(100, visible.reduce(0.0) { $0 + max(0, $1.percentOfPool) })
            let remainder = max(0, 100 - used)
            let slotCount = visible.count + (remainder > 0.5 ? 1 : 0)
            let gapTotal = segmentGap * CGFloat(max(0, slotCount - 1))
            let usable = max(0, geo.size.width - gapTotal)

            let widths = Self.segmentWidths(
                percents: visible.map(\.percentOfPool) + (remainder > 0.5 ? [remainder] : []),
                usable: usable,
                minWidth: minSegmentWidth
            )

            HStack(spacing: segmentGap) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, product in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.product(product.colorToken))
                        .frame(width: widths[index], height: height)
                }
                if remainder > 0.5, let remainderWidth = widths.last {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.usageRemainingTrack)
                        .frame(width: remainderWidth, height: height)
                }
            }
        }
        .frame(height: height)
    }

    /// Segment widths that sum to at most `usable`: proportional to `percents`,
    /// each floored at `minWidth`, then scaled down when the floors together
    /// overflow the track (several tiny slices would otherwise compress or spill
    /// past `usable`).
    static func segmentWidths(percents: [Double], usable: CGFloat, minWidth: CGFloat) -> [CGFloat] {
        let clamped = percents.map { max(minWidth, usable * CGFloat(max(0, $0) / 100)) }
        let total = clamped.reduce(0, +)
        guard usable > 0, total > usable else { return clamped }
        let scale = usable / total
        return clamped.map { $0 * scale }
    }
}
