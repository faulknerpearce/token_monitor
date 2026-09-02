import AppKit
import SwiftUI

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
    @ObservedObject var updateChecker: UpdateChecker
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

            Divider().padding(.vertical, 6)

            menuActions
        }
        .padding(12)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeInOut(duration: 0.15), value: settings.selectedProvider)
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
            hourly: claudeHourly,
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
            selectOpenRouter: selectOpenRouter
        )
    }

    private var menuActions: some View {
        VStack(spacing: 2) {
            panelButton("Refresh Now", shortcut: "⌘R") {
                Task { await refreshActivePoller() }
            }
            .keyboardShortcut("r", modifiers: [.command])

            switch settings.selectedProvider {
            case .grok:
                Toggle(isOn: $settings.showCategoriesInMenuBar) {
                    toggleLabel("Show Categories in Menu Bar", isOn: settings.showCategoriesInMenuBar)
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .font(PanelTypography.body)

                Toggle(isOn: $settings.showGrokBarInMenuBar) {
                    toggleLabel("Show Bar Graph in Menu Bar", isOn: settings.showGrokBarInMenuBar)
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .font(PanelTypography.body)

                if !auth.isSignedIn {
                    panelButton("Sign In…", shortcut: nil, action: openSignIn)
                }
            case .opencode:
                Toggle(isOn: $settings.showOpenCodeBarInMenuBar) {
                    toggleLabel("Show Bar Graph in Menu Bar", isOn: settings.showOpenCodeBarInMenuBar)
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .font(PanelTypography.body)
            case .cursor:
                Toggle(isOn: $settings.showCursorBarInMenuBar) {
                    toggleLabel("Show Bar Graph in Menu Bar", isOn: settings.showCursorBarInMenuBar)
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .font(PanelTypography.body)
            case .claude:
                Toggle(isOn: $settings.showClaudeBarInMenuBar) {
                    toggleLabel("Show Bar Graph in Menu Bar", isOn: settings.showClaudeBarInMenuBar)
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .font(PanelTypography.body)
            case .chatgpt:
                EmptyView()
            case .openrouter:
                EmptyView()
            case .grokbot:
                Toggle(isOn: $settings.showGrokbotBarInMenuBar) {
                    toggleLabel("Show Bar Graph in Menu Bar", isOn: settings.showGrokbotBarInMenuBar)
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .font(PanelTypography.body)
            case .overview:
                EmptyView()
            }

            Divider().padding(.vertical, 4)

            if let release = updateChecker.availableRelease {
                panelButton("Update to \(release.version.description)…", shortcut: nil) {
                    NSWorkspace.shared.open(release.pageURL)
                }
            }

            panelButton("Settings", shortcut: "⌘O", action: openPreferences)
                .keyboardShortcut("o", modifiers: [.command])

            if let url = settings.selectedProvider.websiteURL {
                let title: String = {
                    switch settings.selectedProvider {
                    case .grok: return "Open Grok.com"
                    case .cursor: return "Open Cursor.com"
                    case .opencode: return "Open Opencode.com"
                    case .claude: return "Open Claude.ai"
                    case .chatgpt: return "Open ChatGPT.com"
                    case .openrouter: return "Open OpenRouter.ai"
                    case .grokbot: return "Open Cursor.com/bot"
                    case .overview: return "Visit website"
                    }
                }()
                panelButton(title, shortcut: nil) {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider().padding(.vertical, 4)

            panelButton("Quit TokenMon", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }

    private func panelButton(_ title: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.secondary)
                        .font(PanelTypography.body)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .font(PanelTypography.body)
    }

    private func toggleLabel(_ title: String, isOn: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if isOn {
                Image(systemName: "checkmark")
                    .font(PanelTypography.bodySemibold)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }
}
