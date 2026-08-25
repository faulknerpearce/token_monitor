@testable import TokenMon
import XCTest

@MainActor
final class ClaudeUsagePollerTests: XCTestCase {
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

    /// August 2026: Aug 27 is a Thursday — the reset instant from the live
    /// payload shape, not a fixed Saturday.
    func testBuildDailyBudgetDaysAnchorsFirstBarToPeriodStart() {
        let days = ClaudeUsagePoller.buildDailyBudgetDays(
            spentByDay: [:],
            resetsAt: date(2026, 8, 27, hour: 11),
            now: date(2026, 8, 25, hour: 15),
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertTrue(calendar.isDate(days[0].date, inSameDayAs: date(2026, 8, 20)))
        XCTAssertTrue(calendar.isDate(days[6].date, inSameDayAs: date(2026, 8, 26)))
        // The weekly pool's budget is split evenly across its 7 days.
        XCTAssertEqual(days[0].budgetUSD, 100.0 / 7, accuracy: 1e-9)
    }

    func testBuildDailyBudgetDaysFallsBackToRollingWeekWithoutResetTime() {
        let now = date(2026, 8, 25)
        let days = ClaudeUsagePoller.buildDailyBudgetDays(
            spentByDay: [:],
            resetsAt: nil,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertTrue(calendar.isDate(days[0].date, inSameDayAs: date(2026, 8, 19)))
        XCTAssertTrue(calendar.isDate(days[6].date, inSameDayAs: now))
    }
}
