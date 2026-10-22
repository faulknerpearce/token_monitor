@testable import TokenMon
import XCTest

@MainActor
final class OverviewHourlyHistoryTests: XCTestCase {
    private var directory: URL!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverviewHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? utc.timeZone
        calendar = utc
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> OverviewHourlyHistoryStore {
        OverviewHourlyHistoryStore(
            store: FileBackedStringStore(directory: directory, filenamePrefix: "activity_"),
            calendar: calendar
        )
    }

    private func date(_ day: Int, month: Int = 10, hour: Int = 12) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
    }

    private func hours(_ values: [Int: Double]) -> [Double] {
        (0..<24).map { values[$0] ?? 0 }
    }

    private func series(_ grok: [Int: Double] = [:], claude: [Int: Double] = [:]) -> OverviewDaySeries {
        var series = OverviewDaySeries()
        if !grok.isEmpty { series.weights[.grok] = hours(grok) }
        if !claude.isEmpty { series.weights[.claude] = hours(claude) }
        return series
    }

    // MARK: - History store

    func testRecordKeepsTheLargerValueForEachHour() throws {
        let store = makeStore()
        store.record(series([9: 2, 10: 1]), at: try date(22))
        store.record(series([9: 1, 10: 3], claude: [10: 4]), at: try date(22, hour: 15))

        let saved = try XCTUnwrap(store.series(on: try date(22)))
        XCTAssertEqual(saved.weights[.grok]?[9], 2)
        XCTAssertEqual(saved.weights[.grok]?[10], 3)
        XCTAssertEqual(saved.weights[.claude]?[10], 4)
    }

    func testAnEmptyDayIsNotSaved() throws {
        let store = makeStore()
        store.record(OverviewDaySeries(), at: try date(22))
        XCTAssertTrue(store.days.isEmpty)
        XCTAssertNil(store.earliestDay)
    }

    func testHistoryReloadsFromDisk() throws {
        makeStore().record(series([9: 2]), at: try date(21))
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.series(on: try date(21))?.weights[.grok]?[9], 2)
        XCTAssertEqual(reloaded.earliestDay, try date(21, hour: 0))
    }

    func testDaysPastTheRetentionWindowAreDropped() throws {
        let store = makeStore()
        store.record(series([9: 1]), at: try date(1))
        store.record(series([9: 1]), at: try date(30))
        XCTAssertNotNil(store.series(on: try date(1)))

        // Thirty days including Oct 31 start on Oct 2, so Oct 1 is dropped.
        store.record(series([9: 1]), at: try date(31))
        XCTAssertNil(store.series(on: try date(1)))
        XCTAssertNotNil(store.series(on: try date(30)))
    }

    func testSeriesKeysAreSavedByName() throws {
        let data = try JSONEncoder().encode(series([0: 1]))
        let text = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"grok\""))
        XCTAssertEqual(try JSONDecoder().decode(OverviewDaySeries.self, from: data), series([0: 1]))
        XCTAssertNil(OverviewSeries(rawValue: "unknown"))
        XCTAssertEqual(OverviewSeries(rawValue: OverviewSeries.openCodeZen.rawValue), .openCodeZen)
    }

    // MARK: - Chart scaling

    func testSegmentHeightsAreProportionalAndSumToTheBar() {
        let heights = OverviewHourlyUsageChart.segmentHeights([1, 3], total: 40, minimum: 1)
        XCTAssertEqual(heights[0], 10, accuracy: 0.001)
        XCTAssertEqual(heights[1], 30, accuracy: 0.001)
    }

    func testThinSlicesAreLiftedWithoutOverflowingTheBar() {
        let heights = OverviewHourlyUsageChart.segmentHeights([0.001, 0.002, 10], total: 20, minimum: 1)
        XCTAssertEqual(heights.reduce(0, +), 20, accuracy: 0.001)
        XCTAssertEqual(heights[0], 1, accuracy: 0.001)
        XCTAssertEqual(heights[1], 1, accuracy: 0.001)
        XCTAssertEqual(heights[2], 18, accuracy: 0.001)
    }

    func testSlicesStayProportionalWhenTheBarIsTooShortForMinimums() {
        let heights = OverviewHourlyUsageChart.segmentHeights([1, 1, 2], total: 2, minimum: 1)
        XCTAssertEqual(heights.reduce(0, +), 2, accuracy: 0.001)
        XCTAssertEqual(heights[2], 1, accuracy: 0.001)
    }

    func testBarHeightFollowsActivityWithAVisibleMinimum() {
        XCTAssertEqual(OverviewHourlyUsageChart.barHeight(activity: 5, maxActivity: 10, trackHeight: 60), 30)
        XCTAssertEqual(OverviewHourlyUsageChart.barHeight(activity: 10, maxActivity: 10, trackHeight: 60), 60)
        XCTAssertEqual(OverviewHourlyUsageChart.barHeight(activity: 0.001, maxActivity: 10, trackHeight: 60), 3)
        XCTAssertEqual(OverviewHourlyUsageChart.barHeight(activity: 0, maxActivity: 10, trackHeight: 60), 0)
    }

    func testVisibleHoursWidenToIncludeLateAndEarlyActivity() {
        XCTAssertEqual(OverviewHourlyUsageChart.visibleHourRange(activeHours: [10]), 6...22)
        XCTAssertEqual(OverviewHourlyUsageChart.visibleHourRange(activeHours: [2, 23]), 2...23)
    }

    func testAxisLabelsMatchTheDefaultDayAndNeverCrowd() {
        XCTAssertEqual(OverviewHourlyUsageChart.axisHours(for: 6...22), [6, 9, 12, 15, 18, 22])
        XCTAssertEqual(OverviewHourlyUsageChart.axisHours(for: 2...23), [2, 6, 9, 12, 15, 18, 21, 23])
    }

    // MARK: - Day navigation

    func testDayTitles() throws {
        let day = try date(20)
        XCTAssertEqual(OverviewDailyUsageCard.title(dayOffset: 0, day: day), "Usage Today")
        XCTAssertEqual(OverviewDailyUsageCard.title(dayOffset: -1, day: day), "Usage Yesterday")
        XCTAssertTrue(OverviewDailyUsageCard.title(dayOffset: -2, day: day).hasPrefix("Usage "))
    }

    func testBackArrowNeedsAnEarlierSavedDay() throws {
        XCTAssertFalse(OverviewDailyUsageCard.canGoBack(from: try date(22), earliestDay: nil, calendar: calendar))
        XCTAssertFalse(OverviewDailyUsageCard.canGoBack(from: try date(22), earliestDay: try date(22, hour: 0), calendar: calendar))
        XCTAssertTrue(OverviewDailyUsageCard.canGoBack(from: try date(22), earliestDay: try date(21, hour: 0), calendar: calendar))
    }
}
