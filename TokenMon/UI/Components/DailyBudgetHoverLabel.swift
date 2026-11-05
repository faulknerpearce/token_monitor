import SwiftUI

/// Pointer-to-column and label placement math for the daily bars' hover label.
enum DailyBudgetHover {
    /// The column under `x`, or nil outside the row.
    static func columnIndex(x: CGFloat, columnWidth: CGFloat, columns: Int) -> Int? {
        guard columns >= 1, columnWidth > 0, x >= 0 else { return nil }
        let index = Int(x / columnWidth)
        return index < columns ? index : nil
    }

    /// Gap between the pointer and the label.
    static let pointerGap: CGFloat = 14

    /// Top-left corner of a label floating beside `pointer`: to its left when
    /// it fits, else to its right, else pinned inside the container's width;
    /// vertically centered on the pointer.
    static func labelOrigin(pointer: CGPoint, labelSize: CGSize, containerWidth: CGFloat) -> CGPoint {
        let left = pointer.x - pointerGap - labelSize.width
        let right = pointer.x + pointerGap
        let x: CGFloat
        if left >= 0 {
            x = left
        } else if right + labelSize.width <= containerWidth {
            x = right
        } else {
            x = max(0, min(left, containerWidth - labelSize.width))
        }
        return CGPoint(x: x, y: pointer.y - labelSize.height / 2)
    }

    /// The label's one-line budget summary for `day`.
    static func usageLine(_ day: DailyBudgetDay, allowanceNoun: String) -> String {
        if day.isPriorWindow {
            return String(format: "%.1f%% of the %@ pool before the provider reset it early", day.spentUSD, allowanceNoun)
        }
        if day.budgetUSD <= 0 { return "No budget" }
        if day.spentUSD <= 0.001 { return String(format: "0%% of the %.1f%% daily allowance", day.budgetUSD) }
        let ofAllowance = Int((day.spentUSD / day.budgetUSD * 100).rounded())
        return String(format: "%.1f%% of %@ · %d%% of daily allowance", day.spentUSD, allowanceNoun, ofAllowance)
    }
}

/// Floating detail for one day: date, budget use, and the day's tokens when
/// the provider counts them.
struct DailyBudgetHoverLabel: View {
    let day: DailyBudgetDay
    var allowanceNoun: String
    var isFuture = false

    /// Models listed by name; the rest are left out.
    private static let maxModels = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Format.date(day.date, dateFormat: "EEEE, MMM d"))
                .font(PanelTypography.captionSemibold)
                .foregroundStyle(.primary)
            if !isFuture {
                Text(DailyBudgetHover.usageLine(day, allowanceNoun: allowanceNoun))
                    .font(PanelTypography.caption)
                    .foregroundStyle(.secondary)
            }
            if let tokens = day.tokens, tokens.totalTokens > 0 {
                tokenDetail(tokens)
            }
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

    @ViewBuilder
    private func tokenDetail(_ tokens: DailyTokenUsage) -> some View {
        Divider().opacity(0.4)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(Format.tokens(tokens.totalTokens))
                .font(PanelTypography.title.monospacedDigit())
                .foregroundStyle(.primary)
            Text("tokens")
                .font(PanelTypography.caption)
                .foregroundStyle(.secondary)
            if let cost = tokens.costUSD, cost > 0 {
                Spacer(minLength: 10)
                Text("≈ " + Format.usd(cost) + (tokens.hasUnpriced ? "+" : ""))
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.secondary)
            }
        }
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 1) {
            tokenRow("Input", tokens.inputTokens)
            tokenRow("Output", tokens.outputTokens)
            tokenRow("Cache read", tokens.cacheReadTokens)
            tokenRow("Cache write", tokens.cacheWriteTokens)
        }
        if !tokens.models.isEmpty {
            Divider().opacity(0.4)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 1) {
                ForEach(tokens.models.prefix(Self.maxModels), id: \.self) { model in
                    tokenRow(model.name, model.tokens)
                }
            }
        }
    }

    private func tokenRow(_ label: String, _ count: Int64) -> some View {
        GridRow {
            Text(label)
                .font(PanelTypography.caption)
                .foregroundStyle(.secondary)
            Text(Format.tokens(count))
                .font(PanelTypography.microDigit)
                .foregroundStyle(.primary)
                .gridColumnAlignment(.trailing)
        }
    }
}

/// Hover tracking for a row of equal-width day columns: reports the column
/// under the pointer and floats a ``DailyBudgetHoverLabel`` for it beside the
/// pointer. Shared by every daily bar chart.
private struct DailyBarsHoverModifier: ViewModifier {
    let days: [DailyBudgetDay]
    let allowanceNoun: String
    @Binding var hoveredIndex: Int?

    /// Pointer position in the row while it hovers there.
    @State private var location: CGPoint?
    /// Measured size of the label, for placing it beside the pointer.
    @State private var labelSize: CGSize = .zero

    func body(content: Content) -> some View {
        GeometryReader { geo in
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(point):
                        location = point
                        hoveredIndex = DailyBudgetHover.columnIndex(
                            x: point.x,
                            columnWidth: days.isEmpty ? 0 : geo.size.width / CGFloat(days.count),
                            columns: days.count
                        )
                    case .ended:
                        location = nil
                        hoveredIndex = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let hoveredIndex, let location, days.indices.contains(hoveredIndex) {
                        label(for: days[hoveredIndex], at: location, containerWidth: geo.size.width)
                    }
                }
        }
    }

    private func label(for day: DailyBudgetDay, at pointer: CGPoint, containerWidth: CGFloat) -> some View {
        let origin = DailyBudgetHover.labelOrigin(
            pointer: pointer,
            labelSize: labelSize,
            containerWidth: containerWidth
        )
        return DailyBudgetHoverLabel(
            day: day,
            allowanceNoun: allowanceNoun,
            isFuture: day.date > Calendar.current.startOfDay(for: Date())
        )
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            labelSize = size
        }
        // Hidden until measured, so it never flashes at the corner.
        .opacity(labelSize == .zero ? 0 : 1)
        .offset(x: origin.x, y: origin.y)
        .allowsHitTesting(false)
    }
}

extension View {
    /// Floats a day's detail label beside the pointer over this row of
    /// `days.count` equal-width columns, and reports the hovered column.
    func dailyBarsHover(
        days: [DailyBudgetDay],
        allowanceNoun: String,
        hoveredIndex: Binding<Int?>
    ) -> some View {
        modifier(DailyBarsHoverModifier(days: days, allowanceNoun: allowanceNoun, hoveredIndex: hoveredIndex))
    }

    /// Outlines a bar's stem while its column is hovered.
    func hoverOutline(_ isHovered: Bool, cornerRadius: CGFloat = PanelChartStem.cornerRadius) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.35 : 0), lineWidth: 1)
        )
    }
}
