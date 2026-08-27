import Combine
import Foundation
import os

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
    private let logger = Logger(category: "Grokbot")
    private var cancellables = Set<AnyCancellable>()

    /// Last observed reset instant, so the chart stays anchored if a later
    /// payload omits it.
    private var weeklyResetsAt: Date?

    private lazy var loop = PollingLoop(
        interval: { [weak self] in self?.currentInterval() },
        refresh: { [weak self] in await self?.refreshNow() }
    )

    init(
        settings: AppSettings,
        auth: CursorAuthSession,
        hourly: HourlyDeltaActivityStore,
        daily: DailyQuotaDeltaStore
    ) {
        self.settings = settings
        self.auth = auth
        self.hourly = hourly
        self.daily = daily
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
        lastError = nil
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

        let client = GrokbotUsageClient(cookieHeader: cookieHeader, accountEmail: auth.accountEmail)
        do {
            let fresh = try await client.fetchSnapshot()
            guard !Task.isCancelled, auth.isSignedIn, !auth.needsSignIn else { return }
            snapshot = fresh
            lastError = nil
            lastRefreshedAt = Date()
            logger.info("Grokbot refresh: \(fresh.usedPercent, format: .fixed(precision: 1))% of weekly pool used")

            if let resetsAt = fresh.resetsAt {
                weeklyResetsAt = resetsAt
            }
            hourly.record(usedPercent: fresh.usedPercent, at: fresh.fetchedAt)
            daily.record(windowUsedPercent: fresh.usedPercent, at: fresh.fetchedAt)
            dailyBudgetDays = Self.buildDailyBudgetDays(
                spentByDay: daily.spentByDay,
                resetsAt: fresh.resetsAt ?? weeklyResetsAt,
                daysInPeriod: fresh.daysInPeriod(),
                now: fresh.fetchedAt
            )
        } catch let error as GrokbotUsageError {
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
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            logger.error("Grokbot refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentInterval() -> TimeInterval {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings)
    }

    /// Daily bars for the current allowance period, anchored to the provider's
    /// actual reset instant. Returns `[]` when no reset has ever been observed —
    /// a rolling window is never substituted for the real period.
    ///
    /// `daysInPeriod` comes from the payload's own
    /// `current_period_start` → `next_reset_timestamp_utc` span, so a plan on a
    /// non-7-day cadence still paces correctly.
    static func buildDailyBudgetDays(
        spentByDay: [Date: Double],
        resetsAt: Date?,
        daysInPeriod: Int = 7,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyBudgetDay] {
        guard let resetsAt else { return [] }
        return DailyBudget.buildWeeklyWindowDays(
            limitUSD: 100,
            daysInPeriod: daysInPeriod,
            resetsAt: resetsAt,
            spentByDay: spentByDay,
            now: now,
            calendar: calendar
        )
    }
}
