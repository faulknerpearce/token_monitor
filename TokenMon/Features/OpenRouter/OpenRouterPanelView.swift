import SwiftUI

/// OpenRouter panel with credit budget, stats, and model spend.
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
                ProviderHeaderRow(provider: .openrouter, title: "OpenRouter") {
                    Text(snapshot.budgetSource?.label ?? "No credit limit")
                        .panelMetaLabel()
                }

                PanelCard {
                    PanelSectionHeaderRow(
                        title: "Credit Budget",
                        trailing: snapshot.usedPercent.map { "\(Int($0.rounded()))% Used" }
                    )
                    if let percent = snapshot.usedPercent {
                        SlimUsageTrack(
                            label: "Credits used",
                            percent: percent,
                            color: ProviderColors.openRouterColor,
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

                if !snapshot.models.isEmpty {
                    PanelCard {
                        OpenRouterModelsSection(models: snapshot.models)
                    }
                }

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
                ProviderHeaderRow(provider: .openrouter, title: "OpenRouter")
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
            ProviderHeaderRow(provider: .openrouter, title: "OpenRouter")
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

/// Ranked OpenRouter model spend for the activity window (last 30 UTC days).
struct OpenRouterModelsSection: View {
    let models: [OpenRouterModelUsage]

    private let previewCount = 3
    @State private var showAll = false

    private var visible: [OpenRouterModelUsage] {
        showAll ? models : Array(models.prefix(previewCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader(title: "Top Models by Spend")

            ForEach(Array(visible.enumerated()), id: \.element.id) { index, model in
                OpenRouterModelRow(model: model)
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

private struct OpenRouterModelRow: View {
    let model: OpenRouterModelUsage

    private var costLabel: String {
        let formatted = Format.usd(model.costUSD)
        return model.isCostEstimated ? "~\(formatted)" : formatted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.modelID)
                    .font(PanelTypography.bodySemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if model.isRevealed {
                    Text("revealed").panelMetaLabel()
                }
                Spacer(minLength: 8)
                Text(costLabel)
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            GeometryReader { geo in
                let width = max(0, geo.size.width * CGFloat(max(0, min(100, model.percentOfWindow)) / 100))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(ProviderColors.openRouterColor).frame(width: width)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
    }
}
