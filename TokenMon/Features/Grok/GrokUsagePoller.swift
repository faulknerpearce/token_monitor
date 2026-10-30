import Combine
import Foundation
import os

/// Periodically refreshes usage and publishes the latest snapshot.
@MainActor
final class GrokUsagePoller: ObservableObject, ProviderUsagePoller {
    @Published private(set) var snapshot: WeeklyUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?
    /// Daily bars for the current billing-period week; rebuilt when the
    /// snapshot or the stored history changes, `nil` without a reset instant.
    @Published private(set) var currentWeek: DailyUsageWeek?
    @Published var menuIsOpen = false {
        didSet { if menuIsOpen != oldValue { pollingLoop.wake() } }
    }

    private let auth: GrokAuthSession
    private let history: GrokHistoryStore
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
        auth: GrokAuthSession,
        history: GrokHistoryStore,
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
            try await GrokUsageClient(cookieHeader: cookieHeader, accountEmail: accountEmail).fetchUsage()
        }
        history.setActiveAccount(auth.accountEmail)
        // `@Published` emits the new values before they are stored, so the
        // week is built from the emitted values.
        history.$recent
            .combineLatest($snapshot)
            .sink { [weak self] recent, snapshot in
                self?.currentWeek = Self.buildWeek(recent: recent, current: snapshot, weekOffset: 0)
            }
            .store(in: &cancellables)
        // Signing out drops the snapshot; the account-scoped hourly deltas are
        // kept for the same account and cleared when a different account signs in.
        auth.signedOut
            .sink { [weak self] in self?.clearSnapshot() }
            .store(in: &cancellables)
        auth.accountReset
            .sink { [weak self] in
                self?.clearSnapshot()
                self?.clearAccountHistory()
            }
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
    }

    /// Clears the previous account's hourly deltas.
    private func clearAccountHistory() {
        grokHourly.clear()
    }

    /// Daily bars for the billing-period week `weekOffset` weeks back
    /// (0 is the current week, which is cached in `currentWeek`).
    func week(weekOffset: Int) -> DailyUsageWeek? {
        guard weekOffset != 0 else { return currentWeek }
        return Self.buildWeek(recent: history.recent, current: snapshot, weekOffset: weekOffset)
    }

    private static func buildWeek(
        recent: [WeeklyUsageSnapshot],
        current: WeeklyUsageSnapshot?,
        weekOffset: Int
    ) -> DailyUsageWeek? {
        guard let current else { return nil }
        return GrokDailyUsageBuilder.week(
            history: recent.reversed(),
            current: current,
            weekOffset: weekOffset,
            resetsAt: current.resetsAt
        )
    }

    /// Fetches now when Grok is enabled and restarts the poll wait from here.
    func refreshNow() async {
        await pollingLoop.refreshNow()
    }

    private func performRefresh() async -> PollOutcome {
        guard settings.isProviderEnabled(.grok), !isRefreshing else { return .skipped }
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
