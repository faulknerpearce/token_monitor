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

    func testBuildCalendarMonthDaysMatchesMonthLength() {
        let days = DailyBudget.buildCalendarMonthDays(
            containing: date(2026, 2, 15),
            limitUSD: 280,
            spentByDay: [:],
            calendar: calendar
        )
        XCTAssertEqual(days.count, 28, "2026 is not a leap year")
    }

    func testBuildRolling7DaysEndsToday() {
        let now = date(2026, 8, 20)
        let days = DailyBudget.buildRolling7Days(
            limitUSD: 70,
            daysInPeriod: 30,
            spentByDay: [:],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(calendar.isDate(days.last?.date ?? Date(), inSameDayAs: now), true)
        XCTAssertEqual(calendar.isDate(days.first?.date ?? Date(), inSameDayAs: date(2026, 8, 14)), true)
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
}
