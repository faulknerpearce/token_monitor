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
    @Published var menuIsOpen = false {
        didSet { if menuIsOpen != oldValue { pollingLoop.wake() } }
    }

    private let auth: AuthSessionService
    private let history: HistoryStore
    private let settings: AppSettings
    private let notifier: ThresholdNotifier
    private let grokHourly: HourlyDeltaActivityStore
    /// Injected fetch seam (tests supply a fake); defaults to the live client.
    private let fetchUsage: (String?, String?) async throws -> WeeklyUsageSnapshot
    private let logger = Logger(category: "Poller")

    private(set) lazy var pollingLoop = PollingLoop(
        interval: { [weak self] in self?.pollInterval() },
        refresh: { [weak self] in await self?.performRefresh() ?? .skipped }
    )
    private var cancellables = Set<AnyCancellable>()

    init(
        auth: AuthSessionService,
        history: HistoryStore,
        settings: AppSettings,
        notifier: ThresholdNotifier,
        grokHourly: HourlyDeltaActivityStore,
        fetchUsage: ((String?, String?) async throws -> WeeklyUsageSnapshot)? = nil
    ) {
        self.auth = auth
        self.history = history
        self.settings = settings
        self.notifier = notifier
        self.grokHourly = grokHourly
        self.fetchUsage = fetchUsage ?? { cookieHeader, accountEmail in
            try await UsageClient(cookieHeader: cookieHeader, accountEmail: accountEmail).fetchUsage()
        }
        history.setActiveAccount(auth.accountEmail)
        // Signing out or switching accounts drops the snapshot and the
        // account-scoped hourly deltas immediately. An expired session keeps
        // them: the same account usually signs back in.
        auth.accountReset
            .sink { [weak self] in self?.clearSnapshot() }
            .store(in: &cancellables)
    }

    func start() {
        pollingLoop.start()
    }

    func stop() {
        pollingLoop.stop()
    }

    func clearSnapshot() {
        snapshot = nil
        lastError = nil
        lastRefreshedAt = nil
        grokHourly.clear()
    }

    /// Fetches now when Grok is enabled and restarts the poll wait from here.
    func refreshNow() async {
        await pollingLoop.refreshNow()
    }

    private func performRefresh() async -> PollOutcome {
        guard settings.isProviderEnabled(.grok) else { return .skipped }
        guard !isRefreshing else { return .skipped }
        isRefreshing = true
        defer { isRefreshing = false }

        // needsSignIn means credentials were cleared after a 401/403; polling waits
        // for re-auth.
        guard auth.isSignedIn, !auth.needsSignIn else {
            lastError = ProviderError.notSignedIn(.grok).localizedDescription
            return .skipped
        }

        let generation = auth.sessionGeneration
        let cookieHeader = auth.loadCookieHeader()
        let accountEmail = auth.accountEmail

        do {
            var snap = try await fetchUsage(cookieHeader, accountEmail)
            guard !Task.isCancelled, auth.isCurrent(generation) else { return .skipped }
            if snap.accountEmail == nil {
                snap.accountEmail = auth.accountEmail
            }
            snapshot = snap
            lastError = nil
            lastRefreshedAt = Date()
            auth.recordAuthSuccess()
            history.append(snap)
            grokHourly.record(usedPercent: snap.usedPercent, at: snap.fetchedAt)
            notifier.evaluate(
                usedPercent: snap.usedPercent,
                settings: settings,
                account: auth.accountEmail,
                resetsAt: snap.resetsAt
            )
            logger.info("Usage refreshed: \(snap.usedPercent, format: .fixed(precision: 1))% used")
            return .success
        } catch is CancellationError {
            return .skipped
        } catch let error as ProviderError {
            // A request that began under a previous credential state leaves the
            // current session intact.
            guard auth.isCurrent(generation) else { return .skipped }
            switch error.usageError {
            case .unauthorized, .notSignedIn:
                auth.recordAuthFailure(reason: error.localizedDescription)
            default:
                break
            }
            lastError = error.localizedDescription
            logger.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
            return PollOutcome(error: error)
        } catch {
            guard auth.isCurrent(generation) else { return .skipped }
            lastError = error.localizedDescription
            logger.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
            return PollOutcome(error: error)
        }
    }

    private func pollInterval() -> TimeInterval? {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings, needed: settings.needsGrokPolling)
    }
}
