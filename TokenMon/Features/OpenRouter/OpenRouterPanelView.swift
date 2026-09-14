import SwiftUI

struct OpenRouterPanelView: View {
    @ObservedObject var poller: OpenRouterUsagePoller
    @ObservedObject var auth: OpenRouterAuthSession
    @State private var apiKeyDraft = ""
    @State private var isReplacingKey = false

    var body: some View {
        if auth.needsSignIn && poller.snapshot == nil {
            signedOut
        } else if let snapshot = poller.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProviderHeaderLabel(provider: .openrouter, title: "OpenRouter")
                    Spacer()
                    Text(snapshot.budgetSource?.label ?? "No credit limit")
                        .font(PanelTypography.captionMedium)
                        .foregroundStyle(.secondary)
                }

                PanelCard {
                    PanelSectionHeaderRow(
                        title: "Credit Budget",
                        trailing: snapshot.usedPercent.map { "\(Int($0.rounded()))% used" }
                    )
                    if let percent = snapshot.usedPercent {
                        SlimUsageTrack(
                            label: "Credits used",
                            percent: percent,
                            color: ConcentricUsageRingView.openRouterColor,
                            caption: "\(Format.usd(snapshot.usedUSD)) of \(Format.usd(snapshot.budgetUSD ?? 0))"
                                + " · \(Format.usd(snapshot.remainingUSD ?? 0)) left",
                            showsLabel: false
                        )
                    } else {
                        Text("This key has no credit limit, so usage shows as spend only.")
                            .font(PanelTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    PanelSectionHeader(title: "Stats")
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    MetricStatGrid([
                        MetricStat(title: "Credits purchased", value: Format.usd(snapshot.accountCreditsUSD ?? snapshot.keyLimitUSD ?? 0)),
                        MetricStat(title: "Total spent", value: Format.usd(snapshot.accountUsedUSD ?? snapshot.keyUsageUSD)),
                        MetricStat(title: "Remaining", value: Format.usd(snapshot.remainingUSD ?? 0)),
                        MetricStat(title: "Spent today", value: Format.usd(snapshot.keyUsageDailyUSD))
                    ])
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

                if let err = poller.lastError {
                    Text(err)
                        .font(PanelTypography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                replaceKeyRow

                ProviderSignOutButton(provider: .openrouter) {
                    auth.signOut()
                    poller.clearSnapshot()
                    apiKeyDraft = ""
                    isReplacingKey = false
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ProviderHeaderLabel(provider: .openrouter, title: "OpenRouter")
                Text(poller.isRefreshing ? "Refreshing…" : (poller.lastError ?? "No usage data yet."))
                    .font(PanelTypography.body)
                    .foregroundStyle(.secondary)
                keyEntryFields
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProviderHeaderLabel(provider: .openrouter, title: "OpenRouter")
            Text("Paste an OpenRouter API key to track spending against your purchased credits.")
                .font(PanelTypography.body)
                .foregroundStyle(.secondary)
            keyEntryFields
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var keyEntryFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField("sk-or-v1-…", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Button(isReplacingKey ? "Save Key" : "Add Key") { saveKey() }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let err = auth.lastAuthError {
                Text(err)
                    .font(PanelTypography.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// Signed-in escape hatch to swap an expired/rotated key without signing out first.
    @ViewBuilder
    private var replaceKeyRow: some View {
        if isReplacingKey || auth.needsSignIn {
            keyEntryFields
                .padding(.top, 4)
        } else {
            Button("Replace API Key…") {
                apiKeyDraft = ""
                isReplacingKey = true
            }
            .font(PanelTypography.caption)
            .buttonStyle(.link)
        }
    }

    private func saveKey() {
        guard auth.saveAPIKey(apiKeyDraft) else { return }
        isReplacingKey = false
        apiKeyDraft = ""
        Task { await poller.refreshNow() }
    }
}
