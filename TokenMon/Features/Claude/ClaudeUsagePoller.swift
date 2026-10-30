import Combine
import Foundation
import os

/// Polls Claude rate limits and builds weekly-window daily bars.
@MainActor
final class ClaudeUsagePoller: ObservableObject, ProviderUsagePoller {
    @Published private(set) var snapshot: ClaudeSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?
    /// Daily bars for the current weekly window, anchored to the pool's actual
    /// `resets_at`: % of the weekly pool burned per calendar day.
    @Published private(set) var dailyBudgetDays: [DailyBudgetDay]?
    /// Claude Code usage on this Mac, valued at API rates; `nil` when Claude
    /// Code has no logs on this Mac. Read from local logs on every poll, so it
    /// needs no claude.ai session and is kept across sign-out.
    @Published private(set) var codeUsage: ClaudeCodeUsageSummary?
    @Published var menuIsOpen = false {
        didSet { if menuIsOpen != oldValue { pollingLoop.wake() } }
    }

    private let settings: AppSettings
    private let auth: ClaudeAuthSession
    private let hourly: HourlyDeltaActivityStore
    private let daily: DailyQuotaDeltaStore
    /// Injected fetch seam (tests supply a fake); defaults to the live client.
    private let fetchUsage: (String) async throws -> (ClaudeUsageResponse, Date)
    /// Claude Code usage seam `(now)`; reads Claude Code's local logs and the
    /// saved daily totals in the app, and returns nil under an injected
    /// `fetchUsage` unless a test supplies one.
    private let loadCodeUsage: (Date) async -> ClaudeCodeUsageSummary?
    private let logger = Logger(category: "Claude")
    private var cancellables = Set<AnyCancellable>()

    /// Last observed weekly `resets_at`; anchors the chart when a later payload
    /// omits the reset time. Accumulated day deltas survive a forward move.
    private var weeklyResetsAt: Date?
    /// Instant the current bars were built against, so earlier weeks shift from
    /// the same window.
    private var budgetReferenceNow: Date?

    private(set) lazy var pollingLoop = PollingLoop(
        interval: { [weak self] in self?.pollInterval() },
        refresh: { [weak self] in await self?.performRefresh() ?? .skipped }
    )

    init(
        settings: AppSettings,
        auth: ClaudeAuthSession,
        hourly: HourlyDeltaActivityStore,
        daily: DailyQuotaDeltaStore,
        fetchUsage: ((String) async throws -> (ClaudeUsageResponse, Date))? = nil,
        loadCodeUsage: ((Date) async -> ClaudeCodeUsageSummary?)? = nil
    ) {
        self.settings = settings
        self.auth = auth
        self.hourly = hourly
        self.daily = daily
        self.fetchUsage = fetchUsage ?? { cookieHeader in
            try await ClaudeUsageClient(cookieHeader: cookieHeader).fetchUsage()
        }
        if let loadCodeUsage {
            self.loadCodeUsage = loadCodeUsage
        } else if fetchUsage != nil {
            // Tests with a fake fetch stay hermetic: no reads of the real home.
            self.loadCodeUsage = { _ in nil }
        } else {
            let ledger = ClaudeCodeUsageLedger()
            self.loadCodeUsage = { now in
                await Task.detached(priority: .utility) {
                    let calendar = ClaudeCodeUsageLedger.dayCalendar
                    guard let scanned = ClaudeCodeLocalStats.scanDailyTokens(calendar: calendar) else { return nil }
                    return ClaudeCodeUsageSummary.make(days: ledger.merge(scanned), now: now, calendar: calendar)
                }.value
            }
        }
        // Signing out drops the snapshot. The persisted hourly and daily
        // history is wiped only when a different account signs in.
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
        dailyBudgetDays = nil
        weeklyResetsAt = nil
        budgetReferenceNow = nil
        lastError = nil
        lastRefreshedAt = nil
    }

    /// Clears the previous account's hourly and daily history.
    private func clearAccountHistory() {
        hourly.clear()
        daily.clear()
    }

    /// Fetches now when the provider is enabled and restarts the poll wait from here.
    func refreshNow() async {
        await pollingLoop.refreshNow()
    }

    private func performRefresh() async -> PollOutcome {
        guard settings.isProviderEnabled(.claude), !isRefreshing else { return .skipped }
        isRefreshing = true
        defer { isRefreshing = false }

        let loadedCodeUsage = await loadCodeUsage(Date())
        guard !Task.isCancelled else { return .skipped }
        codeUsage = loadedCodeUsage

        guard let cookieHeader = auth.cookieHeader(), !cookieHeader.isEmpty else {
            auth.needsSignIn = true
            if snapshot == nil {
                lastError = "Sign in to Claude to load usage."
            }
            return .skipped
        }

        let generation = auth.sessionGeneration
        do {
            let (response, fetchedAt) = try await fetchUsage(cookieHeader)
            guard !Task.isCancelled, auth.isCurrent(generation) else { return .skipped }
            snapshot = ClaudeSnapshot(
                fetchedAt: fetchedAt,
                fiveHour: response.fiveHour,
                sevenDay: response.sevenDay,
                accountEmail: auth.accountEmail
            )
            lastError = nil
            lastRefreshedAt = Date()
            auth.needsSignIn = false
            auth.recordAuthSuccess()
            // The 5-hour window counts every model, unlike a model-scoped
            // weekly limit, so it drives the hourly activity series.
            if let percent = response.fiveHour?.usedPercent {
                hourly.record(usedPercent: percent, at: fetchedAt)
                logger.info("Claude refresh: 5h \(percent, format: .fixed(precision: 1))% used")
            }
            if let weeklyPercent = response.sevenDay?.usedPercent {
                noteWeeklyResetAdvance(response.sevenDay?.resetsAt)
                // Claude sends only `resets_at`, so a rollover or early reset is
                // recognized from a moved reset instant plus a used-% drop; the
                // store keeps earlier days as history.
                daily.record(
                    windowUsedPercent: weeklyPercent,
                    at: fetchedAt,
                    window: QuotaWindow(start: nil, resetsAt: response.sevenDay?.resetsAt)
                )
            }
            budgetReferenceNow = fetchedAt
            dailyBudgetDays = Self.buildDailyBudgetDays(
                spentByDay: daily.spentByDay,
                resetsAt: weeklyResetsAt(now: fetchedAt),
                windowStart: daily.windowStart,
                interruptedWindowStart: daily.interruptedWindowStart,
                now: fetchedAt
            )
            return .success
        } catch is CancellationError {
            return .skipped
        } catch let error as ProviderError {
            // Only a request made under the current credential state tears down
            // the session; a stale one is skipped.
            guard auth.isCurrent(generation) else { return .skipped }
            let usageError = error.usageError
            switch usageError {
            case .unauthorized, .notSignedIn:
                auth.recordAuthFailure(reason: error.localizedDescription)
            default:
                break
            }
            lastError = error.localizedDescription
            logger.error("Claude refresh failed: \(error.localizedDescription, privacy: .public)")
            return PollOutcome(error: error)
        } catch {
            guard auth.isCurrent(generation) else { return .skipped }
            lastError = error.localizedDescription
            logger.error("Claude refresh failed: \(error.localizedDescription, privacy: .public)")
            return PollOutcome(error: error)
        }
    }

    private func pollInterval() -> TimeInterval? {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings, needed: settings.needsClaudePolling)
    }

    /// Tracks the latest observed weekly `resets_at` to anchor the chart when a
    /// later payload omits the reset time.
    ///
    /// Keeps accumulated day deltas when `resets_at` moves forward: the
    /// reported reset time can move while the used % holds, so a forward
    /// move alone continues the current period. Old-period days fall outside
    /// the anchored window and are hidden. A true reset is recognized by
    /// `DailyQuotaDeltaStore` only when the used % also drops (rollover, or an
    /// early provider reset); it then keeps earlier days as prior-window history.
    private func noteWeeklyResetAdvance(_ resetsAt: Date?) {
        guard let resetsAt else { return }
        weeklyResetsAt = resetsAt
    }

    /// Daily bars for the current weekly window, anchored to the pool's actual reset
    /// time; returns [] when no provider reset has ever been observed. The pool is
    /// split evenly across the period's days, so each day's budget is 1/7th.
    ///
    /// `windowStart` / `interruptedWindowStart` come from the daily store after a
    /// rollover or early reset (see `DailyBudget.buildWeeklyWindowDays`).
    /// `weekOffset` selects an earlier weekly window (`0` is the current one).
    static func buildDailyBudgetDays(
        spentByDay: [Date: Double],
        resetsAt: Date?,
        windowStart: Date? = nil,
        interruptedWindowStart: Date? = nil,
        weekOffset: Int = 0,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyBudgetDay] {
        guard let resetsAt else { return [] }
        return DailyBudget.buildWeeklyWindowDays(
            limitUSD: 100,
            daysInPeriod: 7,
            resetsAt: resetsAt,
            spentByDay: spentByDay,
            windowStart: windowStart,
            interruptedWindowStart: interruptedWindowStart,
            weekOffset: weekOffset,
            now: now,
            calendar: calendar
        )
    }

    /// Bars for the weekly window `weekOffset` steps before the current one.
    ///
    /// Reads the live daily store so the panel can browse earlier weeks without
    /// a new poll. `0` matches ``dailyBudgetDays``.
    func dailyBudgetDays(weekOffset: Int) -> [DailyBudgetDay] {
        let now = budgetReferenceNow ?? Date()
        return Self.buildDailyBudgetDays(
            spentByDay: daily.spentByDay,
            resetsAt: weeklyResetsAt(now: now),
            windowStart: daily.windowStart,
            interruptedWindowStart: daily.interruptedWindowStart,
            weekOffset: weekOffset,
            now: now
        )
    }

    /// Weekly reset instant the bars and the reset caption anchor to.
    ///
    /// Uses the latest payload's `resets_at`, else the last one seen this run,
    /// else the one the daily store persisted on an earlier run. A remembered
    /// instant that has already passed is carried forward by whole weeks, so a
    /// payload that omits `resets_at` still yields an estimate of the current
    /// window.
    func weeklyResetsAt(now: Date = Date()) -> Date? {
        if let live = snapshot?.sevenDay?.resetsAt {
            return live
        }
        return Self.projectWeeklyReset(weeklyResetsAt ?? daily.windowResetsAt, now: now)
    }

    /// Advances `resetsAt` by whole weeks until it is after `now`.
    static func projectWeeklyReset(_ resetsAt: Date?, now: Date) -> Date? {
        guard let resetsAt else { return nil }
        guard resetsAt <= now else { return resetsAt }
        let week: TimeInterval = 7 * 86_400
        let weeks = (now.timeIntervalSince(resetsAt) / week).rounded(.down) + 1
        return resetsAt.addingTimeInterval(weeks * week)
    }
}
