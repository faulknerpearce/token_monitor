@testable import TokenMon
import XCTest

/// Time-zone-independent day keys and the conversion of older start-of-day instants.
final class DayKeyTests: XCTestCase {
    private func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
        return calendar
    }

    func testKeyRoundTripsThroughStartOfDay() throws {
        let denver = try calendar("America/Denver")
        let date = Date(timeIntervalSinceReferenceDate: 811_144_800 + 15 * 3_600)
        XCTAssertEqual(DayKey.key(for: date, calendar: denver), "2026-09-15")
        let start = try XCTUnwrap(DayKey.startOfDay(for: "2026-09-15", calendar: denver))
        XCTAssertEqual(start, Date(timeIntervalSinceReferenceDate: 811_144_800))
        XCTAssertNil(DayKey.startOfDay(for: "garbage", calendar: denver))
    }

    func testAddingDaysCrossesMonths() throws {
        let utc = try calendar("UTC")
        XCTAssertEqual(DayKey.adding(days: -40, to: "2026-10-10", calendar: utc), "2026-08-31")
        XCTAssertEqual(DayKey.adding(days: 1, to: "2026-12-31", calendar: utc), "2027-01-01")
    }

    /// A Denver local midnight converts to its own date whatever zone the Mac is in now.
    func testStoredStartOfDayKeepsItsDateAcrossZones() throws {
        let instant = Date(timeIntervalSinceReferenceDate: 811_144_800)
        for zone in ["America/Denver", "Asia/Tokyo", "Europe/London", "Pacific/Auckland", "UTC"] {
            let offset = try calendar(zone).timeZone.secondsFromGMT(for: instant)
            XCTAssertEqual(DayKey.key(forStoredStartOfDay: instant, preferredOffset: offset), "2026-09-15", zone)
        }
    }

    func testStoredStartOfDayFromEasternAndHalfHourZones() throws {
        for zone in ["Asia/Tokyo", "Asia/Kolkata", "Pacific/Auckland", "America/Los_Angeles"] {
            let cal = try calendar(zone)
            let start = try XCTUnwrap(DayKey.startOfDay(for: "2026-07-16", calendar: cal))
            let offset = cal.timeZone.secondsFromGMT(for: start)
            XCTAssertEqual(DayKey.key(forStoredStartOfDay: start, preferredOffset: offset), "2026-07-16", zone)
        }
    }
}
