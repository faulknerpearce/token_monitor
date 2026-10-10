import Combine
import Foundation
import os

/// Polls console Go usage with a local-estimate fallback.
@MainActor
final class OpenCodeUsagePoller: ObservableObject, ProviderUsagePoller {
    @Published private(set) var snapshot: OpenCodeSnapshot?
    @Published private(set) var dayHourlyUsage: OpenCodeDayHourlyUsage?
    @Published private(set) var dailyBudgetDays: [DailyBudgetDay]?
    /// Full monthly-period start matching `dailyBudgetDays` (for pace captions).
    @Published private(set) var dailyBudgetPeriodStart: Date?
    /// Last month build, kept so week arrows can re-slice without another SQLite read.
    private var budgetSource: OpenCodeLocalStats.OpenCodeMonthBudget?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var dataSourceLabel: String?
    @Published var menuIsOpen = false {
        didSet { if menuIsOpen != oldValue { pollingLoop.wake() } }
    }

    private let settings: AppSettings
    private let auth: OpenCodeAuthSession
    /// Injected console/local fetch seams (tests supply fakes); default to live.
    private let fetchConsole: (String, String?) async throws -> (OpenCodeSnapshot, String)
    private let fetchLocal: () async throws -> (OpenCodeSnapshot?, OpenCodeDayHourlyUsage?)
    private let logger = Logger(category: "OpenCode")
    private var cancellables = Set<AnyCancellable>()

    private(set) lazy var pollingLoop = PollingLoop(
        interval: { [weak self] in self?.pollInterval() },
        refresh: { [weak self] in await self?.performRefresh() ?? .skipped }
    )

    init(
        settings: AppSettings,
        auth: OpenCodeAuthSession,
        fetchConsole: ((String, String?) async throws -> (OpenCodeSnapshot, String))? = nil,
        fetchLocal: (() async throws -> (OpenCodeSnapshot?, OpenCodeDayHourlyUsage?))? = nil
    ) {
        self.settings = settings
        self.auth = auth
        self.fetchConsole = fetchConsole ?? { cookieHeader, knownOrgID in
            try await OpenCodeConsoleClient(cookieHeader: cookieHeader)
                .fetchGoUsageSnapshot(knownOrgID: knownOrgID)
        }
        self.fetchLocal = fetchLocal ?? {
            try await Task.detached(priority: .userInitiated) {
                // Fetch independently: a snapshot failure must not discard a
                // successful hourly read (which would blank the Overview chart).
                (
                    try? OpenCodeLocalStats.fetchSnapshot(),
                    try? OpenCodeLocalStats.fetchDayHourlyUsage()
                )
            }.value
        }
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
        dayHourlyUsage = nil
        dailyBudgetDays = nil
        dailyBudgetPeriodStart = nil
        budgetSource = nil
        lastError = nil
        dataSourceLabel = nil
        lastRefreshedAt = nil
    }

    /// Fetches now when the provider is enabled and restarts the poll wait from here.
    func refreshNow() async {
        await pollingLoop.refreshNow()
    }

    private func performRefresh() async -> PollOutcome {
        guard settings.isProviderEnabled(.opencode) else { return .skipped }
        guard !isRefreshing else { return .skipped }
        isRefreshing = true
        defer { isRefreshing = false }

        // Prefer official console Go usage (matches opencode.ai bars).
        var generation = auth.sessionGeneration
        let cookieHeader = auth.cookieHeader()
        // A failed console fetch backs the loop off even when the local
        // estimate below succeeds.
        var consoleOutcome = PollOutcome.success
        if let cookieHeader, !cookieHeader.isEmpty {
            do {
                let (consoleSnap, orgID) = try await fetchConsole(cookieHeader, auth.workspaceID)
                let localBundle = try? await fetchLocal()
                var snap = consoleSnap
                if let local = localBundle?.0 {
                    snap = Self.mergeLocalModels(into: snap, local: local)
                }
                guard !Task.isCancelled, auth.isCurrent(generation) else { return .skipped }
                // Persist the workspace id only for the live session, and only
                // when it changed, so a late success cannot rewrite the previous
                // account's id after sign-out cleared it.
                if auth.workspaceID != orgID {
                    auth.saveWorkspaceID(orgID)
                }
                snapshot = snap
                if let hourly = localBundle?.1 { dayHourlyUsage = hourly }
                let budget = await Self.buildDailyBudgetDays(for: snap)
                budgetSource = budget
                dailyBudgetDays = budget?.days
                dailyBudgetPeriodStart = budget?.periodStart
                lastError = nil
                lastRefreshedAt = Date()
                dataSourceLabel = "OpenCode console"
                auth.needsSignIn = false
                auth.recordAuthSuccess()
                let pct = snap.primaryUsedPercent
                logger.info(
                    "OpenCode console refresh: monthly \(pct, format: .fixed(precision: 1))%"
                )
                return .success
            } catch is CancellationError {
                return .skipped
            } catch let error as ProviderError {
                // A request that began under a previous credential state must
                // not tear down the current session.
                guard auth.isCurrent(generation) else { return .skipped }
                switch error.usageError {
                case .unauthorized, .notSignedIn:
                    auth.recordAuthFailure(reason: error.localizedDescription)
                    // A third consecutive rejection invalidates the session and
                    // advances the generation; adopt it so this poll still
                    // publishes the local estimate below.
                    generation = auth.sessionGeneration
                default:
                    break
                }
                consoleOutcome = PollOutcome(error: error)
                logger.error("OpenCode console fetch failed: \(error.localizedDescription, privacy: .public)")
            } catch {
                // Same generation rule as the unauthorized path: a failure from
                // the previous account must not continue into the local publish.
                guard auth.sessionGeneration == generation else { return .skipped }
                consoleOutcome = PollOutcome(error: error)
                logger.error("OpenCode console fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Local estimate fallback (labeled).
        do {
            let (snap, hourly) = try await fetchLocal()
            // Do not republish after a sign-out / account switch cleared the
            // snapshot while this poll was in flight (generation moved). A poll
            // that *started* signed-out keeps working: its generation is stable.
            guard !Task.isCancelled, auth.sessionGeneration == generation else { return .skipped }
            if let hourly { dayHourlyUsage = hourly }
            guard let snap else {
                // The hourly read may still have succeeded; only the snapshot is
                // missing, so keep any prior card rather than blanking it.
                if snapshot == nil {
                    lastError = "Could not read local OpenCode usage."
                }
                return consoleOutcome
            }
            snapshot = snap
            let budget = await Self.buildDailyBudgetDays(for: snap)
            budgetSource = budget
            dailyBudgetDays = budget?.days
            dailyBudgetPeriodStart = budget?.periodStart
            dataSourceLabel = "Local estimate"
            if cookieHeader == nil || cookieHeader?.isEmpty == true {
                lastError = "Showing local estimate. Sign in to OpenCode for official Go usage."
            } else if auth.needsSignIn {
                lastError = "Console session expired — showing local estimate. Sign in again for official numbers."
            } else {
                lastError = "Console fetch failed — showing local estimate."
            }
            lastRefreshedAt = Date()
            logger.info(
                "OpenCode local refresh: monthly \(snap.primaryUsedPercent, format: .fixed(precision: 1))%"
            )
            return consoleOutcome
        } catch {
            // Compare the generation only. A poll that started signed out is
            // not `isCurrent`, and it still needs to surface a local-read error.
            guard auth.sessionGeneration == generation else { return .skipped }
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            logger.error("OpenCode local refresh failed: \(error.localizedDescription, privacy: .public)")
            return consoleOutcome
        }
    }

    private func pollInterval() -> TimeInterval? {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings, needed: settings.needsOpenCodePolling)
    }

    /// Monday-week bars `weekOffset` steps before the week of the last refresh.
    /// `0` matches ``dailyBudgetDays``.
    func dailyBudgetDays(weekOffset: Int) -> [DailyBudgetDay]? {
        guard let budgetSource else { return nil }
        if weekOffset == 0 { return budgetSource.days }
        return DailyBudget.buildSubscriptionMonthLast7Days(
            limitUSD: 100,
            spentByDay: budgetSource.spentPercentByDay,
            knownStart: budgetSource.knownStart,
            resetsAt: budgetSource.resetsAt,
            historyByDay: budgetSource.historyPercentByDay,
            weekOffset: weekOffset,
            now: budgetSource.referenceNow
        )?.days
    }

    private static func buildDailyBudgetDays(
        for snapshot: OpenCodeSnapshot
    ) async -> OpenCodeLocalStats.OpenCodeMonthBudget? {
        let monthly = snapshot.windows.first { $0.kind == .monthly }
        let monthlyLimit = monthly?.limitUSD ?? OpenCodeWindowKind.monthly.defaultLimitUSD
        guard monthlyLimit > 0 else { return nil }
        // Anchor the bars to the consumed monthly usage; prefer console
        // resetsAt when local subscription bounds are unavailable.
        let usedPercent = snapshot.monthlyUsedPercent
        let resetsAt = monthly?.resetsAt
        return await Task.detached(priority: .utility) {
            OpenCodeLocalStats.monthDailyBudgetDays(
                limitUSD: monthlyLimit,
                usedPercent: usedPercent,
                periodResetsAt: resetsAt
            )
        }.value
    }

    /// Keep console limit windows; attach local model/token breakdown when present.
    private static func mergeLocalModels(into server: OpenCodeSnapshot, local: OpenCodeSnapshot) -> OpenCodeSnapshot {
        var merged = server
        if !local.models.isEmpty {
            merged.models = local.models
        }
        if local.monthlyTokens > 0 || local.monthlyEstimatedUSD > 0 {
            merged.monthlyTokens = local.monthlyTokens
            merged.monthlyEstimatedUSD = local.monthlyEstimatedUSD
            merged.monthlyInputTokens = local.monthlyInputTokens
            merged.monthlyOutputTokens = local.monthlyOutputTokens
        }
        return merged
    }
}
