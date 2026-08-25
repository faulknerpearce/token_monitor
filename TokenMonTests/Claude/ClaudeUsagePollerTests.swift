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

    /// No provider reset observed → no bars at all. A rolling 7-day window is
    /// never substituted for the real weekly period.
    func testBuildDailyBudgetDaysEmptyWithoutResetTime() {
        let days = ClaudeUsagePoller.buildDailyBudgetDays(
            spentByDay: [:],
            resetsAt: nil,
            now: date(2026, 8, 25),
            calendar: calendar
        )
        XCTAssertTrue(days.isEmpty)
    }
}
