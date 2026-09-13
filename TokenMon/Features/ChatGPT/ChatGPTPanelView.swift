import SwiftUI

struct ChatGPTPanelView: View {
    @ObservedObject var poller: ChatGPTUsagePoller
    @ObservedObject var auth: ChatGPTAuthSession
    let openSignIn: () -> Void

    var body: some View {
        if auth.needsSignIn && poller.snapshot == nil {
            signedOut
        } else if let snapshot = poller.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProviderHeaderLabel(provider: .chatgpt, title: "ChatGPT")
                    Spacer()
                    Text(snapshot.displayPlanName)
                        .font(PanelTypography.captionMedium)
                        .foregroundStyle(.secondary)
                }

                PanelCard {
                    PanelSectionHeaderRow(
                        title: snapshot.usagePool.sectionTitle,
                        pill: "\(Int(snapshot.headlineUsedPercent.rounded()))% used"
                    )
                    SlimUsageTrack(
                        label: "5-Hour Window",
                        percent: snapshot.primary?.usedPercent ?? 0,
                        color: ConcentricUsageRingView.chatgptColor,
                        caption: snapshot.limitReached
                            ? "Limit reached"
                            : snapshot.primary?.resetsAt.map { "Resets \(Format.resetDate($0, dateFormat: "EEE dd MMMM h:mma"))" }
                    )
                    SlimUsageTrack(
                        label: "Weekly",
                        percent: snapshot.secondary?.usedPercent ?? 0,
                        color: ConcentricUsageRingView.chatgptColor,
                        caption: snapshot.secondary?.resetsAt.map { "Resets \(Format.resetDate($0, dateFormat: "EEE dd MMMM h:mma"))" }
                    )
                    if !snapshot.allowed {
                        Text("Codex access is currently blocked for this account.")
                            .font(PanelTypography.caption)
                            .foregroundStyle(.secondary)
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
                        provider: .chatgpt,
                        title: auth.needsSignIn ? "Sign In to ChatGPT…" : "Sign In Again…",
                        action: openSignIn
                    )
                    .padding(.top, 8)
                }

                ProviderSignOutButton(provider: .chatgpt) {
                    auth.signOut()
                    poller.clearSnapshot()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ProviderHeaderLabel(provider: .chatgpt, title: "ChatGPT")
                Text(poller.isRefreshing ? "Refreshing…" : (poller.lastError ?? "No usage data yet."))
                    .font(PanelTypography.body)
                    .foregroundStyle(.secondary)
                if auth.needsSignIn {
                    ProviderSignInButton(provider: .chatgpt, action: openSignIn)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProviderHeaderLabel(provider: .chatgpt, title: "ChatGPT")
            Text("Sign in to chatgpt.com to load your 5-hour and weekly Codex usage.")
                .font(PanelTypography.body)
                .foregroundStyle(.secondary)
            ProviderSignInButton(provider: .chatgpt, action: openSignIn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
