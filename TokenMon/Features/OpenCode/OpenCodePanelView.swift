import SwiftUI

/// OpenCode Go panel with limit bars, budget, models, and stats.
struct OpenCodePanelView: View {
    @ObservedObject var poller: OpenCodeUsagePoller
    @ObservedObject var auth: OpenCodeAuthSession
    /// Whether the "Top Models by Spend" list is open; saved in settings.
    @Binding var modelsExpanded: Bool
    let openSignIn: () -> Void

    var body: some View {
        if auth.needsSignIn && poller.snapshot == nil {
            signedOut
        } else if let snapshot = poller.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                ProviderHeaderRow(provider: .opencode, title: "OpenCode Go")

                PanelCard {
                    PanelSectionHeader(title: snapshot.usagePool.sectionTitle)
                    ForEach(snapshot.windows) { window in
                        OpenCodeLimitBar(window: window)
                    }
                    if snapshot.isEstimated {
                        Text("Estimated from local sessions — sign in for console accuracy.")
                            .font(PanelTypography.caption)
                            .foregroundStyle(.orange)
                    }
                }

                NavigableDailyBudgetCard(
                    style: .monthly,
                    accent: ModelPalette.purple.color,
                    periodUsedPercent: snapshot.monthlyUsedPercent,
                    periodStart: poller.dailyBudgetPeriodStart,
                    resetsAt: snapshot.windows.first { $0.kind == .monthly }?.resetsAt,
                    daysForWeek: { poller.dailyBudgetDays(weekOffset: $0) ?? [] }
                )

                if !snapshot.models.isEmpty {
                    PanelCard {
                        OpenCodeModelsSection(models: snapshot.models, isExpanded: $modelsExpanded)
                    }
                }

                // Stats shows only when the local session DB supplied data, since a
                // console-only snapshot carries no model/token/spend figures.
                if snapshot.hasLocalStats {
                    OpenCodeStatsRow(
                        monthlySpendUSD: snapshot.monthlyEstimatedUSD,
                        totalTokens: snapshot.monthlyTokens,
                        inputTokens: snapshot.monthlyInputTokens,
                        outputTokens: snapshot.monthlyOutputTokens
                    )
                }

                if let err = poller.lastError {
                    Text(err)
                        .font(PanelTypography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                // The local estimate shows without a console session; a sign-in
                // is offered when there is none or it was rejected.
                if auth.needsSignIn {
                    ProviderSignInButton(provider: .opencode, title: "Sign In to OpenCode…", action: openSignIn)
                        .padding(.top, 8)
                }

                ProviderSignOutButton(provider: .opencode) {
                    auth.signOut()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ProviderHeaderRow(provider: .opencode, title: "OpenCode Go")
                Text(poller.isRefreshing ? "Refreshing…" : (poller.lastError ?? "No usage data yet."))
                    .font(PanelTypography.body)
                    .foregroundStyle(.secondary)
                if auth.needsSignIn {
                    ProviderSignInButton(provider: .opencode, action: openSignIn)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProviderHeaderRow(provider: .opencode, title: "OpenCode Go")
            Text("Sign in to the OpenCode console to load official rolling, weekly, and monthly usage.")
                .font(PanelTypography.body)
                .foregroundStyle(.secondary)
            ProviderSignInButton(provider: .opencode, action: openSignIn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Monthly spend, total tokens, input and output — all monthly.
struct OpenCodeStatsRow: View {
    let monthlySpendUSD: Double
    let totalTokens: Int64
    let inputTokens: Int64
    let outputTokens: Int64

    var body: some View {
        MetricStatGrid([
            MetricStat(title: "Monthly spend", value: Format.usd(monthlySpendUSD)),
            MetricStat(title: "Total tokens", value: Format.tokens(totalTokens)),
            MetricStat(title: "Input tokens", value: Format.tokens(inputTokens)),
            MetricStat(title: "Output tokens", value: Format.tokens(outputTokens))
        ])
    }
}

/// Compact ranked list of Go/Zen models with company logo + usage bar, under
/// a header that opens and closes the list.
struct OpenCodeModelsSection: View {
    let models: [OpenCodeModelUsage]
    @Binding var isExpanded: Bool

    private let previewCount = 3
    @State private var showAll = false

    private var visible: [OpenCodeModelUsage] {
        showAll ? models : Array(models.prefix(previewCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CollapsibleSectionHeader(title: "Top Models by Spend", isExpanded: $isExpanded)

            if isExpanded {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, model in
                    OpenCodeModelWeekRow(model: model)
                    if index < visible.count - 1 {
                        Divider().opacity(0.35)
                    }
                }

                if models.count > previewCount {
                    HStack {
                        Spacer()
                        Button {
                            showAll.toggle()
                        } label: {
                            Text(showAll ? "Show less" : "View all")
                                .font(PanelTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// One ranked model row with spend, share bar, and cost label.
struct OpenCodeModelWeekRow: View {
    let model: OpenCodeModelUsage

    private var accent: Color {
        ModelPalette.sRGB(forProvider: model.providerID, seed: model.id).color
    }

    private var costLabel: String {
        if model.isCostUnpriced, model.costUSD == 0 {
            return "No price"
        }
        let formatted = Format.usdCurrency.string(from: NSNumber(value: model.costUSD)) ?? "$0"
        if model.isCostEstimated || model.isCostUnpriced {
            return "~\(formatted)"
        }
        return formatted
    }

    private var displayModelName: String {
        OpenCodeModelName.display(model.modelID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ModelCompanyLogo(modelID: model.modelID)
                Text(displayModelName)
                    .font(PanelTypography.bodySemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(costLabel)
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            GeometryReader { geo in
                let width = max(0, geo.size.width * CGFloat(max(0, min(100, model.percentOfWindow)) / 100))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(accent)
                        .frame(width: width)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
    }
}
