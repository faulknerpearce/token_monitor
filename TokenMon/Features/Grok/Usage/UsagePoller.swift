import AppKit
import Combine
import Foundation
import os

/// Periodically refreshes usage and publishes the latest snapshot.
@MainActor
final class UsagePoller: ObservableObject, ProviderUsagePoller {
    @Published private(set) var snapshot: WeeklyUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?
    @Published var menuIsOpen = false

    private let auth: AuthSessionService
    private let history: HistoryStore
    private let settings: AppSettings
    private let notifier: ThresholdNotifier
    private let grokHourly: HourlyDeltaActivityStore
    private let logger = Logger(category: "Poller")

    private lazy var loop = PollingLoop(
        interval: { [weak self] in
            guard let self else { return nil }
            return self.currentInterval() + self.backoff.current
        },
        refresh: { [weak self] in
            guard let self, !self.pausedForSleep else { return }
            await self.refreshNow()
        }
    )
    private var backoff = BackoffTimer(initial: 30, maximum: 600)
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var pausedForSleep = false
    private var cancellables = Set<AnyCancellable>()

    init(
        auth: AuthSessionService,
        history: HistoryStore,
        settings: AppSettings,
        notifier: ThresholdNotifier,
        grokHourly: HourlyDeltaActivityStore
    ) {
        self.auth = auth
        self.history = history
        self.settings = settings
        self.notifier = notifier
        self.grokHourly = grokHourly
        observeSleep()
        // Signing out (or a 401) must drop the snapshot and the account-scoped
        // hourly deltas immediately, not on the next poll.
        auth.$isSignedIn
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] signedIn in
                if !signedIn { self?.clearSnapshot() }
            }
            .store(in: &cancellables)
    }

    deinit {
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func start() {
        loop.start()
    }

    func stop() {
        loop.stop()
    }

    func clearSnapshot() {
        snapshot = nil
        lastError = nil
        lastRefreshedAt = nil
        grokHourly.clear()
    }

    func refreshNow() async {
        // Poll only when Grok is visible (menu bar / panel tab) or a session exists;
        // avoid idle churn while signed out.
        guard settings.needsGrokPolling || auth.isSignedIn else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // needsSignIn means credentials were cleared after 401/403 — wait for re-auth
        // instead of spinning on empty cookies every poll interval.
        guard auth.isSignedIn, !auth.needsSignIn else {
            lastError = ProviderError.notSignedIn(.grok).localizedDescription
            return
        }

        let generation = auth.sessionGeneration
        let client = UsageClient(
            cookieHeader: auth.loadCookieHeader(),
            bearerToken: auth.loadBearerToken(),
            accountEmail: auth.accountEmail
        )

        do {
            var snap = try await client.fetchUsage()
            guard auth.isCurrent(generation) else { return }
            if snap.accountEmail == nil {
                snap.accountEmail = auth.accountEmail
            }
            snapshot = snap
            lastError = nil
            lastRefreshedAt = Date()
            backoff.reset()
            auth.needsSignIn = false
            history.append(snap)
            grokHourly.record(usedPercent: snap.usedPercent, at: snap.fetchedAt)
            notifier.evaluate(usedPercent: snap.usedPercent, settings: settings)
            logger.info("Usage refreshed: \(snap.usedPercent, format: .fixed(precision: 1))% used")
        } catch let error as ProviderError {
            switch error.usageError {
            case .unauthorized, .notSignedIn:
                auth.markSessionInvalid(reason: error.localizedDescription)
            default:
                break
            }
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            applyBackoff()
            logger.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
        } catch {
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            applyBackoff()
            logger.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentInterval() -> TimeInterval {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings)
    }

    private func applyBackoff() {
        backoff.recordFailure()
    }

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pausedForSleep = true }
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pausedForSleep = false
                await self?.refreshNow()
            }
        }
    }
}
