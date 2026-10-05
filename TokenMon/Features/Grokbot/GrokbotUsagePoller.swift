import Combine
import Foundation
import os

/// Periodically refreshes the Grok Bot allowance from the shared Cursor session.
@MainActor
final class GrokbotUsagePoller: ObservableObject, ProviderUsagePoller {
    @Published private(set) var snapshot: GrokbotSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?
    /// Daily bars for the current allowance period, anchored to the provider's
    /// own `next_reset_timestamp_utc`: % of the pool burned per calendar day.
    @Published private(set) var dailyBudgetDays: [DailyBudgetDay]?
    @Published var menuIsOpen = false

    private let settings: AppSettings
    /// Grok Bot authenticates against the Cursor account, so this borrows the
    /// existing Cursor session rather than owning a second cookie store.
    private let auth: CursorAuthSession
    private let hourly: HourlyDeltaActivityStore
    private let daily: DailyQuotaDeltaStore
    /// Injected fetch seam (tests supply a fake); defaults to the live client.
    private let fetchSnapshot: (String, String?) async throws -> GrokbotSnapshot
    private let logger = Logger(category: "Grokbot")
    private var cancellables = Set<AnyCancellable>()

    /// Last observed reset instant, so the chart stays anchored if a later
    /// payload omits it.
    private var weeklyResetsAt: Date?
    /// Instant the current bars were built against, so earlier weeks shift from
    /// the same window.
    private var budgetReferenceNow: Date?

    private lazy var loop = PollingLoop(
        interval: { [weak self] in self?.currentInterval() },
        refresh: { [weak self] in await self?.refreshNow() }
    )

    init(
        settings: AppSettings,
        auth: CursorAuthSession,
        hourly: HourlyDeltaActivityStore,
        daily: DailyQuotaDeltaStore,
        fetchSnapshot: ((String, String?) async throws -> GrokbotSnapshot)? = nil
    ) {
        self.settings = settings
        self.auth = auth
        self.hourly = hourly
        self.daily = daily
        self.fetchSnapshot = fetchSnapshot ?? { cookieHeader, accountEmail in
            try await GrokbotUsageClient(cookieHeader: cookieHeader, accountEmail: accountEmail).fetchSnapshot()
        }
        // The session is shared with Cursor. Signing out (or a 401) from either
        // surface must drop this snapshot immediately, not on the next poll.
        auth.$isSignedIn
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] signedIn in
                if !signedIn { self?.clearSnapshot() }
            }
            .store(in: &cancellables)
    }

    func start() {
        loop.start()
    }

    func stop() {
        loop.stop()
    }

    func clearSnapshot() {
        snapshot = nil
        dailyBudgetDays = nil
        weeklyResetsAt = nil
        budgetReferenceNow = nil
        lastError = nil
        lastRefreshedAt = nil
        hourly.clear()
        daily.clear()
    }

    func refreshNow() async {
        guard settings.needsGrokbotPolling else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let cookieHeader = auth.cookieHeader(), !cookieHeader.isEmpty else {
            if snapshot != nil { clearSnapshot() }
            lastError = "Sign in to Cursor to load your Grokbot allowance."
            return
        }

        let generation = auth.sessionGeneration
        do {
            let fresh = try await fetchSnapshot(cookieHeader, auth.accountEmail)
            guard !Task.isCancelled, auth.isCurrent(generation) else { return }
            snapshot = fresh
            lastError = nil
            lastRefreshedAt = Date()
            logger.info("Grokbot refresh: \(fresh.usedPercent, format: .fixed(precision: 1))% of weekly pool used")

            if let resetsAt = fresh.resetsAt {
                weeklyResetsAt = resetsAt
            }
            // The daily store recognizes a normal rollover or a provider-initiated
            // early reset from the payload's own start / reset instants and keeps
            // the earlier days as history. Hourly deltas restart their baseline
            // either way; an early reset keeps the hours already recorded today.
            let transition = daily.record(
                windowUsedPercent: fresh.usedPercent,
                at: fresh.fetchedAt,
                window: QuotaWindow(start: fresh.periodStart, resetsAt: fresh.resetsAt),
                periodDays: fresh.daysInPeriod()
            )
            switch transition {
            case .none: break
            case .rollover: hourly.beginNewWindow()
            case .earlyReset: hourly.beginNewWindow(keepingHours: true)
            }
            hourly.record(usedPercent: fresh.usedPercent, at: fresh.fetchedAt)
            budgetReferenceNow = fresh.fetchedAt
            dailyBudgetDays = Self.buildDailyBudgetDays(
                spentByDay: daily.spentByDay,
                resetsAt: fresh.resetsAt ?? weeklyResetsAt,
                daysInPeriod: fresh.daysInPeriod(),
                windowStart: daily.windowStart,
                interruptedWindowStart: daily.interruptedWindowStart,
                now: fresh.fetchedAt
            )
        } catch let error as ProviderError {
            // A request that began under a previous credential state must not
            // tear down the current session.
            guard auth.isCurrent(generation) else { return }
            switch error.usageError {
            case .unauthorized, .notSignedIn:
                auth.markSessionInvalid(reason: error.localizedDescription)
            default:
                break
            }
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            logger.error("Grokbot refresh failed: \(error.localizedDescription, privacy: .public)")
        } catch {
            guard auth.isCurrent(generation) else { return }
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            logger.error("Grokbot refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentInterval() -> TimeInterval {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings)
    }

    /// True when `nextResetsAt` represents a genuinely new allowance period
    /// rather than the same period's reset instant creeping forward. Forwards to
    /// the shared rule used by `DailyQuotaDeltaStore`.
    static func isNewWindow(
        previousResetsAt: Date?,
        nextResetsAt: Date?,
        periodDays: Int,
        calendar: Calendar = .current
    ) -> Bool {
        QuotaWindowTransition.isRollover(
            previousResetsAt: previousResetsAt,
            nextResetsAt: nextResetsAt,
            periodDays: periodDays
        )
    }

    /// Daily bars for the current allowance period, anchored to the provider's
    /// actual reset instant. Returns `[]` when no reset has ever been observed —
    /// a rolling window is never substituted for the real period.
    ///
    /// `daysInPeriod` comes from the payload's own
    /// `current_period_start` → `next_reset_timestamp_utc` span (see
    /// `GrokbotSnapshot.daysInPeriod`). `windowStart` / `interruptedWindowStart`
    /// anchor the bars to a window the provider began early and lead them with the
    /// preserved days before it (see `DailyBudget.buildWeeklyWindowDays`).
    static func buildDailyBudgetDays(
        spentByDay: [Date: Double],
        resetsAt: Date?,
        daysInPeriod: Int = 7,
        windowStart: Date? = nil,
        interruptedWindowStart: Date? = nil,
        weekOffset: Int = 0,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyBudgetDay] {
        guard let resetsAt else { return [] }
        return DailyBudget.buildWeeklyWindowDays(
            limitUSD: 100,
            daysInPeriod: daysInPeriod,
            resetsAt: resetsAt,
            spentByDay: spentByDay,
            windowStart: windowStart,
            interruptedWindowStart: interruptedWindowStart,
            weekOffset: weekOffset,
            now: now,
            calendar: calendar
        )
    }

    /// Bars for the allowance window `weekOffset` steps before the current one.
    ///
    /// Reads the live daily store so the panel can browse earlier weeks without
    /// a new poll. `0` matches ``dailyBudgetDays``.
    func dailyBudgetDays(weekOffset: Int) -> [DailyBudgetDay] {
        Self.buildDailyBudgetDays(
            spentByDay: daily.spentByDay,
            resetsAt: snapshot?.resetsAt ?? weeklyResetsAt,
            daysInPeriod: snapshot?.daysInPeriod() ?? 7,
            windowStart: daily.windowStart,
            interruptedWindowStart: daily.interruptedWindowStart,
            weekOffset: weekOffset,
            now: budgetReferenceNow ?? Date()
        )
    }
}
