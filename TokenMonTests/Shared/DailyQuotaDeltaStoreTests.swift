@testable import TokenMon
import XCTest

@MainActor
final class DailyQuotaDeltaStoreTests: XCTestCase {
    private func makeStore(key: String = "test_weekly_daily") -> (DailyQuotaDeltaStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileBackedStringStore(directory: dir, filenamePrefix: "activity_")
        return (DailyQuotaDeltaStore(store: store, storageKey: key), dir)
    }

    private func date(dayOffset: Int, hour: Int, minute: Int = 0) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.day = (comps.day ?? 1) + dayOffset
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps)!
    }

    func testGrowthIsAttributedToTheSampledDay() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(windowUsedPercent: 10, at: date(dayOffset: 0, hour: 9))
        store.record(windowUsedPercent: 25, at: date(dayOffset: 0, hour: 10))

        let today = Calendar.current.startOfDay(for: date(dayOffset: 0, hour: 0))
        XCTAssertEqual(store.spentByDay[today] ?? 0, 15, accuracy: 0.001)
    }

    func testWindowResetAttributesPostResetValueToTheSampledDay() {
        // A window reset (used-percent drops) must not silently discard the usage
        // that already accrued in the new window before the next poll — it should
        // be credited to the day it was observed in.
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(windowUsedPercent: 40, at: date(dayOffset: 0, hour: 9))
        store.record(windowUsedPercent: 60, at: date(dayOffset: 0, hour: 10))
        // Window resets and 25% of the new window is already used by the next poll.
        store.record(windowUsedPercent: 25, at: date(dayOffset: 0, hour: 11))

        let today = Calendar.current.startOfDay(for: date(dayOffset: 0, hour: 0))
        XCTAssertEqual(store.spentByDay[today] ?? 0, 45, accuracy: 0.001)
    }

    func testGrowthContinuesAfterWindowReset() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(windowUsedPercent: 60, at: date(dayOffset: 0, hour: 10))
        store.record(windowUsedPercent: 25, at: date(dayOffset: 0, hour: 11))
        store.record(windowUsedPercent: 30, at: date(dayOffset: 0, hour: 12))

        let today = Calendar.current.startOfDay(for: date(dayOffset: 0, hour: 0))
        XCTAssertEqual(store.spentByDay[today] ?? 0, 30, accuracy: 0.001)
    }

    func testTinyDeltaIsIgnoredAsNoise() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(windowUsedPercent: 10, at: date(dayOffset: 0, hour: 9))
        store.record(windowUsedPercent: 10.01, at: date(dayOffset: 0, hour: 9, minute: 5))

        let today = Calendar.current.startOfDay(for: date(dayOffset: 0, hour: 0))
        XCTAssertEqual(store.spentByDay[today] ?? 0, 0, accuracy: 0.001)
    }

    func testOldDaysArePrunedToRetentionWindow() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(windowUsedPercent: 5, at: date(dayOffset: -40, hour: 9))
        store.record(windowUsedPercent: 9, at: date(dayOffset: -40, hour: 10))
        store.record(windowUsedPercent: 10, at: date(dayOffset: 0, hour: 9))
        store.record(windowUsedPercent: 20, at: date(dayOffset: 0, hour: 10))

        let today = Calendar.current.startOfDay(for: date(dayOffset: 0, hour: 0))
        XCTAssertEqual(store.spentByDay.count, 1)
        XCTAssertEqual(store.spentByDay[today] ?? 0, 11, accuracy: 0.001)
    }

    func testBeginNewWindowClearsDaysAndNextSampleIsCreditedAsReset() {
        // A quota-window rollover drops finished-period day totals while the
        // baseline survives, so the first sample of the fresh window is
        // credited whole via the drop-as-reset path instead of being lost.
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(windowUsedPercent: 40, at: date(dayOffset: 0, hour: 9))
        store.record(windowUsedPercent: 60, at: date(dayOffset: 0, hour: 10))
        store.beginNewWindow()
        XCTAssertTrue(store.spentByDay.isEmpty)

        // New period already burned 25% by the next poll.
        store.record(windowUsedPercent: 25, at: date(dayOffset: 0, hour: 11))

        let today = Calendar.current.startOfDay(for: date(dayOffset: 0, hour: 0))
        XCTAssertEqual(store.spentByDay.count, 1)
        XCTAssertEqual(store.spentByDay[today] ?? 0, 25, accuracy: 0.001)
    }

    func testReloadRestoresPersistedDaysAndBaseline() {
        let (store, dir) = makeStore()
        store.record(windowUsedPercent: 10, at: date(dayOffset: 0, hour: 9))
        store.record(windowUsedPercent: 22, at: date(dayOffset: 0, hour: 10))

        // Fresh instance over the same backing store continues the baseline.
        let reloaded = DailyQuotaDeltaStore(store: FileBackedStringStore(directory: dir, filenamePrefix: "activity_"), storageKey: "test_weekly_daily")
        defer { try? FileManager.default.removeItem(at: dir) }

        reloaded.record(windowUsedPercent: 27, at: date(dayOffset: 0, hour: 11))
        let today = Calendar.current.startOfDay(for: date(dayOffset: 0, hour: 0))
        XCTAssertEqual(reloaded.spentByDay[today] ?? 0, 17, accuracy: 0.001)
    }
}
