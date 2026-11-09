import SwiftUI

/// Pointer-to-column math and the budget line for the daily bars' hover label.
enum DailyBudgetHover {
    /// The column under `x`, or nil outside the row.
    static func columnIndex(x: CGFloat, columnWidth: CGFloat, columns: Int) -> Int? {
        guard columns >= 1, columnWidth > 0, x >= 0 else { return nil }
        let index = Int(x / columnWidth)
        return index < columns ? index : nil
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
        HoverLabelCard {
            HoverLabelTitle(text: Format.date(day.date, dateFormat: "EEEE, MMM d"))
            if !isFuture {
                HoverLabelCaption(text: DailyBudgetHover.usageLine(day, allowanceNoun: allowanceNoun))
            }
            if let tokens = day.tokens, tokens.totalTokens > 0 {
                tokenDetail(tokens)
            }
        }
    }

    @ViewBuilder
    private func tokenDetail(_ tokens: DailyTokenUsage) -> some View {
        HoverLabelDivider()
        HoverLabelTokenTotal(tokens: tokens.totalTokens, valueText: Self.valueText(tokens))
        HoverLabelRows(
            rows: HoverLabelRow.breakdown(
                input: tokens.inputTokens,
                output: tokens.outputTokens,
                cacheRead: tokens.cacheReadTokens,
                cacheWrite: tokens.cacheWriteTokens
            )
        )
        if !tokens.models.isEmpty {
            HoverLabelDivider()
            HoverLabelRows(rows: tokens.models.prefix(Self.maxModels).map { .tokens($0.name, $0.tokens) })
        }
    }

    /// "≈ $12.40", with a trailing "+" when unpriced usage is left out; nil
    /// when nothing was spent.
    static func valueText(_ tokens: DailyTokenUsage) -> String? {
        guard let cost = tokens.costUSD, cost > 0 else { return nil }
        return "≈ " + Format.usd(cost) + (tokens.hasUnpriced ? "+" : "")
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
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .floatingHoverLabel(hoveredIndex: hoveredIndex) { pointer, size in
                DailyBudgetHover.columnIndex(
                    x: pointer.x,
                    columnWidth: days.isEmpty ? 0 : size.width / CGFloat(days.count),
                    columns: days.count
                )
            } label: { index in
                if days.indices.contains(index) {
                    DailyBudgetHoverLabel(
                        day: days[index],
                        allowanceNoun: allowanceNoun,
                        isFuture: days[index].date > Calendar.current.startOfDay(for: Date())
                    )
                }
            }
    }

    /// Outlines a bar's stem while its column is hovered.
    func hoverOutline(_ isHovered: Bool, cornerRadius: CGFloat = PanelChartStem.cornerRadius) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.35 : 0), lineWidth: 1)
        )
    }
}
