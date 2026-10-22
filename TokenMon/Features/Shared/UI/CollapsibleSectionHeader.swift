import SwiftUI

/// A section header that opens and closes its section, with a chevron that
/// points down while open.
struct CollapsibleSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack {
                PanelSectionHeader(title: title)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}
