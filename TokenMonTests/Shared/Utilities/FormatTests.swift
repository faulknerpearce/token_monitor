@testable import TokenMon
import XCTest

final class FormatTests: XCTestCase {
    // MARK: tokens

    func testTokensBelowThousandShowsBareCount() {
        XCTAssertEqual(Format.tokens(0), "0")
        XCTAssertEqual(Format.tokens(999), "999")
    }

    func testTokensThousands() {
        XCTAssertEqual(Format.tokens(1_000), "1K")
        XCTAssertEqual(Format.tokens(12_400), "12K")
    }

    func testTokensMillionsRoundsToOneDecimalBelowTen() {
        XCTAssertEqual(Format.tokens(1_000_000), "1.0M")
        XCTAssertEqual(Format.tokens(1_234_567), "1.2M")
    }

    func testTokensMillionsRoundsWholeAtTenPlus() {
        XCTAssertEqual(Format.tokens(10_000_000), "10M")
        XCTAssertEqual(Format.tokens(123_000_000), "123M")
    }

    func testTokensBillions() {
        XCTAssertEqual(Format.tokens(1_000_000_000), "1.0B")
        XCTAssertEqual(Format.tokens(2_500_000_000), "2.5B")
    }

    func testTokensRollToNextUnitAtRoundingBoundary() {
        XCTAssertEqual(Format.tokens(999_499), "999K")
        XCTAssertEqual(Format.tokens(999_500), "1.0M")
        XCTAssertEqual(Format.tokens(9_949_999), "9.9M")
        XCTAssertEqual(Format.tokens(9_950_000), "10M")
        XCTAssertEqual(Format.tokens(999_499_999), "999M")
        XCTAssertEqual(Format.tokens(999_500_000), "1.0B")
    }

    func testTokensRoundHalfAwayFromZero() {
        XCTAssertEqual(Format.tokens(1_500), "2K")
        XCTAssertEqual(Format.tokens(2_500), "3K")
        XCTAssertEqual(Format.tokens(1_250_000), "1.3M")
    }

    // MARK: usd

    func testUSDFormatsCurrencyWithoutTilde() {
        XCTAssertEqual(Format.usd(4.1), "$4.10")
        XCTAssertEqual(Format.usd(0), "$0.00")
    }

    // MARK: hourLabel

    func testHourLabelTwelveHourClock() {
        XCTAssertEqual(Format.hourLabel(for: 0), "12a")
        XCTAssertEqual(Format.hourLabel(for: 12), "12p")
        XCTAssertEqual(Format.hourLabel(for: 5), "5a")
        XCTAssertEqual(Format.hourLabel(for: 11), "11a")
        XCTAssertEqual(Format.hourLabel(for: 13), "1p")
        XCTAssertEqual(Format.hourLabel(for: 15), "3p")
        XCTAssertEqual(Format.hourLabel(for: 23), "11p")
    }

    // MARK: parseFlexible

    func testParseFlexiblePlainAndFractional() throws {
        let plain = try XCTUnwrap(ISO8601DateFormatter.parseFlexible("2026-07-16T20:25:00Z"))
        XCTAssertEqual(plain.timeIntervalSince1970, 1_784_233_500, accuracy: 1)

        let fractional = try XCTUnwrap(ISO8601DateFormatter.parseFlexible("2026-07-16T20:25:00.123Z"))
        XCTAssertEqual(fractional.timeIntervalSince1970, 1_784_233_500.123, accuracy: 0.001)
    }

    func testParseFlexibleRejectsGarbage() {
        XCTAssertNil(ISO8601DateFormatter.parseFlexible("not a date"))
    }

    // MARK: resetDate

    func testResetDateMatchesNaiveFormatterAndLowercasesMeridian() throws {
        let utc = TimeZone(secondsFromGMT: 0)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-16T18:57:00Z"))

        let naive = DateFormatter()
        naive.locale = Locale(identifier: "en_US_POSIX")
        naive.timeZone = utc
        naive.dateFormat = "EEE h:mma"
        let expected = naive.string(from: date)
            .replacingOccurrences(of: "AM", with: "am")
            .replacingOccurrences(of: "PM", with: "pm")

        XCTAssertEqual(Format.resetDate(date, dateFormat: "EEE h:mma", timeZone: utc), expected)
        XCTAssertTrue(expected.hasSuffix("pm"))
    }

    /// Formatters are keyed by zone, so different explicit zones never share one.
    func testResetDateUsesTheRequestedTimeZone() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-16T18:57:00Z"))
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(Format.resetDate(date, dateFormat: "HH:mm", timeZone: utc), "18:57")
        XCTAssertEqual(Format.resetDate(date, dateFormat: "HH:mm", timeZone: tokyo), "03:57")
        XCTAssertEqual(Format.resetDate(date, dateFormat: "HH:mm", timeZone: utc), "18:57")
    }

    /// Without an explicit zone the formatter follows the current system zone.
    func testResetDateDefaultsToCurrentTimeZone() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-16T18:57:00Z"))
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "en_US_POSIX")
        naive.timeZone = TimeZone.current
        naive.dateFormat = "dd HH:mm"
        XCTAssertEqual(Format.resetDate(date, dateFormat: "dd HH:mm"), naive.string(from: date))
    }

    /// A system time-zone change empties the cache so no formatter keeps the old zone.
    func testSystemTimeZoneChangeClearsFormatterCache() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-16T18:57:00Z"))
        _ = Format.resetDate(date, dateFormat: "HH:mm", timeZone: TimeZone(identifier: "UTC"))
        XCTAssertGreaterThan(Format.cachedFormatterCount, 0)
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        XCTAssertEqual(Format.cachedFormatterCount, 0)
    }
}
