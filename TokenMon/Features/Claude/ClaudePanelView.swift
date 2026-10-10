import SwiftUI

/// Claude usage panel (5-hour and weekly windows plus daily bars).
struct ClaudePanelView: View {
    @ObservedObject var poller: ClaudeUsagePoller
    @ObservedObject var auth: ClaudeAuthSession
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
                    poller.clearSnapshot()
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProviderHeaderRow(provider: .claude, title: "Claude")
            Text("Sign in to claude.ai to load your 5-hour and weekly usage.")
                .font(PanelTypography.body)
                .foregroundStyle(.secondary)
            ProviderSignInButton(provider: .claude, action: openSignIn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
