import SwiftUI

/// Compact Grok product chip: color mark, short name, and percent of the weekly pool.
struct CategoryRow: View {
    let product: ProductUsage

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.product(product.colorToken))
                .frame(width: 7, height: 7)
            Text(ProductCatalog.shortName(for: product.id))
                .font(PanelTypography.bodySemibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("\(Int(product.percentOfPool.rounded()))%")
                .font(PanelTypography.bodyDigit)
                .foregroundStyle(.primary)
        }
    }
}
