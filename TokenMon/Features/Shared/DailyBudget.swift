import Foundation

/// One calendar day in the monthly budget chart.
///
/// `spentUSD`/`budgetUSD` are nominally USD for the legacy dollar chart, but
/// for the usage-quota chart they carry **percent of the monthly allocation**
/// (0…100). `isUsagePercent` disambiguates formatting; the math is identical.
struct DailyBudgetDay: Identifiable, Hashable, Sendable {
    var id: Date { date }
    var date: Date
    var spentUSD: Double
    var budgetUSD: Double

    var percentOfBudget: Double {
        guard budgetUSD > 0 else { return 0 }
        return Percent.clamp(spentUSD / budgetUSD * 100)
    }

    var isOverBudget: Bool { spentUSD > budgetUSD && budgetUSD > 0 }
}

enum DailyBudget {
    /// Daily allowance from monthly limit (same units as `limit`).
    static func budgetPerDay(limitUSD: Double, daysInPeriod: Int) -> Double {
        guard limitUSD > 0, daysInPeriod > 0 else { return 0 }
        return limitUSD / Double(daysInPeriod)
    }

    /// Days in a billing cycle defined by start/end.
    static func daysInBillingCycle(start: Date, end: Date, calendar: Calendar = .current) -> Int {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        let comps = calendar.dateComponents([.day], from: startDay, to: endDay)
        let days = comps.day ?? 30
        return max(1, days)
    }

    /// Builds an array of DailyBudgetDay for each calendar day in the period.
    /// `spentByDay` is keyed by `calendar.startOfDay(date)` with totals in the same
    /// units as `limitUSD`.
    ///
    /// When `now` falls on the `periodEnd` calendar day *before* the reset instant,
    /// the running period still owns today, so that day is included (same rule as
    /// the weekly window).
    static func buildDays(
        periodStart: Date,
        periodEnd: Date,
        limitUSD: Double,
        spentByDay: [Date: Double],
        now: Date? = nil,
        calendar: Calendar = .current
    ) -> [DailyBudgetDay] {
        let start = calendar.startOfDay(for: periodStart)
        let endDay = calendar.startOfDay(for: periodEnd)
        let includeEndDay = now.map { now in
            now >= start && now < periodEnd && calendar.isDate(calendar.startOfDay(for: now), inSameDayAs: endDay)
        } ?? false
        let exclusiveEnd = includeEndDay
            ? calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            : endDay
        let totalDays = daysInBillingCycle(start: start, end: exclusiveEnd, calendar: calendar)
        let perDay = budgetPerDay(limitUSD: limitUSD, daysInPeriod: totalDays)
        var days: [DailyBudgetDay] = []
        for offset in 0..<totalDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let dayKey = calendar.startOfDay(for: day)
            let spent = spentByDay[dayKey] ?? 0
            days.append(DailyBudgetDay(date: dayKey, spentUSD: spent, budgetUSD: perDay))
        }
        return days
    }

    /// 7-bar window ending on the last painted day of the period. Daily budget
    /// is derived from the *full period* allocation (`limit` / daysInPeriod),
    /// but only the last 7 days are returned for the chart.
    static func buildLast7Days(
        periodStart: Date,
        periodEnd: Date,
        limitUSD: Double,
        spentByDay: [Date: Double],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyBudgetDay] {
        let all = buildDays(
            periodStart: periodStart,
            periodEnd: periodEnd,
            limitUSD: limitUSD,
            spentByDay: spentByDay,
            now: now,
            calendar: calendar
        )
        return last7(from: all, now: now, calendar: calendar)
    }

    /// Filters `all` to the 7 calendar days ending on `now` (inclusive). If `now`
    /// is outside `all`'s period, returns the last 7 of `all`.
    static func last7(from all: [DailyBudgetDay], now: Date, calendar: Calendar) -> [DailyBudgetDay] {
        let today = calendar.startOfDay(for: now)
        if let idx = all.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: today) }) {
            let start = max(0, idx - 6)
            let end = min(all.count, start + 7)
            return Array(all[start..<end])
        }
        // Today not in period (e.g. preview data) — just return last 7
        if all.count <= 7 { return all }
        return Array(all.suffix(7))
    }

    /// Bars for the full weekly window anchored at the pool's actual reset
    /// instant rather than a fixed weekday. The window is the 7 days ending on
    /// the last day of the running period (advancing `resetsAt` by whole periods
    /// when the payload is stale), so it always contains today. On reset day
    /// before the instant that last day is today — calendar-keyed deltas stay
    /// visible. After the instant the window rolls to the new period. Never
    /// mixes two partial periods. Days after today carry 0 and are dimmed.
    static func buildWeeklyWindowDays(
        limitUSD: Double,
        daysInPeriod: Int,
        resetsAt: Date,
        spentByDay: [Date: Double],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyBudgetDay] {
        let perDay = budgetPerDay(limitUSD: limitUSD, daysInPeriod: daysInPeriod)
        let today = calendar.startOfDay(for: now)
        // Advance a stale `resetsAt` to the next future reset so the window
        // still contains today instead of sliding into the future empty.
        var nextReset = resetsAt
        var guardIter = 0
        while nextReset <= now, guardIter < 520 {
            guard let advanced = calendar.date(
                byAdding: .day, value: daysInPeriod, to: nextReset
            ) else { break }
            nextReset = advanced
            guardIter += 1
        }
        let resetDay = calendar.startOfDay(for: nextReset)
        // Normally the running period ends the calendar day before reset. On
        // reset day itself (before the instant) end on today so same-day
        // usage recorded under today's key is still painted.
        let weekEnd: Date
        if calendar.isDate(today, inSameDayAs: resetDay) {
            weekEnd = today
        } else {
            weekEnd = calendar.date(byAdding: .day, value: -1, to: resetDay) ?? today
        }
        let weekStart = calendar.date(
            byAdding: .day, value: -(max(1, daysInPeriod) - 1),
            to: weekEnd
        ) ?? today
        var days: [DailyBudgetDay] = []
        for offset in 0..<max(1, daysInPeriod) {
            let day = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
            let key = calendar.startOfDay(for: day)
            days.append(DailyBudgetDay(date: key, spentUSD: spentByDay[key] ?? 0, budgetUSD: perDay))
        }
        return days
    }

    /// Even-pace headroom through today vs live period consumption.
    ///
    /// Uses `days` for the per-day allotment. `periodConsumed` is the pulled
    /// used % for the pool — not the sum of bar spends. When the chart is a
    /// rolling 7-bar slice of a longer period (monthly), pass
    /// `elapsedDaysInPeriod` so earned days match the full pool, not just the
    /// visible bars.
    struct PaceHeadroom: Hashable, Sendable {
        var dailyBudget: Double
        var earnedThroughToday: Double
        var periodConsumed: Double
        var headroomToday: Double
    }

    /// Quota window the daily bars pace against.
    ///
    /// - `weekly`: Claude / Grok — bars usually cover the full period.
    /// - `monthly`: Cursor / OpenCode — bars are a 7-day slice of a
    ///   **subscription / billing** month (never the calendar month of `now`).
    enum AllowancePeriod: String, Sendable {
        case weekly
        case monthly
    }

    /// Inclusive calendar days from `periodStart` through today (0 if today is before start).
    static func elapsedDaysThroughToday(
        from periodStart: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let start = calendar.startOfDay(for: periodStart)
        let today = calendar.startOfDay(for: now)
        guard today >= start else { return 0 }
        let gap = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return gap + 1
    }

    /// Subscription / billing month bounds. Never uses “calendar month of now”.
    ///
    /// Prefer explicit `knownStart` + `resetsAt` and keep their exact instants
    /// (Cursor cycles can start mid-day). With only one side, infer the other by
    /// shifting one calendar month (anniversary-style cycles).
    ///
    /// When `now` is provided and the resolved cycle already ended (stale payload
    /// after a rollover), the provider-given anchor advances in whole months
    /// until it describes the running period — same treatment as weekly windows.
    static func subscriptionMonth(
        knownStart: Date? = nil,
        resetsAt: Date? = nil,
        now: Date? = nil,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        var start: Date
        var end: Date
        if let knownStart, let resetsAt, resetsAt > knownStart {
            start = knownStart
            end = resetsAt
        } else if let knownStart {
            guard let inferredEnd = calendar.date(byAdding: .month, value: 1, to: knownStart),
                  inferredEnd > knownStart else { return nil }
            start = knownStart
            end = inferredEnd
        } else if let resetsAt {
            guard let inferredStart = calendar.date(byAdding: .month, value: -1, to: resetsAt),
                  resetsAt > inferredStart else { return nil }
            start = inferredStart
            end = resetsAt
        } else {
            return nil
        }

        if let now {
            var guardIter = 0
            while end <= now, guardIter < 520 {
                start = end
                guard let advanced = calendar.date(byAdding: .month, value: 1, to: end),
                      advanced > end else { break }
                end = advanced
                guardIter += 1
            }
        }
        return (start, end)
    }

    /// Last-7 bars for a subscription/billing month. Returns nil when neither
    /// cycle start nor reset is known — refuses calendar-month guesses. A stale
    /// (already-ended) cycle advances to the running one before painting.
    static func buildSubscriptionMonthLast7Days(
        limitUSD: Double,
        spentByDay: [Date: Double],
        knownStart: Date? = nil,
        resetsAt: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (days: [DailyBudgetDay], periodStart: Date)? {
        guard let bounds = subscriptionMonth(
            knownStart: knownStart,
            resetsAt: resetsAt,
            now: now,
            calendar: calendar
        ) else { return nil }
        let days = buildLast7Days(
            periodStart: bounds.start,
            periodEnd: bounds.end,
            limitUSD: limitUSD,
            spentByDay: spentByDay,
            now: now,
            calendar: calendar
        )
        return (days, calendar.startOfDay(for: bounds.start))
    }

    /// Weekly providers (Claude / Grok): the painted window *is* the period, so
    /// the first bar is the start. `resetsAt` is ignored for start resolution.
    static func weeklyPacePeriodStart(
        days: [DailyBudgetDay],
        calendar: Calendar = .current
    ) -> Date? {
        days.first.map { calendar.startOfDay(for: $0.date) }
    }

    /// Monthly providers (Cursor / OpenCode): always a subscription/billing month.
    ///
    /// 1. `subscriptionMonth` (advances a stale cycle the same way bars do)
    /// 2. else `resetsAt − daysInPeriod` from the bar daily share
    /// Never falls back to calendar month of `now`.
    static func monthlyPacePeriodStart(
        days: [DailyBudgetDay],
        knownStart: Date? = nil,
        resetsAt: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        if let bounds = subscriptionMonth(
            knownStart: knownStart,
            resetsAt: resetsAt,
            now: now,
            calendar: calendar
        ) {
            return calendar.startOfDay(for: bounds.start)
        }
        let daily = days.first?.budgetUSD ?? 0
        let daysInPeriod = daysInPeriod(fromDailyBudget: daily, fallback: 0)
        if let resetsAt {
            let resetDay = calendar.startOfDay(for: resetsAt)
            if daysInPeriod > 0 {
                return calendar.date(byAdding: .day, value: -daysInPeriod, to: resetDay)
            }
        }
        return nil
    }

    /// Resolves period start for the given allowance kind.
    static func pacePeriodStart(
        period: AllowancePeriod,
        days: [DailyBudgetDay],
        knownStart: Date? = nil,
        resetsAt: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        switch period {
        case .weekly:
            return weeklyPacePeriodStart(days: days, calendar: calendar)
        case .monthly:
            return monthlyPacePeriodStart(
                days: days,
                knownStart: knownStart,
                resetsAt: resetsAt,
                now: now,
                calendar: calendar
            )
        }
    }

    /// Days-in-period implied by an even daily share of a 100% pool.
    static func daysInPeriod(fromDailyBudget daily: Double, fallback: Int) -> Int {
        guard daily > 0 else { return max(0, fallback) }
        return max(1, Int((100.0 / daily).rounded()))
    }

    /// Earned = dailyBudget × elapsed days (full period when `elapsedDaysInPeriod`
    /// is set; otherwise sum of budgets for visible bars with `date <= today`).
    /// Headroom = earned − consumed. Future bars do not earn. Elapsed is capped
    /// at the period length implied by the daily share so clock skew cannot
    /// push earned above ~100%.
    static func paceHeadroom(
        days: [DailyBudgetDay],
        periodConsumed: Double,
        elapsedDaysInPeriod: Int? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PaceHeadroom? {
        guard let first = days.first, first.budgetUSD > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        let periodLength = max(
            1,
            daysInPeriod(fromDailyBudget: first.budgetUSD, fallback: days.count)
        )
        let earned: Double
        if let elapsed = elapsedDaysInPeriod {
            let capped = min(max(0, elapsed), periodLength)
            earned = first.budgetUSD * Double(capped)
        } else {
            earned = days
                .filter { calendar.startOfDay(for: $0.date) <= today }
                .reduce(0.0) { $0 + $1.budgetUSD }
        }
        let consumed = max(0, periodConsumed)
        return PaceHeadroom(
            dailyBudget: first.budgetUSD,
            earnedThroughToday: earned,
            periodConsumed: consumed,
            headroomToday: earned - consumed
        )
    }
}
