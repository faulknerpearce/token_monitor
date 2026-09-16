import Combine
import Foundation
import os

@MainActor
final class CursorUsagePoller: ObservableObject, ProviderUsagePoller {
    @Published private(set) var snapshot: CursorSnapshot?
    @Published private(set) var dayHourlyUsage: CursorDayHourlyUsage?
    @Published private(set) var dailyBudgetDays: [DailyBudgetDay]?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var dataSourceLabel: String?
    @Published var menuIsOpen = false

    private let settings: AppSettings
    private let auth: CursorAuthSession
    private let daily: DailyQuotaDeltaStore
    private let logger = Logger(category: "Cursor")
    private var cancellables = Set<AnyCancellable>()

    /// Last observed billing-cycle end, so the chart stays anchored if a later
    /// payload omits it.
    private var billingCycleEnd: Date?

    /// Reuse the last refreshed result when a rapid consecutive poll lands within
    /// this window, avoiding redundant full-cycle event paging on every poll step.
    private let eventCacheTTL: TimeInterval = 4

    private lazy var loop = PollingLoop(
        interval: { [weak self] in self?.currentInterval() },
        refresh: { [weak self] in await self?.refreshNow() }
    )

    init(settings: AppSettings, auth: CursorAuthSession, daily: DailyQuotaDeltaStore) {
        self.settings = settings
        self.auth = auth
        self.daily = daily
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
        loop.start()
    }

    func stop() {
        loop.stop()
    }

    func clearSnapshot() {
        snapshot = nil
        dayHourlyUsage = nil
        dailyBudgetDays = nil
        billingCycleEnd = nil
        lastError = nil
        dataSourceLabel = nil
        lastRefreshedAt = nil
        daily.clear()
    }

    func refreshNow() async {
        guard settings.needsCursorPolling else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let cookieHeader = auth.cookieHeader(), !cookieHeader.isEmpty else {
            auth.needsSignIn = true
            if snapshot == nil {
                lastError = "Sign in to Cursor to load usage."
            }
            return
        }

        // Rapid consecutive polls (e.g. while the menu is open) can reuse the
        // last result instead of re-paginating the full event history.
        if let lastRefreshedAt,
           snapshot != nil,
           Date().timeIntervalSince(lastRefreshedAt) < eventCacheTTL {
            auth.needsSignIn = false
            return
        }

        let generation = auth.sessionGeneration
        let client = CursorUsageClient(cookieHeader: cookieHeader)
        do {
            let (snap, hourly, estimatedWeightByDay) = try await client.fetchSnapshot()
            guard !Task.isCancelled, auth.isCurrent(generation) else { return }
            snapshot = snap
            dayHourlyUsage = hourly
            if let email = snap.accountEmail {
                auth.saveAccountEmail(email)
            }
            // The daily bars prefer the real day-over-day growth of the reported
            // pool %, falling back to a list-price estimate for days this build
            // never observed (see `buildDailyBudgetDays`).
            if let cycleEnd = snap.billingCycleEnd {
                billingCycleEnd = cycleEnd
            }
            daily.record(windowUsedPercent: snap.usedPercent, at: snap.fetchedAt)
            dailyBudgetDays = Self.buildDailyBudgetDays(
                observedByDay: daily.spentByDay,
                estimatedWeightByDay: estimatedWeightByDay,
                usedPercent: snap.usedPercent,
                billingCycleStart: snap.billingCycleStart,
                billingCycleEnd: snap.billingCycleEnd ?? billingCycleEnd,
                now: snap.fetchedAt
            )
            lastError = nil
            lastRefreshedAt = Date()
            dataSourceLabel = "Cursor dashboard"
            auth.needsSignIn = false
            logger.info(
                "Cursor refresh: total \(snap.usedPercent, format: .fixed(precision: 1))% used (\(Int((100 - snap.usedPercent).rounded()))% left)"
            )
        } catch let cursorError as ProviderError {
            let usageError = cursorError.usageError
            switch usageError {
            case .unauthorized, .notSignedIn:
                auth.markSessionInvalid(reason: cursorError.localizedDescription)
            default:
                break
            }
            if snapshot == nil {
                lastError = cursorError.localizedDescription
            }
            logger.error("Cursor refresh failed: \(cursorError.localizedDescription, privacy: .public)")
        } catch {
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            logger.error("Cursor refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentInterval() -> TimeInterval {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings)
    }

    /// Daily bars for the current **billing cycle**.
    ///
    /// Days the app observed directly use the real day-over-day growth of the
    /// reported pool % (`observedByDay`). Days it did not observe are back-filled
    /// from a per-day pool-estimate weight (`estimatedWeightByDay`), scaled so the
    /// whole cycle still sums to `usedPercent`. Returns nil when the subscription
    /// month cannot be resolved (a calendar month is never substituted).
    static func buildDailyBudgetDays(
        observedByDay: [Date: Double],
        estimatedWeightByDay: [Date: Double],
        usedPercent: Double,
        billingCycleStart: Date?,
        billingCycleEnd: Date?,
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
        let untracked = max(0, usedPercent - tracked)
        let unobserved = estimated.filter { effectiveObserved[$0.key] == nil }

        var blended = effectiveObserved
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

        return DailyBudget.buildLast7Days(
            periodStart: bounds.start,
            periodEnd: bounds.end,
            limitUSD: 100,
            spentByDay: blended,
            now: now,
            calendar: calendar
        )
    }
}
