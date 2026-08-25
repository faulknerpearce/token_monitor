import AppKit
import SwiftUI

struct OpenCodePanelView: View {
    @ObservedObject var poller: OpenCodeUsagePoller
    @ObservedObject var auth: OpenCodeAuthSession
    let openSignIn: () -> Void

    var body: some View {
        if auth.needsSignIn && poller.snapshot == nil {
            signedOut
        } else if let snapshot = poller.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProviderHeaderLabel(provider: .opencode, title: "OpenCode Go")
                    Spacer()
                    if let source = poller.dataSourceLabel {
                        Text(source)
                            .font(PanelTypography.captionMedium)
                            .foregroundStyle(snapshot.isEstimated ? Color.orange : Color.secondary)
                    }
                }

                PanelCard {
                    PanelSectionHeader(title: "Limits")
                    ForEach(snapshot.windows) { window in
                        OpenCodeLimitBar(window: window)
                    }
                    if snapshot.isEstimated {
                        Text("Estimated from local sessions — sign in for console accuracy.")
                            .font(PanelTypography.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if let days = poller.dailyBudgetDays, !days.isEmpty {
                    PanelCard {
                        DailyBudgetBarsView(
                            days: days,
                            accent: ModelPalette.purple.color,
                            allowanceNoun: "monthly",
                            infoText: "Go-only share of monthly quota per day. "
                                + "Last 7 days shown.",
                            periodUsedPercent: snapshot.monthlyUsedPercent
                        )
                    }
                }

                if !snapshot.models.isEmpty {
                    PanelCard {
                        OpenCodeModelsSection(models: snapshot.models)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    PanelSectionHeader(title: "Stats")
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    OpenCodeStatsRow(
                        monthlySpendUSD: snapshot.monthlyEstimatedUSD,
                        totalTokens: snapshot.monthlyTokens,
                        inputTokens: snapshot.monthlyInputTokens,
                        outputTokens: snapshot.monthlyOutputTokens
                    )
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

                if auth.needsSignIn || poller.lastError != nil {
                    if let err = poller.lastError {
                        Text(err)
                            .font(PanelTypography.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ProviderSignInButton(
                        provider: .opencode,
                        title: auth.needsSignIn ? "Sign In to OpenCode…" : "Sign In Again…",
                        action: openSignIn
                    )
                    .padding(.top, 8)
                }

                ProviderSignOutButton(provider: .opencode) {
                    auth.signOut()
                    poller.clearSnapshot()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ProviderHeaderLabel(provider: .opencode, title: "OpenCode Go")
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
            ProviderHeaderLabel(provider: .opencode, title: "OpenCode Go")
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

/// Compact ranked list of Go/Zen models with company logo + usage bar.
struct OpenCodeModelsSection: View {
    let models: [OpenCodeModelUsage]

    private let previewCount = 3
    @State private var showAll = false

    private var visible: [OpenCodeModelUsage] {
        showAll ? models : Array(models.prefix(previewCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader(title: "Top Models by Spend")

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

// MARK: - Company logo helper (uses provider SVGs from temp → Assets, circles)

private enum ModelCompany {
    case kimi, qwen, glm, minimax, deepseek, nvidia, muse, anthropic, openai, meta, other

    static func forModelID(_ id: String) -> Self {
        let lower = id.lowercased()
        // Muse Spark is actually Meta — check before generic "muse"
        if lower.contains("muse-spark") || lower.contains("muse_spark") { return .meta }
        if lower.contains("kimi") { return .kimi }
        if lower.contains("qwen") { return .qwen }
        if lower.contains("glm") { return .glm }
        if lower.contains("mimo") || lower.contains("minimax") { return .minimax }
        if lower.contains("deepseek") { return .deepseek }
        if lower.contains("nvidia") { return .nvidia }
        if lower.contains("muse") { return .muse }
        if lower.contains("claude") || lower.contains("anthropic") { return .anthropic }
        if lower.contains("gpt") || lower.contains("openai") { return .openai }
        if lower.contains("llama") || lower.contains("meta") { return .meta }
        return .other
    }

    var displayName: String {
        switch self {
        case .kimi: return "moonshotai"
        case .qwen: return "qwen"
        case .glm: return "z-ai"
        case .minimax: return "minimax"
        case .deepseek: return "deepseek"
        case .nvidia: return "nvidia"
        case .muse: return "muse"
        case .anthropic: return "anthropic"
        case .openai: return "openai"
        case .meta: return "meta"
        case .other: return "other"
        }
    }

    var assetName: String? {
        switch self {
        case .kimi: return "KimiLogo"
        case .qwen: return "AlibabaLogo"
        case .glm: return "ZaiLogo"
        case .minimax: return "MinimaxLogo"
        case .deepseek: return "DeepSeekLogo"
        case .nvidia: return "NvidiaLogo"
        case .muse: return nil
        case .anthropic: return "AnthropicLogo"
        case .openai: return "OpenAILogo"
        case .meta: return "MetaLogo"
        case .other: return nil
        }
    }

    var letter: String {
        switch self {
        case .kimi: return "K"
        case .qwen: return "Q"
        case .glm: return "Z"
        case .minimax: return "M"
        case .deepseek: return "D"
        case .nvidia: return "N"
        case .muse: return "M"
        case .anthropic: return "A"
        case .openai: return "O"
        case .meta: return "M"
        case .other: return "•"
        }
    }

    var logoBackground: Color {
        switch self {
        case .kimi: return Color(red: 0.12, green: 0.12, blue: 0.13)
        case .qwen: return Color(red: 0.32, green: 0.25, blue: 0.65)
        case .glm: return Color.white
        case .minimax: return Color(red: 0.95, green: 0.25, blue: 0.40)
        case .deepseek: return Color(red: 0.11, green: 0.38, blue: 0.82)
        case .nvidia: return Color(red: 0.45, green: 0.72, blue: 0.11)
        case .muse: return Color(red: 0.90, green: 0.20, blue: 0.22)
        case .anthropic: return Color(red: 0.85, green: 0.65, blue: 0.25)
        case .openai: return Color(red: 0.10, green: 0.10, blue: 0.10)
        case .meta: return Color(red: 0.05, green: 0.45, blue: 0.95)
        case .other: return Color.primary.opacity(0.12)
        }
    }

    var logoForeground: Color {
        self == .glm ? .black : .white
    }
}

private struct ModelCompanyLogo: View {
    let modelID: String
    private var company: ModelCompany { ModelCompany.forModelID(modelID) }

    var body: some View {
        Group {
            if let asset = company.assetName {
                ZStack {
                    Circle().fill(Color.white)
                    Image(asset, bundle: nil)
                        .resizable()
                        .scaledToFit()
                        // Template logos (OpenAI, Anthropic) must tint dark so they
                        // stay visible on the white backing in dark mode.
                        .foregroundStyle(Color.black)
                        .padding(company == .deepseek ? 5 : 4)
                        .frame(width: 28, height: 28, alignment: .center)
                }
            } else {
                ZStack {
                    Circle().fill(company.logoBackground)
                    Text(company.letter)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(company.logoForeground)
                }
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct OpenCodeModelWeekRow: View {
    let model: OpenCodeModelUsage

    private var accent: Color {
        ModelPalette.sRGB(forProvider: model.providerID, seed: model.id).color
    }

    private var costLabel: String {
        let formatted = Format.usdCurrency.string(from: NSNumber(value: model.costUSD)) ?? "$0"
        if model.isCostEstimated {
            return "~\(formatted)"
        }
        return formatted
    }

    private var company: ModelCompany { ModelCompany.forModelID(model.modelID) }

    private var displayModelName: String {
        // Use catalog display but prefer short "Kimi K2.6" style; fall back to raw id.
        let lower = model.modelID.lowercased()
        if lower.contains("muse-spark") { return "Muse Spark" }
        // Turn "kimi-k2.6" → "Kimi K2.6", "qwen3.6-plus" → "Qwen3.6 Plus"
        let base = model.modelID.replacingOccurrences(of: "-", with: " ").capitalized
        return base
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ModelCompanyLogo(modelID: model.modelID)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayModelName)
                        .font(PanelTypography.bodySemibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(company.displayName)
                        .font(PanelTypography.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
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
