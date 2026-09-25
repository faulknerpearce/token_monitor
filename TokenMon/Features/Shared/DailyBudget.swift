import Foundation

/// One calendar day in the monthly budget chart.
///
/// `spentUSD`/`budgetUSD` are nominally USD, but on the usage-quota chart they
/// carry **percent of the monthly allocation** (0…100); the math is identical.
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

    /// Bars for the full weekly window. The first bar is the day the pool
    /// opened (a Thursday reset → Thursday first) and stays there until the
    /// reset instant, when the window rolls to the new period. A stale
    /// `resetsAt` advances by whole periods so the window still contains today.
    static func buildWeeklyWindowDays(
        limitUSD: Double,
        daysInPeriod: Int,
        resetsAt: Date,
        spentByDay: [Date: Double],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyBudgetDay] {
        let count = max(1, daysInPeriod)
        let perDay = budgetPerDay(limitUSD: limitUSD, daysInPeriod: count)
        let weekStart = weeklyPeriodStart(
            resetsAt: resetsAt,
            daysInPeriod: count,
            now: now,
            calendar: calendar
        )
        var days: [DailyBudgetDay] = []
        for offset in 0..<count {
            let day = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
            let key = calendar.startOfDay(for: day)
            days.append(DailyBudgetDay(date: key, spentUSD: spentByDay[key] ?? 0, budgetUSD: perDay))
        }
        return days
    }

    /// Start of the running weekly pool. Before `resetsAt`, that is one period
    /// before the reset day, so the first bar's weekday matches the reset.
    static func weeklyPeriodStart(
        resetsAt: Date,
        daysInPeriod: Int,
        now: Date,
        calendar: Calendar
    ) -> Date {
        let count = max(1, daysInPeriod)
        let resetDay = calendar.startOfDay(for: resetsAt)
        var baseStart: Date
        if now >= resetsAt {
            baseStart = resetDay
            let today = calendar.startOfDay(for: now)
            var guardIter = 0
            while guardIter < 520 {
                let windowEnd = calendar.date(byAdding: .day, value: count - 1, to: baseStart) ?? baseStart
                if calendar.startOfDay(for: windowEnd) >= today { break }
                guard let advanced = calendar.date(byAdding: .day, value: count, to: baseStart) else { break }
                baseStart = advanced
                guardIter += 1
            }
        } else {
            baseStart = calendar.date(byAdding: .day, value: -count, to: resetDay) ?? resetDay
        }
        return calendar.startOfDay(for: baseStart)
    }

    /// Monday of the calendar week that contains `now`. Monthly charts always
    /// start here, independent of the billing-cycle anniversary.
    static func mondayOfWeek(containing now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: today) ?? today
    }

    /// Monday–Sunday bars for a subscription month. Days outside the billing
    /// period are present so the week still starts on Monday, with 0 spend.
    static func buildMondayWeekDays(
        periodStart: Date,
        periodEnd: Date,
        limitUSD: Double,
        spentByDay: [Date: Double],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyBudgetDay] {
        let periodDays = buildDays(
            periodStart: periodStart,
            periodEnd: periodEnd,
            limitUSD: limitUSD,
            spentByDay: spentByDay,
            now: now,
            calendar: calendar
        )
        let perDay = periodDays.first?.budgetUSD
            ?? budgetPerDay(limitUSD: limitUSD, daysInPeriod: max(1, periodDays.count))
        let spentInPeriod = Dictionary(
            periodDays.map { (calendar.startOfDay(for: $0.date), $0.spentUSD) },
            uniquingKeysWith: { _, last in last }
        )
        let weekStart = mondayOfWeek(containing: now, calendar: calendar)
        return (0..<7).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
            let key = calendar.startOfDay(for: day)
            return DailyBudgetDay(date: key, spentUSD: spentInPeriod[key] ?? 0, budgetUSD: perDay)
        }
    }

    /// Even-pace headroom vs live period consumption.
    ///
    /// `periodConsumed` is the pulled used % for the pool, not the sum of bar
    /// spends. The allowance is credited in **whole calendar days** through today,
    /// so it grows one day's share at a time and the caption's "left today" is
    /// that allowance minus what has been used. `resetsAt`, when known, only names
    /// the reset day in the caption; it does not change the day-based allowance.
    struct PaceHeadroom: Hashable, Sendable {
        var dailyBudget: Double
        /// Even-pace allowance accrued through today (elapsed days × daily share).
        var earned: Double
        var periodConsumed: Double
        /// `earned − consumed`: positive = ahead of pace, negative = over pace.
        var headroomToday: Double
        /// Reset instant the pool runs to, when known.
        var resetsAt: Date?
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

    /// Subscription / billing month bounds, never the calendar month of `now`.
    ///
    /// With only one side, infers the other by shifting one calendar month
    /// (anniversary-style cycles). A stale ended cycle advances in whole months
    /// to the running period.
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

    /// Monday–Sunday bars for a subscription/billing month. Returns nil when
    /// neither cycle start nor reset is known — refuses calendar-month guesses.
    /// A stale (already-ended) cycle advances to the running one before painting.
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
        let days = buildMondayWeekDays(
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

    /// Even-pace headroom for the pool, credited in whole calendar days.
    ///
    ///     earned = dailyBudget × elapsed days through today   (today counts)
    ///
    /// so the on-track allowance grows one day's share at a time: on day 1 of a
    /// weekly pool the allowance is 100/7 ≈ 14.3%, and 7% used leaves 7.3%. The
    /// count is capped at the period length implied by the daily share so clock
    /// skew cannot push `earned` above ~100%. Pass `elapsedDaysInPeriod` to match
    /// a full-period window; otherwise the budgets of the visible bars through
    /// today are summed.
    ///
    /// On the **final day** of the window the day-based allowance has already
    /// credited the whole pool, but the period may run past the last bar to a
    /// reset instant (e.g. a Thursday-evening reset with a Wednesday last bar).
    /// There the unspent pool is compared against the even share of the time
    /// actually left until reset, so a pool that cannot cover it reads as over
    /// pace instead of "left today".
    static func paceHeadroom(
        days: [DailyBudgetDay],
        periodConsumed: Double,
        elapsedDaysInPeriod: Int? = nil,
        resetsAt: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PaceHeadroom? {
        guard let first = days.first, first.budgetUSD > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        let periodLength = max(
            1,
            daysInPeriod(fromDailyBudget: first.budgetUSD, fallback: days.count)
        )
        let elapsedDays: Int
        if let elapsed = elapsedDaysInPeriod {
            elapsedDays = min(max(0, elapsed), periodLength)
        } else {
            elapsedDays = days.filter { calendar.startOfDay(for: $0.date) <= today }.count
        }
        let earned = first.budgetUSD * Double(elapsedDays)
        let consumed = max(0, periodConsumed)
        var headroomToday = earned - consumed
        if let resetsAt, resetsAt > now, elapsedDays >= periodLength {
            let daysUntilReset = resetsAt.timeIntervalSince(now) / 86_400
            let remainingPool = first.budgetUSD * Double(periodLength) - consumed
            headroomToday = remainingPool - first.budgetUSD * daysUntilReset
        }
        return PaceHeadroom(
            dailyBudget: first.budgetUSD,
            earned: earned,
            periodConsumed: consumed,
            headroomToday: headroomToday,
            resetsAt: resetsAt
        )
    }

    /// Footer caption for a pace headroom. Shared by the Grok daily-use chart and
    /// the weekly/monthly bars so the wording and thresholds cannot drift.
    ///
    /// A plain surplus reads "X% usage left today"; when the surplus exceeds one
    /// day's share the caption notes the extra banked from unused prior days.
    /// An overrun reads "Usage X% over today's allowance" — the used amount is
    /// never reported.
    static func paceCaption(_ pace: PaceHeadroom) -> String? {
        /// Headroom meaningfully above zero → otherwise call it on pace.
        let bankEpsilon = 0.05
        if pace.periodConsumed <= 0.001 {
            guard pace.dailyBudget > 0 else { return nil }
            if pace.earned > pace.dailyBudget + bankEpsilon {
                return String(
                    format: "%.1f%% usage left today from unused prior days",
                    pace.headroomToday
                )
            }
            return String(format: "No usage yet · %.1f%% today", pace.dailyBudget)
        }
        if pace.headroomToday < 0 {
            return String(
                format: "Usage %.1f%% over today's allowance",
                -pace.headroomToday
            )
        }
        if pace.headroomToday > pace.dailyBudget + bankEpsilon {
            return String(
                format: "%.1f%% usage left today from unused prior days",
                pace.headroomToday
            )
        }
        if pace.headroomToday < bankEpsilon {
            return "On pace for today"
        }
        return String(format: "%.1f%% usage left today", pace.headroomToday)
    }
}
