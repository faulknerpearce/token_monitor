import SwiftUI

/// Cursor usage panel (pools, daily bars, and cost stats).
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
                ProviderHeaderRow(provider: .cursor, title: "Cursor") {
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

                NavigableDailyBudgetCard(
                    style: .monthly,
                    accent: ProviderColors.cursorColor,
                    periodUsedPercent: cursorModelsPercent,
                    periodStart: snapshot.billingCycleStart,
                    resetsAt: snapshot.billingCycleEnd,
                    daysForWeek: { poller.dailyBudgetDays(weekOffset: $0) ?? [] }
                )

                if let stats = snapshot.costStats {
                    CursorStatsGrid(stats: stats)
                }

                if let err = poller.lastError {
                    StaleDataCaption(message: err, lastRefreshedAt: poller.lastRefreshedAt)
                        .padding(.top, 8)
                }
                // Only a rejected session needs a new sign-in; network and
                // server errors clear on a later refresh.
                if auth.needsSignIn {
                    ProviderSignInButton(provider: .cursor, title: "Sign In Again…", action: openSignIn)
                        .padding(.top, 8)
                }

                ProviderSignOutButton(provider: .cursor) {
                    auth.signOut()
                    poller.clearSnapshot()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ProviderHeaderRow(provider: .cursor, title: "Cursor")
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
            ProviderHeaderRow(provider: .cursor, title: "Cursor")
            Text("Sign in to cursor.com to load Total, Auto, and API usage.")
                .font(PanelTypography.body)
                .foregroundStyle(.secondary)
            ProviderSignInButton(provider: .cursor, action: openSignIn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Cycle and lifetime spend/token totals for `CursorSnapshot.costStats`.
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
