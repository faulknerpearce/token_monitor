@testable import TokenMon
import XCTest

/// DailyBudget math: per-day allowance, period windows, over-budget flags.
final class DailyBudgetTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar = gregorian
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testBudgetPerDayDividesEvenly() {
        XCTAssertEqual(DailyBudget.budgetPerDay(limitUSD: 100, daysInPeriod: 7), 100.0 / 7, accuracy: 1e-9)
    }

    func testBudgetPerDayZeroGuards() {
        XCTAssertEqual(DailyBudget.budgetPerDay(limitUSD: 0, daysInPeriod: 7), 0)
        XCTAssertEqual(DailyBudget.budgetPerDay(limitUSD: 100, daysInPeriod: 0), 0)
    }

    func testDaysInBillingCycleCountsInclusiveStartExclusiveEnd() {
        let start = date(2026, 8, 1)
        let end = date(2026, 8, 8)
        XCTAssertEqual(DailyBudget.daysInBillingCycle(start: start, end: end, calendar: calendar), 7)
    }

    func testDaysInBillingCycleMinimumOne() {
        let same = date(2026, 8, 1)
        XCTAssertEqual(DailyBudget.daysInBillingCycle(start: same, end: same, calendar: calendar), 1)
    }

    func testBuildDaysCoversWholePeriodWithPerDayBudget() {
        // Contract: spentByDay is keyed by calendar.startOfDay.
        let spent: [Date: Double] = [calendar.startOfDay(for: date(2026, 8, 1)): 10]
        let days = DailyBudget.buildDays(
            periodStart: date(2026, 8, 1),
            periodEnd: date(2026, 8, 8),
            limitUSD: 70,
            spentByDay: spent,
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days[0].spentUSD, 10)
        XCTAssertEqual(days[1].spentUSD, 0)
        for day in days {
            XCTAssertEqual(day.budgetUSD, 10, accuracy: 1e-9)
        }
    }

    func testOverBudgetFlag() {
        let over = DailyBudgetDay(date: date(2026, 8, 1), spentUSD: 15, budgetUSD: 10)
        let under = DailyBudgetDay(date: date(2026, 8, 2), spentUSD: 5, budgetUSD: 10)
        XCTAssertTrue(over.isOverBudget)
        XCTAssertFalse(under.isOverBudget)
        // percentOfBudget clamps at 100 even when over budget.
        XCTAssertEqual(over.percentOfBudget, 100)
    }

    func testPercentOfBudgetZeroBudgetIsZero() {
        let day = DailyBudgetDay(date: date(2026, 8, 1), spentUSD: 15, budgetUSD: 0)
        XCTAssertEqual(day.percentOfBudget, 0)
        XCTAssertFalse(day.isOverBudget)
    }

    func testLast7AtPeriodStartPadsForward() {
        // Period starts today: only one real day exists; window must still be 7 bars.
        let today = date(2026, 8, 1)
        let days = DailyBudget.buildLast7Days(
            periodStart: today,
            periodEnd: date(2026, 9, 1),
            limitUSD: 310,
            spentByDay: [:],
            now: today,
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
    }

    // MARK: buildWeeklyWindowDays

    /// August 2026: Aug 27 is a Thursday. The window anchors to the reset
    /// instant itself — not a hardcoded weekday.
    func testWeeklyWindowAnchorsToResetMidPeriod() {
        // Running period that resets Thu Aug 27 11:00 → bars run Thu Aug 20…Wed Aug 26.
        let tuesday = date(2026, 8, 25, hour: 15)
        let reset = date(2026, 8, 27, hour: 11)
        let spent: [Date: Double] = [calendar.startOfDay(for: date(2026, 8, 22)): 3]
        let days = DailyBudget.buildWeeklyWindowDays(
            limitUSD: 70,
            daysInPeriod: 7,
            resetsAt: reset,
            spentByDay: spent,
            now: tuesday,
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertTrue(calendar.isDate(days[0].date, inSameDayAs: date(2026, 8, 20)))
        XCTAssertTrue(calendar.isDate(days[3].date, inSameDayAs: date(2026, 8, 23)))
        XCTAssertTrue(calendar.isDate(days[6].date, inSameDayAs: date(2026, 8, 26)))
        XCTAssertEqual(days[2].spentUSD, 3)
        XCTAssertEqual(days[3].spentUSD, 0)
        // Days after today are present but empty (chart dims them as future).
        XCTAssertEqual(days[5].spentUSD, 0)
        XCTAssertEqual(days[0].budgetUSD, 10, accuracy: 1e-9)
    }

    func testWeeklyWindowBeforeResetInstantKeepsRunningPeriod() {
        // Reset lands at 11:00 on Aug 27; at 09:00 the old period is still
        // running, so the window must not roll yet — but it must include today
        // so calendar-keyed same-day usage is not hidden until the instant.
        let beforeReset = date(2026, 8, 27, hour: 9)
        let reset = date(2026, 8, 27, hour: 11)
        let todayKey = calendar.startOfDay(for: beforeReset)
        let spent: [Date: Double] = [todayKey: 12]
        let days = DailyBudget.buildWeeklyWindowDays(
            limitUSD: 70,
            daysInPeriod: 7,
            resetsAt: reset,
            spentByDay: spent,
            now: beforeReset,
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertTrue(calendar.isDate(days[0].date, inSameDayAs: date(2026, 8, 21)))
        XCTAssertTrue(calendar.isDate(days[6].date, inSameDayAs: date(2026, 8, 27)))
        XCTAssertEqual(days[6].spentUSD, 12)
    }

    func testWeeklyWindowRollsForwardAtResetInstant() {
        // At/after the reset instant the whole window rolls to the new period
        // starting today — never two partial periods in one chart.
        let atReset = date(2026, 8, 27, hour: 11)
        let staleSpent: [Date: Double] = [calendar.startOfDay(for: date(2026, 8, 21)): 40]
        let days = DailyBudget.buildWeeklyWindowDays(
            limitUSD: 70,
            daysInPeriod: 7,
            resetsAt: atReset,
            spentByDay: staleSpent,
            now: atReset,
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertTrue(calendar.isDate(days[0].date, inSameDayAs: date(2026, 8, 27)))
        XCTAssertTrue(calendar.isDate(days[6].date, inSameDayAs: date(2026, 9, 2)))
        // The finished period's day totals no longer appear.
        for day in days where !calendar.isDate(day.date, inSameDayAs: date(2026, 8, 27)) {
            XCTAssertEqual(day.spentUSD, 0)
        }
    }

    /// A payload lagging several periods must still produce a window that
    /// contains today — the advance loop rolls whole weeks.
    func testWeeklyWindowAdvancesWeeksStaleReset() {
        let now = date(2026, 8, 25, hour: 15)
        // Three weeks before the next would-be reset.
        let staleReset = date(2026, 8, 4, hour: 11)
        let days = DailyBudget.buildWeeklyWindowDays(
            limitUSD: 70,
            daysInPeriod: 7,
            resetsAt: staleReset,
            spentByDay: [:],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        // Rolls 8/4 → 8/11 → 8/18 → 8/25 → 9/1 (> now); running week starts today.
        XCTAssertTrue(calendar.isDate(days[0].date, inSameDayAs: now))
        XCTAssertTrue(calendar.isDate(days[6].date, inSameDayAs: date(2026, 8, 31)))
    }

    // MARK: paceHeadroom

    /// Three elapsed days at 3%/day, zero API consumed → 9% headroom (banked prior).
    func testPaceHeadroomZeroConsumedBanksPriorDays() throws {
        let today = date(2026, 8, 25)
        let days = (0..<7).map { offset -> DailyBudgetDay in
            let day = calendar.date(byAdding: .day, value: offset - 2, to: today)!
            return DailyBudgetDay(
                date: calendar.startOfDay(for: day),
                spentUSD: 99, // bar spends must be ignored
                budgetUSD: 3
            )
        }
        let pace = DailyBudget.paceHeadroom(
            days: days,
            periodConsumed: 0,
            now: today,
            calendar: calendar
        )
        let unwrapped = try XCTUnwrap(pace)
        XCTAssertEqual(unwrapped.dailyBudget, 3, accuracy: 1e-9)
        XCTAssertEqual(unwrapped.earnedThroughToday, 9, accuracy: 1e-9)
        XCTAssertEqual(unwrapped.periodConsumed, 0, accuracy: 1e-9)
        XCTAssertEqual(unwrapped.headroomToday, 9, accuracy: 1e-9)
    }

    func testPaceHeadroomPartialConsumedReducesHeadroom() throws {
        let today = date(2026, 8, 25)
        let days = (0..<7).map { offset -> DailyBudgetDay in
            let day = calendar.date(byAdding: .day, value: offset - 2, to: today)!
            return DailyBudgetDay(
                date: calendar.startOfDay(for: day),
                spentUSD: 0,
                budgetUSD: 3
            )
        }
        let pace = try XCTUnwrap(DailyBudget.paceHeadroom(
            days: days,
            periodConsumed: 5,
            now: today,
            calendar: calendar
        ))
        XCTAssertEqual(pace.earnedThroughToday, 9, accuracy: 1e-9)
        XCTAssertEqual(pace.headroomToday, 4, accuracy: 1e-9)
    }

    func testPaceHeadroomOverPaceWhenConsumedExceedsEarned() throws {
        let today = date(2026, 8, 25)
        let days = (0..<7).map { offset -> DailyBudgetDay in
            let day = calendar.date(byAdding: .day, value: offset - 2, to: today)!
            return DailyBudgetDay(
                date: calendar.startOfDay(for: day),
                spentUSD: 0,
                budgetUSD: 3
            )
        }
        let pace = try XCTUnwrap(DailyBudget.paceHeadroom(
            days: days,
            periodConsumed: 12,
            now: today,
            calendar: calendar
        ))
        XCTAssertEqual(pace.earnedThroughToday, 9, accuracy: 1e-9)
        XCTAssertEqual(pace.headroomToday, -3, accuracy: 1e-9)
    }

    func testPaceHeadroomExcludesFutureDaysFromEarned() throws {
        // Window: Aug 20…26; "today" is Aug 22 → only 3 days earn.
        let today = date(2026, 8, 22)
        let days = (0..<7).map { offset -> DailyBudgetDay in
            let day = date(2026, 8, 20 + offset)
            return DailyBudgetDay(
                date: calendar.startOfDay(for: day),
                spentUSD: 0,
                budgetUSD: 10
            )
        }
        let pace = try XCTUnwrap(DailyBudget.paceHeadroom(
            days: days,
            periodConsumed: 0,
            now: today,
            calendar: calendar
        ))
        XCTAssertEqual(pace.earnedThroughToday, 30, accuracy: 1e-9)
        XCTAssertEqual(pace.headroomToday, 30, accuracy: 1e-9)
    }

    func testPaceHeadroomNilWhenBudgetZero() {
        let days = [
            DailyBudgetDay(date: calendar.startOfDay(for: date(2026, 8, 25)), spentUSD: 0, budgetUSD: 0)
        ]
        XCTAssertNil(DailyBudget.paceHeadroom(days: days, periodConsumed: 10, now: date(2026, 8, 25), calendar: calendar))
        XCTAssertNil(DailyBudget.paceHeadroom(days: [], periodConsumed: 10, now: date(2026, 8, 25), calendar: calendar))
    }

    /// Monthly 7-bar slice: elapsed days must come from the full period, not the window.
    func testPaceHeadroomUsesElapsedDaysForFullPeriod() throws {
        let today = date(2026, 8, 25)
        // Visible bars are only the last 7 days, each ~3.226% of a 31-day month.
        let daily = 100.0 / 31.0
        let days = (0..<7).map { offset -> DailyBudgetDay in
            let day = calendar.date(byAdding: .day, value: offset - 6, to: today)!
            return DailyBudgetDay(
                date: calendar.startOfDay(for: day),
                spentUSD: 0,
                budgetUSD: daily
            )
        }
        let pace = try XCTUnwrap(DailyBudget.paceHeadroom(
            days: days,
            periodConsumed: 20,
            elapsedDaysInPeriod: 25, // Aug 1…25
            now: today,
            calendar: calendar
        ))
        XCTAssertEqual(pace.earnedThroughToday, daily * 25, accuracy: 1e-9)
        XCTAssertEqual(pace.headroomToday, daily * 25 - 20, accuracy: 1e-9)
        // Without elapsedDays, earned would wrongly cap at 7 shares.
        let short = try XCTUnwrap(DailyBudget.paceHeadroom(
            days: days,
            periodConsumed: 20,
            now: today,
            calendar: calendar
        ))
        XCTAssertEqual(short.earnedThroughToday, daily * 7, accuracy: 1e-9)
    }

    func testElapsedDaysThroughTodayIsInclusive() {
        XCTAssertEqual(
            DailyBudget.elapsedDaysThroughToday(
                from: date(2026, 8, 1),
                now: date(2026, 8, 25),
                calendar: calendar
            ),
            25
        )
        XCTAssertEqual(
            DailyBudget.elapsedDaysThroughToday(
                from: date(2026, 8, 25),
                now: date(2026, 8, 25),
                calendar: calendar
            ),
            1
        )
    }

    func testPacePeriodStartPrefersKnownStart() {
        let days = [
            DailyBudgetDay(date: calendar.startOfDay(for: date(2026, 8, 20)), spentUSD: 0, budgetUSD: 100.0 / 31)
        ]
        let start = DailyBudget.monthlyPacePeriodStart(
            days: days,
            knownStart: date(2026, 8, 5),
            resetsAt: date(2026, 9, 5),
            calendar: calendar
        )
        XCTAssertTrue(calendar.isDate(start!, inSameDayAs: date(2026, 8, 5)))
    }

    /// Rolling 7-bar monthly slice: derive start from resetsAt − daysInPeriod.
    func testMonthlyPacePeriodStartDerivesFromResetsAtWhenSliceIsShorterThanPeriod() {
        let daily = 100.0 / 31.0
        let today = date(2026, 8, 25)
        let days = (0..<7).map { offset -> DailyBudgetDay in
            let day = calendar.date(byAdding: .day, value: offset - 6, to: today)!
            return DailyBudgetDay(date: calendar.startOfDay(for: day), spentUSD: 0, budgetUSD: daily)
        }
        let start = DailyBudget.monthlyPacePeriodStart(
            days: days,
            resetsAt: date(2026, 9, 16),
            calendar: calendar
        )
        XCTAssertTrue(calendar.isDate(start!, inSameDayAs: date(2026, 8, 16)))
    }

    /// Weekly 7/7 window: first bar is the period start.
    func testWeeklyPacePeriodStartUsesFirstBar() {
        let days = (0..<7).map { offset -> DailyBudgetDay in
            DailyBudgetDay(
                date: calendar.startOfDay(for: date(2026, 8, 20 + offset)),
                spentUSD: 0,
                budgetUSD: 100.0 / 7
            )
        }
        let start = DailyBudget.weeklyPacePeriodStart(days: days, calendar: calendar)
        XCTAssertTrue(calendar.isDate(start!, inSameDayAs: date(2026, 8, 20)))
    }

    /// Stale billing-cycle dates must pace against the running month, not the closed one.
    func testMonthlyPacePeriodStartAdvancesStaleCycle() throws {
        let today = date(2026, 8, 25)
        let daily = 100.0 / 31.0
        let days = (0..<7).map { offset -> DailyBudgetDay in
            let day = calendar.date(byAdding: .day, value: offset - 6, to: today)!
            return DailyBudgetDay(date: calendar.startOfDay(for: day), spentUSD: 0, budgetUSD: daily)
        }
        let start = try XCTUnwrap(
            DailyBudget.monthlyPacePeriodStart(
                days: days,
                knownStart: date(2026, 6, 16),
                resetsAt: date(2026, 7, 16),
                now: today,
                calendar: calendar
            )
        )
        XCTAssertTrue(calendar.isDate(start, inSameDayAs: date(2026, 8, 16)))
    }

    /// Monthly pace never invents a calendar month of `now`.
    func testMonthlyPacePeriodStartNilWithoutSubscriptionSignals() {
        let daily = 100.0 / 31.0
        let today = date(2026, 8, 25)
        let days = (0..<7).map { offset -> DailyBudgetDay in
            let day = calendar.date(byAdding: .day, value: offset - 6, to: today)!
            return DailyBudgetDay(date: calendar.startOfDay(for: day), spentUSD: 0, budgetUSD: daily)
        }
        XCTAssertNil(DailyBudget.monthlyPacePeriodStart(days: days, calendar: calendar))
    }

    func testSubscriptionMonthFromResetsAtAlone() throws {
        let bounds = DailyBudget.subscriptionMonth(
            resetsAt: date(2026, 9, 16),
            calendar: calendar
        )
        let unwrapped = try XCTUnwrap(bounds)
        XCTAssertTrue(calendar.isDate(unwrapped.start, inSameDayAs: date(2026, 8, 16)))
        XCTAssertTrue(calendar.isDate(unwrapped.end, inSameDayAs: date(2026, 9, 16)))
    }

    func testSubscriptionMonthNilWithoutSignals() {
        XCTAssertNil(DailyBudget.subscriptionMonth(calendar: calendar))
    }

    func testBuildSubscriptionMonthLast7DaysRequiresCycle() throws {
        XCTAssertNil(
            DailyBudget.buildSubscriptionMonthLast7Days(
                limitUSD: 100,
                spentByDay: [:],
                now: date(2026, 8, 25),
                calendar: calendar
            )
        )
        let built = try XCTUnwrap(
            DailyBudget.buildSubscriptionMonthLast7Days(
                limitUSD: 100,
                spentByDay: [:],
                knownStart: date(2026, 8, 16),
                resetsAt: date(2026, 9, 16),
                now: date(2026, 8, 25),
                calendar: calendar
            )
        )
        XCTAssertEqual(built.days.count, 7)
        XCTAssertTrue(calendar.isDate(built.periodStart, inSameDayAs: date(2026, 8, 16)))
        XCTAssertEqual(built.days.first?.budgetUSD ?? 0, 100.0 / 31.0, accuracy: 1e-9)
    }

    /// On the reset calendar day *before* the instant the running period still
    /// owns today — the monthly grid must include it (same rule as weekly).
    func testMonthlyLast7IncludesTodayOnResetMorning() throws {
        let morning = date(2026, 8, 16, hour: 9)
        let built = try XCTUnwrap(
            DailyBudget.buildSubscriptionMonthLast7Days(
                limitUSD: 100,
                spentByDay: [calendar.startOfDay(for: morning): 12],
                knownStart: date(2026, 7, 17),
                resetsAt: date(2026, 8, 16, hour: 12),
                now: morning,
                calendar: calendar
            )
        )
        let last = try XCTUnwrap(built.days.last)
        XCTAssertTrue(calendar.isDate(last.date, inSameDayAs: morning))
        XCTAssertEqual(last.spentUSD, 12)
    }

    /// A stale (already-ended) monthly cycle advances to the running anniversary
    /// month instead of painting the closed month's suffix.
    func testSubscriptionMonthAdvancesStaleCycle() throws {
        let bounds = try XCTUnwrap(
            DailyBudget.subscriptionMonth(
                knownStart: date(2026, 6, 16),
                resetsAt: date(2026, 7, 16),
                now: date(2026, 8, 25),
                calendar: calendar
            )
        )
        XCTAssertTrue(calendar.isDate(bounds.start, inSameDayAs: date(2026, 8, 16)))
        XCTAssertTrue(calendar.isDate(bounds.end, inSameDayAs: date(2026, 9, 16)))
    }

    func testStaleMonthlyEndDoesNotPaintClosedSuffix() throws {
        let built = try XCTUnwrap(
            DailyBudget.buildSubscriptionMonthLast7Days(
                limitUSD: 100,
                spentByDay: [calendar.startOfDay(for: date(2026, 7, 10)): 50],
                knownStart: date(2026, 6, 16),
                resetsAt: date(2026, 7, 16),
                now: date(2026, 8, 25),
                calendar: calendar
            )
        )
        // Window belongs to the running Aug 16 – Sep 16 cycle.
        XCTAssertTrue(built.days.contains { calendar.isDate($0.date, inSameDayAs: date(2026, 8, 25)) })
        XCTAssertFalse(built.days.contains { $0.date < calendar.startOfDay(for: date(2026, 8, 16)) })
        XCTAssertEqual(built.periodStart, calendar.startOfDay(for: date(2026, 8, 16)))
    }

    func testPaceHeadroomZeroElapsedEarnsNothing() throws {
        let today = date(2026, 8, 25)
        let days = [
            DailyBudgetDay(date: calendar.startOfDay(for: today), spentUSD: 0, budgetUSD: 10)
        ]
        let pace = try XCTUnwrap(DailyBudget.paceHeadroom(
            days: days,
            periodConsumed: 5,
            elapsedDaysInPeriod: 0,
            now: today,
            calendar: calendar
        ))
        XCTAssertEqual(pace.earnedThroughToday, 0, accuracy: 1e-9)
        XCTAssertEqual(pace.headroomToday, -5, accuracy: 1e-9)
    }

    func testPaceHeadroomCapsElapsedAtPeriodLength() throws {
        let today = date(2026, 8, 25)
        let daily = 100.0 / 31.0
        let days = [
            DailyBudgetDay(date: calendar.startOfDay(for: today), spentUSD: 0, budgetUSD: daily)
        ]
        let pace = try XCTUnwrap(DailyBudget.paceHeadroom(
            days: days,
            periodConsumed: 50,
            elapsedDaysInPeriod: 40, // beyond 31-day month
            now: today,
            calendar: calendar
        ))
        XCTAssertEqual(pace.earnedThroughToday, daily * 31, accuracy: 1e-9)
        XCTAssertEqual(pace.headroomToday, daily * 31 - 50, accuracy: 1e-9)
    }
}
