import Foundation

/// Daily Budget bars for OpenCode Go from local spend.
extension OpenCodeLocalStats {
    /// Daily USD spend per calendar day for the current monthly period, counting
    /// only Go-plan usage (Zen is free and tracked separately in the models and
    /// overview sections).
    static func fetchMonthDailySpends(now: Date = Date()) throws -> [Date: Double] {
        try fetchMonthDailySpends(dbURL: databaseURL, now: now)
    }

    /// Daily Go spend for the subscription-anchored month from `opencode.db`.
    static func fetchMonthDailySpends(dbURL: URL, now: Date) throws -> [Date: Double] {
        let scan = try loadScan(dbURL: dbURL, since: scanStart(now: now))
        let month = monthlyBounds(now: now, subscribedAt: scan.subscribedAt ?? now)
        return dailySpendsByDay(rows: scan.rows.filter {
            goEligibleProvider($0.providerID) && inWindow($0, start: month.start, end: month.end)
        })
    }

    /// Go-plan USD spend per calendar day within an explicit window, so the
    /// per-day shape matches the console billing window.
    static func fetchDailySpends(
        from start: Date,
        to end: Date,
        dbURL: URL = databaseURL,
        calendar: Calendar = .current
    ) -> [Date: Double] {
        guard let scan = try? loadScan(dbURL: dbURL, since: start) else { return [:] }
        return dailySpendsByDay(
            rows: scan.rows.filter { goEligibleProvider($0.providerID) && inWindow($0, start: start, end: end) },
            calendar: calendar
        )
    }

    /// Sums billable Go spend per calendar day, skipping `$0` rows.
    static func dailySpendsByDay(rows: [SessionRow], calendar: Calendar = .current) -> [Date: Double] {
        var byDay: [Date: Double] = [:]
        for row in rows {
            let billable = row.billable.cost
            guard billable > 0 else { continue }
            let dayKey = calendar.startOfDay(for: row.date)
            byDay[dayKey, default: 0] += billable
        }
        return byDay
    }

    /// Scaled in-period spends plus unscaled history so the panel can re-slice
    /// an earlier Monday week without reading SQLite again.
    struct OpenCodeMonthBudget: Sendable {
        var days: [DailyBudgetDay]
        var periodStart: Date
        /// Percent of the monthly pool, scaled so in-period days sum to the headline used %.
        var spentPercentByDay: [Date: Double]
        /// Percent of the monthly limit for days before the period, unscaled.
        var historyPercentByDay: [Date: Double]
        var knownStart: Date?
        var resetsAt: Date?
        var referenceNow: Date
    }

    /// Builds the last-7 daily-budget bars for the Go **subscription** month,
    /// plus that period's start for pace captions.
    ///
    /// Console `periodResetsAt` is authoritative when present; the local
    /// first-Go-session anniversary is the fallback. Returns nil when neither
    /// signal exists.
    ///
    /// `weekOffset` selects an earlier Monday week. Days before the billing
    /// period come from local history and stay outside the headline scale.
    static func monthDailyBudgetDays(
        limitUSD: Double,
        usedPercent: Double = 0,
        periodResetsAt: Date? = nil,
        weekOffset: Int = 0,
        now: Date = Date(),
        spentByDay: [Date: Double]? = nil,
        dbURL: URL = databaseURL,
        calendar: Calendar = .current
    ) -> OpenCodeMonthBudget? {
        // Prefer the console billing window when present. The per-day shares
        // cover exactly the days the monthly percent was measured over, so the
        // rescale below spreads the console total only across days in the window.
        let consoleBounds = DailyBudget.subscriptionMonth(
            knownStart: nil,
            resetsAt: periodResetsAt,
            now: now,
            calendar: calendar
        )

        let usdSpends: [Date: Double]
        var historyUSD: [Date: Double] = [:]
        if let spentByDay {
            usdSpends = spentByDay
        } else if let consoleBounds {
            let split = spendHistory(
                periodStart: consoleBounds.start,
                periodEnd: consoleBounds.end,
                dbURL: dbURL,
                calendar: calendar
            )
            usdSpends = split.period
            historyUSD = split.history
        } else {
            usdSpends = (try? fetchMonthDailySpends(dbURL: dbURL, now: now)) ?? [:]
        }
        // Convert USD spends → percent of monthly allocation for the usage chart
        let spendsPercent: [Date: Double] = limitUSD > 0
            ? usdSpends.mapValues { $0 / limitUSD * 100 }
            : [:]
        // Anchor the bars to the consumed monthly usage: local events shape how
        // the budget spread across days, while the monthly total sets the scale.
        var anchoredPercent = scaledSpendsPercent(spendsPercent, to: usedPercent)
        // No local rows for the console window (OpenCode not installed here, DB
        // path changed, or usage not flushed yet): spread the console total over
        // the elapsed days so the bars match the headline caption.
        if anchoredPercent.isEmpty, usedPercent > 0, let consoleBounds {
            let elapsed = max(1, (calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: consoleBounds.start),
                to: calendar.startOfDay(for: now)
            ).day ?? 0) + 1)
            let perDay = usedPercent / Double(elapsed)
            for offset in 0..<elapsed {
                guard let day = calendar.date(byAdding: .day, value: offset, to: consoleBounds.start) else {
                    continue
                }
                anchoredPercent[calendar.startOfDay(for: day)] = perDay
            }
        }
        let percentLimit: Double = 100 // monthly allocation = 100%

        func packaged(knownStart: Date?, resetsAt: Date?, historyUSD: [Date: Double]) -> OpenCodeMonthBudget? {
            let historyPercent: [Date: Double] = limitUSD > 0
                ? historyUSD.mapValues { $0 / limitUSD * 100 }
                : [:]
            guard let built = DailyBudget.buildSubscriptionMonthLast7Days(
                limitUSD: percentLimit,
                spentByDay: anchoredPercent,
                knownStart: knownStart,
                resetsAt: resetsAt,
                historyByDay: historyPercent,
                weekOffset: weekOffset,
                now: now,
                calendar: calendar
            ) else { return nil }
            return OpenCodeMonthBudget(
                days: built.days,
                periodStart: built.periodStart,
                spentPercentByDay: anchoredPercent,
                historyPercentByDay: historyPercent,
                knownStart: knownStart,
                resetsAt: resetsAt,
                referenceNow: now
            )
        }

        // Console monthly reset wins: signed-in bars must agree with the Monthly bar.
        if let periodResetsAt {
            return packaged(knownStart: nil, resetsAt: periodResetsAt, historyUSD: historyUSD)
        }

        guard let subscribedAt = (try? loadScan(dbURL: dbURL, since: scanStart(now: now)))?.subscribedAt else {
            return nil
        }
        let month = monthlyBounds(now: now, subscribedAt: subscribedAt)
        if spentByDay == nil, historyUSD.isEmpty {
            historyUSD = spendHistory(
                periodStart: month.start,
                periodEnd: month.end,
                dbURL: dbURL,
                calendar: calendar
            ).history
        }
        return packaged(knownStart: month.start, resetsAt: month.end, historyUSD: historyUSD)
    }

    /// Days of local Go spend kept so the daily-budget arrows can show weeks
    /// before the current billing period. Matches the quota store's ~30-day
    /// horizon closely enough for four earlier weeks.
    private static let priorWeekHistoryDays = 28

    /// Period spends stay inside the billing window so the headline percent
    /// covers only that window. Earlier days are returned separately for week browsing.
    private static func spendHistory(
        periodStart: Date,
        periodEnd: Date,
        dbURL: URL,
        calendar: Calendar
    ) -> (period: [Date: Double], history: [Date: Double]) {
        let startDay = calendar.startOfDay(for: periodStart)
        let lookback = calendar.date(byAdding: .day, value: -priorWeekHistoryDays, to: startDay) ?? startDay
        let all = fetchDailySpends(from: lookback, to: periodEnd, dbURL: dbURL, calendar: calendar)
        let period = all.filter { $0.key >= startDay && $0.key < periodEnd }
        let history = all.filter { $0.key < startDay }
        return (period, history)
    }

    /// Scales per-day percentage-point spends so their sum equals the consumed
    /// monthly usage (`usedPercent`). Returns the spends unchanged when there is
    /// nothing to anchor to.
    static func scaledSpendsPercent(
        _ spendsPercent: [Date: Double],
        to usedPercent: Double
    ) -> [Date: Double] {
        let total = spendsPercent.values.reduce(0, +)
        guard total > 0, usedPercent > 0 else { return spendsPercent }
        let scale = usedPercent / total
        return spendsPercent.mapValues { $0 * scale }
    }
}
