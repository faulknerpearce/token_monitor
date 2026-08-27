import SwiftUI

/// Today's hourly Grok / Grokbot / OpenCode Go / OpenCode Zen / Cursor / Claude usage.
struct OverviewHourlyUsageChart: View {
    let usage: ProviderDayHourlyUsage?

    private let trackHeight: CGFloat = PanelChartStem.height
    private static let firstHour = 6
    private static let lastHour = 22 // 10pm
    private static let stemWidth: CGFloat = PanelChartStem.width
    private static let barCornerRadius: CGFloat = PanelChartStem.cornerRadius
    private static let openCodeGoColor = ModelPalette.purple.color.opacity(0.85)
    private static let openCodeZenColor = ModelPalette.orange.color.opacity(0.78)

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
            case .grok: return ConcentricUsageRingView.grokColor
            case .grokbot: return ConcentricUsageRingView.grokbotColor
            case .cursor: return ConcentricUsageRingView.cursorColor
            case .claude: return ConcentricUsageRingView.claudeColor
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

        /// Unit label for the hover tooltip — each provider's activity is a
        /// percentage of a *different* quota window, so this can't be one hardcoded string.
        var quotaLabel: String {
            switch self {
            case .grok, .grokbot: return "weekly"
            case .cursor: return "monthly"
            case .claude: return "5-hour window"
            case .openCodeGo, .openCodeZen: return "monthly"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let usage, visibleHours(usage).contains(where: \.hasActivity) {
                hourBars(usage)
                legend
            } else {
                Text("No Grok, Grokbot, OpenCode, Cursor, or Claude activity yet today.")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(Self.stackOrderBottomToTop) { provider in
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
                .font(PanelTypography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func visibleHours(_ usage: ProviderDayHourlyUsage) -> [ProviderHourUsage] {
        usage.hours.filter { $0.hour >= Self.firstHour && $0.hour <= Self.lastHour }
    }

    private func hourBars(_ usage: ProviderDayHourlyUsage) -> some View {
        let hours = visibleHours(usage)
        let providerMax = Dictionary(
            uniqueKeysWithValues: ProviderKind.allCases.map { provider in
                (provider, max(hours.map { provider.activity(for: $0) }.max() ?? 0, 0.0001))
            }
        )
        let maxStack = max(
            hours.map { Self.relativeStackWeight(for: $0, providerMax: providerMax) }.max() ?? 0,
            0.0001
        )

        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(hours) { hour in
                hourColumn(hour, providerMax: providerMax, maxStack: maxStack)
            }
        }
        .frame(height: trackHeight + 14)
    }

    private func hourColumn(
        _ hour: ProviderHourUsage,
        providerMax: [ProviderKind: Double],
        maxStack: Double
    ) -> some View {
        let stackWeight = Self.relativeStackWeight(for: hour, providerMax: providerMax)
        let fillHeight = max(
            6,
            trackHeight * CGFloat(Self.heightFraction(activity: stackWeight, maxActivity: maxStack))
        )
        let showAxis = [Self.firstHour, 9, 12, 15, 18, Self.lastHour].contains(hour.hour)
        let segments = Self.segmentsInStackOrder(hour, providerMax: providerMax)

        return VStack(spacing: 5) {
            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(width: Self.stemWidth, height: trackHeight)

                if segments.isEmpty {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: Self.stemWidth, height: 2)
                } else {
                    let totalWeight = max(segments.map(\.relativeWeight).reduce(0, +), 0.0001)
                    VStack(spacing: 0) {
                        ForEach(segments.reversed(), id: \.id) { segment in
                            let segmentHeight = max(
                                2,
                                fillHeight * CGFloat(segment.relativeWeight / totalWeight)
                            )
                            Rectangle()
                                .fill(segment.color)
                                .frame(height: segmentHeight)
                        }
                    }
                    .frame(width: Self.stemWidth, height: min(trackHeight, fillHeight), alignment: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: Self.barCornerRadius, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: trackHeight, alignment: .bottom)
            .help(hourHelp(hour, segments: segments))

            Text(showAxis ? Self.axisLabel(for: hour.hour) : " ")
                .font(PanelTypography.micro)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: 10)
        }
        .frame(maxWidth: .infinity)
    }

    /// Scale bars proportionally to the largest visible hour.
    static func heightFraction(activity: Double, maxActivity: Double) -> Double {
        guard activity > 0, maxActivity > 0 else { return 0 }
        return min(1, activity / maxActivity)
    }

    /// Sum of each provider's activity relative to that provider's day max.
    private static func relativeStackWeight(
        for hour: ProviderHourUsage,
        providerMax: [ProviderKind: Double]
    ) -> Double {
        ProviderKind.allCases.reduce(0) { partial, provider in
            partial + heightFraction(
                activity: provider.activity(for: hour),
                maxActivity: providerMax[provider] ?? 0
            )
        }
    }

    /// Fixed legend order so colors stay in the same vertical position across hours.
    private static func segmentsInStackOrder(
        _ hour: ProviderHourUsage,
        providerMax: [ProviderKind: Double]
    ) -> [HourBarSegment] {
        stackOrderBottomToTop.compactMap { provider -> HourBarSegment? in
            let activity = provider.activity(for: hour)
            let weight = heightFraction(activity: activity, maxActivity: providerMax[provider] ?? 0)
            guard weight > 0 else { return nil }
            return HourBarSegment(
                id: provider.id,
                title: provider.title,
                relativeWeight: weight,
                activity: activity,
                tokens: provider.tokenCount(for: hour),
                color: provider.color,
                quotaLabel: provider.quotaLabel
            )
        }
    }

    struct HourBarSegment {
        let id: String
        let title: String
        let relativeWeight: Double
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
            let quota = String(format: "%.2f%% \(segment.quotaLabel)", segment.activity)
            if let tokens = segment.tokens, tokens > 0 {
                return "\(segment.title) \(quota) · \(Format.tokens(tokens))"
            }
            return "\(segment.title) \(quota)"
        }
        return "\(hour.hourLabel): \(parts.joined(separator: " · "))"
    }
}
