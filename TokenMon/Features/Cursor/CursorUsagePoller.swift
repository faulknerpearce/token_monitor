import Combine
import Foundation
import os

/// Polls Cursor usage and builds billing-cycle daily bars.
@MainActor
final class CursorUsagePoller: ObservableObject, ProviderUsagePoller {
    @Published private(set) var snapshot: CursorSnapshot?
    @Published private(set) var dayHourlyUsage: CursorDayHourlyUsage?
    @Published private(set) var dailyBudgetDays: [DailyBudgetDay]?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var dataSourceLabel: String?
    @Published var menuIsOpen = false {
        didSet { if menuIsOpen != oldValue { pollingLoop.wake() } }
    }

    private let settings: AppSettings
    private let auth: CursorAuthSession
    private let daily: DailyQuotaDeltaStore
    /// Injected fetch seam (tests supply a fake); defaults to the live client.
    private let fetchSnapshot:
        (String) async throws -> (CursorSnapshot, CursorDayHourlyUsage, [Date: Double])
    private let logger = Logger(category: "Cursor")
    private var cancellables = Set<AnyCancellable>()

    /// Last observed billing-cycle end, so the chart stays anchored if a later
    /// payload omits it.
    private var billingCycleEnd: Date?

    /// Inputs from the last refresh, so the panel can rebuild an earlier Monday
    /// week without paging Cursor events again.
    private var budgetContext: BudgetContext?

    /// Estimate weights and cycle bounds captured at the last successful refresh.
    private struct BudgetContext {
        var estimatedWeightByDay: [Date: Double]
        var usedPercent: Double
        var billingCycleStart: Date?
        var billingCycleEnd: Date?
        var referenceNow: Date
    }

    /// Reuse the last refreshed result when a rapid consecutive poll lands within
    /// this window, avoiding redundant full-cycle event paging on every poll step.
    private let eventCacheTTL: TimeInterval = 4

    private(set) lazy var pollingLoop = PollingLoop(
        interval: { [weak self] in self?.pollInterval() },
        refresh: { [weak self] in await self?.performRefresh() ?? .skipped }
    )

    init(
        settings: AppSettings,
        auth: CursorAuthSession,
        daily: DailyQuotaDeltaStore,
        fetchSnapshot: ((String) async throws -> (CursorSnapshot, CursorDayHourlyUsage, [Date: Double]))? = nil
    ) {
        self.settings = settings
        self.auth = auth
        self.daily = daily
        self.fetchSnapshot = fetchSnapshot ?? { cookieHeader in
            try await CursorUsageClient(cookieHeader: cookieHeader).fetchSnapshot()
        }
        // Drop the Cursor snapshot as soon as this shared session signs out.
        auth.$isSignedIn
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] signedIn in
                if !signedIn { self?.clearSnapshot() }
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
        dayHourlyUsage = nil
        dailyBudgetDays = nil
        billingCycleEnd = nil
        budgetContext = nil
        lastError = nil
        dataSourceLabel = nil
        lastRefreshedAt = nil
        daily.clear()
    }

    /// Fetches now when the provider is enabled and restarts the poll wait from here.
    func refreshNow() async {
        await pollingLoop.refreshNow()
    }

    private func performRefresh() async -> PollOutcome {
        guard settings.isProviderEnabled(.cursor) else { return .skipped }
        guard !isRefreshing else { return .skipped }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let cookieHeader = auth.cookieHeader(), !cookieHeader.isEmpty else {
            auth.needsSignIn = true
            if snapshot == nil {
                lastError = "Sign in to Cursor to load usage."
            }
            return .skipped
        }

        // Rapid consecutive polls (e.g. while the menu is open) can reuse the
        // last result instead of re-paginating the full event history.
        if let lastRefreshedAt,
           snapshot != nil,
           Date().timeIntervalSince(lastRefreshedAt) < eventCacheTTL {
            auth.needsSignIn = false
            return .skipped
        }

        let generation = auth.sessionGeneration
        do {
            let (snap, hourly, estimatedWeightByDay) = try await fetchSnapshot(cookieHeader)
            guard !Task.isCancelled, auth.isCurrent(generation) else { return .skipped }
            snapshot = snap
            dayHourlyUsage = hourly
            if let email = snap.accountEmail, email != auth.accountEmail {
                auth.saveAccountEmail(email)
            }
            // The daily bars prefer the real day-over-day growth of the reported
            // pool %, falling back to a list-price estimate for days this build
            // never observed (see `buildDailyBudgetDays`).
            if let cycleEnd = snap.billingCycleEnd {
                billingCycleEnd = cycleEnd
            }
            // The store spots a billing-cycle rollover or a provider-initiated early
            // reset from the cycle start/end and keeps earlier days as history.
            let cycleEnd = snap.billingCycleEnd ?? billingCycleEnd
            daily.record(
                windowUsedPercent: snap.usedPercent,
                at: snap.fetchedAt,
                window: QuotaWindow(start: snap.billingCycleStart, resetsAt: cycleEnd),
                periodDays: Self.cycleLengthDays(start: snap.billingCycleStart, end: cycleEnd)
            )
            budgetContext = BudgetContext(
                estimatedWeightByDay: estimatedWeightByDay,
                usedPercent: snap.usedPercent,
                billingCycleStart: snap.billingCycleStart,
                billingCycleEnd: cycleEnd,
                referenceNow: snap.fetchedAt
            )
            dailyBudgetDays = Self.buildDailyBudgetDays(
                observedByDay: daily.spentByDay,
                interruptedWindowStart: daily.interruptedWindowStart,
                estimatedWeightByDay: estimatedWeightByDay,
                usedPercent: snap.usedPercent,
                billingCycleStart: snap.billingCycleStart,
                billingCycleEnd: cycleEnd,
                now: snap.fetchedAt
            )
            lastError = nil
            lastRefreshedAt = Date()
            dataSourceLabel = "Cursor dashboard"
            auth.needsSignIn = false
            logger.info(
                "Cursor refresh: total \(snap.usedPercent, format: .fixed(precision: 1))% used (\(Int((100 - snap.usedPercent).rounded()))% left)"
            )
            return .success
        } catch is CancellationError {
            return .skipped
        } catch let cursorError as ProviderError {
            // A request that began under a previous credential state must not
            // tear down the current session (sign-out → sign in as another
            // account while this fetch was in flight).
            guard auth.isCurrent(generation) else { return .skipped }
            let usageError = cursorError.usageError
            switch usageError {
            case .unauthorized, .notSignedIn:
                auth.markSessionInvalid(reason: cursorError.localizedDescription)
            default:
                break
            }
            lastError = cursorError.localizedDescription
            logger.error("Cursor refresh failed: \(cursorError.localizedDescription, privacy: .public)")
            return PollOutcome(error: cursorError)
        } catch {
            guard auth.isCurrent(generation) else { return .skipped }
            lastError = error.localizedDescription
            logger.error("Cursor refresh failed: \(error.localizedDescription, privacy: .public)")
            return PollOutcome(error: error)
        }
    }

    private func pollInterval() -> TimeInterval? {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings, needed: settings.needsCursorPolling)
    }

    /// Billing-cycle length in days for rollover detection; 30 when either end is unknown.
    private static func cycleLengthDays(start: Date?, end: Date?) -> Int {
        guard let start, let end, end > start else { return 30 }
        return DailyBudget.daysInBillingCycle(start: start, end: end)
    }

    /// Daily bars for the current **billing cycle**.
    ///
    /// Days the app observed directly use the real day-over-day growth of the
    /// reported pool % (`observedByDay`). Days it did not observe are back-filled
    /// from a per-day pool-estimate weight (`estimatedWeightByDay`), scaled so the
    /// whole cycle still sums to `usedPercent`. If tracked deltas exceed the live
    /// pool %, they are rescaled down to match instead of overshooting. Returns
    /// nil when the subscription month cannot be resolved (a calendar month is
    /// never substituted).
    ///
    /// After an early provider reset, `interruptedWindowStart` marks the cycle
    /// that was cut short: its observed days that fall before the new cycle start
    /// are shown (dimmed) as history in the displayed Monday–Sunday week, but
    /// never count toward the new cycle's pool math.
    static func buildDailyBudgetDays(
        observedByDay: [Date: Double],
        interruptedWindowStart: Date? = nil,
        estimatedWeightByDay: [Date: Double],
        usedPercent: Double,
        billingCycleStart: Date?,
        billingCycleEnd: Date?,
        weekOffset: Int = 0,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyBudgetDay]? {
        guard let bounds = DailyBudget.subscriptionMonth(
            knownStart: billingCycleStart,
            resetsAt: billingCycleEnd,
            now: now,
            calendar: calendar
        ) else { return nil }
        let cycleStartDay = calendar.startOfDay(for: bounds.start)
        let observed = observedByDay.filter { $0.key >= cycleStartDay && $0.key < bounds.end }
        let estimated = estimatedWeightByDay.filter { $0.key >= cycleStartDay && $0.key < bounds.end }

        // The first day the app tracked is only partially observed (tracking began
        // mid-day), so estimate it rather than paint a misleading sliver. Later
        // days are covered fully and use their measured delta.
        var effectiveObserved = observed
        if let firstTrackedDay = observed.keys.min() {
            effectiveObserved.removeValue(forKey: firstTrackedDay)
        }

        let tracked = effectiveObserved.values.reduce(0, +)
        let unobserved = estimated.filter { effectiveObserved[$0.key] == nil }

        var blended = effectiveObserved
        if tracked > usedPercent + 0.001, tracked > 0 {
            // Pool % fell below the sum of tracked daily deltas (downward tick,
            // API rebase, or drift past the reset floor). Rescale so bars still
            // sum to the live headline usedPercent instead of overshooting it.
            let scale = usedPercent / tracked
            for (day, value) in effectiveObserved {
                blended[day] = value * scale
            }
        } else {
            let untracked = max(0, usedPercent - tracked)
            let weightSum = unobserved.values.reduce(0, +)
            if untracked > 0.001, weightSum > 0 {
                for (day, usd) in unobserved {
                    blended[day, default: 0] += usd / weightSum * untracked
                }
            } else if untracked > 0.001, !unobserved.isEmpty {
                let perDay = untracked / Double(unobserved.count)
                for day in unobserved.keys {
                    blended[day, default: 0] += perDay
                }
            }
        }

        var prior: [Date: Double] = [:]
        if let interruptedWindowStart {
            let from = calendar.startOfDay(for: interruptedWindowStart)
            prior = observedByDay.filter { $0.key >= from && $0.key < cycleStartDay }
        }
        return DailyBudget.buildMondayWeekDays(
            periodStart: bounds.start,
            periodEnd: bounds.end,
            limitUSD: 100,
            spentByDay: blended,
            priorWindowSpentByDay: prior,
            historyByDay: observedByDay,
            weekOffset: weekOffset,
            now: now,
            calendar: calendar
        )
    }

    /// Monday-week bars `weekOffset` steps before the week containing the last
    /// refresh. `0` matches ``dailyBudgetDays``. Returns nil before the first
    /// refresh, or when the subscription month cannot be resolved.
    func dailyBudgetDays(weekOffset: Int) -> [DailyBudgetDay]? {
        guard let budgetContext else { return nil }
        return Self.buildDailyBudgetDays(
            observedByDay: daily.spentByDay,
            interruptedWindowStart: daily.interruptedWindowStart,
            estimatedWeightByDay: budgetContext.estimatedWeightByDay,
            usedPercent: budgetContext.usedPercent,
            billingCycleStart: budgetContext.billingCycleStart,
            billingCycleEnd: budgetContext.billingCycleEnd,
            weekOffset: weekOffset,
            now: budgetContext.referenceNow
        )
    }
}
