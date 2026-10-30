import AppKit
import SwiftUI

/// Dropdown panel switching between Overview and provider tabs.
///
/// Observes only `settings` (tab list and selection); each tab view observes
/// its own pollers and sessions, so only polls of the visible provider
/// re-render the visible tab.
struct MenuBarPanelView: View {
    let model: AppModel
    @Bindable var settings: AppSettings
    let openWindow: (AppWindow) -> Void

    /// Fixed dropdown width. The panel host sizes only its height, so the
    /// provider tabs keep a fixed horizontal position.
    static let panelWidth: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProviderSwitcherView(
                providers: [.overview] + settings.visibleUsageProviders,
                selection: $settings.selectedProvider
            )

            Color.clear.frame(height: 12)

            switch settings.selectedProvider {
            case .overview:
                overviewContent
            case .opencode:
                openCodeContent
            case .cursor:
                cursorContent
            case .grok:
                grokContent
            case .claude:
                claudeContent
            case .chatgpt:
                chatGPTContent
            case .openrouter:
                openRouterContent
            case .grokbot:
                grokbotContent
            }

            UpdateAvailableIndicator()
        }
        .padding(12)
        .frame(width: Self.panelWidth)
        .environment(\.openPreferences) { openWindow(.preferences) }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var grokContent: some View {
        GrokPanelView(
            auth: model.grokAuth,
            poller: model.grokPoller,
            settings: settings,
            openSignIn: { openWindow(.signIn(.grok)) }
        )
    }

    /// Open/closed state of `section`, read from and saved to settings.
    private func expansion(of section: PanelSection) -> Binding<Bool> {
        Binding(
            get: { settings.isExpanded(section) },
            set: { settings.setExpanded($0, for: section) }
        )
    }

    private var openCodeContent: some View {
        OpenCodePanelView(
            poller: model.openCodePoller,
            auth: model.openCodeAuth,
            modelsExpanded: expansion(of: .openCodeModels),
            openSignIn: { openWindow(.signIn(.opencode)) }
        )
    }

    private var cursorContent: some View {
        CursorPanelView(
            poller: model.cursorPoller,
            auth: model.cursorAuth,
            openSignIn: { openWindow(.signIn(.cursor)) }
        )
    }

    private var claudeContent: some View {
        ClaudePanelView(
            poller: model.claudePoller,
            auth: model.claudeAuth,
            modelsExpanded: expansion(of: .claudeModels),
            openSignIn: { openWindow(.signIn(.claude)) }
        )
    }

    private var chatGPTContent: some View {
        ChatGPTPanelView(
            poller: model.chatGPTPoller,
            auth: model.chatGPTAuth,
            openSignIn: { openWindow(.signIn(.chatgpt)) }
        )
    }

    private var grokbotContent: some View {
        GrokbotPanelView(
            poller: model.grokbotPoller,
            auth: model.cursorAuth,
            openSignIn: { openWindow(.signIn(.cursor)) }
        )
    }

    private var openRouterContent: some View {
        OpenRouterPanelView(
            poller: model.openRouterPoller,
            auth: model.openRouterAuth
        )
    }

    private var overviewContent: some View {
        OverviewPanelView(
            grokPoller: model.grokPoller,
            openCodePoller: model.openCodePoller,
            cursorPoller: model.cursorPoller,
            claudePoller: model.claudePoller,
            chatGPTPoller: model.chatGPTPoller,
            openRouterPoller: model.openRouterPoller,
            grokbotPoller: model.grokbotPoller,
            settings: settings,
            grokHourly: model.grokHourly,
            claudeHourly: model.claudeHourly,
            grokbotHourly: model.grokbotHourly,
            hourlyHistory: model.overviewHistory,
            todaySeries: { [model] date in model.overviewSeries(on: date) },
            grokAuth: model.grokAuth,
            openCodeAuth: model.openCodeAuth,
            cursorAuth: model.cursorAuth,
            claudeAuth: model.claudeAuth,
            chatGPTAuth: model.chatGPTAuth,
            openRouterAuth: model.openRouterAuth,
            openSignIn: { openWindow(.signIn($0)) },
            selectOpenRouter: { settings.selectedProvider = .openrouter },
            openPreferences: { openWindow(.preferences) }
        )
    }
}
