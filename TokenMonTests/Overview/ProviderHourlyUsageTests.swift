@testable import TokenMon
import XCTest

/// `ProviderDayHourlyUsage.build` must degrade gracefully on short/long input
/// arrays rather than trapping on a precondition.
final class ProviderHourlyUsageTests: XCTestCase {
    func testShortArraysArePaddedToTwentyFourHours() {
        let usage = ProviderDayHourlyUsage.build(
            dayStart: Date(),
            grokHourWeights: [5.0],
            openCodeGoHourWeights: [],
            openCodeZenHourWeights: [1.0, 2.0]
        )
        XCTAssertEqual(usage.hours.count, 24)
        XCTAssertEqual(usage.hours[0].grokSharePercent, 5.0 / 6.0 * 100, accuracy: 0.001)
        XCTAssertEqual(usage.hours[0].activity, 6, accuracy: 0.001)
        XCTAssertEqual(usage.hours[1].activity, 2, accuracy: 0.001)
        XCTAssertEqual(usage.hours[23].activity, 0, accuracy: 0.001)
    }

    func testLongArraysAreTruncatedToTwentyFourHours() {
        let usage = ProviderDayHourlyUsage.build(
            dayStart: Date(),
            grokHourWeights: Array(repeating: 1.0, count: 30),
            openCodeGoHourWeights: [],
            openCodeZenHourWeights: []
        )
        XCTAssertEqual(usage.hours.count, 24)
        XCTAssertEqual(usage.hours[23].activity, 1, accuracy: 0.001)
    }

    /// The Overview chart's schedule starts at today's midnight, so the first
    /// render shows today, then has one entry per following local midnight.
    func testMidnightScheduleStartsAtTodayThenEachLocalMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        let lateEvening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 59)))
        let midnights = OverviewPanelView.midnightSchedule(from: lateEvening, calendar: calendar)
        XCTAssertEqual(midnights.count, 8)
        XCTAssertEqual(midnights.first, calendar.date(from: DateComponents(year: 2026, month: 3, day: 7)))
        XCTAssertLessThanOrEqual(try XCTUnwrap(midnights.first), lateEvening)
        XCTAssertEqual(midnights[1], calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        // DST starts on 2026-03-08 in Denver: still one entry per local midnight.
        XCTAssertEqual(midnights[2], calendar.date(from: DateComponents(year: 2026, month: 3, day: 9)))
        XCTAssertTrue(midnights.allSatisfy { calendar.component(.hour, from: $0) == 0 })
    }
}
