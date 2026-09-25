import SwiftUI

struct GrokbotPanelView: View {
    @ObservedObject var poller: GrokbotUsagePoller
    /// Grok Bot rides on the Cursor account, so this is the shared Cursor session.
    @ObservedObject var auth: CursorAuthSession
    let openSignIn: () -> Void

    var body: some View {
        if auth.needsSignIn && poller.snapshot == nil {
            signedOut
        } else if let snapshot = poller.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                ProviderHeaderRow(provider: .grokbot, title: "Grokbot")

                PanelCard {
                    PanelSectionHeaderRow(
                        title: snapshot.usagePool.sectionTitle,
                        trailing: "\(Int(snapshot.usedPercent.rounded()))% Used"
                    )
                    if snapshot.hasIncludedAllowance {
                        SlimUsageTrack(
                            label: "Weekly",
                            percent: snapshot.usedPercent,
                            color: ProviderColors.grokbotColor,
                            caption: snapshot.resetsAt.map { Format.resetCaption($0) },
                            showsLabel: false
                        )
                    } else {
                        Text("This plan has no included Bot allowance — usage bills on demand.")
                            .font(PanelTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if snapshot.hasIncludedAllowance, let days = poller.dailyBudgetDays, !days.isEmpty {
                    PanelCard {
                        WeeklyDailyBudgetBarsView(
                            days: days,
                            accent: ProviderColors.grokbotColor,
                            periodUsedPercent: snapshot.usedPercent,
                            resetsAt: snapshot.resetsAt
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
                        provider: .grokbot,
                        title: auth.needsSignIn ? "Sign In to Cursor…" : "Sign In Again…",
                        action: openSignIn
                    )
                    .padding(.top, 8)
                }

                // The session belongs to Cursor, so the confirm prompt names Cursor:
                // signing out here also ends the Cursor provider's session.
                ProviderSignOutButton(provider: .cursor) {
                    auth.signOut()
                    poller.clearSnapshot()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ProviderHeaderRow(provider: .grokbot, title: "Grokbot")
                Text(poller.isRefreshing ? "Refreshing…" : (poller.lastError ?? "No usage data yet."))
                    .font(PanelTypography.body)
                    .foregroundStyle(.secondary)
                if auth.needsSignIn {
                    ProviderSignInButton(provider: .grokbot, action: openSignIn)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProviderHeaderRow(provider: .grokbot, title: "Grokbot")
            Text("Sign in to Cursor to load your weekly Grokbot allowance. "
                + "Grokbot is billed through Cursor even when a SuperGrok plan pays for it.")
                .font(PanelTypography.body)
                .foregroundStyle(.secondary)
            ProviderSignInButton(provider: .grokbot, action: openSignIn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
