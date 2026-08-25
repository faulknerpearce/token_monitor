import Combine
import Foundation
import os

@MainActor
final class ClaudeUsagePoller: ObservableObject, ProviderUsagePoller {
    @Published private(set) var snapshot: ClaudeSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?
    /// Daily bars for the current weekly window, anchored to the pool's actual
    /// `resets_at`: % of the weekly pool burned per calendar day.
    @Published private(set) var dailyBudgetDays: [DailyBudgetDay]?
    @Published var menuIsOpen = false

    private let settings: AppSettings
    private let auth: ClaudeAuthSession
    private let hourly: HourlyDeltaActivityStore
    private let daily: DailyQuotaDeltaStore
    private let logger = Logger(category: "Claude")

    /// Last observed `seven_day.resets_at`; tracks weekly-pool rollovers so the
    /// day-delta history can be cleared when a new period begins, and anchors
    /// the chart if a later payload omits the reset time.
    private var weeklyResetsAt: Date?

    private lazy var loop = PollingLoop(
        interval: { [weak self] in self?.currentInterval() },
        refresh: { [weak self] in await self?.refreshNow() }
    )

    init(settings: AppSettings, auth: ClaudeAuthSession, hourly: HourlyDeltaActivityStore, daily: DailyQuotaDeltaStore) {
        self.settings = settings
        self.auth = auth
        self.hourly = hourly
        self.daily = daily
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
        guard settings.needsClaudePolling else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let cookieHeader = auth.cookieHeader() ?? ""
        let oauthToken = ClaudeOAuthTokenProvider.accessToken()
        let startedWithCookieSession = auth.isSignedIn
        guard !cookieHeader.isEmpty || !(oauthToken?.isEmpty ?? true) else {
            auth.needsSignIn = true
            if snapshot == nil {
                lastError = "Sign in to Claude to load usage."
            }
            return
        }

        let client = ClaudeUsageClient(
            cookieHeader: cookieHeader,
            oauthToken: oauthToken
        )
        do {
            let (response, fetchedAt) = try await client.fetchUsage()
            guard !Task.isCancelled else { return }
            // Drop mid-flight cookie sign-out. OAuth-only users never set
            // `isSignedIn`, so they must still accept a successful OAuth payload.
            if startedWithCookieSession && auth.needsSignIn { return }
            let hasOAuth = !(oauthToken?.isEmpty ?? true)
            guard auth.isSignedIn || hasOAuth else { return }
            snapshot = ClaudeSnapshot(
                fetchedAt: fetchedAt,
                fiveHour: response.fiveHour,
                sevenDay: response.sevenDay,
                sevenDayOpus: response.sevenDayOpus,
                sevenDaySonnet: response.sevenDaySonnet,
                sevenDayHaiku: response.sevenDayHaiku,
                accountEmail: auth.accountEmail
            )
            lastError = nil
            lastRefreshedAt = Date()
            // Cookie sessions clear needsSignIn; OAuth-only keeps the Sign In
            // affordance so users can still link the web session for email/org.
            if auth.isSignedIn {
                auth.needsSignIn = false
            }
            if let percent = response.fiveHour?.usedPercent {
                hourly.record(usedPercent: percent, at: fetchedAt)
                logger.info("Claude refresh: 5h \(percent, format: .fixed(precision: 1))% used")
            }
            if let weeklyPercent = response.sevenDay?.usedPercent {
                noteWeeklyResetAdvance(response.sevenDay?.resetsAt)
                daily.record(windowUsedPercent: weeklyPercent, at: fetchedAt)
            }
            dailyBudgetDays = Self.buildDailyBudgetDays(
                spentByDay: daily.spentByDay,
                resetsAt: response.sevenDay?.resetsAt ?? weeklyResetsAt,
                now: fetchedAt
            )
        } catch let error as ClaudeUsageError {
            let usageError = error.usageError
            switch usageError {
            case .unauthorized, .notSignedIn:
                auth.markSessionInvalid(reason: error.localizedDescription)
            default:
                break
            }
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            logger.error("Claude refresh failed: \(error.localizedDescription, privacy: .public)")
        } catch {
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            logger.error("Claude refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentInterval() -> TimeInterval {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings)
    }

    /// Tracks the latest observed `seven_day.resets_at` so it can anchor the
    /// chart if a later payload omits the reset time.
    ///
    /// Note: this deliberately does NOT wipe accumulated day deltas when
    /// `resets_at` moves forward. Claude's weekly pool is a rolling window whose
    /// reset time advances with usage, so a forward move is not necessarily a
    /// fresh period — clearing on it erased real history. Old-period days simply
    /// fall outside the anchored window and are hidden; a true reset still gets
    /// captured by the drop-as-reset credit in `DailyQuotaDeltaStore`.
    private func noteWeeklyResetAdvance(_ resetsAt: Date?) {
        guard let resetsAt else { return }
        weeklyResetsAt = resetsAt
    }

    /// Daily bars for the current weekly window, anchored to the pool's actual
    /// reset time: while the period runs, the first bar is the day it began
    /// and the last bar is the day before reset — except on reset day itself
    /// before the instant, when the last bar is today so calendar-keyed
    /// deltas stay visible. Falls back to a rolling 7-day window while no
    /// reset time has been observed. The weekly window's 100% pool is split
    /// evenly across its 7 days, so each day's budget is 1/7th of it.
    static func buildDailyBudgetDays(
        spentByDay: [Date: Double],
        resetsAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyBudgetDay] {
        guard let resetsAt else {
            return DailyBudget.buildRolling7Days(
                limitUSD: 100,
                daysInPeriod: 7,
                spentByDay: spentByDay,
                now: now,
                calendar: calendar
            )
        }
        return DailyBudget.buildWeeklyWindowDays(
            limitUSD: 100,
            daysInPeriod: 7,
            resetsAt: resetsAt,
            spentByDay: spentByDay,
            now: now,
            calendar: calendar
        )
    }
}
