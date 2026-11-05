import SwiftUI

/// Pointer-to-column and label placement math for the daily bars' hover label.
enum DailyBudgetHover {
    /// The column under `x`, or nil outside the row.
    static func columnIndex(x: CGFloat, columnWidth: CGFloat, count: Int) -> Int? {
        guard count > 0, columnWidth > 0, x >= 0 else { return nil }
        let index = Int(x / columnWidth)
        return index < count ? index : nil
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
