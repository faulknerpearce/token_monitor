import SwiftUI

/// What the hover label, and the row's accessibility label, say about one of
/// this month's Claude models: its month total and breakdown, and how it
/// compares with last month.
///
/// Last month is compared only as far as the ledger covers it (see
/// ``ClaudeMonthCoverage``): a partly recorded month is named by the days it
/// covers ("Oct 9–31"), and a month with no record gives no comparison.
struct ClaudeModelHoverDetail: Hashable, Sendable {
    /// Model and month, e.g. "Opus 5.5 · November".
    var title: String
    /// This month's tokens.
    var tokens: Int64
    /// This month's API-rate value ("≈ $1,712.45"), or "No price".
    var valueText: String
    /// Input, output, cache read, and cache write tokens this month.
    var breakdown: [HoverLabelRow]
    /// Last month's tokens and value, e.g. "October: 1.4M tokens · ≈ $1,500.05";
    /// nil when there is nothing recorded to show.
    var previousLine: String?
    /// The change against last month, e.g. "↑ 14% · +$212.40 vs October".
    var changeLine: String
    /// All of the above as one sentence list for VoiceOver.
    var accessibilityLabel: String

    init(model: ClaudeModelUsage, summary: ClaudeCodeUsageSummary) {
        let name = ClaudeModelName.display(model.modelID)
        let month = summary.currentMonth.name
        let comparison = Comparison(model: model, summary: summary)
        title = "\(name) · \(month)"
        tokens = model.tokens.totalTokens
        valueText = model.isUnpriced ? "No price" : "≈ " + Self.usd(model.costUSD)
        breakdown = HoverLabelRow.breakdown(
            input: model.tokens.inputTokens,
            output: model.tokens.outputTokens,
            cacheRead: model.tokens.cacheReadTokens,
            cacheWrite: model.tokens.cacheWrite5mTokens + model.tokens.cacheWrite1hTokens
        )
        previousLine = comparison.previousLine
        changeLine = comparison.changeLine
        let value = model.isUnpriced ? "no listed price" : "about " + Self.usd(model.costUSD)
        let rows = breakdown.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
        accessibilityLabel = [
            "\(name), \(month): \(Format.tokens(tokens)) tokens, \(value)",
            rows,
            comparison.spokenPrevious,
            comparison.spokenChange
        ]
        .compactMap { $0 }
        .joined(separator: ". ")
    }

    /// A dollar value, with "<$0.01" for one that would otherwise read
    /// "$0.00" although something was spent.
    static func usd(_ cost: Double) -> String {
        cost > 0 && cost < 0.005 ? "<" + Format.usd(0.01) : Format.usd(cost)
    }

    /// The last-month lines, shown and spoken.
    private struct Comparison {
        var previousLine: String?
        var spokenPrevious: String?
        var changeLine: String
        var spokenChange: String

        init(model: ClaudeModelUsage, summary: ClaudeCodeUsageSummary) {
            let previous = summary.previousMonth
            let period: String
            switch summary.previousMonthCoverage {
            case .complete:
                period = previous.name
            case let .partial(since):
                period = previous.span(from: since)
            case let .none(recordedSince):
                let since = recordedSince.map { " (recorded since \(summary.currentMonth.shortDate($0)))" } ?? ""
                self.init(unchanging: "No \(previous.name) history\(since)")
                return
            }
            guard let previousTokens = summary.previousMonthModels[model.modelID] else {
                // A model missing from a partly recorded month may have been
                // used on the days before the record starts.
                let isComplete = summary.previousMonthCoverage == .complete
                self.init(unchanging: isComplete ? MonthlyUsageChange.new.summary(versus: period, unit: .usd)
                    : "No usage recorded \(period)")
                return
            }
            self.init(model: model, previousTokens: previousTokens, period: period)
        }

        /// A comparison with only a change line, the same shown and spoken.
        private init(unchanging line: String) {
            changeLine = line
            spokenChange = line
        }

        private init(model: ClaudeModelUsage, previousTokens: ClaudeModelTokens, period: String) {
            let unit: MonthlyUsageChange.Unit = model.isUnpriced ? .tokens : .usd
            let tokens = "\(period): \(Format.tokens(previousTokens.totalTokens)) tokens"
            let change: MonthlyUsageChange
            switch unit {
            case .usd:
                let cost = ClaudeAPIPricing.cost(of: previousTokens, modelID: model.modelID) ?? 0
                change = .between(previous: cost, current: model.costUSD, unit: .usd)
                previousLine = "\(tokens) · ≈ \(ClaudeModelHoverDetail.usd(cost))"
                spokenPrevious = "\(tokens), about \(ClaudeModelHoverDetail.usd(cost))"
            case .tokens:
                change = .between(
                    previous: Double(previousTokens.totalTokens),
                    current: Double(model.tokens.totalTokens),
                    unit: .tokens
                )
                previousLine = tokens
                spokenPrevious = tokens
            }
            changeLine = change.summary(versus: period, unit: unit)
            spokenChange = change.spokenSummary(versus: period, unit: unit)
        }
    }
}

/// Floating detail for one of this month's Claude models, in the same style
/// as the daily bars' label.
struct ClaudeModelHoverLabel: View {
    let detail: ClaudeModelHoverDetail

    var body: some View {
        HoverLabelCard {
            HoverLabelTitle(text: detail.title)
            HoverLabelDivider()
            HoverLabelTokenTotal(tokens: detail.tokens, valueText: detail.valueText)
            HoverLabelRows(rows: detail.breakdown)
            HoverLabelDivider()
            if let previousLine = detail.previousLine {
                HoverLabelCaption(text: previousLine)
            }
            HoverLabelTitle(text: detail.changeLine)
        }
    }
}
