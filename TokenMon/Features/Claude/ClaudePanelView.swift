import SwiftUI

/// Claude usage panel (5-hour and weekly windows plus daily bars).
struct ClaudePanelView: View {
    @ObservedObject var poller: ClaudeUsagePoller
    @ObservedObject var auth: ClaudeAuthSession
    /// Whether the "Models This Month" list is open; saved in settings.
    @Binding var modelsExpanded: Bool
    let openSignIn: () -> Void

    var body: some View {
        if auth.needsSignIn && poller.snapshot == nil {
            signedOut
        } else if let snapshot = poller.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                ProviderHeaderRow(provider: .claude, title: "Claude")

                PanelCard {
                    PanelSectionHeader(title: snapshot.usagePool.sectionTitle)
                    SlimUsageTrack(
                        label: "5-Hour Window",
                        percent: snapshot.fiveHour?.usedPercent ?? 0,
                        color: ProviderColors.claudeColor,
                        caption: snapshot.fiveHour?.resetsAt.map { Format.resetCaption($0) }
                    )
                    SlimUsageTrack(
                        label: snapshot.weeklyLabel,
                        percent: snapshot.sevenDay?.usedPercent ?? 0,
                        color: ProviderColors.claudeColor,
                        caption: poller.weeklyResetsAt().map { Format.resetCaption($0) }
                    )
                }

                NavigableDailyBudgetCard(
                    style: .weekly,
                    accent: ProviderColors.claudeColor,
                    periodUsedPercent: snapshot.sevenDay?.usedPercent,
                    resetsAt: poller.weeklyResetsAt(),
                    daysForWeek: { poller.dailyBudgetDays(weekOffset: $0) }
                )

                codeUsageSection

                if let err = poller.lastError {
                    StaleDataCaption(message: err, lastRefreshedAt: poller.lastRefreshedAt)
                        .padding(.top, 8)
                }
                // Only a rejected session needs a new sign-in; network and
                // server errors clear on a later refresh.
                if auth.needsSignIn {
                    ProviderSignInButton(provider: .claude, title: "Sign In Again…", action: openSignIn)
                        .padding(.top, 8)
                }

                ProviderSignOutButton(provider: .claude) {
                    auth.signOut()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ProviderHeaderRow(provider: .claude, title: "Claude")
                Text(poller.isRefreshing ? "Refreshing…" : (poller.lastError ?? "No usage data yet."))
                    .font(PanelTypography.body)
                    .foregroundStyle(.secondary)
                if auth.needsSignIn {
                    ProviderSignInButton(provider: .claude, action: openSignIn)
                }
                codeUsageSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Claude Code usage read from this Mac's logs; shown whether or not
    /// claude.ai is signed in.
    @ViewBuilder
    private var codeUsageSection: some View {
        if let usage = poller.codeUsage {
            ClaudeCodeUsageSection(usage: usage, modelsExpanded: $modelsExpanded)
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProviderHeaderRow(provider: .claude, title: "Claude")
            Text("Sign in to claude.ai to load your 5-hour and weekly usage.")
                .font(PanelTypography.body)
                .foregroundStyle(.secondary)
            ProviderSignInButton(provider: .claude, action: openSignIn)
            codeUsageSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Claude Code usage on this Mac: month and all-time totals, then this
/// month's models ranked by API-rate value.
struct ClaudeCodeUsageSection: View {
    let usage: ClaudeCodeUsageSummary
    @Binding var modelsExpanded: Bool

    /// API-rate value, with a trailing "+" when a model with no listed price
    /// is left out of it.
    static func spend(_ totals: ClaudeUsageTotals) -> String {
        Format.usd(totals.costUSD) + (totals.hasUnpriced ? "+" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MetricStatGrid([
                MetricStat(title: "Tokens this month", value: Format.tokens(usage.month.tokens)),
                MetricStat(title: "Spend this month", value: Self.spend(usage.month)),
                MetricStat(title: "Total tokens", value: Format.tokens(usage.allTime.tokens)),
                MetricStat(title: "Total spend", value: Self.spend(usage.allTime))
            ])
            if !usage.monthModels.isEmpty {
                PanelCard {
                    ClaudeModelsSection(models: usage.monthModels, isExpanded: $modelsExpanded)
                }
            }
        }
    }
}

/// This month's Claude models with a share-of-spend bar each, under a header
/// that opens and closes the list.
struct ClaudeModelsSection: View {
    let models: [ClaudeModelUsage]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CollapsibleSectionHeader(title: "Models This Month", isExpanded: $isExpanded)

            if isExpanded {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    ClaudeModelRow(model: model)
                    if index < models.count - 1 {
                        Divider().opacity(0.35)
                    }
                }
            }
        }
    }
}

/// One model: logo, name, API-rate value, and its share bar.
struct ClaudeModelRow: View {
    let model: ClaudeModelUsage

    private var valueLabel: String {
        model.isUnpriced ? "No price" : Format.usd(model.costUSD)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ModelCompanyLogo(modelID: model.modelID)
                Text(ClaudeModelName.display(model.modelID))
                    .font(PanelTypography.bodySemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(valueLabel)
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            GeometryReader { geo in
                let share = CGFloat(max(0, min(100, model.sharePercent)) / 100)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(ProviderColors.claudeColor)
                        .frame(width: max(0, geo.size.width * share))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
    }
}
