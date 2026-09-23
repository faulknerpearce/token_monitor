@testable import TokenMon
import XCTest

@MainActor
final class CursorUsagePollerTests: XCTestCase {
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

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.startOfDay(for: date(year, month, day))
    }

    private func makeStore() -> (DailyQuotaDeltaStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileBackedStringStore(directory: dir, filenamePrefix: "activity_")
        return (DailyQuotaDeltaStore(store: store, storageKey: "cursor_daily_usage"), dir)
    }

    /// A fully-tracked day uses its measured pool-% delta and is paced against the
    /// 31-day billing cycle; other days are back-filled from the estimate so the
    /// cycle still sums to `usedPercent`.
    func testTrackedDayUsesMeasuredDeltaAndOthersBackfilled() throws {
        let days = try XCTUnwrap(CursorUsagePoller.buildDailyBudgetDays(
            observedByDay: [day(2026, 8, 23): 9, day(2026, 8, 25): 3],
            estimatedWeightByDay: [
                day(2026, 8, 22): 100,
                day(2026, 8, 23): 100,
                day(2026, 8, 24): 100,
                day(2026, 8, 26): 100,
                day(2026, 8, 27): 100
            ],
            usedPercent: 9,
            billingCycleStart: date(2026, 8, 22, hour: 17),
            billingCycleEnd: date(2026, 9, 22, hour: 17),
            now: date(2026, 8, 28, hour: 12),
            calendar: calendar
        ))

        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days[0].budgetUSD, 100.0 / 31, accuracy: 1e-9)
        // Aug 28 2026 is a Friday; monthly bars open on that week's Monday.
        XCTAssertEqual(calendar.component(.weekday, from: days[0].date), 2)
        XCTAssertTrue(calendar.isDate(days[0].date, inSameDayAs: date(2026, 8, 24)))

        let aug25 = try XCTUnwrap(days.first { calendar.isDate($0.date, inSameDayAs: date(2026, 8, 25)) })
        XCTAssertEqual(aug25.spentUSD, 3.0, accuracy: 0.001)
        let aug26 = try XCTUnwrap(days.first { calendar.isDate($0.date, inSameDayAs: date(2026, 8, 26)) })
        XCTAssertEqual(aug26.spentUSD, 1.2, accuracy: 0.001)
    }

    /// The first day the app tracked is only partially covered, so it falls back to
    /// the estimate instead of painting a misleading sliver.
    func testFirstTrackedDayUsesEstimate() throws {
        let days = try XCTUnwrap(CursorUsagePoller.buildDailyBudgetDays(
            observedByDay: [day(2026, 8, 25): 1],
            estimatedWeightByDay: [day(2026, 8, 25): 50, day(2026, 8, 24): 50],
            usedPercent: 4,
            billingCycleStart: date(2026, 8, 22, hour: 17),
            billingCycleEnd: date(2026, 9, 22, hour: 17),
            now: date(2026, 8, 25, hour: 18),
            calendar: calendar
        ))
        let today = try XCTUnwrap(days.first { calendar.isDate($0.date, inSameDayAs: date(2026, 8, 25)) })
        XCTAssertEqual(today.spentUSD, 2.0, accuracy: 0.001)
    }

    /// A completed tracked day reads its real pool-% growth (68% → 71% ⇒ 3%),
    /// not a list-price estimate.
    func testCompletedDayUsesPoolPercentDelta() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The store buckets by `Calendar.current`, so drive both sides with it.
        let current = Calendar.current
        let now = Date()
        let yesterday = current.date(byAdding: .day, value: -1, to: now) ?? now
        func at(_ date: Date, _ hour: Int) -> Date {
            current.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
        }
        store.record(windowUsedPercent: 66, at: at(yesterday, 9))
        store.record(windowUsedPercent: 68, at: at(yesterday, 18))
        store.record(windowUsedPercent: 68, at: at(now, 9))
        store.record(windowUsedPercent: 71, at: at(now, 18))

        let days = try XCTUnwrap(CursorUsagePoller.buildDailyBudgetDays(
            observedByDay: store.spentByDay,
            estimatedWeightByDay: [current.startOfDay(for: now): 100],
            usedPercent: 71,
            billingCycleStart: current.date(byAdding: .day, value: -16, to: now),
            billingCycleEnd: current.date(byAdding: .day, value: 14, to: now),
            now: at(now, 18),
            calendar: current
        ))
        let today = try XCTUnwrap(days.first { current.isDate($0.date, inSameDayAs: now) })
        XCTAssertEqual(today.spentUSD, 3.0, accuracy: 0.001)
    }

    /// No billing-cycle signal → no bars. A calendar month is never substituted.
    func testBuildDailyBudgetDaysNilWithoutCycleDates() {
        XCTAssertNil(CursorUsagePoller.buildDailyBudgetDays(
            observedByDay: [day(2026, 8, 25): 2],
            estimatedWeightByDay: [:],
            usedPercent: 2,
            billingCycleStart: nil,
            billingCycleEnd: nil,
            now: date(2026, 8, 25),
            calendar: calendar
        ))
    }

    /// When tracked daily deltas exceed the live pool %, rescale so chart bars
    /// still sum to `usedPercent` instead of overshooting the headline.
    func testTrackedExceedingPoolPercentIsRescaled() throws {
        // Two fully tracked days (first tracked day is dropped as partial).
        let days = try XCTUnwrap(CursorUsagePoller.buildDailyBudgetDays(
            observedByDay: [
                day(2026, 8, 23): 1,
                day(2026, 8, 25): 6,
                day(2026, 8, 26): 4
            ],
            estimatedWeightByDay: [
                day(2026, 8, 22): 100,
                day(2026, 8, 24): 100,
                day(2026, 8, 27): 100
            ],
            usedPercent: 5,
            billingCycleStart: date(2026, 8, 22, hour: 17),
            billingCycleEnd: date(2026, 9, 22, hour: 17),
            now: date(2026, 8, 28, hour: 12),
            calendar: calendar
        ))

        let aug25 = try XCTUnwrap(days.first { calendar.isDate($0.date, inSameDayAs: date(2026, 8, 25)) })
        let aug26 = try XCTUnwrap(days.first { calendar.isDate($0.date, inSameDayAs: date(2026, 8, 26)) })
        // tracked = 6+4 = 10 → scale 5/10; no back-fill on unobserved days.
        XCTAssertEqual(aug25.spentUSD, 3.0, accuracy: 0.001)
        XCTAssertEqual(aug26.spentUSD, 2.0, accuracy: 0.001)
        let chartSum = days.map(\.spentUSD).reduce(0, +)
        XCTAssertEqual(chartSum, 5.0, accuracy: 0.001)
    }
}
