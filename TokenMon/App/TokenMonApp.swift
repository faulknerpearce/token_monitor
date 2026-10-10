import AppKit
import Combine
import SwiftUI

/// Menu-bar app root wiring `AppModel` to settings and sign-in scenes.
@main
struct TokenMonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model: AppModel
    /// Owns the `NSStatusItem` + dropdown that replace `MenuBarExtra`. Self-registers
    /// in `init`, so it is retained for the app's lifetime and never read directly.
    private let menuBar: MenuBarController

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        // A click on a provider's menu bar graph opens that provider's dropdown.
        menuBar = MenuBarController(model: model)
    }

    var body: some Scene {
        // TokenMon lives in the menu bar, but SwiftUI presents the app's *first*
        // scene at launch. `AppDelegate` dismisses that auto-presented window so
        // launching shows only the menu bar item; Settings opens on request from
        // the menu bar's Settings button.
        Window("TokenMon", id: AppWindowID.preferences.rawValue) {
            PreferencesRoot(model: model)
                .onDisappear { AppDelegate.hideDockIfNoWindows() }
        }
        .defaultSize(width: 480, height: 640)

        Window("Sign in to Grok", id: AppWindowID.grokSignIn.rawValue) {
            SignInView(auth: model.auth) {
                Task { await model.poller.refreshNow() }
                AppDelegate.hideDockIfNoWindows()
            }
            .signInWindowChrome()
        }
        .defaultSize(width: 920, height: 700)
        .windowResizability(.contentMinSize)

        Window("Sign in to OpenCode", id: AppWindowID.openCodeSignIn.rawValue) {
            OpenCodeSignInView(auth: model.openCodeAuth) {
                Task { await model.openCodePoller.refreshNow() }
                AppDelegate.hideDockIfNoWindows()
            }
            .signInWindowChrome()
        }
        .defaultSize(width: 920, height: 700)
        .windowResizability(.contentMinSize)

        Window("Sign in to Cursor", id: AppWindowID.cursorSignIn.rawValue) {
            CursorSignInView(auth: model.cursorAuth) {
                Task {
                    await model.cursorPoller.refreshNow()
                    await model.grokbotPoller.refreshNow()
                }
                AppDelegate.hideDockIfNoWindows()
            }
            .signInWindowChrome()
        }
        .defaultSize(width: 920, height: 700)
        .windowResizability(.contentMinSize)

        Window("Sign in to Claude", id: AppWindowID.claudeSignIn.rawValue) {
            ClaudeSignInView(auth: model.claudeAuth) {
                Task { await model.claudePoller.refreshNow() }
                AppDelegate.hideDockIfNoWindows()
            }
            .signInWindowChrome()
        }
        .defaultSize(width: 920, height: 700)
        .windowResizability(.contentMinSize)

        Window("Sign in to ChatGPT", id: AppWindowID.chatGPTSignIn.rawValue) {
            ChatGPTSignInView(auth: model.chatGPTAuth) {
                Task { await model.chatGPTPoller.refreshNow() }
                AppDelegate.hideDockIfNoWindows()
            }
            .signInWindowChrome()
        }
        .defaultSize(width: 920, height: 700)
        .windowResizability(.contentMinSize)
    }
}

/// Scene identifiers for settings and each provider sign-in window.
enum AppWindowID: String {
    case preferences
    case grokSignIn = "signin"
    case openCodeSignIn = "opencode-signin"
    case cursorSignIn = "cursor-signin"
    case claudeSignIn = "claude-signin"
    case chatGPTSignIn = "chatgpt-signin"
}

private extension View {
    func signInWindowChrome() -> some View {
        background(
            Color.clear
                .frame(width: 0, height: 0)
                .onDisappear {
                    AppDelegate.hideDockIfNoWindows()
                }
        )
    }
}

/// Shared app services owned for the process lifetime.
@MainActor
final class AppModel: ObservableObject {
    let auth: AuthSessionService
    let openCodeAuth: OpenCodeAuthSession
    let cursorAuth: CursorAuthSession
    let claudeAuth: ClaudeAuthSession
    let chatGPTAuth: ChatGPTAuthSession
    let openRouterAuth: OpenRouterAuthSession
    let settings: AppSettings
    let history = HistoryStore(inMemory: AppModel.isRunningTests)
    let notifier: ThresholdNotifier
    let grokHourly = HourlyDeltaActivityStore(storageKey: "grok_hourly_today")
    let claudeHourly = HourlyDeltaActivityStore(storageKey: "claude_hourly_today")
    let claudeDaily = DailyQuotaDeltaStore(storageKey: "claude_daily_usage")
    let cursorDaily = DailyQuotaDeltaStore(storageKey: "cursor_daily_usage")
    let grokbotHourly = HourlyDeltaActivityStore(storageKey: "grokbot_hourly_today")
    let grokbotDaily = DailyQuotaDeltaStore(storageKey: "grokbot_daily_usage")
    let poller: UsagePoller
    let openCodePoller: OpenCodeUsagePoller
    let cursorPoller: CursorUsagePoller
    let claudePoller: ClaudeUsagePoller
    let chatGPTPoller: ChatGPTUsagePoller
    let openRouterPoller: OpenRouterUsagePoller
    let grokbotPoller: GrokbotUsagePoller
    let providers: ProviderRegistry
    let updateChecker: UpdateChecker

    private var cancellables = Set<AnyCancellable>()
    private var terminateObserver: NSObjectProtocol?
    private var wakeGate: SystemWakeGate?

    /// A menu open refreshes a provider only when its data is older than this,
    /// so quickly reopening the menu does not refetch.
    static let menuOpenFreshness: TimeInterval = 15

    /// True when the process is the XCTest host — tests must not start pollers,
    /// prompt for notifications, or touch live hosts / the real history store.
    /// Files land in a temporary directory (`AppSupport.baseDirectory`) and
    /// preferences in a throwaway defaults suite.
    nonisolated static var isRunningTests: Bool {
        AppSupport.isRunningTests
    }

    /// Defaults suite the XCTest host uses in place of the installed app's domain.
    nonisolated static let testDefaultsSuiteName = "com.modelmonitor.app.tests.appmodel"

    /// The installed app's defaults, or a throwaway suite (emptied on every
    /// launch) under XCTest.
    nonisolated static func makeDefaults() -> UserDefaults {
        guard isRunningTests else { return .standard }
        guard let defaults = UserDefaults(suiteName: testDefaultsSuiteName) else {
            preconditionFailure("could not open the test defaults suite")
        }
        defaults.removePersistentDomain(forName: testDefaultsSuiteName)
        return defaults
    }

    init() {
        let defaults = Self.makeDefaults()
        settings = AppSettings(defaults: defaults)
        notifier = ThresholdNotifier(defaults: defaults)
        let auth = AuthSessionService()
        let openCodeAuth = OpenCodeAuthSession()
        let cursorAuth = CursorAuthSession()
        let claudeAuth = ClaudeAuthSession()
        let chatGPTAuth = ChatGPTAuthSession()
        let openRouterAuth = OpenRouterAuthSession()
        self.auth = auth
        self.openCodeAuth = openCodeAuth
        self.cursorAuth = cursorAuth
        self.claudeAuth = claudeAuth
        self.chatGPTAuth = chatGPTAuth
        self.openRouterAuth = openRouterAuth
        poller = UsagePoller(
            auth: auth,
            history: history,
            settings: settings,
            notifier: notifier,
            grokHourly: grokHourly
        )
        openCodePoller = OpenCodeUsagePoller(settings: settings, auth: openCodeAuth)
        cursorPoller = CursorUsagePoller(settings: settings, auth: cursorAuth, daily: cursorDaily)
        claudePoller = ClaudeUsagePoller(settings: settings, auth: claudeAuth, hourly: claudeHourly, daily: claudeDaily)
        chatGPTPoller = ChatGPTUsagePoller(settings: settings, auth: chatGPTAuth)
        openRouterPoller = OpenRouterUsagePoller(settings: settings, auth: openRouterAuth)
        // Grokbot bills through the Cursor account, so it borrows that session.
        grokbotPoller = GrokbotUsagePoller(
            settings: settings,
            auth: cursorAuth,
            hourly: grokbotHourly,
            daily: grokbotDaily
        )
        updateChecker = UpdateChecker(settings: settings)
        providers = ProviderRegistry(
            grok: poller,
            openCode: openCodePoller,
            cursor: cursorPoller,
            claude: claudePoller,
            chatGPT: chatGPTPoller,
            openRouter: openRouterPoller,
            grokbot: grokbotPoller
        )
        forwardChanges(from: settings)
        forwardChanges(from: history)
        forwardChanges(from: grokHourly)
        forwardChanges(from: claudeHourly)
        forwardChanges(from: claudeDaily)
        forwardChanges(from: cursorDaily)
        forwardChanges(from: grokbotHourly)
        forwardChanges(from: grokbotDaily)
        for (_, providerPoller) in providers.all {
            forwardChanges(from: providerPoller)
        }
        forwardChanges(from: auth)
        forwardChanges(from: openCodeAuth)
        forwardChanges(from: cursorAuth)
        forwardChanges(from: claudeAuth)
        forwardChanges(from: chatGPTAuth)
        forwardChanges(from: openRouterAuth)
        forwardChanges(from: updateChecker)
        settings.$checksForUpdates
            .dropFirst()
            .sink { [weak self] _ in self?.updateChecker.settingChanged() }
            .store(in: &cancellables)
        observePollingInputs()
        guard !Self.isRunningTests else { return }
        notifier.requestAuthorizationIfNeeded()
        providers.startAll()
        updateChecker.start()
        observeTermination()
        wakeGate = SystemWakeGate(
            onSleep: { [weak self] in self?.forEachPollingLoop { $0.pause() } },
            onReady: { [weak self] in self?.forEachPollingLoop { $0.resume() } }
        )
    }

    /// Marks every poller's menu-open state (switching it to the active
    /// interval) and, on open, refreshes the providers the menu shows when
    /// their data is older than `menuOpenFreshness`.
    func setMenuOpen(_ isOpen: Bool) {
        for (_, providerPoller) in providers.all {
            providerPoller.menuIsOpen = isOpen
        }
        // The test host never fetches (see `isRunningTests`).
        guard isOpen, !Self.isRunningTests else { return }
        for (provider, providerPoller) in providers.all where settings.needsPolling(provider) {
            let loop = providerPoller.pollingLoop
            Task { await loop.refreshNow(ifOlderThan: Self.menuOpenFreshness) }
        }
    }

    private func forEachPollingLoop(_ body: (PollingLoop) -> Void) {
        for (_, providerPoller) in providers.all {
            body(providerPoller.pollingLoop)
        }
    }

    /// Re-arms the polling loops when a setting that feeds their interval or
    /// "needed" check changes, and refreshes a provider at once when its menu
    /// bar graph is switched on.
    private func observePollingInputs() {
        settings.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.forEachPollingLoop { $0.wake() } }
            .store(in: &cancellables)
        let graphToggles: [(Published<Bool>.Publisher, any ProviderUsagePoller)] = [
            (settings.$showGrokBarInMenuBar, poller),
            (settings.$showOpenCodeBarInMenuBar, openCodePoller),
            (settings.$showCursorBarInMenuBar, cursorPoller),
            (settings.$showClaudeBarInMenuBar, claudePoller),
            (settings.$showGrokbotBarInMenuBar, grokbotPoller)
        ]
        for (toggle, providerPoller) in graphToggles {
            toggle
                .dropFirst()
                .removeDuplicates()
                .filter { $0 }
                .sink { _ in Task { await providerPoller.refreshNow() } }
                .store(in: &cancellables)
        }
    }

    /// Flush coalesced history writes on quit so the last samples are not lost.
    private func observeTermination() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.history.flush()
        }
    }

    /// MenuBarExtra label only observes `AppModel`; forward child updates.
    private func forwardChanges(from object: some ObservableObject) {
        object.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Activates dock presence, then opens the window for `id`.
    func openWindow(_ id: AppWindowID, openWindow: OpenWindowAction) {
        AppDelegate.revealWindow()
        openWindow(id: id.rawValue)
    }
}

/// Bridges `AppModel` into the menu-bar dropdown content.
struct MenuBarRoot: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarPanelView(
            auth: model.auth,
            poller: model.poller,
            openCodeAuth: model.openCodeAuth,
            openCodePoller: model.openCodePoller,
            cursorAuth: model.cursorAuth,
            cursorPoller: model.cursorPoller,
            claudeAuth: model.claudeAuth,
            claudePoller: model.claudePoller,
            chatGPTAuth: model.chatGPTAuth,
            chatGPTPoller: model.chatGPTPoller,
            openRouterAuth: model.openRouterAuth,
            openRouterPoller: model.openRouterPoller,
            grokbotPoller: model.grokbotPoller,
            settings: model.settings,
            history: model.history,
            grokHourly: model.grokHourly,
            claudeHourly: model.claudeHourly,
            grokbotHourly: model.grokbotHourly,
            openPreferences: { model.openWindow(.preferences, openWindow: openWindow) },
            openSignIn: { model.openWindow(.grokSignIn, openWindow: openWindow) },
            openOpenCodeSignIn: { model.openWindow(.openCodeSignIn, openWindow: openWindow) },
            openCursorSignIn: { model.openWindow(.cursorSignIn, openWindow: openWindow) },
            openClaudeSignIn: { model.openWindow(.claudeSignIn, openWindow: openWindow) },
            openChatGPTSignIn: { model.openWindow(.chatGPTSignIn, openWindow: openWindow) },
            selectOpenRouter: { model.settings.selectedProvider = .openrouter }
        )
    }
}

private struct PreferencesRoot: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PreferencesView(
            auth: model.auth,
            openCodeAuth: model.openCodeAuth,
            cursorAuth: model.cursorAuth,
            claudeAuth: model.claudeAuth,
            chatGPTAuth: model.chatGPTAuth,
            openRouterAuth: model.openRouterAuth,
            settings: model.settings,
            history: model.history,
            poller: model.poller,
            openCodePoller: model.openCodePoller,
            cursorPoller: model.cursorPoller,
            claudePoller: model.claudePoller,
            chatGPTPoller: model.chatGPTPoller,
            openRouterPoller: model.openRouterPoller,
            grokbotPoller: model.grokbotPoller,
            updateChecker: model.updateChecker,
            openSignIn: { model.openWindow(.grokSignIn, openWindow: openWindow) },
            openOpenCodeSignIn: { model.openWindow(.openCodeSignIn, openWindow: openWindow) },
            openCursorSignIn: { model.openWindow(.cursorSignIn, openWindow: openWindow) },
            openClaudeSignIn: { model.openWindow(.claudeSignIn, openWindow: openWindow) },
            openChatGPTSignIn: { model.openWindow(.chatGPTSignIn, openWindow: openWindow) }
        )
    }
}

/// Observes nested services so the menu bar label refreshes on poll/settings updates.
