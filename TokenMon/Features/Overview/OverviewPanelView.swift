import AppKit
import SwiftUI

/// Aggregate cards for every enabled provider plus the hourly chart.
struct OverviewPanelView: View {
    @ObservedObject var grokPoller: GrokUsagePoller
    @ObservedObject var openCodePoller: OpenCodeUsagePoller
    @ObservedObject var cursorPoller: CursorUsagePoller
    @ObservedObject var claudePoller: ClaudeUsagePoller
    @ObservedObject var chatGPTPoller: ChatGPTUsagePoller
    @ObservedObject var openRouterPoller: OpenRouterUsagePoller
    @ObservedObject var grokbotPoller: GrokbotUsagePoller
    @ObservedObject var settings: AppSettings
    // The hourly stores are observed so today's chart redraws when they grow.
    @ObservedObject var grokHourly: HourlyDeltaActivityStore
    @ObservedObject var claudeHourly: HourlyDeltaActivityStore
    @ObservedObject var grokbotHourly: HourlyDeltaActivityStore
    @ObservedObject var hourlyHistory: OverviewHourlyHistoryStore
    /// Today's live chart inputs for a moment in today.
    var todaySeries: (Date) -> OverviewDaySeries
    @ObservedObject var grokAuth: GrokAuthSession
    @ObservedObject var openCodeAuth: OpenCodeAuthSession
    @ObservedObject var cursorAuth: CursorAuthSession
    @ObservedObject var claudeAuth: ClaudeAuthSession
    @ObservedObject var chatGPTAuth: ChatGPTAuthSession
    @ObservedObject var openRouterAuth: OpenRouterAuthSession

    var openGrokSignIn: () -> Void
    var openOpenCodeSignIn: () -> Void
    var openCursorSignIn: () -> Void
    var openClaudeSignIn: () -> Void
    var openChatGPTSignIn: () -> Void
    var selectOpenRouter: () -> Void
    var openPreferences: () -> Void

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        return "v\(version)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(nsImage: ProviderLogo.tokenmon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.primary)
                Text("TokenMon")
                    .font(PanelTypography.title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(appVersion)
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.tertiary)
                SettingsCogButton(action: openPreferences)
            }

            ForEach(settings.visibleUsageProviders) { provider in
                usageCard(for: provider)
            }

            // Re-evaluates at each local midnight so a panel left open across
            // the day boundary switches to the new day. The schedule starts at
            // today's midnight, so the first render shows today.
            TimelineView(.explicit(Self.midnightSchedule(from: Date()))) { context in
                OverviewDailyUsageCard(now: context.date, history: hourlyHistory, todaySeries: todaySeries)
            }
        }
    }

    /// Local midnights from the start of `date`'s day through the next week.
    ///
    /// `TimelineView` renders the latest entry at or before the current time,
    /// so the first entry is today's midnight and the first render shows today.
    static func midnightSchedule(from date: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: date)
        return (0...7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    @ViewBuilder
    private func usageCard(for provider: MonitorProvider) -> some View {
        switch provider {
        case .grok: grokUsageCard
        case .opencode: openCodeUsageCard
        case .cursor: cursorUsageCard
        case .claude: claudeUsageCard
        case .chatgpt: chatGPTUsageCard
        case .openrouter: openRouterUsageCard
        case .grokbot: grokbotUsageCard
        case .overview: EmptyView()
        }
    }

    private var grokUsageCard: some View {
        let percent = grokPoller.snapshot?.usedPercent ?? 0
        let resetsAt = grokPoller.snapshot?.resetsAt
        return PanelCard {
            HStack(alignment: .center, spacing: 8) {
                Image(nsImage: ProviderLogo.image(for: .grok))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text("Grok")
                    .font(PanelTypography.title)
                    .foregroundStyle(.primary)
                Text("— Weekly").panelMetaLabel(uppercased: true)
                Spacer()
                Text("\(Int(percent.rounded()))% Used")
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                let fillWidth = max(0, geo.size.width * CGFloat(Percent.clamp(percent) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(ProviderColors.grokColor).frame(width: fillWidth)
                }
            }
            .frame(height: 8)
            if let resetsAt {
                Text(Format.resetCaption(resetsAt))
                    .resetCaption()
            } else if grokPoller.snapshot == nil {
                Text("No Grok data yet")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            if !grokAuth.isSignedIn || grokAuth.needsSignIn {
                ProviderSignInButton(provider: .grok, action: openGrokSignIn)
            }
            if grokAuth.isSignedIn && !grokAuth.needsSignIn {
                ProviderSignOutButton(provider: .grok) {
                    grokAuth.signOut()
                }
            }
        }
    }

    private var openCodeUsageCard: some View {
        let monthly = openCodePoller.snapshot?.windows.first { $0.kind == .monthly }
        let percent = monthly?.usedPercent ?? openCodePoller.snapshot?.monthlyUsedPercent ?? 0
        let resetsAt = monthly?.resetsAt
        return PanelCard {
            HStack(alignment: .center, spacing: 8) {
                Image(nsImage: ProviderLogo.image(for: .opencode))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text("OpenCode")
                    .font(PanelTypography.title)
                    .foregroundStyle(.primary)
                Text("— Monthly").panelMetaLabel(uppercased: true)
                Spacer()
                Text("\(Int(percent.rounded()))% Used")
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                let fillWidth = max(0, geo.size.width * CGFloat(Percent.clamp(percent) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(ModelPalette.purple.color).frame(width: fillWidth)
                }
            }
            .frame(height: 8)
            if let resetsAt {
                Text(Format.resetCaption(resetsAt))
                    .resetCaption()
            } else if openCodePoller.snapshot == nil {
                Text("No OpenCode data yet")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            if openCodeAuth.needsSignIn && openCodePoller.snapshot == nil {
                ProviderSignInButton(provider: .opencode, action: openOpenCodeSignIn)
            }
            if !openCodeAuth.needsSignIn {
                ProviderSignOutButton(provider: .opencode) {
                    openCodeAuth.signOut()
                }
            }
        }
    }

    private var cursorUsageCard: some View {
        let percent = cursorPoller.snapshot?.usedPercent ?? 0
        let resetsAt = cursorPoller.snapshot?.resetsAt
        return PanelCard {
            HStack(alignment: .center, spacing: 8) {
                Image(nsImage: ProviderLogo.image(for: .cursor))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text("Cursor")
                    .font(PanelTypography.title)
                    .foregroundStyle(.primary)
                Text("— Monthly").panelMetaLabel(uppercased: true)
                Spacer()
                Text("\(Int(percent.rounded()))% Used")
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                let fillWidth = max(0, geo.size.width * CGFloat(Percent.clamp(percent) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(ProviderColors.cursorColor).frame(width: fillWidth)
                }
            }
            .frame(height: 8)
            if let resetsAt {
                Text(Format.resetCaption(resetsAt))
                    .resetCaption()
            } else if cursorPoller.snapshot == nil {
                Text("No Cursor data yet")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            if cursorAuth.needsSignIn && cursorPoller.snapshot == nil {
                ProviderSignInButton(provider: .cursor, action: openCursorSignIn)
            }
            if !cursorAuth.needsSignIn {
                ProviderSignOutButton(provider: .cursor) {
                    cursorAuth.signOut()
                }
            }
        }
    }

    private var claudeUsageCard: some View {
        let percent = claudePoller.snapshot?.sevenDay?.usedPercent ?? 0
        let resetsAt = claudePoller.snapshot?.sevenDay?.resetsAt
        return PanelCard {
            HStack(alignment: .center, spacing: 8) {
                Image(nsImage: ProviderLogo.image(for: .claude))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text("Claude")
                    .font(PanelTypography.title)
                    .foregroundStyle(.primary)
                Text("— Weekly").panelMetaLabel(uppercased: true)
                Spacer()
                Text("\(Int(percent.rounded()))% Used")
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                let fillWidth = max(0, geo.size.width * CGFloat(Percent.clamp(percent) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(ProviderColors.claudeColor).frame(width: fillWidth)
                }
            }
            .frame(height: 8)
            if let resetsAt {
                Text(Format.resetCaption(resetsAt))
                    .resetCaption()
            } else if claudePoller.snapshot == nil {
                Text("No Claude data yet")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            if claudeAuth.needsSignIn && claudePoller.snapshot == nil {
                ProviderSignInButton(provider: .claude, action: openClaudeSignIn)
            }
            if !claudeAuth.needsSignIn {
                ProviderSignOutButton(provider: .claude) {
                    claudeAuth.signOut()
                }
            }
        }
    }

    private var chatGPTUsageCard: some View {
        let percent = chatGPTPoller.snapshot?.headlineUsedPercent ?? 0
        let resetsAt = chatGPTPoller.snapshot?.resetsAt
        return PanelCard {
            HStack(alignment: .center, spacing: 8) {
                Image(nsImage: ProviderLogo.image(for: .chatgpt))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text("ChatGPT")
                    .font(PanelTypography.title)
                    .foregroundStyle(.primary)
                Text("— Codex").panelMetaLabel(uppercased: true)
                Spacer()
                Text("\(Int(percent.rounded()))% Used")
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                let fillWidth = max(0, geo.size.width * CGFloat(Percent.clamp(percent) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(ProviderColors.chatgptColor).frame(width: fillWidth)
                }
            }
            .frame(height: 8)
            if let resetsAt {
                Text(Format.resetCaption(resetsAt))
                    .resetCaption()
            } else if chatGPTPoller.snapshot == nil {
                Text("No ChatGPT data yet")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            if chatGPTAuth.needsSignIn && chatGPTPoller.snapshot == nil {
                ProviderSignInButton(provider: .chatgpt, action: openChatGPTSignIn)
            }
            if !chatGPTAuth.needsSignIn {
                ProviderSignOutButton(provider: .chatgpt) {
                    chatGPTAuth.signOut()
                }
            }
        }
    }

    private var grokbotUsageCard: some View {
        let percent = grokbotPoller.snapshot?.usedPercent ?? 0
        let resetsAt = grokbotPoller.snapshot?.resetsAt
        return PanelCard {
            HStack(alignment: .center, spacing: 8) {
                Image(nsImage: ProviderLogo.image(for: .grokbot))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text("Grokbot")
                    .font(PanelTypography.title)
                    .foregroundStyle(.primary)
                Text("— Weekly").panelMetaLabel(uppercased: true)
                Spacer()
                Text("\(Int(percent.rounded()))% Used")
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                let fillWidth = max(0, geo.size.width * CGFloat(Percent.clamp(percent) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(ProviderColors.grokbotColor).frame(width: fillWidth)
                }
            }
            .frame(height: 8)
            if let resetsAt {
                Text(Format.resetCaption(resetsAt))
                    .resetCaption()
            } else if grokbotPoller.snapshot == nil {
                Text("No Grokbot data yet")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            // Grokbot bills through Cursor, so its session lives on the Cursor card.
            if cursorAuth.needsSignIn && grokbotPoller.snapshot == nil {
                ProviderSignInButton(
                    provider: .grokbot,
                    title: "Sign In to Cursor…",
                    action: openCursorSignIn
                )
            }
        }
    }

    private var openRouterUsageCard: some View {
        let percent = openRouterPoller.snapshot?.usedPercent ?? 0
        let remaining = openRouterPoller.snapshot?.remainingUSD
        return PanelCard {
            HStack(alignment: .center, spacing: 8) {
                Image(nsImage: ProviderLogo.image(for: .openrouter))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text("OpenRouter")
                    .font(PanelTypography.title)
                    .foregroundStyle(.primary)
                Text("— Credits").panelMetaLabel(uppercased: true)
                Spacer()
                Text(openRouterPoller.snapshot?.usedPercent == nil && openRouterPoller.snapshot != nil
                    ? Format.usd(openRouterPoller.snapshot?.keyUsageUSD ?? 0)
                    : "\(Int(percent.rounded()))% Used")
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                let fillWidth = max(0, geo.size.width * CGFloat(Percent.clamp(percent) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(ProviderColors.openRouterColor).frame(width: fillWidth)
                }
            }
            .frame(height: 8)
            if openRouterPoller.snapshot?.budgetSource == nil, let snapshot = openRouterPoller.snapshot {
                Text("No credit limit — \(Format.usd(snapshot.keyUsageUSD)) spent on this key")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            } else if let remaining {
                Text("\(Format.usd(remaining)) of credits left")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            } else if openRouterPoller.snapshot == nil {
                Text("No OpenRouter data yet")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            if openRouterAuth.needsSignIn && openRouterPoller.snapshot == nil {
                ProviderSignInButton(provider: .openrouter, action: selectOpenRouter)
            }
            if !openRouterAuth.needsSignIn {
                ProviderSignOutButton(provider: .openrouter) {
                    openRouterAuth.signOut()
                }
            }
        }
    }
}

/// The hourly usage chart for today or an earlier saved day, with arrows to
/// step between days.
struct OverviewDailyUsageCard: View {
    let now: Date
    @ObservedObject var history: OverviewHourlyHistoryStore
    let todaySeries: (Date) -> OverviewDaySeries
    var calendar: Calendar = .current

    /// 0 is today; -1 is yesterday.
    @State private var dayOffset = 0

    private var day: Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
    }

    private var series: OverviewDaySeries? {
        dayOffset == 0 ? todaySeries(now) : history.series(on: day)
    }

    var body: some View {
        let day = day
        let usage = series.map { ProviderDayHourlyUsage.build(dayStart: day, series: $0) }
        PanelCard {
            PanelSectionHeader(title: Self.title(dayOffset: dayOffset, day: day))
            OverviewHourlyUsageChart(
                usage: usage?.isEmpty == false ? usage : nil,
                emptyMessage: dayOffset == 0
                    ? "No Grok, Grokbot, OpenCode, Cursor, or Claude activity yet today."
                    : "No activity recorded on this day."
            )
            if Self.canGoBack(from: day, earliestDay: history.earliestDay, calendar: calendar) || dayOffset < 0 {
                WeekChartNavigation(
                    onPreviousWeek: Self.canGoBack(from: day, earliestDay: history.earliestDay, calendar: calendar)
                        ? { dayOffset -= 1 }
                        : nil,
                    onNextWeek: { dayOffset = min(0, dayOffset + 1) },
                    canGoNext: dayOffset < 0
                )
            }
        }
    }

    /// "Usage Today", "Usage Yesterday", or "Usage Mon, Oct 20".
    static func title(dayOffset: Int, day: Date) -> String {
        switch dayOffset {
        case 0: return "Usage Today"
        case -1: return "Usage Yesterday"
        default: return "Usage \(Format.date(day, dateFormat: "EEE, MMM d"))"
        }
    }

    /// True when a saved day exists before `day`.
    static func canGoBack(from day: Date, earliestDay: Date?, calendar: Calendar) -> Bool {
        guard let earliestDay else { return false }
        return calendar.startOfDay(for: earliestDay) < calendar.startOfDay(for: day)
    }
}
