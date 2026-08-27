import AppKit
import SwiftUI

struct OverviewPanelView: View {
    @ObservedObject var grokPoller: UsagePoller
    @ObservedObject var openCodePoller: OpenCodeUsagePoller
    @ObservedObject var cursorPoller: CursorUsagePoller
    @ObservedObject var claudePoller: ClaudeUsagePoller
    @ObservedObject var chatGPTPoller: ChatGPTUsagePoller
    @ObservedObject var openRouterPoller: OpenRouterUsagePoller
    @ObservedObject var grokbotPoller: GrokbotUsagePoller
    @ObservedObject var settings: AppSettings
    @ObservedObject var grokHourly: HourlyDeltaActivityStore
    @ObservedObject var claudeHourly: HourlyDeltaActivityStore
    @ObservedObject var grokbotHourly: HourlyDeltaActivityStore
    @ObservedObject var grokAuth: AuthSessionService
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
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            ForEach(settings.visibleUsageProviders) { provider in
                usageCard(for: provider)
            }

            PanelCard {
                PanelSectionHeader(title: "Today")
                OverviewHourlyUsageChart(usage: providerHourlyUsage)
            }
        }
    }

    private var providerHourlyUsage: ProviderDayHourlyUsage? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())

        let openCodeWeights: (openCodeGo: [Double], openCodeZen: [Double]) = {
            guard settings.enabledProviderIDs.contains(.opencode),
                  let hourly = openCodePoller.dayHourlyUsage,
                  calendar.isDate(hourly.dayStart, inSameDayAs: dayStart),
                  hourly.hours.count == 24
            else {
                let empty = Array(repeating: 0.0, count: 24)
                return (empty, empty)
            }
            let monthlyLimit = openCodePoller.snapshot?.windows
                .first { $0.kind == .monthly }?.limitUSD
                ?? OpenCodeWindowKind.monthly.defaultLimitUSD
            return hourly.overviewProviderQuotaHourWeights(monthlyLimitUSD: monthlyLimit)
        }()

        let openCodeCostWeights: (openCodeGo: [Double], openCodeZen: [Double]) = {
            guard settings.enabledProviderIDs.contains(.opencode),
                  let hourly = openCodePoller.dayHourlyUsage,
                  calendar.isDate(hourly.dayStart, inSameDayAs: dayStart),
                  hourly.hours.count == 24
            else {
                let empty = Array(repeating: 0.0, count: 24)
                return (empty, empty)
            }
            let raw = hourly.overviewProviderHourWeights()
            return (raw.openCodeGo, raw.openCodeZen)
        }()

        let openCodeTokenWeights: (openCodeGo: [Int64], openCodeZen: [Int64]) = {
            guard settings.enabledProviderIDs.contains(.opencode),
                  let hourly = openCodePoller.dayHourlyUsage,
                  calendar.isDate(hourly.dayStart, inSameDayAs: dayStart),
                  hourly.hours.count == 24
            else {
                let empty = Array(repeating: Int64(0), count: 24)
                return (empty, empty)
            }
            let raw = hourly.overviewProviderHourTokenCounts()
            return (raw.openCodeGo, raw.openCodeZen)
        }()

        let grokPollWeights: [Double] = {
            guard settings.enabledProviderIDs.contains(.grok) else {
                return Array(repeating: 0, count: 24)
            }
            if calendar.isDate(grokHourly.dayStart, inSameDayAs: dayStart),
               grokHourly.hourWeights.count == 24 {
                return grokHourly.hourWeights
            }
            return Array(repeating: 0, count: 24)
        }()

        let cursorWeights: [Double] = {
            guard settings.enabledProviderIDs.contains(.cursor),
                  let hourly = cursorPoller.dayHourlyUsage,
                  calendar.isDate(hourly.dayStart, inSameDayAs: dayStart),
                  hourly.quotaHourWeights.count == 24
            else {
                return Array(repeating: 0, count: 24)
            }
            return hourly.quotaHourWeights
        }()

        let claudeWeights: [Double] = {
            guard settings.enabledProviderIDs.contains(.claude) else {
                return Array(repeating: 0, count: 24)
            }
            if calendar.isDate(claudeHourly.dayStart, inSameDayAs: dayStart),
               claudeHourly.hourWeights.count == 24 {
                return claudeHourly.hourWeights
            }
            return Array(repeating: 0, count: 24)
        }()

        let grokbotWeights: [Double] = {
            guard settings.enabledProviderIDs.contains(.grokbot) else {
                return Array(repeating: 0, count: 24)
            }
            if calendar.isDate(grokbotHourly.dayStart, inSameDayAs: dayStart),
               grokbotHourly.hourWeights.count == 24 {
                return grokbotHourly.hourWeights
            }
            return Array(repeating: 0, count: 24)
        }()

        let cursorTokenWeights: [Int64] = {
            guard settings.enabledProviderIDs.contains(.cursor),
                  let hourly = cursorPoller.dayHourlyUsage,
                  calendar.isDate(hourly.dayStart, inSameDayAs: dayStart),
                  hourly.hourTokenWeights.count == 24
            else {
                return Array(repeating: Int64(0), count: 24)
            }
            return hourly.hourTokenWeights
        }()

        // Official Grok pool deltas plus OpenCode plan quota deltas.
        // Direct BYOK Grok-through-OpenCode usage has no shared quota denominator.
        let hourCostUSD = zip(openCodeCostWeights.openCodeGo, openCodeCostWeights.openCodeZen).map(+)

        let built = ProviderDayHourlyUsage.build(
            dayStart: dayStart,
            grokHourWeights: grokPollWeights,
            openCodeGoHourWeights: openCodeWeights.openCodeGo,
            openCodeZenHourWeights: openCodeWeights.openCodeZen,
            cursorHourWeights: cursorWeights,
            claudeHourWeights: claudeWeights,
            grokbotHourWeights: grokbotWeights,
            hourCostUSD: hourCostUSD,
            openCodeGoHourTokens: openCodeTokenWeights.openCodeGo,
            openCodeZenHourTokens: openCodeTokenWeights.openCodeZen,
            cursorHourTokens: cursorTokenWeights
        )
        return built.isEmpty ? nil : built
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
                Text("— Weekly")
                    .font(PanelTypography.micro)
                    .fontWeight(.semibold)
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Spacer()
                PanelPill(text: "\(Int(percent.rounded()))% used")
            }
            GeometryReader { geo in
                let fillWidth = max(0, geo.size.width * CGFloat(Percent.clamp(percent) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(ConcentricUsageRingView.grokColor).frame(width: fillWidth)
                }
            }
            .frame(height: 8)
            if let resetsAt {
                Text("Resets \(Format.resetDate(resetsAt, dateFormat: "EEE dd MMMM h:mma"))")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            } else if grokPoller.snapshot == nil {
                Text("No Grok data yet")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            if !grokAuth.isSignedIn || grokAuth.needsSignIn {
                ProviderSignInButton(provider: .grok, font: PanelTypography.caption, action: openGrokSignIn)
            }
            if grokAuth.isSignedIn && !grokAuth.needsSignIn {
                ProviderSignOutButton(provider: .grok) {
                    grokAuth.signOut()
                    grokPoller.clearSnapshot()
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
                Text("— Monthly")
                    .font(PanelTypography.micro)
                    .fontWeight(.semibold)
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Spacer()
                PanelPill(text: "\(Int(percent.rounded()))% used")
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
                Text("Resets \(Format.resetDate(resetsAt, dateFormat: "EEE dd MMMM h:mma"))")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            } else if openCodePoller.snapshot == nil {
                Text("No OpenCode data yet")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            if openCodeAuth.needsSignIn && openCodePoller.snapshot == nil {
                ProviderSignInButton(provider: .opencode, font: PanelTypography.caption, action: openOpenCodeSignIn)
            }
            if !openCodeAuth.needsSignIn {
                ProviderSignOutButton(provider: .opencode) {
                    openCodeAuth.signOut()
                    openCodePoller.clearSnapshot()
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
                Text("— Monthly")
                    .font(PanelTypography.micro)
                    .fontWeight(.semibold)
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Spacer()
                PanelPill(text: "\(Int(percent.rounded()))% used")
            }
            GeometryReader { geo in
                let fillWidth = max(0, geo.size.width * CGFloat(Percent.clamp(percent) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(ConcentricUsageRingView.cursorColor).frame(width: fillWidth)
                }
            }
            .frame(height: 8)
            if let resetsAt {
                Text("Resets \(Format.resetDate(resetsAt, dateFormat: "EEE dd MMMM h:mma"))")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            } else if cursorPoller.snapshot == nil {
                Text("No Cursor data yet")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            if cursorAuth.needsSignIn && cursorPoller.snapshot == nil {
                ProviderSignInButton(provider: .cursor, font: PanelTypography.caption, action: openCursorSignIn)
            }
            if !cursorAuth.needsSignIn {
                ProviderSignOutButton(provider: .cursor) {
                    cursorAuth.signOut()
                    cursorPoller.clearSnapshot()
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
                Text("— Weekly")
                    .font(PanelTypography.micro)
                    .fontWeight(.semibold)
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Spacer()
                PanelPill(text: "\(Int(percent.rounded()))% used")
            }
            GeometryReader { geo in
                let fillWidth = max(0, geo.size.width * CGFloat(Percent.clamp(percent) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(ConcentricUsageRingView.claudeColor).frame(width: fillWidth)
                }
            }
            .frame(height: 8)
            if let resetsAt {
                Text("Resets \(Format.resetDate(resetsAt, dateFormat: "EEE dd MMMM h:mma"))")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            } else if claudePoller.snapshot == nil {
                Text("No Claude data yet")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            if claudeAuth.needsSignIn && claudePoller.snapshot == nil {
                ProviderSignInButton(provider: .claude, font: PanelTypography.caption, action: openClaudeSignIn)
            }
            if !claudeAuth.needsSignIn {
                ProviderSignOutButton(provider: .claude) {
                    claudeAuth.signOut()
                    claudePoller.clearSnapshot()
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
                Text("— Codex")
                    .font(PanelTypography.micro)
                    .fontWeight(.semibold)
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Spacer()
                PanelPill(text: "\(Int(percent.rounded()))% used")
            }
            GeometryReader { geo in
                let fillWidth = max(0, geo.size.width * CGFloat(Percent.clamp(percent) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(ConcentricUsageRingView.chatgptColor).frame(width: fillWidth)
                }
            }
            .frame(height: 8)
            if let resetsAt {
                Text("Resets \(Format.resetDate(resetsAt, dateFormat: "EEE dd MMMM h:mma"))")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            } else if chatGPTPoller.snapshot == nil {
                Text("No ChatGPT data yet")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            if chatGPTAuth.needsSignIn && chatGPTPoller.snapshot == nil {
                ProviderSignInButton(provider: .chatgpt, font: PanelTypography.caption, action: openChatGPTSignIn)
            }
            if !chatGPTAuth.needsSignIn {
                ProviderSignOutButton(provider: .chatgpt) {
                    chatGPTAuth.signOut()
                    chatGPTPoller.clearSnapshot()
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
                Text("— Weekly")
                    .font(PanelTypography.micro)
                    .fontWeight(.semibold)
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Spacer()
                PanelPill(text: "\(Int(percent.rounded()))% used")
            }
            GeometryReader { geo in
                let fillWidth = max(0, geo.size.width * CGFloat(Percent.clamp(percent) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(ConcentricUsageRingView.grokbotColor).frame(width: fillWidth)
                }
            }
            .frame(height: 8)
            if let resetsAt {
                Text("Resets \(Format.resetDate(resetsAt, dateFormat: "EEE dd MMMM h:mma"))")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
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
                    font: PanelTypography.caption,
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
                Text("— Credits")
                    .font(PanelTypography.micro)
                    .fontWeight(.semibold)
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Spacer()
                PanelPill(text: openRouterPoller.snapshot?.usedPercent == nil && openRouterPoller.snapshot != nil
                    ? Format.usd(openRouterPoller.snapshot?.keyUsageUSD ?? 0)
                    : "\(Int(percent.rounded()))% used")
            }
            GeometryReader { geo in
                let fillWidth = max(0, geo.size.width * CGFloat(Percent.clamp(percent) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(ConcentricUsageRingView.openRouterColor).frame(width: fillWidth)
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
                ProviderSignInButton(provider: .openrouter, font: PanelTypography.caption, action: selectOpenRouter)
            }
            if !openRouterAuth.needsSignIn {
                ProviderSignOutButton(provider: .openrouter) {
                    openRouterAuth.signOut()
                    openRouterPoller.clearSnapshot()
                }
            }
        }
    }
}
