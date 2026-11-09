@testable import TokenMon
import XCTest

/// Weekly bars around a provider reset instant that an early reset left in place.
final class DailyBudgetResetBoundaryTests: XCTestCase {
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

    /// Grokbot, Nov 2026: the provider began a new period on Sunday Nov 8 but kept
    /// the old reset instant (Wednesday Nov 11). The new window's bars stop before
    /// the reset day, so the chart is the original Wed–Tue week with the days
    /// before the early reset as prior-window history, not 11 bars running past
    /// the reset.
    func testEarlyResetWithUnchangedResetInstantStopsBarsAtReset() {
        let days = DailyBudget.buildWeeklyWindowDays(
            limitUSD: 100,
            daysInPeriod: 7,
            resetsAt: date(2026, 11, 11, hour: 12),
            spentByDay: [
                calendar.startOfDay(for: date(2026, 11, 4)): 8,
                calendar.startOfDay(for: date(2026, 11, 7)): 53,
                calendar.startOfDay(for: date(2026, 11, 9)): 37
            ],
            windowStart: date(2026, 11, 8, hour: 23),
            interruptedWindowStart: date(2026, 11, 4, hour: 12),
            now: date(2026, 11, 9, hour: 11),
            calendar: calendar
        )

        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first?.date, calendar.startOfDay(for: date(2026, 11, 4)))
        XCTAssertEqual(days.last?.date, calendar.startOfDay(for: date(2026, 11, 10)))
        XCTAssertEqual(days.map(\.isPriorWindow), [true, true, true, true, false, false, false])
        XCTAssertEqual(days.map(\.spentUSD), [8, 0, 0, 53, 0, 37, 0])
        XCTAssertEqual(
            DailyBudget.weeklyPacePeriodStart(days: days, calendar: calendar),
            calendar.startOfDay(for: date(2026, 11, 8))
        )
    }

    /// A window start on the reset day itself still gets one bar.
    func testWindowStartOnResetDayKeepsOneBar() {
        let days = DailyBudget.buildWeeklyWindowDays(
            limitUSD: 100,
            daysInPeriod: 7,
            resetsAt: date(2026, 11, 11, hour: 18),
            spentByDay: [:],
            windowStart: date(2026, 11, 11, hour: 6),
            now: date(2026, 11, 11, hour: 9),
            calendar: calendar
        )
        XCTAssertEqual(days.map(\.date), [calendar.startOfDay(for: date(2026, 11, 11))])
    }
}
