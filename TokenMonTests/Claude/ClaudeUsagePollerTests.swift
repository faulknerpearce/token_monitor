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

    // MARK: - Provider-initiated early resets

    private func makeStore() -> (DailyQuotaDeltaStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backing = FileBackedStringStore(directory: dir, filenamePrefix: "activity_")
        return (DailyQuotaDeltaStore(store: backing, storageKey: "claude_daily_usage"), dir)
    }

    private func local(_ dayOffset: Int, hour: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date()))!
        return cal.date(byAdding: .hour, value: hour, to: day)!
    }

    private func poll(_ store: DailyQuotaDeltaStore, used: Double, at fetched: Date, resetOffset: Int) -> [DailyBudgetDay] {
        let resetsAt = local(resetOffset, hour: 8)
        store.record(windowUsedPercent: used, at: fetched, window: QuotaWindow(start: nil, resetsAt: resetsAt))
        return ClaudeUsagePoller.buildDailyBudgetDays(
            spentByDay: store.spentByDay,
            resetsAt: resetsAt,
            windowStart: store.windowStart,
            interruptedWindowStart: store.interruptedWindowStart,
            now: fetched
        )
    }

    /// Claude sends only `seven_day.resets_at`. A drop plus a reset instant that
    /// jumps while the old one is still ahead is an early reset: prior days stay
    /// as dimmed history and the 7 live bars open on the new window's start.
    func testEarlyResetKeepsPriorDaysAndRestartsTheWeeklyWindow() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = poll(store, used: 20, at: local(-2, hour: 9), resetOffset: 5)
        _ = poll(store, used: 45, at: local(-1, hour: 9), resetOffset: 5)

        let days = poll(store, used: 2, at: local(0, hour: 9), resetOffset: 7)

        let window = days.filter { !$0.isPriorWindow }
        let prior = days.filter(\.isPriorWindow)
        XCTAssertEqual(window.count, 7)
        XCTAssertTrue(Calendar.current.isDate(window[0].date, inSameDayAs: local(0, hour: 8)))
        XCTAssertEqual(window[0].spentUSD, 2, accuracy: 0.001)
        XCTAssertEqual(prior.last?.spentUSD ?? 0, 25, accuracy: 0.001)
        XCTAssertEqual(DailyBudget.weeklyPacePeriodStart(days: days), Calendar.current.startOfDay(for: local(0, hour: 8)))
    }

    /// Without any reset movement a bigger-than-noise drop is still just the
    /// store's drop-as-reset credit; no prior-window bars appear.
    func testSameResetInstantDropLeavesBarsUnchanged() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = poll(store, used: 60, at: local(-1, hour: 9), resetOffset: 5)
        let days = poll(store, used: 10, at: local(0, hour: 9), resetOffset: 5)
        XCTAssertEqual(days.count, 7)
        XCTAssertFalse(days.contains(where: \.isPriorWindow))
    }
}
