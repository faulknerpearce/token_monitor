@testable import TokenMon
import XCTest

/// Week-arrow offsets for daily budget charts. Split from DailyBudgetTests so the
/// length gates stay at the current maxima.
final class DailyBudgetWeekOffsetTests: XCTestCase {
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

    func testWeekOffsetNeverMovesPastTheCurrentWeek() {
        XCTAssertEqual(WeekOffset.previous(0), -1)
        XCTAssertEqual(WeekOffset.previous(-2), -3)
        XCTAssertEqual(WeekOffset.next(0), 0)
        XCTAssertEqual(WeekOffset.next(-1), 0)
        XCTAssertEqual(WeekOffset.next(-4), -3)
        XCTAssertFalse(WeekOffset.canGoNext(0))
        XCTAssertTrue(WeekOffset.canGoNext(-1))
    }

    /// Chevron-left on a weekly pool shows the previous period's bars, including
    /// spend recorded before the current window.
    func testWeeklyWindowOffsetShowsPreviousPeriod() {
        let spent = [calendar.startOfDay(for: date(2026, 8, 14)): 6.0]
        let days = DailyBudget.buildWeeklyWindowDays(
            limitUSD: 70,
            daysInPeriod: 7,
            resetsAt: date(2026, 8, 27, hour: 11),
            spentByDay: spent,
            weekOffset: -1,
            now: date(2026, 8, 25, hour: 15),
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertTrue(calendar.isDate(days[0].date, inSameDayAs: date(2026, 8, 13)))
        XCTAssertTrue(calendar.isDate(days[6].date, inSameDayAs: date(2026, 8, 19)))
        XCTAssertEqual(days[1].spentUSD, 6)
        XCTAssertFalse(days.contains(where: \.isPriorWindow))
    }

    /// The current week still leads with an early-reset's preserved days. The
    /// previous week is that prior period itself, not another lead-in.
    func testWeeklyWindowOffsetSkipsEarlyResetLeadIn() {
        let spent = [
            calendar.startOfDay(for: date(2026, 9, 30)): 12.0,
            calendar.startOfDay(for: date(2026, 10, 1)): 18.0,
            calendar.startOfDay(for: date(2026, 10, 2)): 3.0
        ]
        let days = DailyBudget.buildWeeklyWindowDays(
            limitUSD: 100,
            daysInPeriod: 7,
            resetsAt: date(2026, 10, 9, hour: 18),
            spentByDay: spent,
            windowStart: date(2026, 10, 2, hour: 18),
            interruptedWindowStart: date(2026, 9, 30, hour: 11),
            weekOffset: -1,
            now: date(2026, 10, 3, hour: 9),
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertFalse(days.contains(where: \.isPriorWindow))
        XCTAssertEqual(days.first?.date, calendar.startOfDay(for: date(2026, 9, 25)))
        XCTAssertEqual(days.last?.date, calendar.startOfDay(for: date(2026, 10, 1)))
        XCTAssertEqual(days[5].spentUSD, 12)
        XCTAssertEqual(days[6].spentUSD, 18)
    }

    /// Chevron-left on a monthly chart is the previous Monday–Sunday week.
    /// Days still inside the billing period keep their recorded spend.
    func testMondayWeekOffsetShowsPreviousWeekInsidePeriod() {
        let days = DailyBudget.buildMondayWeekDays(
            periodStart: date(2026, 8, 1),
            periodEnd: date(2026, 9, 1),
            limitUSD: 100,
            spentByDay: [calendar.startOfDay(for: date(2026, 8, 11)): 4],
            weekOffset: -1,
            now: date(2026, 8, 20, hour: 12),
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days[0].date, calendar.startOfDay(for: date(2026, 8, 10)))
        XCTAssertEqual(days[1].spentUSD, 4)
        XCTAssertFalse(days[1].isPriorWindow)
    }

    /// The current Monday week does not pick up pre-period history. That map is
    /// only for weeks the arrows have moved off of today.
    func testMondayWeekOffsetZeroIgnoresHistoryBeforePeriod() {
        let days = DailyBudget.buildMondayWeekDays(
            periodStart: date(2026, 10, 2, hour: 18),
            periodEnd: date(2026, 11, 2, hour: 18),
            limitUSD: 100,
            spentByDay: [:],
            historyByDay: [calendar.startOfDay(for: date(2026, 9, 30)): 9],
            now: date(2026, 10, 3, hour: 9),
            calendar: calendar
        )
        let sep30 = days.first { calendar.isDate($0.date, inSameDayAs: date(2026, 9, 30)) }
        XCTAssertEqual(sep30?.spentUSD ?? -1, 0)
        XCTAssertEqual(sep30?.isPriorWindow, false)
    }

    func testMondayWeekOffsetUsesHistoryBeforePeriod() {
        let days = DailyBudget.buildMondayWeekDays(
            periodStart: date(2026, 10, 2, hour: 18),
            periodEnd: date(2026, 11, 2, hour: 18),
            limitUSD: 100,
            spentByDay: [:],
            historyByDay: [calendar.startOfDay(for: date(2026, 9, 22)): 8],
            weekOffset: -1,
            now: date(2026, 10, 3, hour: 9),
            calendar: calendar
        )
        XCTAssertEqual(days[0].date, calendar.startOfDay(for: date(2026, 9, 21)))
        XCTAssertEqual(days[1].spentUSD, 8)
        XCTAssertFalse(days[1].isPriorWindow)
    }
}
