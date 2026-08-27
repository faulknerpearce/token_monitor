@testable import TokenMon
import XCTest

@MainActor
final class GrokbotUsagePollerTests: XCTestCase {
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

    /// Bars run from the day the period began to the day before it resets.
    func testBarsAnchorToTheProviderResetInstant() {
        let days = GrokbotUsagePoller.buildDailyBudgetDays(
            spentByDay: [:],
            resetsAt: date(2026, 8, 27, hour: 11),
            now: date(2026, 8, 25, hour: 15),
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertTrue(calendar.isDate(days[0].date, inSameDayAs: date(2026, 8, 20)))
        XCTAssertTrue(calendar.isDate(days[6].date, inSameDayAs: date(2026, 8, 26)))
        XCTAssertEqual(days[0].budgetUSD, 100.0 / 7, accuracy: 1e-9)
    }

    /// No reset ever observed → no bars. The project never substitutes a
    /// calendar-derived window for the provider's real period.
    func testNoResetYieldsNoBars() {
        XCTAssertTrue(GrokbotUsagePoller.buildDailyBudgetDays(
            spentByDay: [:],
            resetsAt: nil,
            now: date(2026, 8, 25),
            calendar: calendar
        ).isEmpty)
    }

    /// On reset day, before the instant, today stays the last bar so the day's
    /// calendar-keyed deltas remain visible instead of rolling out of the window.
    func testResetDayBeforeInstantKeepsTodayAsLastBar() {
        let days = GrokbotUsagePoller.buildDailyBudgetDays(
            spentByDay: [:],
            resetsAt: date(2026, 8, 27, hour: 11),
            now: date(2026, 8, 27, hour: 9),
            calendar: calendar
        )
        XCTAssertTrue(calendar.isDate(days.last!.date, inSameDayAs: date(2026, 8, 27)))
    }

    /// The period length comes from the payload's own start → reset span rather
    /// than a hardcoded 7, so a non-weekly cadence still paces correctly.
    func testPeriodLengthIsDerivedFromTheSnapshotSpan() {
        let fortnightly = GrokbotSnapshot(
            fetchedAt: date(2026, 8, 25),
            usedPercent: 20,
            periodStart: date(2026, 8, 13, hour: 11),
            resetsAt: date(2026, 8, 27, hour: 11)
        )
        XCTAssertEqual(fortnightly.daysInPeriod(calendar: calendar), 14)

        let days = GrokbotUsagePoller.buildDailyBudgetDays(
            spentByDay: [:],
            resetsAt: fortnightly.resetsAt,
            daysInPeriod: fortnightly.daysInPeriod(calendar: calendar),
            now: date(2026, 8, 25),
            calendar: calendar
        )
        XCTAssertEqual(days.count, 14)
        XCTAssertEqual(days[0].budgetUSD, 100.0 / 14, accuracy: 1e-9)
    }

    /// A 7-day window that is a few hours short must not collapse to 6 bars.
    func testDaysInPeriodUsesCalendarDaysNotTruncatedHours() {
        let snapshot = GrokbotSnapshot(
            fetchedAt: date(2026, 8, 25),
            usedPercent: 20,
            periodStart: date(2026, 8, 20, hour: 12),
            resetsAt: date(2026, 8, 27, hour: 11)
        )
        XCTAssertEqual(snapshot.daysInPeriod(calendar: calendar), 7)
    }

    /// A snapshot carrying a reset but no period start falls back to a week.
    func testDaysInPeriodFallsBackToSevenWithoutPeriodStart() {
        let snapshot = GrokbotSnapshot(
            fetchedAt: date(2026, 8, 25),
            usedPercent: 20,
            resetsAt: date(2026, 8, 27, hour: 11)
        )
        XCTAssertEqual(snapshot.daysInPeriod(calendar: calendar), 7)
    }

    func testEntitlementCaptions() {
        XCTAssertEqual(GrokbotEntitlement.cursor.captionText, "via Cursor")
        XCTAssertEqual(GrokbotEntitlement.superGrok(planLabel: "SuperGrok Heavy").captionText, "via SuperGrok Heavy")
        XCTAssertEqual(GrokbotEntitlement.superGrok(planLabel: "").captionText, "via SuperGrok")
    }

    /// Grokbot is a real, pollable provider and must appear in the switcher.
    func testGrokbotIsARegisteredUsageProvider() {
        XCTAssertTrue(MonitorProvider.usageProviders.contains(.grokbot))
        XCTAssertEqual(MonitorProvider.grokbot.displayName, "Grokbot")
        XCTAssertTrue(MonitorProvider.grokbot.pollsGrokbot)
        XCTAssertTrue(MonitorProvider.overview.pollsGrokbot)
        XCTAssertFalse(MonitorProvider.cursor.pollsGrokbot)
    }
}
