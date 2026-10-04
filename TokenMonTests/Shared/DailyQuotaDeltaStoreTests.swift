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

    /// A small downward tick (rounding/rebase noise) must not be credited as a
    /// full window reset; `50.0 -> 49.9` used to add 49.9 to the day.
    func testSmallDownwardNoiseIsNotCreditedAsReset() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(windowUsedPercent: 50.0, at: date(dayOffset: 0, hour: 9))
        store.record(windowUsedPercent: 49.9, at: date(dayOffset: 0, hour: 9, minute: 5))

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

    /// A known rollover credits the fresh window's first sample whole even when
    /// it is already above the old window's last value (20% → 30%).
    func testBeginNewWindowCreditsRisingFirstSample() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(windowUsedPercent: 20, at: date(dayOffset: 0, hour: 9))
        store.beginNewWindow()
        store.record(windowUsedPercent: 30, at: date(dayOffset: 0, hour: 10))

        let today = Calendar.current.startOfDay(for: date(dayOffset: 0, hour: 0))
        XCTAssertEqual(store.spentByDay[today] ?? 0, 30, accuracy: 0.001)
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

    // MARK: - Provider-initiated early resets

    private func day(_ offset: Int) -> Date {
        Calendar.current.startOfDay(for: date(dayOffset: offset, hour: 0))
    }

    /// A weekly window that opened at `startOffset` days from today (08:00).
    private func weekWindow(startOffset: Int, resetOffset: Int? = nil) -> QuotaWindow {
        QuotaWindow(
            start: date(dayOffset: startOffset, hour: 8),
            resetsAt: date(dayOffset: resetOffset ?? startOffset + 7, hour: 8)
        )
    }

    /// Builds history in a window that opened three days ago: 20 points on each of
    /// the two days before today.
    private func seedOldWindow(_ store: DailyQuotaDeltaStore) {
        let window = weekWindow(startOffset: -3)
        store.record(windowUsedPercent: 10, at: date(dayOffset: -3, hour: 12), window: window)
        store.record(windowUsedPercent: 30, at: date(dayOffset: -2, hour: 9), window: window)
        store.record(windowUsedPercent: 50, at: date(dayOffset: -1, hour: 9), window: window)
    }

    func testEarlyResetPreservesPriorDaysAndCreditsFirstPostResetSample() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        seedOldWindow(store)

        // Provider resets everyone today, long before the old window's reset day.
        let transition = store.record(
            windowUsedPercent: 4,
            at: date(dayOffset: 0, hour: 9),
            window: weekWindow(startOffset: 0, resetOffset: 7)
        )

        XCTAssertEqual(transition, .earlyReset)
        XCTAssertEqual(store.spentByDay[day(-2)] ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(store.spentByDay[day(-1)] ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(store.spentByDay[day(0)] ?? 0, 4, accuracy: 0.001)
        XCTAssertEqual(store.windowStart, date(dayOffset: 0, hour: 8))
        XCTAssertEqual(store.interruptedWindowStart, date(dayOffset: -3, hour: 8))
    }

    /// The baseline restarts at 0, so the first post-reset sample is credited to
    /// the new window even when it is above the old window's last value.
    func testEarlyResetBaselineCreditsFirstSampleWhole() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = weekWindow(startOffset: -3)
        store.record(windowUsedPercent: 40, at: date(dayOffset: -1, hour: 9), window: window)
        store.record(windowUsedPercent: 8, at: date(dayOffset: 0, hour: 9), window: weekWindow(startOffset: 0))
        store.record(windowUsedPercent: 11, at: date(dayOffset: 0, hour: 10), window: weekWindow(startOffset: 0))

        XCTAssertEqual(store.spentByDay[day(0)] ?? 0, 11, accuracy: 0.001)
        XCTAssertEqual(store.lastUsedPercent ?? -1, 11, accuracy: 0.001)
    }

    /// Usage already recorded today belongs to the old window; it shares a calendar
    /// day with the new one, so it is dropped rather than inflating the new bar.
    func testEarlyResetDropsOnlyTheBoundaryDay() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        seedOldWindow(store)
        let old = weekWindow(startOffset: -3)
        store.record(windowUsedPercent: 58, at: date(dayOffset: 0, hour: 7), window: old)
        XCTAssertEqual(store.spentByDay[day(0)] ?? 0, 8, accuracy: 0.001)

        store.record(windowUsedPercent: 2, at: date(dayOffset: 0, hour: 9), window: weekWindow(startOffset: 0))
        XCTAssertEqual(store.spentByDay[day(0)] ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(store.spentByDay[day(-1)] ?? 0, 20, accuracy: 0.001)
    }

    func testNormalRolloverStillStartsFreshWindowAndKeepsEarlierDays() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Old window ran its full course: it resets this morning at 08:00.
        let old = QuotaWindow(start: date(dayOffset: -7, hour: 8), resetsAt: date(dayOffset: 0, hour: 8))
        store.record(windowUsedPercent: 30, at: date(dayOffset: -2, hour: 9), window: old)
        store.record(windowUsedPercent: 70, at: date(dayOffset: -1, hour: 9), window: old)

        let transition = store.record(
            windowUsedPercent: 3,
            at: date(dayOffset: 0, hour: 9),
            window: QuotaWindow(start: date(dayOffset: 0, hour: 8), resetsAt: date(dayOffset: 7, hour: 8))
        )

        XCTAssertEqual(transition, .rollover)
        XCTAssertEqual(store.spentByDay[day(-1)] ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(store.spentByDay[day(0)] ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(store.windowStart, date(dayOffset: 0, hour: 8))
        // A normal rollover is not an interrupted window: nothing is flagged as prior.
        XCTAssertNil(store.interruptedWindowStart)
    }

    func testDropWithUnchangedWindowIsARebaseNotAnEarlyReset() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = weekWindow(startOffset: -3)
        store.record(windowUsedPercent: 60, at: date(dayOffset: -1, hour: 9), window: window)
        let transition = store.record(windowUsedPercent: 20, at: date(dayOffset: 0, hour: 9), window: window)

        XCTAssertEqual(transition, .none)
        XCTAssertNil(store.interruptedWindowStart)
    }

    func testMovedWindowWithoutUsageDropIsNotAReset() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(windowUsedPercent: 30, at: date(dayOffset: -1, hour: 9), window: weekWindow(startOffset: -3))
        let transition = store.record(
            windowUsedPercent: 32,
            at: date(dayOffset: 0, hour: 9),
            window: weekWindow(startOffset: 0)
        )
        XCTAssertEqual(transition, .none)
        XCTAssertEqual(store.spentByDay[day(0)] ?? 0, 2, accuracy: 0.001)
    }

    /// Claude sends only `resets_at`; the window start is the reset minus one period.
    func testEarlyResetWithoutPeriodStartDerivesStartFromResetInstant() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = QuotaWindow(start: nil, resetsAt: date(dayOffset: 4, hour: 8))
        store.record(windowUsedPercent: 20, at: date(dayOffset: -1, hour: 9), window: old)
        store.record(windowUsedPercent: 45, at: date(dayOffset: -1, hour: 20), window: old)

        let transition = store.record(
            windowUsedPercent: 1,
            at: date(dayOffset: 0, hour: 9),
            window: QuotaWindow(start: nil, resetsAt: date(dayOffset: 7, hour: 8))
        )

        XCTAssertEqual(transition, .earlyReset)
        XCTAssertEqual(store.spentByDay[day(-1)] ?? 0, 25, accuracy: 0.001)
        XCTAssertEqual(store.windowStart, date(dayOffset: 0, hour: 8))
        XCTAssertEqual(store.interruptedWindowStart, date(dayOffset: -3, hour: 8))
    }

    func testWindowMetadataSurvivesRelaunchSoAnEarlyResetWhileClosedIsStillSeen() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        seedOldWindow(store)

        let reloaded = DailyQuotaDeltaStore(
            store: FileBackedStringStore(directory: dir, filenamePrefix: "activity_"),
            storageKey: "test_weekly_daily"
        )
        XCTAssertEqual(reloaded.windowResetsAt, date(dayOffset: 4, hour: 8))
        let transition = reloaded.record(
            windowUsedPercent: 5,
            at: date(dayOffset: 0, hour: 9),
            window: weekWindow(startOffset: 0)
        )
        XCTAssertEqual(transition, .earlyReset)

        let again = DailyQuotaDeltaStore(
            store: FileBackedStringStore(directory: dir, filenamePrefix: "activity_"),
            storageKey: "test_weekly_daily"
        )
        XCTAssertEqual(again.windowStart, date(dayOffset: 0, hour: 8))
        XCTAssertEqual(again.interruptedWindowStart, date(dayOffset: -3, hour: 8))
        XCTAssertEqual(again.spentByDay[day(-1)] ?? 0, 20, accuracy: 0.001)
    }

    /// Payloads written before window metadata existed must still load, with the
    /// days and baseline intact and no window boundary.
    func testLegacyPayloadWithoutWindowMetadataStillDecodes() throws {
        struct LegacyPayload: Codable {
            var days: [Date: Double]
            var lastUsedPercent: Double?
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = FileBackedStringStore(directory: dir, filenamePrefix: "activity_")
        let legacy = LegacyPayload(days: [day(-1): 12.5], lastUsedPercent: 40)
        backing.set(String(data: try JSONEncoder().encode(legacy), encoding: .utf8) ?? "", forKey: "legacy_daily")

        let store = DailyQuotaDeltaStore(store: backing, storageKey: "legacy_daily")

        XCTAssertEqual(store.spentByDay[day(-1)] ?? 0, 12.5, accuracy: 0.001)
        XCTAssertEqual(store.lastUsedPercent ?? 0, 40, accuracy: 0.001)
        XCTAssertNil(store.windowStart)
        XCTAssertNil(store.windowResetsAt)
        XCTAssertNil(store.interruptedWindowStart)

        // With no stored window to compare against, the first windowed sample just
        // records metadata; it is never mistaken for a reset.
        let transition = store.record(
            windowUsedPercent: 45,
            at: date(dayOffset: 0, hour: 9),
            window: weekWindow(startOffset: -1)
        )
        XCTAssertEqual(transition, .none)
        XCTAssertEqual(store.spentByDay[day(0)] ?? 0, 5, accuracy: 0.001)
    }

    func testClearDropsWindowMetadata() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        seedOldWindow(store)
        store.record(windowUsedPercent: 4, at: date(dayOffset: 0, hour: 9), window: weekWindow(startOffset: 0))
        store.clear()
        XCTAssertNil(store.windowStart)
        XCTAssertNil(store.windowResetsAt)
        XCTAssertNil(store.interruptedWindowStart)
        XCTAssertTrue(store.spentByDay.isEmpty)
    }

    // MARK: - QuotaWindowTransition.classify

    private func classify(
        previous: QuotaWindow,
        previousUsed: Double?,
        next: QuotaWindow,
        used: Double,
        now: Date
    ) -> QuotaWindowTransition {
        QuotaWindowTransition.classify(
            from: previous,
            previousUsedPercent: previousUsed,
            to: next,
            usedPercent: used,
            periodDays: 7,
            now: now
        )
    }

    func testClassifyNeedsProviderMetadataOnBothSides() {
        let now = date(dayOffset: 0, hour: 9)
        XCTAssertEqual(
            classify(previous: QuotaWindow(), previousUsed: 60, next: weekWindow(startOffset: 0), used: 2, now: now),
            .none
        )
        XCTAssertEqual(
            classify(previous: weekWindow(startOffset: -3), previousUsed: 60, next: QuotaWindow(), used: 2, now: now),
            .none
        )
    }

    func testClassifyEarlyResetRequiresAUsageDrop() {
        let now = date(dayOffset: 0, hour: 9)
        let previous = weekWindow(startOffset: -3)
        let next = weekWindow(startOffset: 0)
        XCTAssertEqual(classify(previous: previous, previousUsed: 60, next: next, used: 2, now: now), .earlyReset)
        XCTAssertEqual(classify(previous: previous, previousUsed: 60, next: next, used: 58, now: now), .none)
        XCTAssertEqual(classify(previous: previous, previousUsed: nil, next: next, used: 2, now: now), .none)
    }

    /// The reset instant alone moving by more than the jitter threshold is enough
    /// when the provider sends no period start.
    func testClassifyIgnoresResetInstantJitter() {
        let now = date(dayOffset: 0, hour: 9)
        let previous = QuotaWindow(start: nil, resetsAt: date(dayOffset: 4, hour: 8))
        let jitter = QuotaWindow(start: nil, resetsAt: date(dayOffset: 4, hour: 8).addingTimeInterval(30))
        XCTAssertEqual(classify(previous: previous, previousUsed: 60, next: jitter, used: 2, now: now), .none)
        let moved = QuotaWindow(start: nil, resetsAt: date(dayOffset: 7, hour: 8))
        XCTAssertEqual(classify(previous: previous, previousUsed: 60, next: moved, used: 2, now: now), .earlyReset)
    }

    /// A reset instant that advances by nearly a whole period while the old one
    /// is still ahead is an early reset, not a scheduled rollover.
    func testClassifyLateEarlyResetIsNotMistakenForRollover() {
        let now = date(dayOffset: 0, hour: 9)
        let previous = QuotaWindow(start: date(dayOffset: -6, hour: 8), resetsAt: date(dayOffset: 1, hour: 8))
        let next = QuotaWindow(start: date(dayOffset: 0, hour: 8), resetsAt: date(dayOffset: 7, hour: 8))
        XCTAssertEqual(classify(previous: previous, previousUsed: 90, next: next, used: 1, now: now), .earlyReset)
    }

    func testClassifyRolloverNeedsOldResetPassedAndHalfPeriodAdvance() {
        let now = date(dayOffset: 0, hour: 9)
        let previous = QuotaWindow(start: date(dayOffset: -7, hour: 8), resetsAt: date(dayOffset: 0, hour: 8))
        let next = QuotaWindow(start: date(dayOffset: 0, hour: 8), resetsAt: date(dayOffset: 7, hour: 8))
        XCTAssertEqual(classify(previous: previous, previousUsed: 70, next: next, used: 3, now: now), .rollover)
        let creep = QuotaWindow(start: nil, resetsAt: date(dayOffset: 1, hour: 8))
        XCTAssertEqual(classify(previous: previous, previousUsed: 70, next: creep, used: 3, now: now), .none)
    }
}
