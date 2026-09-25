import AppKit
import SwiftUI

/// Dropdown panel switching between Overview and provider tabs.
struct MenuBarPanelView: View {
    @ObservedObject var auth: AuthSessionService
    @ObservedObject var poller: UsagePoller
    @ObservedObject var openCodeAuth: OpenCodeAuthSession
    @ObservedObject var openCodePoller: OpenCodeUsagePoller
    @ObservedObject var cursorAuth: CursorAuthSession
    @ObservedObject var cursorPoller: CursorUsagePoller
    @ObservedObject var claudeAuth: ClaudeAuthSession
    @ObservedObject var claudePoller: ClaudeUsagePoller
    @ObservedObject var chatGPTAuth: ChatGPTAuthSession
    @ObservedObject var chatGPTPoller: ChatGPTUsagePoller
    @ObservedObject var openRouterAuth: OpenRouterAuthSession
    @ObservedObject var openRouterPoller: OpenRouterUsagePoller
    @ObservedObject var grokbotPoller: GrokbotUsagePoller
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    @ObservedObject var grokHourly: HourlyDeltaActivityStore
    @ObservedObject var claudeHourly: HourlyDeltaActivityStore
    @ObservedObject var grokbotHourly: HourlyDeltaActivityStore

    let openPreferences: () -> Void
    let openSignIn: () -> Void
    let openOpenCodeSignIn: () -> Void
    let openCursorSignIn: () -> Void
    let openClaudeSignIn: () -> Void
    let openChatGPTSignIn: () -> Void
    let selectOpenRouter: () -> Void

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
        }
        .padding(12)
        .frame(width: Self.panelWidth)
        .environment(\.openPreferences, openPreferences)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            poller.menuIsOpen = true
            openCodePoller.menuIsOpen = true
            cursorPoller.menuIsOpen = true
            claudePoller.menuIsOpen = true
            chatGPTPoller.menuIsOpen = true
            openRouterPoller.menuIsOpen = true
            grokbotPoller.menuIsOpen = true
            Task { await refreshActivePoller() }
        }
        .onDisappear {
            poller.menuIsOpen = false
            openCodePoller.menuIsOpen = false
            cursorPoller.menuIsOpen = false
            claudePoller.menuIsOpen = false
            chatGPTPoller.menuIsOpen = false
            openRouterPoller.menuIsOpen = false
            grokbotPoller.menuIsOpen = false
        }
        .onChange(of: settings.selectedProvider) { _, _ in
            Task { await refreshActivePoller() }
        }
        .onChange(of: settings.enabledProviderIDs) { _, ids in
            if settings.selectedProvider != .overview && !ids.contains(settings.selectedProvider) {
                settings.selectedProvider = .overview
            }
        }
        .onChange(of: settings.showOpenCodeBarInMenuBar) { _, enabled in
            if enabled { Task { await openCodePoller.refreshNow() } }
        }
        .onChange(of: settings.showCursorBarInMenuBar) { _, enabled in
            if enabled { Task { await cursorPoller.refreshNow() } }
        }
        .onChange(of: settings.showClaudeBarInMenuBar) { _, enabled in
            if enabled { Task { await claudePoller.refreshNow() } }
        }
        .onChange(of: settings.showGrokbotBarInMenuBar) { _, enabled in
            if enabled { Task { await grokbotPoller.refreshNow() } }
        }
    }

    private func refreshActivePoller() async {
        // Menu bar always shows Grok, so always refresh it.
        async let grok: Void = poller.refreshNow()
        async let openCode: Void = {
            if settings.needsOpenCodePolling {
                await openCodePoller.refreshNow()
            }
        }()
        async let cursor: Void = {
            if settings.needsCursorPolling {
                await cursorPoller.refreshNow()
            }
        }()
        async let claude: Void = {
            if settings.needsClaudePolling {
                await claudePoller.refreshNow()
            }
        }()
        async let chatGPT: Void = {
            if settings.needsChatGPTPolling {
                await chatGPTPoller.refreshNow()
            }
        }()
        async let openRouter: Void = {
            if settings.needsOpenRouterPolling {
                await openRouterPoller.refreshNow()
            }
        }()
        async let grokbot: Void = {
            if settings.needsGrokbotPolling {
                await grokbotPoller.refreshNow()
            }
        }()
        _ = await (grok, openCode, cursor, claude, chatGPT, openRouter, grokbot)
    }

    private var grokContent: some View {
        GrokPanelView(
            auth: auth,
            poller: poller,
            settings: settings,
            history: history,
            openSignIn: openSignIn
        )
    }

    @ViewBuilder
    private var openCodeContent: some View {
        OpenCodePanelView(
            poller: openCodePoller,
            auth: openCodeAuth,
            openSignIn: openOpenCodeSignIn
        )
    }

    @ViewBuilder
    private var cursorContent: some View {
        CursorPanelView(
            poller: cursorPoller,
            auth: cursorAuth,
            openSignIn: openCursorSignIn
        )
    }

    private var claudeContent: some View {
        ClaudePanelView(
            poller: claudePoller,
            auth: claudeAuth,
            openSignIn: openClaudeSignIn
        )
    }

    private var chatGPTContent: some View {
        ChatGPTPanelView(
            poller: chatGPTPoller,
            auth: chatGPTAuth,
            openSignIn: openChatGPTSignIn
        )
    }

    private var grokbotContent: some View {
        GrokbotPanelView(
            poller: grokbotPoller,
            auth: cursorAuth,
            openSignIn: openCursorSignIn
        )
    }

    private var openRouterContent: some View {
        OpenRouterPanelView(
            poller: openRouterPoller,
            auth: openRouterAuth
        )
    }

    private var overviewContent: some View {
        OverviewPanelView(
            grokPoller: poller,
            openCodePoller: openCodePoller,
            cursorPoller: cursorPoller,
            claudePoller: claudePoller,
            chatGPTPoller: chatGPTPoller,
            openRouterPoller: openRouterPoller,
            grokbotPoller: grokbotPoller,
            settings: settings,
            grokHourly: grokHourly,
            claudeHourly: claudeHourly,
            grokbotHourly: grokbotHourly,
            grokAuth: auth,
            openCodeAuth: openCodeAuth,
            cursorAuth: cursorAuth,
            claudeAuth: claudeAuth,
            chatGPTAuth: chatGPTAuth,
            openRouterAuth: openRouterAuth,
            openGrokSignIn: openSignIn,
            openOpenCodeSignIn: openOpenCodeSignIn,
            openCursorSignIn: openCursorSignIn,
            openClaudeSignIn: openClaudeSignIn,
            openChatGPTSignIn: openChatGPTSignIn,
            selectOpenRouter: selectOpenRouter,
            openPreferences: openPreferences
        )
    }
}
