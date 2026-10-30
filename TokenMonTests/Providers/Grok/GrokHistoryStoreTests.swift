import SwiftData
@testable import TokenMon
import XCTest

/// `GrokHistoryStore` (in-memory SwiftData): same-day `recent` upsert, skip
/// window, 200-entry cap, and `clear`.
@MainActor
final class GrokHistoryStoreTests: XCTestCase {
    private var store: GrokHistoryStore!

    override func setUp() async throws {
        store = GrokHistoryStore(inMemory: true)
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

    // MARK: - Accounts

    /// Another account's same-day poll gets its own row beside the first
    /// account's, and `recent` shows only the active account.
    func testRowsAreKeyedByAccount() {
        let start = Calendar.current.startOfDay(for: Date())
        store.append(WeeklyUsageSnapshot(fetchedAt: start.addingTimeInterval(3600), usedPercent: 40, accountEmail: "a@example.com"))
        store.append(WeeklyUsageSnapshot(fetchedAt: start.addingTimeInterval(7200), usedPercent: 5, accountEmail: "b@example.com"))

        XCTAssertEqual(store.allSnapshots().count, 2)
        XCTAssertEqual(store.activeAccount, "b@example.com")
        XCTAssertEqual(store.recent.map(\.usedPercent), [5])

        store.setActiveAccount("a@example.com")
        XCTAssertEqual(store.recent.map(\.usedPercent), [40])
    }

    func testUnchangedUsageLaterTheSameDayLeavesTheRowAlone() {
        let first = snapshot(usedPercent: 30, minutesAgo: 120)
        store.append(first)
        store.append(snapshot(usedPercent: 30, minutesAgo: 0))
        XCTAssertEqual(store.recent.first?.fetchedAt, first.fetchedAt, "an identical idle poll is not re-saved")
        XCTAssertEqual(store.allSnapshots().first?.fetchedAt, first.fetchedAt)

        let changed = snapshot(usedPercent: 31, minutesAgo: 0)
        store.append(changed)
        XCTAssertEqual(store.recent.first?.usedPercent ?? -1, 31, accuracy: 0.001)
    }

    // MARK: - Saved file

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testHistoryIsSavedAndReloaded() throws {
        let dir = try tempDirectory()
        let file = FileBackedStringStore(directory: dir, filenamePrefix: "grok_")
        let first = GrokHistoryStore(store: file, legacyStoreURL: nil)
        first.append(snapshot(usedPercent: 42))
        first.flush()

        let reloaded = GrokHistoryStore(store: file, legacyStoreURL: nil)
        XCTAssertEqual(reloaded.allSnapshots().map(\.usedPercent), [42])
        XCTAssertEqual(reloaded.recent.count, 1)
        XCTAssertFalse(reloaded.storeFailed)
    }

    /// An unreadable file is reported and never written over.
    func testUnreadableHistoryIsKept() throws {
        let dir = try tempDirectory()
        let file = FileBackedStringStore(directory: dir, filenamePrefix: "grok_")
        file.set("not json", forKey: "history")
        let store = GrokHistoryStore(store: file, legacyStoreURL: nil)
        XCTAssertTrue(store.storeFailed)
        store.append(snapshot(usedPercent: 10))
        store.flush()
        XCTAssertEqual(file.value(forKey: "history"), "not json")
        XCTAssertEqual(store.recent.count, 1, "the session still keeps history in memory")
    }

    /// Rows saved by earlier versions in SwiftData are carried into the file
    /// once; the SwiftData store is left in place.
    func testSwiftDataHistoryIsImportedOnce() throws {
        let dir = try tempDirectory()
        let legacyURL = dir.appendingPathComponent("history.store")
        let container = try ModelContainer(
            for: UsageSnapshotRecord.self,
            configurations: ModelConfiguration(url: legacyURL)
        )
        let context = ModelContext(container)
        let day = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()
        context.insert(UsageSnapshotRecord(from: WeeklyUsageSnapshot(fetchedAt: day, usedPercent: 17, accountEmail: "a@example.com")))
        try context.save()

        let file = FileBackedStringStore(directory: dir, filenamePrefix: "grok_")
        let imported = GrokHistoryStore(store: file, legacyStoreURL: legacyURL)
        XCTAssertEqual(imported.allSnapshots().map(\.usedPercent), [17])
        XCTAssertNotNil(file.value(forKey: "history"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        // The file now exists, so a later launch reads it and imports nothing.
        imported.clear()
        let later = GrokHistoryStore(store: file, legacyStoreURL: legacyURL)
        XCTAssertTrue(later.allSnapshots().isEmpty)
    }
}
