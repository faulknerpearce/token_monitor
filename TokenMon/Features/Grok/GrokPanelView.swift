import SwiftUI

struct GrokPanelView: View {
    @ObservedObject var auth: AuthSessionService
    @ObservedObject var poller: UsagePoller
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore

    let openSignIn: () -> Void

    /// 0 = current calendar week; negative = past weeks.
    @State private var weekOffset: Int = 0

    var body: some View {
        if auth.needsSignIn && auth.isSignedIn {
            sessionExpiredHeader
        } else if auth.isSignedIn, let snapshot = poller.snapshot {
            usageHeader(snapshot)
        } else if auth.isSignedIn {
            VStack(alignment: .leading, spacing: 8) {
                grokTitle
                Text(poller.isRefreshing ? "Refreshing…" : (poller.lastError ?? "Signed in — waiting for usage data."))
                    .font(PanelTypography.body)
                    .foregroundStyle(.secondary)
                if poller.lastError != nil {
                    ProviderSignInButton(provider: .grok, title: "Sign In Again…", action: openSignIn)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            signedOutHeader
        }
    }

    private var grokTitle: some View {
        ProviderHeaderLabel(provider: .grok, title: "SuperGrok")
    }

    private var sessionExpiredHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            grokTitle
            Text(poller.lastError ?? "Session expired. Sign in again to load usage.")
                .font(PanelTypography.body)
                .foregroundStyle(.secondary)
            ProviderSignInButton(provider: .grok, title: "Sign In Again…", action: openSignIn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func usageHeader(_ snapshot: WeeklyUsageSnapshot) -> some View {
        // Show only Chat, Build, Imagine, Voice (as requested), defaulting to 0% when unused
        let productsByID = Dictionary(
            snapshot.products.map { ($0.id.lowercased(), $0) },
            uniquingKeysWith: { _, last in last }
        )
        let products: [ProductUsage] = ["chat", "build", "imagine", "voice"].compactMap { id in
            if let existing = productsByID[id] { return existing }
            return ProductUsage(id: id, displayName: ProductCatalog.displayName(for: id), percentOfPool: 0)
        }
        let week = DailyUsageBuilder.week(
            history: history.recent.reversed(),
            current: snapshot,
            serverDaily: snapshot.dailySeries,
            weekOffset: weekOffset,
            resetsAt: snapshot.resetsAt
        )

        VStack(alignment: .leading, spacing: 10) {
            grokTitle

            PanelCard {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    PanelSectionHeader(title: "Weekly Usage")
                    Spacer()
                    PanelPill(text: "\(Int(snapshot.usedPercent.rounded()))% used")
                }

                SegmentedUsageBar(products: products, height: 8)

                if let resetsAt = snapshot.resetsAt {
                    Text("Resets \(Format.resetDate(resetsAt, dateFormat: "EEE dd MMMM h:mma"))")
                        .font(PanelTypography.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            PanelCard {
                PanelSectionHeader(title: "Categories")
                HStack(spacing: 12) {
                    ForEach(products) { product in
                        CategoryRow(product: product)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if let credits = snapshot.extraCreditsBalance, credits > 0 {
                PanelCard {
                    HStack {
                        Text("Extra credits")
                        Spacer()
                        Text(credits as NSDecimalNumber, formatter: Format.usdCurrency)
                    }
                    .font(PanelTypography.body)
                    .foregroundStyle(.tertiary)
                }
            }

            PanelCard {
                DailyUsageChartView(
                    week: week,
                    onPreviousWeek: { weekOffset -= 1 },
                    onNextWeek: { weekOffset = min(0, weekOffset + 1) },
                    canGoNext: weekOffset < 0,
                    periodUsedPercent: weekOffset == 0 ? snapshot.usedPercent : nil
                )
            }

            if let error = poller.lastError {
                Text(error)
                    .font(PanelTypography.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 2)
            }

            ProviderSignOutButton(provider: .grok) {
                auth.signOut()
                poller.clearSnapshot()
            }
        }
    }

    private var signedOutHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            grokTitle
            Text("Sign in to load your usage.")
                .font(PanelTypography.body)
                .foregroundStyle(.secondary)
            ProviderSignInButton(provider: .grok, title: "Sign In…", action: openSignIn)
                .keyboardShortcut("s", modifiers: [.command])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
