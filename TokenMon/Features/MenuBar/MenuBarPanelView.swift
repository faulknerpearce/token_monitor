import AppKit
import SwiftUI

/// Dropdown panel switching between Overview and provider tabs.
///
/// Observes only `settings` (tab list and selection); each tab view observes
/// its own pollers and sessions, so a poll of a hidden provider does not
/// re-render the visible tab.
struct MenuBarPanelView: View {
    let model: AppModel
    @ObservedObject var settings: AppSettings
    let openWindow: (AppWindowID) -> Void

    /// Fixed dropdown width. The panel host sizes only its height, so the
    /// provider tabs never move horizontally.
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
            auth: model.auth,
            poller: model.poller,
            settings: settings,
            history: model.history,
            openSignIn: { openWindow(.grokSignIn) }
        )
    }

    private var openCodeContent: some View {
        OpenCodePanelView(
            poller: model.openCodePoller,
            auth: model.openCodeAuth,
            openSignIn: { openWindow(.openCodeSignIn) }
        )
    }

    private var cursorContent: some View {
        CursorPanelView(
            poller: model.cursorPoller,
            auth: model.cursorAuth,
            openSignIn: { openWindow(.cursorSignIn) }
        )
    }

    private var claudeContent: some View {
        ClaudePanelView(
            poller: model.claudePoller,
            auth: model.claudeAuth,
            openSignIn: { openWindow(.claudeSignIn) }
        )
    }

    private var chatGPTContent: some View {
        ChatGPTPanelView(
            poller: model.chatGPTPoller,
            auth: model.chatGPTAuth,
            openSignIn: { openWindow(.chatGPTSignIn) }
        )
    }

    private var grokbotContent: some View {
        GrokbotPanelView(
            poller: model.grokbotPoller,
            auth: model.cursorAuth,
            openSignIn: { openWindow(.cursorSignIn) }
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
            grokPoller: model.poller,
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
            grokAuth: model.auth,
            openCodeAuth: model.openCodeAuth,
            cursorAuth: model.cursorAuth,
            claudeAuth: model.claudeAuth,
            chatGPTAuth: model.chatGPTAuth,
            openRouterAuth: model.openRouterAuth,
            openGrokSignIn: { openWindow(.grokSignIn) },
            openOpenCodeSignIn: { openWindow(.openCodeSignIn) },
            openCursorSignIn: { openWindow(.cursorSignIn) },
            openClaudeSignIn: { openWindow(.claudeSignIn) },
            openChatGPTSignIn: { openWindow(.chatGPTSignIn) },
            selectOpenRouter: { settings.selectedProvider = .openrouter },
            openPreferences: { openWindow(.preferences) }
        )
    }
}
