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

    /// On reset morning the first bar stays the day the pool opened (Thursday).
    func testResetMorningKeepsPeriodStartAsFirstBar() {
        let days = GrokbotUsagePoller.buildDailyBudgetDays(
            spentByDay: [:],
            resetsAt: date(2026, 8, 27, hour: 11),
            now: date(2026, 8, 27, hour: 9),
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.weekday, from: days[0].date), 5) // Thursday
        XCTAssertTrue(calendar.isDate(days[0].date, inSameDayAs: date(2026, 8, 20)))
        XCTAssertTrue(calendar.isDate(days[6].date, inSameDayAs: date(2026, 8, 26)))
    }

    /// The pool is weekly, so a span that is not roughly a week (here a
    /// fortnight) is not trusted and falls back to 7 bars.
    func testPeriodLengthIsDerivedFromTheSnapshotSpan() {
        let fortnightly = GrokbotSnapshot(
            fetchedAt: date(2026, 8, 25),
            usedPercent: 20,
            periodStart: date(2026, 8, 13, hour: 11),
            resetsAt: date(2026, 8, 27, hour: 11)
        )
        XCTAssertEqual(fortnightly.daysInPeriod(calendar: calendar), 7)

        let days = GrokbotUsagePoller.buildDailyBudgetDays(
            spentByDay: [:],
            resetsAt: fortnightly.resetsAt,
            daysInPeriod: fortnightly.daysInPeriod(calendar: calendar),
            now: date(2026, 8, 25),
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days[0].budgetUSD, 100.0 / 7, accuracy: 1e-9)
    }

    /// A 5-day start → reset span from the payload keeps the weekly pool at 7 bars.
    func testFiveDaySpanStillYieldsSevenBars() {
        let snapshot = GrokbotSnapshot(
            fetchedAt: date(2026, 8, 25),
            usedPercent: 20,
            periodStart: date(2026, 8, 22, hour: 11),
            resetsAt: date(2026, 8, 27, hour: 11)
        )
        XCTAssertEqual(snapshot.daysInPeriod(calendar: calendar), 7)

        let days = GrokbotUsagePoller.buildDailyBudgetDays(
            spentByDay: [:],
            resetsAt: snapshot.resetsAt,
            daysInPeriod: snapshot.daysInPeriod(calendar: calendar),
            now: date(2026, 8, 25),
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days[0].budgetUSD, 100.0 / 7, accuracy: 1e-9)
    }

    /// A 7-day window that is a few hours short counts as 7 days.
    func testDaysInPeriodUsesCalendarDaysNotTruncatedHours() {
        let snapshot = GrokbotSnapshot(
            fetchedAt: date(2026, 8, 25),
            usedPercent: 20,
            periodStart: date(2026, 8, 20, hour: 12),
            resetsAt: date(2026, 8, 27, hour: 11)
        )
        XCTAssertEqual(snapshot.daysInPeriod(calendar: calendar), 7)
    }

    /// A payload whose period start and reset land on the same day falls back
    /// to a 7-day period.
    func testSameDayStartAndResetFallsBackToAWeek() {
        let snapshot = GrokbotSnapshot(
            fetchedAt: date(2026, 9, 2, hour: 14),
            usedPercent: 96,
            periodStart: date(2026, 9, 2, hour: 1),
            resetsAt: date(2026, 9, 2, hour: 13)
        )
        XCTAssertEqual(snapshot.daysInPeriod(calendar: calendar), 7)

        let days = GrokbotUsagePoller.buildDailyBudgetDays(
            spentByDay: [:],
            resetsAt: snapshot.resetsAt,
            daysInPeriod: snapshot.daysInPeriod(calendar: calendar),
            now: date(2026, 9, 2, hour: 14),
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days[0].budgetUSD, 100.0 / 7, accuracy: 1e-9)
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

    /// The pool label follows the payload's own span even when bars fall back to 7.
    func testReportedSpanIsNotSanitized() {
        let fortnightly = GrokbotSnapshot(
            fetchedAt: date(2026, 8, 25),
            usedPercent: 10,
            periodStart: date(2026, 8, 13, hour: 11),
            resetsAt: date(2026, 8, 27, hour: 11)
        )
        XCTAssertEqual(fortnightly.reportedSpanDays(calendar: calendar), 14)
        XCTAssertEqual(fortnightly.daysInPeriod(calendar: calendar), 7)
        XCTAssertNil(GrokbotSnapshot(fetchedAt: date(2026, 8, 25), usedPercent: 10).reportedSpanDays(calendar: calendar))
    }

    func testEntitlementCaptions() {
        XCTAssertEqual(GrokbotEntitlement.cursor.captionText, "via Cursor")
        XCTAssertEqual(GrokbotEntitlement.superGrok(planLabel: "SuperGrok Heavy").captionText, "via SuperGrok Heavy")
        XCTAssertEqual(GrokbotEntitlement.superGrok(planLabel: "").captionText, "via SuperGrok")
    }

    /// Grokbot is a real, pollable provider and appears in the switcher.
    func testGrokbotIsARegisteredUsageProvider() {
        XCTAssertTrue(MonitorProvider.usageProviders.contains(.grokbot))
        XCTAssertEqual(MonitorProvider.grokbot.displayName, "Grokbot")
        XCTAssertTrue(MonitorProvider.grokbot.polls(.grokbot))
        XCTAssertTrue(MonitorProvider.overview.polls(.grokbot))
        XCTAssertFalse(MonitorProvider.cursor.polls(.grokbot))
    }

    /// A reset instant that jumps forward by ~a whole period is a new window;
    /// small forward drift within the same period is not.
    func testIsNewWindowDetectsRollover() {
        let previous = date(2026, 8, 20, hour: 11)
        XCTAssertTrue(GrokbotUsagePoller.isNewWindow(
            previousResetsAt: previous,
            nextResetsAt: date(2026, 8, 27, hour: 11),
            periodDays: 7
        ))
        XCTAssertFalse(GrokbotUsagePoller.isNewWindow(
            previousResetsAt: previous,
            nextResetsAt: date(2026, 8, 21, hour: 11),
            periodDays: 7
        ))
        // No prior anchor, or a backwards move, is never a rollover.
        XCTAssertFalse(GrokbotUsagePoller.isNewWindow(
            previousResetsAt: nil,
            nextResetsAt: previous,
            periodDays: 7
        ))
        XCTAssertFalse(GrokbotUsagePoller.isNewWindow(
            previousResetsAt: previous,
            nextResetsAt: date(2026, 8, 19, hour: 11),
            periodDays: 7
        ))
    }

    // MARK: - Provider-initiated early resets

    /// Runs Grokbot's poller flow against a real store: the payload's own period
    /// start / reset instant drive detection and the bars.
    private func makeStore() -> (DailyQuotaDeltaStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backing = FileBackedStringStore(directory: dir, filenamePrefix: "activity_")
        return (DailyQuotaDeltaStore(store: backing, storageKey: "grokbot_daily_usage"), dir)
    }

    private func local(_ dayOffset: Int, hour: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date()))!
        return cal.date(byAdding: .hour, value: hour, to: day)!
    }

    private func snapshot(used: Double, at fetched: Date, startOffset: Int, resetOffset: Int) -> GrokbotSnapshot {
        GrokbotSnapshot(
            fetchedAt: fetched,
            usedPercent: used,
            periodStart: local(startOffset, hour: 8),
            resetsAt: local(resetOffset, hour: 8)
        )
    }

    private func poll(_ store: DailyQuotaDeltaStore, _ snap: GrokbotSnapshot) -> [DailyBudgetDay] {
        store.record(
            windowUsedPercent: snap.usedPercent,
            at: snap.fetchedAt,
            window: QuotaWindow(start: snap.periodStart, resetsAt: snap.resetsAt),
            periodDays: snap.daysInPeriod()
        )
        return GrokbotUsagePoller.buildDailyBudgetDays(
            spentByDay: store.spentByDay,
            resetsAt: snap.resetsAt,
            daysInPeriod: snap.daysInPeriod(),
            windowStart: store.windowStart,
            interruptedWindowStart: store.interruptedWindowStart,
            now: snap.fetchedAt
        )
    }

    /// A free reset pushed mid-cycle: the new period start is well before the old
    /// reset. Earlier days stay in the chart as prior-window history, the bars of
    /// the new window open at the new period start, and pace restarts there.
    func testEarlyResetKeepsHistoryAndAnchorsBarsToNewPeriodStart() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = poll(store, snapshot(used: 10, at: local(-3, hour: 12), startOffset: -3, resetOffset: 4))
        _ = poll(store, snapshot(used: 30, at: local(-2, hour: 9), startOffset: -3, resetOffset: 4))
        _ = poll(store, snapshot(used: 50, at: local(-1, hour: 9), startOffset: -3, resetOffset: 4))

        let days = poll(store, snapshot(used: 3, at: local(0, hour: 9), startOffset: 0, resetOffset: 7))

        let cal = Calendar.current
        let prior = days.filter(\.isPriorWindow)
        let window = days.filter { !$0.isPriorWindow }
        XCTAssertEqual(window.count, 7)
        XCTAssertTrue(cal.isDate(window[0].date, inSameDayAs: local(0, hour: 8)))
        XCTAssertEqual(window[0].spentUSD, 3, accuracy: 0.001)
        // Old-window days before the reset survive with their recorded spend.
        XCTAssertEqual(prior.count, 3)
        XCTAssertTrue(cal.isDate(prior[0].date, inSameDayAs: local(-3, hour: 8)))
        XCTAssertEqual(prior[1].spentUSD, 20, accuracy: 0.001)
        XCTAssertEqual(prior[2].spentUSD, 20, accuracy: 0.001)
        // Pace anchors to the new start and counts only the new window's days.
        XCTAssertEqual(DailyBudget.weeklyPacePeriodStart(days: days), cal.startOfDay(for: local(0, hour: 8)))
        let pace = try XCTUnwrap(DailyBudget.paceHeadroom(
            days: days,
            periodConsumed: 3,
            elapsedDaysInPeriod: DailyBudget.elapsedDaysThroughToday(from: local(0, hour: 8), now: local(0, hour: 9)),
            now: local(0, hour: 9)
        ))
        XCTAssertEqual(pace.earned, 100.0 / 7, accuracy: 1e-9)
        XCTAssertEqual(pace.headroomToday, 100.0 / 7 - 3, accuracy: 1e-9)
    }

    /// When the provider moves the period start but leaves the old reset instant
    /// in place, the bars still open on the new period start.
    func testNewPeriodStartWinsOverUnchangedResetInstant() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = poll(store, snapshot(used: 40, at: local(-1, hour: 9), startOffset: -3, resetOffset: 4))
        let days = poll(store, snapshot(used: 2, at: local(0, hour: 9), startOffset: 0, resetOffset: 4))

        XCTAssertEqual(store.interruptedWindowStart.map { Calendar.current.startOfDay(for: $0) }, Calendar.current.startOfDay(for: local(-3, hour: 8)))
        let window = days.filter { !$0.isPriorWindow }
        XCTAssertTrue(Calendar.current.isDate(window[0].date, inSameDayAs: local(0, hour: 8)))
        XCTAssertEqual(window.count, 7)
    }

    /// A scheduled rollover still opens a clean 7-bar window with no prior-window
    /// days, and the finished week's days stay in the store.
    func testNormalRolloverShowsNoPriorWindowBars() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = poll(store, snapshot(used: 30, at: local(-2, hour: 9), startOffset: -7, resetOffset: 0))
        _ = poll(store, snapshot(used: 70, at: local(-1, hour: 9), startOffset: -7, resetOffset: 0))
        let days = poll(store, snapshot(used: 3, at: local(0, hour: 9), startOffset: 0, resetOffset: 7))

        XCTAssertEqual(days.count, 7)
        XCTAssertFalse(days.contains(where: \.isPriorWindow))
        XCTAssertEqual(days[0].spentUSD, 3, accuracy: 0.001)
        XCTAssertEqual(store.spentByDay[Calendar.current.startOfDay(for: local(-1, hour: 9))] ?? 0, 40, accuracy: 0.001)
    }

    /// A drop with an unchanged period is a rebase, not a new window.
    func testSamePeriodDropIsNotTreatedAsEarlyReset() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = poll(store, snapshot(used: 60, at: local(-1, hour: 9), startOffset: -3, resetOffset: 4))
        let days = poll(store, snapshot(used: 20, at: local(0, hour: 9), startOffset: -3, resetOffset: 4))
        XCTAssertNil(store.interruptedWindowStart)
        XCTAssertFalse(days.contains(where: \.isPriorWindow))
    }
}
