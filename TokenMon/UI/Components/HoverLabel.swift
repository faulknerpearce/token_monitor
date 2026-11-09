import SwiftUI

/// Building blocks of the panel's floating hover labels: the card, its title
/// and caption lines, the token total with its API-rate value, and the token
/// breakdown rows. The daily bars and the Claude model rows build their labels
/// from these so every hover label looks the same.
struct HoverLabelCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

/// The label's first line, naming what it describes (a day, a model).
struct HoverLabelTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PanelTypography.captionSemibold)
            .foregroundStyle(.primary)
    }
}

/// A secondary one-line summary under the title.
struct HoverLabelCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PanelTypography.caption)
            .foregroundStyle(.secondary)
    }
}

/// The faint rule between a label's sections.
struct HoverLabelDivider: View {
    var body: some View {
        Divider().opacity(0.4)
    }
}

/// A large token total, with its API-rate value ("≈ $12.40") on the right
/// when there is one.
struct HoverLabelTokenTotal: View {
    let tokens: Int64
    /// The value text, already prefixed ("≈ $12.40"); nil leaves it out.
    var valueText: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(Format.tokens(tokens))
                .font(PanelTypography.title.monospacedDigit())
                .foregroundStyle(.primary)
            Text("tokens")
                .font(PanelTypography.caption)
                .foregroundStyle(.secondary)
            if let valueText {
                Spacer(minLength: 10)
                Text(valueText)
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One label/value row of a ``HoverLabelRows`` grid.
struct HoverLabelRow: Hashable, Sendable {
    var label: String
    var value: String

    /// A row counting tokens, e.g. "Input" / "1.2M".
    static func tokens(_ label: String, _ count: Int64) -> Self {
        Self(label: label, value: Format.tokens(count))
    }

    /// Input, output, cache read, and cache write rows, in that order.
    static func breakdown(input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64) -> [Self] {
        [
            .tokens("Input", input),
            .tokens("Output", output),
            .tokens("Cache read", cacheRead),
            .tokens("Cache write", cacheWrite)
        ]
    }
}

/// Label/value rows in two columns, values right-aligned.
struct HoverLabelRows: View {
    let rows: [HoverLabelRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.label)
                        .font(PanelTypography.caption)
                        .foregroundStyle(.secondary)
                    Text(row.value)
                        .font(PanelTypography.microDigit)
                        .foregroundStyle(.primary)
                        .gridColumnAlignment(.trailing)
                }
            }
        }
    }
}
