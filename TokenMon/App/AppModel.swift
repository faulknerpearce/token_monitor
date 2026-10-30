import AppKit
import Foundation
import SwiftUI

/// Shared app services owned for the process lifetime.
@MainActor
final class AppModel {
    let grokAuth: GrokAuthSession
    let openCodeAuth: OpenCodeAuthSession
    let cursorAuth: CursorAuthSession
    let claudeAuth: ClaudeAuthSession
    let chatGPTAuth: ChatGPTAuthSession
    let openRouterAuth: OpenRouterAuthSession
    let settings: AppSettings
    let grokHistory = GrokHistoryStore(inMemory: AppModel.isRunningTests)
    let notifier: ThresholdNotifier
    let grokHourly = HourlyDeltaActivityStore(storageKey: "grok_hourly_today")
    let claudeHourly = HourlyDeltaActivityStore(storageKey: "claude_hourly_today")
    let claudeDaily = DailyQuotaDeltaStore(storageKey: "claude_daily_usage")
    let cursorDaily = DailyQuotaDeltaStore(storageKey: "cursor_daily_usage")
    let grokbotHourly = HourlyDeltaActivityStore(storageKey: "grokbot_hourly_today")
    let grokbotDaily = DailyQuotaDeltaStore(storageKey: "grokbot_daily_usage")
    /// Earlier days of the Overview hourly chart.
    let overviewHistory = OverviewHourlyHistoryStore()
    let grokPoller: GrokUsagePoller
    let openCodePoller: OpenCodeUsagePoller
    let cursorPoller: CursorUsagePoller
    let claudePoller: ClaudeUsagePoller
    let chatGPTPoller: ChatGPTUsagePoller
    let openRouterPoller: OpenRouterUsagePoller
    let grokbotPoller: GrokbotUsagePoller
    let providers: ProviderRegistry
    let updateChecker: UpdateChecker

    private var observers: [ObservationLoop] = []
    private var terminateObserver: NSObjectProtocol?
    private var wakeGate: SystemWakeGate?

    /// Wait after a change before reacting, so a burst of changes (one poll
    /// sets several values) is handled once.
    static let changeCoalescing: Duration = .milliseconds(100)

    /// A menu open refreshes a provider only when its data is older than this,
    /// so quickly reopening the menu reuses the loaded data.
    static let menuOpenFreshness: TimeInterval = 15

    /// True when the process is the XCTest host. The test host skips pollers,
    /// notification prompts, live hosts, and the real history store.
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
        // The test host uses an in-memory store, leaving the user's credentials untouched.
        let store: () -> (any CredentialStore)? = { Self.isRunningTests ? InMemoryCredentialStore() : nil }
        let grokAuth = GrokAuthSession(directory: nil, store: store())
        let openCodeAuth = OpenCodeAuthSession(store: store())
        let cursorAuth = CursorAuthSession(store: store())
        let claudeAuth = ClaudeAuthSession(store: store())
        let chatGPTAuth = ChatGPTAuthSession(store: store())
        let openRouterAuth = OpenRouterAuthSession(store: store())
        self.grokAuth = grokAuth
        self.openCodeAuth = openCodeAuth
        self.cursorAuth = cursorAuth
        self.claudeAuth = claudeAuth
        self.chatGPTAuth = chatGPTAuth
        self.openRouterAuth = openRouterAuth
        grokPoller = GrokUsagePoller(
            auth: grokAuth,
            history: grokHistory,
            settings: settings,
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
        providers = ProviderRegistry([
            .init(provider: .grok, poller: grokPoller, auth: grokAuth),
            .init(provider: .opencode, poller: openCodePoller, auth: openCodeAuth),
            .init(provider: .cursor, poller: cursorPoller, auth: cursorAuth),
            .init(provider: .claude, poller: claudePoller, auth: claudeAuth),
            .init(provider: .chatgpt, poller: chatGPTPoller, auth: chatGPTAuth),
            .init(provider: .openrouter, poller: openRouterPoller, auth: openRouterAuth),
            // Grokbot bills through the Cursor account and shares its session.
            .init(provider: .grokbot, poller: grokbotPoller, auth: cursorAuth)
        ])
        observeOverviewInputs()
        observers.append(ObservationLoop(
            initial: false,
            track: { [settings] in settings.checksForUpdates },
            handle: { [updateChecker] _ in updateChecker.settingChanged() }
        ))
        observePollingInputs()
        observeUsageAlerts()
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
        // The test host skips fetching (see `isRunningTests`).
        guard isOpen, !Self.isRunningTests else { return }
        for (provider, providerPoller) in providers.all where settings.needsPolling(provider) {
            let loop = providerPoller.pollingLoop
            Task { await loop.refreshNow(ifOlderThan: Self.menuOpenFreshness) }
        }
    }

    /// Loads a provider's data right after its sign-in window succeeds, even
    /// when its tab is not selected, together with every provider that shares
    /// the session (Grokbot shares Cursor's).
    func signInCompleted(_ provider: MonitorProvider) {
        for providerPoller in providers.pollers(sharingSessionWith: provider) {
            Task { await providerPoller.refreshNow() }
        }
        AppDelegate.hideDockIfNoWindows()
    }

    private func forEachPollingLoop(_ body: (PollingLoop) -> Void) {
        for (_, providerPoller) in providers.all {
            body(providerPoller.pollingLoop)
        }
    }

    /// Records today's Overview chart inputs whenever one of them changes.
    /// Building the series reads exactly those inputs; recording happens
    /// outside tracking, so writing the history does not loop.
    private func observeOverviewInputs() {
        observers.append(ObservationLoop(
            coalescing: Self.changeCoalescing,
            track: { [weak self] in self?.overviewSeries(on: Date()) ?? OverviewDaySeries() },
            handle: { [overviewHistory] series in overviewHistory.record(series, at: Date()) }
        ))
    }

    /// Re-arms the polling loops when an input to their interval or "needed"
    /// check changes, and refreshes a provider at once when its menu bar graph
    /// is switched on.
    private func observePollingInputs() {
        observers.append(ObservationLoop(
            coalescing: Self.changeCoalescing,
            initial: false,
            track: { [settings] in
                (
                    MonitorProvider.usageProviders.map(settings.needsPolling),
                    settings.activePollSeconds,
                    settings.idlePollSeconds
                )
            },
            handle: { [weak self] _ in self?.forEachPollingLoop { $0.wake() } }
        ))
        var shownGraphs = settings.menuBarGraphProviders
        observers.append(ObservationLoop(
            initial: false,
            track: { [settings] in settings.menuBarGraphProviders },
            handle: { [weak self] graphs in
                let added = graphs.subtracting(shownGraphs)
                shownGraphs = graphs
                for (provider, providerPoller) in self?.providers.all ?? [] where added.contains(provider) {
                    Task { await providerPoller.refreshNow() }
                }
            }
        ))
    }

    /// Evaluates the usage alert whenever a provider's headline figures or the
    /// alert settings change.
    private func observeUsageAlerts() {
        for (provider, providerPoller) in providers.all {
            observers.append(ObservationLoop(
                track: { [settings] in
                    _ = (settings.thresholdEnabled, settings.thresholdPercent, settings.alertProviders)
                    return (providerPoller.headlineUsedPercent, providerPoller.headlineResetsAt, providerPoller.alertAccount)
                },
                handle: { [weak self] reading in
                    guard let self, let usedPercent = reading.0 else { return }
                    notifier.evaluate(
                        provider: provider,
                        usedPercent: usedPercent,
                        settings: settings,
                        account: reading.2,
                        resetsAt: reading.1
                    )
                }
            ))
        }
    }

    /// Flushes coalesced history writes on quit so the last samples are saved.
    private func observeTermination() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue.
            MainActor.assumeIsolated { self?.grokHistory.flush() }
        }
    }

    /// Activates dock presence, then opens `window`.
    func openWindow(_ window: AppWindow, openWindow: OpenWindowAction) {
        AppDelegate.revealWindow()
        switch window {
        case .preferences:
            openWindow(id: AppWindow.preferencesID)
        case let .signIn(provider):
            openWindow(id: AppWindow.signInID, value: provider.signInProvider)
        }
    }
}
