import AppKit
import SwiftUI

struct CursorPanelView: View {
    @ObservedObject var poller: CursorUsagePoller
    @ObservedObject var auth: CursorAuthSession
    let openSignIn: () -> Void

    var body: some View {
        if auth.needsSignIn && poller.snapshot == nil {
            signedOut
        } else if let snapshot = poller.snapshot {
            let cursorModelsPercent: Double = {
                if let total = snapshot.pools.first(where: { $0.kind == .total }) { return total.usedPercent }
                if let auto = snapshot.pools.first(where: { $0.kind == .auto }) { return auto.usedPercent }
                return snapshot.usedPercent
            }()
            let otherModelsPercent: Double = {
                if let api = snapshot.pools.first(where: { $0.kind == .api }) { return api.usedPercent }
                return 0
            }()
            let cursorModelsResetsAt = snapshot.pools.first(where: { $0.kind == .total })?.resetsAt ?? snapshot.resetsAt
            let otherModelsResetsAt = snapshot.pools.first(where: { $0.kind == .api })?.resetsAt ?? snapshot.resetsAt
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProviderHeaderLabel(provider: .cursor, title: "Cursor")
                    Spacer()
                    Text(snapshot.displayPlanName)
                        .panelMetaLabel()
                }

                PanelCard {
                    PanelSectionHeader(title: snapshot.usagePool.sectionTitle)
                    SlimUsageTrack(
                        label: "Cursor Models",
                        percent: cursorModelsPercent,
                        color: ProviderColors.cursorColor,
                        caption: cursorModelsResetsAt.map { Format.resetCaption($0) }
                    )
                    SlimUsageTrack(
                        label: "Other Models",
                        percent: otherModelsPercent,
                        color: ProviderColors.cursorColor,
                        caption: otherModelsResetsAt.map { Format.resetCaption($0) }
                    )
                }

                if let days = poller.dailyBudgetDays, !days.isEmpty {
                    PanelCard {
                        MonthlyDailyBudgetBarsView(
                            days: days,
                            accent: ProviderColors.cursorColor,
                            periodUsedPercent: cursorModelsPercent,
                            periodStart: snapshot.billingCycleStart,
                            resetsAt: snapshot.billingCycleEnd
                        )
                    }
                }

                if let stats = snapshot.costStats {
                    VStack(alignment: .leading, spacing: 0) {
                        PanelSectionHeader(title: "Stats")
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 8)
                        CursorStatsGrid(stats: stats)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                }

                if auth.needsSignIn || poller.lastError != nil {
                    if let err = poller.lastError {
                        Text(err)
                            .font(PanelTypography.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ProviderSignInButton(
                        provider: .cursor,
                        title: auth.needsSignIn ? "Sign In to Cursor…" : "Sign In Again…",
                        action: openSignIn
                    )
                    .padding(.top, 8)
                }

                ProviderSignOutButton(provider: .cursor) {
                    auth.signOut()
                    poller.clearSnapshot()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ProviderHeaderLabel(provider: .cursor, title: "Cursor")
                Text(poller.isRefreshing ? "Refreshing…" : (poller.lastError ?? "No usage data yet."))
                    .font(PanelTypography.body)
                    .foregroundStyle(.secondary)
                if auth.needsSignIn {
                    ProviderSignInButton(provider: .cursor, action: openSignIn)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProviderHeaderLabel(provider: .cursor, title: "Cursor")
            Text("Sign in to cursor.com to load Total, Auto, and API usage.")
                .font(PanelTypography.body)
                .foregroundStyle(.secondary)
            ProviderSignInButton(provider: .cursor, action: openSignIn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CursorStatsGrid: View {
    let stats: CursorCostStats

    var body: some View {
        MetricStatGrid([
            MetricStat(title: "Monthly spend", value: Format.usd(stats.meteredCycleUSD)),
            MetricStat(title: "Total tokens", value: Format.tokens(stats.cycleTokens)),
            MetricStat(title: "Input tokens", value: Format.tokens(stats.cycleInputTokens)),
            MetricStat(title: "Output tokens", value: Format.tokens(stats.cycleOutputTokens))
        ])
    }
}
