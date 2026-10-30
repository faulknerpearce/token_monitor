import Foundation

/// Pace against the pool: period start and headroom.
extension DailyBudget {
    /// Weekly providers (Claude / Grok): the painted window *is* the period, so
    /// the first bar is the start. `resetsAt` is ignored for start resolution.
    /// Preserved prior-window days lead the bars after an early reset but belong
    /// to the old pool, so the start is the first bar that is not one of them.
    static func weeklyPacePeriodStart(
        days: [DailyBudgetDay],
        calendar: Calendar = .current
    ) -> Date? {
        days.first { !$0.isPriorWindow }.map { calendar.startOfDay(for: $0.date) }
    }

    /// Monthly providers (Cursor / OpenCode): always a subscription/billing month.
    ///
    /// 1. `subscriptionMonth` (advances a stale cycle the same way bars do)
    /// 2. else `resetsAt − daysInPeriod` from the bar daily share
    /// 3. else nil
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
    /// count is capped at the period length implied by the daily share so
    /// `earned` stays at or below ~100% under clock skew. Pass `elapsedDaysInPeriod` to match
    /// a full-period window; otherwise the budgets of the visible bars through
    /// today are summed.
    ///
    /// On the **final day** of the window the day-based allowance has already
    /// credited the whole pool, but the period may run past the last bar to a
    /// reset instant (e.g. a Thursday-evening reset with a Wednesday last bar).
    /// There the unspent pool is compared against the even share of the time
    /// actually left until reset, so a pool that cannot cover it reads as over
    /// pace.
    static func paceHeadroom(
        days: [DailyBudgetDay],
        periodConsumed: Double,
        elapsedDaysInPeriod: Int? = nil,
        resetsAt: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PaceHeadroom? {
        let days = days.filter { !$0.isPriorWindow }
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
    /// the weekly/monthly bars so the wording and thresholds stay in sync.
    ///
    /// A plain surplus reads "X% usage left today"; when the surplus exceeds one
    /// day's share the caption notes the extra banked from unused prior days.
    /// An overrun reads "Usage X% over today's allowance", stating the overrun
    /// alone.
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
