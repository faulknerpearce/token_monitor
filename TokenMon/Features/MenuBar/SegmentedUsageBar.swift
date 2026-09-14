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

            HStack(spacing: segmentGap) {
                ForEach(visible) { product in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.product(product.colorToken))
                        .frame(
                            width: max(
                                minSegmentWidth,
                                usable * CGFloat(product.percentOfPool / 100)
                            ),
                            height: height
                        )
                }
                if remainder > 0.5 {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.usageRemainingTrack)
                        .frame(width: max(minSegmentWidth, usable * CGFloat(remainder / 100)), height: height)
                }
            }
        }
        .frame(height: height)
    }
}
