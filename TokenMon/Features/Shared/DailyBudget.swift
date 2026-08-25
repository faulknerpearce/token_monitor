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

    /// Days in the calendar month containing `date`.
    static func daysInCalendarMonth(for date: Date, calendar: Calendar = .current) -> Int {
        calendar.range(of: .day, in: .month, for: date)?.count ?? 30
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
    static func buildDays(
        periodStart: Date,
        periodEnd: Date,
        limitUSD: Double,
        spentByDay: [Date: Double],
        calendar: Calendar = .current
    ) -> [DailyBudgetDay] {
        let start = calendar.startOfDay(for: periodStart)
        let end = calendar.startOfDay(for: periodEnd)
        let totalDays = daysInBillingCycle(start: start, end: end, calendar: calendar)
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

    /// Calendar-month variant. `periodEnd` is exclusive (first day of next month).
    static func buildCalendarMonthDays(
        containing date: Date,
        limitUSD: Double,
        spentByDay: [Date: Double],
        calendar: Calendar = .current
    ) -> [DailyBudgetDay] {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return [] }
        let totalDays = daysInCalendarMonth(for: date, calendar: calendar)
        let perDay = budgetPerDay(limitUSD: limitUSD, daysInPeriod: totalDays)
        var days: [DailyBudgetDay] = []
        for offset in 0..<totalDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: interval.start) else { continue }
            let dayKey = calendar.startOfDay(for: day)
            let spent = spentByDay[dayKey] ?? 0
            days.append(DailyBudgetDay(date: dayKey, spentUSD: spent, budgetUSD: perDay))
        }
        return days
    }

    /// 7-bar window: rolling 7 days ending today (inclusive). Daily budget is still
    /// derived from the *monthly* allocation (`limit` / `daysInPeriod`), but only
    /// the last 7 days are returned for the chart.
    static func buildLast7Days(
        periodStart: Date,
        periodEnd: Date,
        limitUSD: Double,
        spentByDay: [Date: Double],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyBudgetDay] {
        let all = buildDays(periodStart: periodStart, periodEnd: periodEnd, limitUSD: limitUSD, spentByDay: spentByDay, calendar: calendar)
        return last7(from: all, now: now, calendar: calendar)
    }

    static func buildCalendarMonthLast7Days(
        containing date: Date,
        limitUSD: Double,
        spentByDay: [Date: Double],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyBudgetDay] {
        let all = buildCalendarMonthDays(containing: date, limitUSD: limitUSD, spentByDay: spentByDay, calendar: calendar)
        if all.count <= 7 { return all }
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

    /// Convenience: 7 rolling days ending today derived directly from spent map.
    static func buildRolling7Days(
        limitUSD: Double,
        daysInPeriod: Int,
        spentByDay: [Date: Double],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyBudgetDay] {
        let perDay = budgetPerDay(limitUSD: limitUSD, daysInPeriod: daysInPeriod)
        let today = calendar.startOfDay(for: now)
        var days: [DailyBudgetDay] = []
        for offset in (0..<7).reversed() {
            // 6 days ago … today
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let key = calendar.startOfDay(for: day)
            days.append(DailyBudgetDay(date: key, spentUSD: spentByDay[key] ?? 0, budgetUSD: perDay))
        }
        return days
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
}
