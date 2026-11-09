@testable import TokenMon
import XCTest

/// This month's and last month's per-model Claude Code totals from the UTC
/// ledger, and how much of last month the ledger covers.
final class ClaudeUsageMonthTests: XCTestCase {
    private let utc = ClaudeCodeUsageLedger.dayCalendar

    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return calendar
    }

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter.parseFlexible(iso))
    }

    private func tokens(input: Int64 = 0, output: Int64 = 0) -> ClaudeModelTokens {
        ClaudeModelTokens(inputTokens: input, outputTokens: output, responseCount: 1)
    }

    // MARK: - Months

    func testMonthStartPreviousAndKeys() throws {
        let month = ClaudeUsageMonth(containing: try date("2026-11-09T15:00:00Z"), calendar: utc)
        XCTAssertEqual(month.start, try date("2026-11-01T00:00:00Z"))
        XCTAssertEqual(month.keyPrefix, "2026-11")
        XCTAssertEqual(month.firstDayKey, "2026-11-01")
        XCTAssertEqual(month.name, "November")
        XCTAssertEqual(month.previous.start, try date("2026-10-01T00:00:00Z"))
        XCTAssertEqual(month.previous.name, "October")
        XCTAssertTrue(month.contains(dayKey: "2026-11-30"))
        XCTAssertFalse(month.contains(dayKey: "2026-10-31"))
        XCTAssertFalse(month.contains(dayKey: "2025-11-09"))
    }

    func testPreviousMonthCrossesTheYear() throws {
        let january = ClaudeUsageMonth(containing: try date("2027-01-01T00:00:00Z"), calendar: utc)
        XCTAssertEqual(january.previous.keyPrefix, "2026-12")
        XCTAssertEqual(january.previous.name, "December")
    }

    /// Month names and short dates are read in the month's own calendar, so
    /// a UTC month is named the same on a Mac in any time zone.
    func testNamesUseTheMonthsCalendarNotTheSystemZone() throws {
        let month = ClaudeUsageMonth(containing: try date("2026-11-01T00:00:00Z"), calendar: utc)
        XCTAssertEqual(month.name, "November")
        XCTAssertEqual(month.shortDate(try date("2026-11-01T00:00:00Z")), "Nov 1")
    }

    // MARK: - Aggregation

    func testLastMonthSumsEachModelAcrossItsDays() throws {
        let days: ClaudeDailyTokens = [
            "2026-10-01": ["claude-opus-5-5": tokens(input: 10), "claude-sonnet-5-5": tokens(output: 5)],
            "2026-10-31": ["claude-opus-5-5": tokens(input: 20, output: 7)],
            "2026-11-01": ["claude-opus-5-5": tokens(input: 1_000)]
        ]
        let summary = ClaudeCodeUsageSummary.make(days: days, now: try date("2026-11-09T12:00:00Z"), calendar: utc)

        XCTAssertEqual(summary.currentMonth.keyPrefix, "2026-11")
        XCTAssertEqual(summary.previousMonth.keyPrefix, "2026-10")
        XCTAssertEqual(summary.previousMonthModels["claude-opus-5-5"], ClaudeModelTokens(inputTokens: 30, outputTokens: 7, responseCount: 2))
        XCTAssertEqual(summary.previousMonthModels["claude-sonnet-5-5"]?.outputTokens, 5)
        XCTAssertEqual(summary.monthModels.map(\.modelID), ["claude-opus-5-5"])
        XCTAssertEqual(summary.monthModels.first?.tokens.inputTokens, 1_000)
    }

    /// The first and last UTC days belong to their own months, and days
    /// from two months back are left out of last month.
    func testMonthBoundariesFollowUTCDays() throws {
        let days: ClaudeDailyTokens = [
            "2026-09-30": ["claude-opus-5-5": tokens(input: 1)],
            "2026-10-01": ["claude-opus-5-5": tokens(input: 10)],
            "2026-10-31": ["claude-opus-5-5": tokens(input: 100)],
            "2026-11-01": ["claude-opus-5-5": tokens(input: 1_000)]
        ]
        let summary = ClaudeCodeUsageSummary.make(days: days, now: try date("2026-11-01T00:00:00Z"), calendar: utc)
        XCTAssertEqual(summary.previousMonthModels["claude-opus-5-5"]?.inputTokens, 110)
        XCTAssertEqual(summary.month.tokens, 1_000)
    }

    /// At 17:00 on October 31 in Los Angeles it is already November 1 in
    /// UTC; the ledger's calendar decides, as for the existing month totals.
    func testTheLedgerCalendarDecidesTheMonthNotTheLocalZone() throws {
        let days: ClaudeDailyTokens = [
            "2026-10-31": ["claude-opus-5-5": tokens(input: 100)],
            "2026-11-01": ["claude-opus-5-5": tokens(input: 1_000)]
        ]
        let now = try date("2026-10-31T17:00:00-07:00")

        let inUTC = ClaudeCodeUsageSummary.make(days: days, now: now, calendar: utc)
        XCTAssertEqual(inUTC.currentMonth.name, "November")
        XCTAssertEqual(inUTC.month.tokens, 1_000)
        XCTAssertEqual(inUTC.previousMonthModels["claude-opus-5-5"]?.inputTokens, 100)

        // Reckoned in a local calendar instead, the same instant is October.
        let local = ClaudeCodeUsageSummary.make(days: days, now: now, calendar: try calendar("America/Los_Angeles"))
        XCTAssertEqual(local.currentMonth.name, "October")
        XCTAssertEqual(local.month.tokens, 100)
        XCTAssertNil(local.previousMonthModels["claude-opus-5-5"])
    }

    func testModelsMissingFromOneMonth() throws {
        let days: ClaudeDailyTokens = [
            "2026-10-05": ["claude-haiku-5-5": tokens(input: 50)],
            "2026-11-02": ["claude-fable-5-1": tokens(output: 30)]
        ]
        let summary = ClaudeCodeUsageSummary.make(days: days, now: try date("2026-11-09T00:00:00Z"), calendar: utc)
        // Fable is new this month; Haiku was used only last month.
        XCTAssertNil(summary.previousMonthModels["claude-fable-5-1"])
        XCTAssertEqual(summary.previousMonthModels["claude-haiku-5-5"]?.inputTokens, 50)
        XCTAssertEqual(summary.monthModels.map(\.modelID), ["claude-fable-5-1"])
    }

    /// A model saved with all-zero counts last month counts as unused, so
    /// it reads as new rather than as a rise from nothing.
    func testZeroTokenDaysDoNotCountAsUsage() throws {
        let days: ClaudeDailyTokens = [
            "2026-10-05": ["claude-opus-5-5": ClaudeModelTokens(responseCount: 1)],
            "2026-11-02": ["claude-opus-5-5": tokens(output: 30)]
        ]
        let summary = ClaudeCodeUsageSummary.make(days: days, now: try date("2026-11-09T00:00:00Z"), calendar: utc)
        XCTAssertTrue(summary.previousMonthModels.isEmpty)
    }

    // MARK: - Coverage

    func testCoverageIsCompleteWhenTheLedgerReachesTheMonthStart() throws {
        let november = ClaudeUsageMonth(containing: try date("2026-11-09T00:00:00Z"), calendar: utc)
        XCTAssertEqual(ClaudeMonthCoverage.of(november.previous, earliestDayKey: "2026-10-01"), .complete)
        XCTAssertEqual(ClaudeMonthCoverage.of(november.previous, earliestDayKey: "2026-09-12"), .complete)
    }

    func testCoverageIsPartialWhenTheLedgerStartsInsideTheMonth() throws {
        let october = ClaudeUsageMonth(containing: try date("2026-10-15T00:00:00Z"), calendar: utc)
        XCTAssertEqual(
            ClaudeMonthCoverage.of(october, earliestDayKey: "2026-10-09"),
            .partial(since: try date("2026-10-09T00:00:00Z"))
        )
    }

    func testCoverageIsNoneWhenTheLedgerStartsAfterTheMonth() throws {
        let october = ClaudeUsageMonth(containing: try date("2026-10-15T00:00:00Z"), calendar: utc)
        XCTAssertEqual(
            ClaudeMonthCoverage.of(october, earliestDayKey: "2026-11-04"),
            .none(recordedSince: try date("2026-11-04T00:00:00Z"))
        )
        XCTAssertEqual(ClaudeMonthCoverage.of(october, earliestDayKey: nil), .none(recordedSince: nil))
    }

    func testSummaryReportsLastMonthsCoverageFromTheEarliestSavedDay() throws {
        let now = try date("2026-11-09T00:00:00Z")
        let partial = ClaudeCodeUsageSummary.make(
            days: ["2026-10-20": ["claude-opus-5-5": tokens(input: 1)], "2026-11-02": ["claude-opus-5-5": tokens(input: 1)]],
            now: now,
            calendar: utc
        )
        XCTAssertEqual(partial.previousMonthCoverage, .partial(since: try date("2026-10-20T00:00:00Z")))

        let complete = ClaudeCodeUsageSummary.make(
            days: ["2026-09-28": ["claude-opus-5-5": tokens(input: 1)], "2026-11-02": ["claude-opus-5-5": tokens(input: 1)]],
            now: now,
            calendar: utc
        )
        XCTAssertEqual(complete.previousMonthCoverage, .complete)
    }
}
