import SwiftUI

struct ClaudePanelView: View {
    @ObservedObject var poller: ClaudeUsagePoller
    @ObservedObject var auth: ClaudeAuthSession
    @ObservedObject var hourly: HourlyDeltaActivityStore
    let openSignIn: () -> Void

    var body: some View {
        if auth.needsSignIn && poller.snapshot == nil {
            signedOut
        } else if let snapshot = poller.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProviderHeaderLabel(provider: .claude, title: "Claude")
                    Spacer()
                    if let email = snapshot.accountEmail {
                        Text(email)
                            .font(PanelTypography.captionMedium)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                PanelCard {
                    PanelSectionHeader(title: "Usage")
                    SlimUsageTrack(
                        label: "5-Hour Window",
                        percent: snapshot.fiveHour?.usedPercent ?? 0,
                        color: ConcentricUsageRingView.claudeColor,
                        caption: snapshot.fiveHour?.resetsAt.map { "Resets \(Format.resetDate($0, dateFormat: "EEE dd MMMM h:mma"))" }
                    )
                    SlimUsageTrack(
                        label: "Weekly",
                        percent: snapshot.sevenDay?.usedPercent ?? 0,
                        color: ConcentricUsageRingView.claudeColor,
                        caption: snapshot.sevenDay?.resetsAt.map { "Resets \(Format.resetDate($0, dateFormat: "EEE dd MMMM h:mma"))" }
                    )
                }

                if let days = poller.dailyBudgetDays, !days.isEmpty {
                    PanelCard {
                        DailyBudgetBarsView(
                            days: days,
                            accent: ConcentricUsageRingView.claudeColor,
                            allowanceNoun: "weekly",
                            infoText: "Share of weekly allowance per day "
                                + "(budget 14.3%/day)."
                        )
                    }
                }

                if auth.needsSignIn || poller.lastError != nil {
                    if let err = poller.lastError {
                        Text(err)
                            .font(PanelTypography.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ProviderSignInButton(
                        provider: .claude,
                        title: auth.needsSignIn ? "Sign In to Claude…" : "Sign In Again…",
                        action: openSignIn
                    )
                    .padding(.top, 8)
                }

                ProviderSignOutButton(provider: .claude) {
                    auth.signOut()
                    poller.clearSnapshot()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ProviderHeaderLabel(provider: .claude, title: "Claude")
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
            ProviderHeaderLabel(provider: .claude, title: "Claude")
            Text("Sign in to claude.ai to load your 5-hour and weekly usage.")
                .font(PanelTypography.body)
                .foregroundStyle(.secondary)
            ProviderSignInButton(provider: .claude, action: openSignIn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
