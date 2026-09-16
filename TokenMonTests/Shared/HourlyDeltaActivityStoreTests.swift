@testable import TokenMon
import XCTest

@MainActor
final class HourlyDeltaActivityStoreTests: XCTestCase {
    private func makeStore(key: String = "test_hourly") -> (HourlyDeltaActivityStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileBackedStringStore(directory: dir, filenamePrefix: "activity_")
        return (HourlyDeltaActivityStore(store: store, storageKey: key), dir)
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps)!
    }

    func testGrowthWithinAWindowIsAttributedToTheSampledHour() {
        let (activity, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        activity.record(usedPercent: 10, at: date(hour: 9))
        activity.record(usedPercent: 25, at: date(hour: 9, minute: 30))

        XCTAssertEqual(activity.hourWeights[9], 15, accuracy: 0.001)
    }

    func testWindowResetAttributesPostResetValueInsteadOfDroppingIt() {
        // A window reset (used-percent drops) credits the usage already accrued
        // in the new window to the hour it was observed in.
        let (activity, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        activity.record(usedPercent: 95, at: date(hour: 9))
        // Window resets and 15% of new-window quota is already used by the next poll.
        activity.record(usedPercent: 15, at: date(hour: 10))

        XCTAssertEqual(activity.hourWeights[9], 0, accuracy: 0.001)
        XCTAssertEqual(activity.hourWeights[10], 15, accuracy: 0.001)
    }

    func testTinyDeltaIsIgnoredAsNoise() {
        let (activity, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        activity.record(usedPercent: 10, at: date(hour: 9))
        activity.record(usedPercent: 10.01, at: date(hour: 9, minute: 5))

        XCTAssertEqual(activity.hourWeights[9], 0, accuracy: 0.001)
    }

    /// A small downward tick must not be credited as a full window reset.
    func testSmallDownwardNoiseIsNotCreditedAsReset() {
        let (activity, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        activity.record(usedPercent: 50.0, at: date(hour: 9))
        activity.record(usedPercent: 49.9, at: date(hour: 9, minute: 5))

        XCTAssertEqual(activity.hourWeights[9], 0, accuracy: 0.001)
    }

    func testDifferentKeysDoNotCollideOnDisk() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileBackedStringStore(directory: dir, filenamePrefix: "activity_")

        let storeA = HourlyDeltaActivityStore(store: store, storageKey: "provider_a")
        let storeB = HourlyDeltaActivityStore(store: store, storageKey: "provider_b")
        storeA.record(usedPercent: 20, at: date(hour: 8))
        storeA.record(usedPercent: 30, at: date(hour: 8))
        storeB.record(usedPercent: 5, at: date(hour: 8))
        storeB.record(usedPercent: 6, at: date(hour: 8))

        XCTAssertEqual(storeA.hourWeights[8], 10, accuracy: 0.001)
        XCTAssertEqual(storeB.hourWeights[8], 1, accuracy: 0.001)
    }

    /// Sign-out / account switch must wipe the series and baseline so one
    /// account's growth never appears in the next account's chart.
    func testClearResetsSeriesAndBaseline() {
        let (activity, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        activity.record(usedPercent: 10, at: date(hour: 9))
        activity.record(usedPercent: 40, at: date(hour: 9, minute: 30))
        activity.clear()
        XCTAssertEqual(activity.hourWeights, Array(repeating: 0, count: 24))

        // A new account's first sample after clear is not compared to the old 40.
        activity.record(usedPercent: 5, at: date(hour: 10))
        XCTAssertEqual(activity.hourWeights[10], 0, accuracy: 0.001)
        activity.record(usedPercent: 12, at: date(hour: 11))
        XCTAssertEqual(activity.hourWeights[11], 7, accuracy: 0.001)
    }

    /// A known window rollover credits the first sample whole even when it is
    /// already above the old window's last value.
    func testBeginNewWindowCreditsRisingFirstSample() {
        let (activity, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        activity.record(usedPercent: 20, at: date(hour: 9))
        activity.beginNewWindow()
        activity.record(usedPercent: 30, at: date(hour: 10))
        XCTAssertEqual(activity.hourWeights[10], 30, accuracy: 0.001)
    }
}
