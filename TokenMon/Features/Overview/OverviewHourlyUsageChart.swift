import SwiftUI

/// One day's hourly Grok / Grokbot / OpenCode Go / OpenCode Zen / Cursor / Claude usage.
///
/// Every provider's hourly value is percentage points of its own allowance
/// (see `ProviderKind.quotaLabel`). A bar's height is that hour's total against
/// the day's busiest hour, and each slice is its provider's share of the hour.
struct OverviewHourlyUsageChart: View {
    let usage: ProviderDayHourlyUsage?
    /// Shown when the day has no activity.
    var emptyMessage = "No Grok, Grokbot, OpenCode, Cursor, or Claude activity yet today."

    private let trackHeight: CGFloat = PanelChartStem.height
    private static let firstHour = 6
    private static let lastHour = 22 // 10pm
    private static let stemWidth: CGFloat = PanelChartStem.width
    private static let barCornerRadius: CGFloat = PanelChartStem.cornerRadius
    private static let openCodeGoColor = ModelPalette.orange.color.opacity(0.85)
    private static let openCodeZenColor = ModelPalette.purple.color.opacity(0.78)

    /// Bottom → top in the stacked bar (matches legend reading order).
    private static let stackOrderBottomToTop: [ProviderKind] = [
        .grok, .grokbot, .cursor, .claude, .openCodeGo, .openCodeZen
    ]

    private enum ProviderKind: String, CaseIterable, Identifiable {
        case grok
        case grokbot
        case cursor
        case claude
        case openCodeGo
        case openCodeZen

        var id: String { rawValue }

        var title: String {
            switch self {
            case .grok: return "Grok"
            case .grokbot: return "Grokbot"
            case .cursor: return "Cursor"
            case .claude: return "Claude"
            case .openCodeGo: return "OpenCode Go"
            case .openCodeZen: return "OpenCode Zen"
            }
        }

        var legendTitle: String {
            switch self {
            case .grok: return "Grok"
            case .grokbot: return "Grokbot"
            case .cursor: return "Cursor"
            case .claude: return "Claude"
            case .openCodeGo: return "Go"
            case .openCodeZen: return "Zen"
            }
        }

        var color: Color {
            switch self {
            case .grok: return MonitorProvider.grok.accentColor
            case .grokbot: return MonitorProvider.grokbot.accentColor
            case .cursor: return MonitorProvider.cursor.accentColor
            case .claude: return MonitorProvider.claude.accentColor
            case .openCodeGo: return OverviewHourlyUsageChart.openCodeGoColor
            case .openCodeZen: return OverviewHourlyUsageChart.openCodeZenColor
            }
        }

        func activity(for hour: ProviderHourUsage) -> Double {
            switch self {
            case .grok: return hour.grokActivity
            case .grokbot: return hour.grokbotActivity
            case .cursor: return hour.cursorActivity
            case .claude: return hour.claudeActivity
            case .openCodeGo: return hour.openCodeGoActivity
            case .openCodeZen: return hour.openCodeZenActivity
            }
        }

        func tokenCount(for hour: ProviderHourUsage) -> Int64? {
            switch self {
            case .grok: return hour.grokTokens
            case .grokbot: return nil
            case .cursor: return hour.cursorTokens
            case .claude: return hour.claudeTokens
            case .openCodeGo: return hour.openCodeGoTokens
            case .openCodeZen: return hour.openCodeZenTokens
            }
        }

        /// Unit label for the hover tooltip: Grok and Grokbot report a weekly
        /// pool, Claude its 5-hour window (which counts every model), and
        /// Cursor and OpenCode a weekly share of their monthly plan.
        var quotaLabel: String {
            switch self {
            case .grok, .grokbot: return "of weekly"
            case .claude: return "of 5-hour window"
            case .cursor, .openCodeGo, .openCodeZen: return "of weekly share"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let usage, visibleHours(usage).contains(where: \.hasActivity) {
                hourBars(usage)
                legend(for: usage)
            } else {
                Text(emptyMessage)
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            }
        }
    }

    private func legend(for usage: ProviderDayHourlyUsage) -> some View {
        let hours = visibleHours(usage)
        let used = Self.stackOrderBottomToTop.filter { provider in
            hours.contains { provider.activity(for: $0) > 0 }
        }
        return HStack(spacing: 10) {
            ForEach(used) { provider in
                legendItem(title: provider.legendTitle, color: provider.color)
            }
        }
    }

    private func legendItem(title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 8, height: 10)
            Text(title)
                .font(PanelTypography.bodySemibold)
                .foregroundStyle(.secondary)
        }
    }

    private func visibleHours(_ usage: ProviderDayHourlyUsage) -> [ProviderHourUsage] {
        let range = Self.visibleHourRange(activeHours: usage.hours.filter(\.hasActivity).map(\.hour))
        return usage.hours.filter { range.contains($0.hour) }
    }

    /// 6am–10pm, widened to include any earlier or later hour with activity.
    static func visibleHourRange(activeHours: [Int]) -> ClosedRange<Int> {
        let lower = min(firstHour, activeHours.min() ?? firstHour)
        let upper = max(lastHour, activeHours.max() ?? lastHour)
        return lower...upper
    }

    private func hourBars(_ usage: ProviderDayHourlyUsage) -> some View {
        let hours = visibleHours(usage)
        let maxActivity = hours.map(\.activity).max() ?? 0
        let range = (hours.first?.hour ?? Self.firstHour)...(hours.last?.hour ?? Self.lastHour)
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(hours) { hour in
                hourColumn(hour, maxActivity: maxActivity, axisHours: Self.axisHours(for: range))
            }
        }
        .frame(height: trackHeight + 19)
    }

    private func hourColumn(_ hour: ProviderHourUsage, maxActivity: Double, axisHours: Set<Int>) -> some View {
        let fillHeight = Self.barHeight(activity: hour.activity, maxActivity: maxActivity, trackHeight: trackHeight)
        let segments = Self.segmentsInStackOrder(hour)
        let heights = Self.segmentHeights(segments.map(\.activity), total: fillHeight, minimum: 1)

        return VStack(spacing: 5) {
            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(width: Self.stemWidth, height: trackHeight)

                if segments.isEmpty {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: Self.stemWidth, height: 2)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(zip(segments, heights).reversed()), id: \.0.id) { segment, height in
                            Rectangle()
                                .fill(segment.color)
                                .frame(height: height)
                        }
                    }
                    .frame(width: Self.stemWidth, height: fillHeight, alignment: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: Self.barCornerRadius, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: trackHeight, alignment: .bottom)
            .help(hourHelp(hour, segments: segments))

            Text(axisHours.contains(hour.hour) ? Self.axisLabel(for: hour.hour) : " ")
                .font(PanelTypography.bodyDigit)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: 14)
        }
        .frame(maxWidth: .infinity)
    }

    /// Axis labels at both ends of the range and every third hour between,
    /// skipping any within an hour of an end so labels never crowd.
    static func axisHours(for range: ClosedRange<Int>) -> Set<Int> {
        let inner = range.filter { hour in
            hour.isMultiple(of: 3) && hour - range.lowerBound >= 2 && range.upperBound - hour >= 2
        }
        return Set(inner).union([range.lowerBound, range.upperBound])
    }

    /// Height of an hour's bar: its activity against the day's busiest hour,
    /// with any activity at least 3 points tall so it stays visible.
    static func barHeight(activity: Double, maxActivity: Double, trackHeight: CGFloat) -> CGFloat {
        let fraction = heightFraction(activity: activity, maxActivity: maxActivity)
        guard fraction > 0 else { return 0 }
        return min(trackHeight, max(3, trackHeight * CGFloat(fraction)))
    }

    /// Scale bars proportionally to the largest visible hour.
    static func heightFraction(activity: Double, maxActivity: Double) -> Double {
        guard activity > 0, maxActivity > 0 else { return 0 }
        return min(1, activity / maxActivity)
    }

    /// Slice heights proportional to `activities` that sum to `total`.
    ///
    /// A slice below `minimum` is lifted to it and the difference comes out of
    /// the tallest slice, so thin slices stay visible without overflowing the
    /// bar. When the bar is too short to give every slice `minimum`, the
    /// heights stay exactly proportional.
    static func segmentHeights(_ activities: [Double], total: CGFloat, minimum: CGFloat) -> [CGFloat] {
        let sum = activities.reduce(0) { $0 + max(0, $1) }
        guard sum > 0, total > 0 else { return activities.map { _ in 0 } }
        var heights = activities.map { CGFloat(max(0, $0) / sum) * total }
        let shown = heights.indices.filter { heights[$0] > 0 }
        guard shown.count > 1, minimum * CGFloat(shown.count) <= total else { return heights }
        var lifted: CGFloat = 0
        for index in shown where heights[index] < minimum {
            lifted += minimum - heights[index]
            heights[index] = minimum
        }
        if lifted > 0, let tallest = shown.max(by: { heights[$0] < heights[$1] }) {
            heights[tallest] -= lifted
        }
        return heights
    }

    /// Fixed legend order so colors stay in the same vertical position across hours.
    private static func segmentsInStackOrder(_ hour: ProviderHourUsage) -> [HourBarSegment] {
        stackOrderBottomToTop.compactMap { provider -> HourBarSegment? in
            let activity = provider.activity(for: hour)
            guard activity > 0 else { return nil }
            return HourBarSegment(
                id: provider.id,
                title: provider.title,
                activity: activity,
                tokens: provider.tokenCount(for: hour),
                color: provider.color,
                quotaLabel: provider.quotaLabel
            )
        }
    }

    /// One provider's slice of a stacked hourly bar.
    struct HourBarSegment {
        let id: String
        let title: String
        let activity: Double
        let tokens: Int64?
        let color: Color
        let quotaLabel: String
    }

    private static func axisLabel(for hour: Int) -> String {
        switch hour {
        case 0, 12: return "12"
        case 13...23: return "\(hour - 12)"
        default: return "\(hour)"
        }
    }

    private func hourHelp(_ hour: ProviderHourUsage, segments: [HourBarSegment]) -> String {
        guard !segments.isEmpty else { return "" }
        let parts = segments.map { segment -> String in
            let quota = String(format: "%.2f%% %@", segment.activity, segment.quotaLabel)
            if let tokens = segment.tokens, tokens > 0 {
                return "\(segment.title) \(quota) · \(Format.tokens(tokens))"
            }
            return "\(segment.title) \(quota)"
        }
        return "\(hour.hourLabel): \(parts.joined(separator: " · "))"
    }
}
