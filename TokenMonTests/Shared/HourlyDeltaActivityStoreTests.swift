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

    /// An early provider reset restarts the baseline but keeps the hours already
    /// recorded today: they are real activity from before the reset.
    func testBeginNewWindowKeepingHoursPreservesTodaysSeries() {
        let (activity, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        activity.record(usedPercent: 20, at: date(hour: 8))
        activity.record(usedPercent: 35, at: date(hour: 9))
        activity.beginNewWindow(keepingHours: true)
        activity.record(usedPercent: 4, at: date(hour: 11))

        XCTAssertEqual(activity.hourWeights[9], 15, accuracy: 0.001)
        XCTAssertEqual(activity.hourWeights[11], 4, accuracy: 0.001)
    }

    func testUnchangedSampleDoesNotRewriteTheFile() throws {
        let (activity, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("activity_test_hourly.dat")

        activity.record(usedPercent: 10, at: date(hour: 9))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.removeItem(at: file)

        activity.record(usedPercent: 10, at: date(hour: 9, minute: 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "same state, no write")

        activity.record(usedPercent: 12, at: date(hour: 9, minute: 10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a change is written")
    }

    // MARK: - Midnight, time zones, and older payloads

    private func denver() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        return calendar
    }

    private func makeBacking() throws -> (FileBackedStringStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (FileBackedStringStore(directory: dir, filenamePrefix: "activity_"), dir)
    }

    /// Growth between the last sample before midnight and the first after it is
    /// credited to the new day's first hour instead of being dropped.
    func testFirstDeltaAfterMidnightIsCredited() throws {
        let (backing, dir) = try makeBacking()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = try denver()
        let lateEvening = Date(timeIntervalSinceReferenceDate: 811_144_800 - 300)
        let activity = HourlyDeltaActivityStore(store: backing, storageKey: "midnight", calendar: calendar, now: lateEvening)
        activity.record(usedPercent: 20, at: lateEvening)
        activity.record(usedPercent: 27, at: lateEvening.addingTimeInterval(600))

        XCTAssertEqual(activity.dayStart, Date(timeIntervalSinceReferenceDate: 811_144_800))
        XCTAssertEqual(activity.hourWeights[0], 7, accuracy: 0.001)
        XCTAssertEqual(activity.hourWeights.reduce(0, +), 7, accuracy: 0.001)
    }

    /// The older payload shape (day named by its start instant only) restores
    /// today's hours and is rewritten with a day key.
    func testOlderPayloadRestoresTodayAndIsRewritten() throws {
        let (backing, dir) = try makeBacking()
        defer { try? FileManager.default.removeItem(at: dir) }
        var weights = Array(repeating: 0.0, count: 24)
        weights[9] = 4
        weights[14] = 2.5
        let list = weights.map { String($0) }.joined(separator: ",")
        backing.set(#"{"dayStart":813304800,"hourWeights":["# + list + #"],"lastUsedPercent":30}"#, forKey: "grok_hourly_today")
        let afternoon = Date(timeIntervalSinceReferenceDate: 813_304_800 + 15 * 3_600)

        let activity = HourlyDeltaActivityStore(
            store: backing,
            storageKey: "grok_hourly_today",
            calendar: try denver(),
            now: afternoon
        )

        XCTAssertEqual(activity.hourWeights, weights)
        XCTAssertEqual(activity.dayStart, Date(timeIntervalSinceReferenceDate: 813_304_800))
        activity.record(usedPercent: 33, at: afternoon)
        XCTAssertEqual(activity.hourWeights[15], 3, accuracy: 0.001)
        let rewritten = try XCTUnwrap(backing.value(forKey: "grok_hourly_today"))
        XCTAssertTrue(rewritten.contains("\"dayKey\":\"2026-10-10\""), rewritten)
    }

    /// An older payload from a previous day starts today empty, with no baseline.
    func testOlderPayloadFromAnotherDayStartsFresh() throws {
        let (backing, dir) = try makeBacking()
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = Array(repeating: "1", count: 24).joined(separator: ",")
        backing.set(#"{"dayStart":813304800,"hourWeights":["# + list + #"],"lastUsedPercent":30}"#, forKey: "old")
        let nextDay = Date(timeIntervalSinceReferenceDate: 813_304_800 + 30 * 3_600)

        let activity = HourlyDeltaActivityStore(store: backing, storageKey: "old", calendar: try denver(), now: nextDay)
        activity.record(usedPercent: 50, at: nextDay)

        XCTAssertEqual(activity.hourWeights.reduce(0, +), 0, accuracy: 0.001)
    }
}
