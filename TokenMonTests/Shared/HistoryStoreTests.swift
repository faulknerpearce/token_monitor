@testable import TokenMon
import XCTest

/// `HistoryStore` (in-memory SwiftData): same-day `recent` upsert, skip
/// window, 200-entry cap, and `clear`.
@MainActor
final class HistoryStoreTests: XCTestCase {
    private var store: HistoryStore!

    override func setUp() async throws {
        store = HistoryStore(inMemory: true)
    }

    private func snapshot(
        usedPercent: Double,
        minutesAgo: Double = 0,
        calendar: Calendar = .current
    ) -> WeeklyUsageSnapshot {
        WeeklyUsageSnapshot(
            fetchedAt: calendar.startOfDay(for: Date()).addingTimeInterval(60 * 60 * 12 - minutesAgo * 60),
            usedPercent: usedPercent
        )
    }

    func testAppendInsertsAtFrontOfRecent() {
        let cal = Calendar.current
        let yesterday = WeeklyUsageSnapshot(
            fetchedAt: cal.date(byAdding: .day, value: -1, to: Date()) ?? Date(),
            usedPercent: 20
        )
        let today = snapshot(usedPercent: 10)

        // Chronological order, as the poller appends.
        store.append(yesterday)
        store.append(today)

        XCTAssertEqual(store.recent.count, 2)
        XCTAssertEqual(store.recent.first?.usedPercent ?? -1, 10, "newest day must be first")
    }

    func testSecondSameDaySampleReplacesInsteadOfPrepending() {
        // Upsert by calendar day replaces in place, though each poll mints a
        // fresh snapshot id.
        let cal = Calendar.current
        let morning = WeeklyUsageSnapshot(fetchedAt: cal.startOfDay(for: Date()).addingTimeInterval(3600), usedPercent: 10)
        let afternoon = WeeklyUsageSnapshot(fetchedAt: cal.startOfDay(for: Date()).addingTimeInterval(3600 * 10), usedPercent: 42)
        let evening = WeeklyUsageSnapshot(fetchedAt: cal.startOfDay(for: Date()).addingTimeInterval(3600 * 20), usedPercent: 55)

        store.append(morning)
        store.append(afternoon)
        store.append(evening)

        XCTAssertEqual(store.recent.count, 1, "same-day samples must collapse to one recent entry")
        XCTAssertEqual(store.recent.first?.usedPercent ?? -1, 55)
        XCTAssertEqual(store.allSnapshots().count, 1, "disk keeps exactly one row per day")
    }

    func testTinyChangeWithinSixtySecondsIsSkipped() {
        let base = snapshot(usedPercent: 50, minutesAgo: 1)
        store.append(base)
        let noise = WeeklyUsageSnapshot(
            fetchedAt: base.fetchedAt.addingTimeInterval(30),
            usedPercent: base.usedPercent + 0.01
        )
        store.append(noise)

        XCTAssertEqual(store.recent.count, 1)
        XCTAssertEqual(store.recent.first?.usedPercent ?? -1, 50, "noise sample must not overwrite")
    }

    func testSignificantChangeWithinSixtySecondsIsKept() {
        let base = snapshot(usedPercent: 50, minutesAgo: 1)
        store.append(base)
        let jump = WeeklyUsageSnapshot(
            fetchedAt: base.fetchedAt.addingTimeInterval(30),
            usedPercent: base.usedPercent + 5
        )
        store.append(jump)

        XCTAssertEqual(store.recent.count, 1)
        XCTAssertEqual(store.recent.first?.usedPercent ?? -1, 55, "real movement replaces same-day entry")
    }

    func testDifferentDaysProduceDistinctEntries() {
        let cal = Calendar.current
        let today = WeeklyUsageSnapshot(fetchedAt: Date(), usedPercent: 10)
        let yesterday = WeeklyUsageSnapshot(
            fetchedAt: cal.date(byAdding: .day, value: -1, to: Date()) ?? Date(),
            usedPercent: 20
        )

        store.append(today)
        store.append(yesterday)

        XCTAssertEqual(store.recent.count, 2)
    }

    func testRecentCapEvictsOldest() {
        let cal = Calendar.current
        for offset in stride(from: 250, through: 1, by: -1) {
            let day = cal.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            store.append(WeeklyUsageSnapshot(fetchedAt: day, usedPercent: Double(offset % 100)))
        }

        XCTAssertLessThanOrEqual(store.recent.count, 200)
        XCTAssertEqual(store.allSnapshots().count, 250, "disk is not capped")
    }

    func testClearEmptiesRecentAndDisk() {
        store.append(snapshot(usedPercent: 33))
        store.flush()

        store.clear()

        XCTAssertTrue(store.recent.isEmpty)
        XCTAssertTrue(store.allSnapshots().isEmpty)
    }
}
