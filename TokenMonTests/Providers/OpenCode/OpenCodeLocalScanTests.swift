import SQLite3
@testable import TokenMon
import XCTest

/// Message-time windows, consistent monthly totals, and the scan cache.
final class OpenCodeLocalScanTests: XCTestCase {
    private var dbURL: URL!
    private let now = Date(timeIntervalSince1970: 1_785_592_600)

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmon-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("opencode.db")
        try exec("""
        CREATE TABLE session (
            id TEXT, time_created INTEGER NOT NULL, cost REAL NOT NULL DEFAULT 0,
            tokens_input INTEGER NOT NULL DEFAULT 0, tokens_output INTEGER NOT NULL DEFAULT 0,
            tokens_cache_read INTEGER NOT NULL DEFAULT 0, tokens_cache_write INTEGER NOT NULL DEFAULT 0,
            time_archived INTEGER, model TEXT NOT NULL
        );
        CREATE TABLE message (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
        );
        """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
    }

    // MARK: - Windows use message time

    func testSessionStartedBeforeRollingWindowCountsItsRecentMessages() throws {
        session("s1", at: now.addingTimeInterval(-6 * 3600))
        message("s1", at: now.addingTimeInterval(-7 * 3600 + 3600), cost: 1)
        message("s1", at: now.addingTimeInterval(-3600), cost: 3)

        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)
        let rolling = try XCTUnwrap(snap.windows.first { $0.kind == .rolling5h })
        XCTAssertEqual(rolling.usedUSD, 3, accuracy: 0.001)
        XCTAssertEqual(rolling.sessionCount, 1)
    }

    func testLongSessionSplitsAcrossWeeksByMessageTime() throws {
        let week = OpenCodeLocalStats.weeklyBounds(now: now)
        session("s1", at: week.start.addingTimeInterval(-3 * 86400))
        message("s1", at: week.start.addingTimeInterval(-2 * 86400), cost: 5)
        message("s1", at: week.start.addingTimeInterval(3600), cost: 2)

        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)
        let weekly = try XCTUnwrap(snap.windows.first { $0.kind == .weekly })
        XCTAssertEqual(weekly.usedUSD, 2, accuracy: 0.001)
    }

    /// Monthly figures come from the month's messages only: a heavy day in the
    /// UTC week but before the billing month does not inflate them, and total
    /// tokens always equal the sum of their parts.
    func testMonthlyTotalsComeFromTheMonthOnly() throws {
        let week = OpenCodeLocalStats.weeklyBounds(now: now)
        let monthStart = week.start.addingTimeInterval(86400)
        // Subscription anchor whose monthly cycle starts one day into this week.
        session("anchor", at: Self.anchor(for: monthStart))
        message("anchor", at: week.start.addingTimeInterval(3600), cost: 40, input: 900, output: 900)
        message("anchor", at: monthStart.addingTimeInterval(3600), cost: 2, input: 10, output: 5, cacheRead: 7, cacheWrite: 3)

        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)
        let monthly = try XCTUnwrap(snap.windows.first { $0.kind == .monthly })
        XCTAssertEqual(monthly.usedUSD, 2, accuracy: 0.001)
        XCTAssertEqual(snap.monthlyEstimatedUSD, 2, accuracy: 0.001)
        XCTAssertEqual(snap.monthlyInputTokens, 10)
        XCTAssertEqual(snap.monthlyOutputTokens, 5)
        XCTAssertEqual(snap.monthlyTokens, 25)
    }

    /// A Go row recorded at `$0` is valued the same way in the headline window
    /// and in the daily bars.
    func testHeadlineAndDailyBarsValueZeroCostGoRowsAlike() throws {
        session("s1", at: now.addingTimeInterval(-3600))
        message("s1", at: now.addingTimeInterval(-3600), cost: 0, input: 1_000_000, model: "minimax-m3")

        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)
        let weekly = try XCTUnwrap(snap.windows.first { $0.kind == .weekly })
        XCTAssertGreaterThan(weekly.usedUSD, 0)
        let spends = OpenCodeLocalStats.fetchDailySpends(
            from: now.addingTimeInterval(-86400),
            to: now.addingTimeInterval(86400),
            dbURL: dbURL
        )
        XCTAssertEqual(spends.values.reduce(0, +), weekly.usedUSD, accuracy: 0.0001)
    }

    func testMalformedMessageRowsAreSkipped() throws {
        session("s1", at: now.addingTimeInterval(-3600))
        try exec("INSERT INTO message VALUES ('bad', 's1', \(Self.ms(now.addingTimeInterval(-60))), 0, 'not json')")
        message("s1", at: now.addingTimeInterval(-120), cost: 1)
        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)
        XCTAssertEqual(snap.windows.first { $0.kind == .rolling5h }?.usedUSD ?? -1, 1, accuracy: 0.001)
    }

    // MARK: - Cache

    func testScanCacheReusesUnchangedDatabase() throws {
        session("s1", at: now.addingTimeInterval(-3600))
        message("s1", at: now.addingTimeInterval(-3600), cost: 1)
        let cache = OpenCodeLocalScanCache()
        var loads = 0
        let since = now.addingTimeInterval(-86400)
        func load(_ start: Date) throws -> OpenCodeLocalScan {
            try cache.scan(dbURL: dbURL, since: start) {
                loads += 1
                return OpenCodeLocalScan(since: start, subscribedAt: nil, rows: [])
            }
        }
        _ = try load(since)
        _ = try load(since.addingTimeInterval(3600))
        XCTAssertEqual(loads, 1)

        _ = try load(since.addingTimeInterval(-3600))
        XCTAssertEqual(loads, 2)

        Thread.sleep(forTimeInterval: 0.01)
        message("s1", at: now, cost: 1)
        _ = try load(since)
        XCTAssertEqual(loads, 3)
    }

    func testFetchesShareOneScanUntilTheDatabaseChanges() throws {
        session("s1", at: now.addingTimeInterval(-3600))
        message("s1", at: now.addingTimeInterval(-3600), cost: 1)
        let cache = OpenCodeLocalScanCache()
        let first = try OpenCodeLocalStats.loadScan(dbURL: dbURL, since: OpenCodeLocalStats.scanStart(now: now), cache: cache)
        XCTAssertEqual(first.rows.count, 1)
        XCTAssertNotNil(first.subscribedAt)

        Thread.sleep(forTimeInterval: 0.01)
        message("s1", at: now.addingTimeInterval(-60), cost: 2)
        let second = try OpenCodeLocalStats.loadScan(dbURL: dbURL, since: OpenCodeLocalStats.scanStart(now: now), cache: cache)
        XCTAssertEqual(second.rows.count, 2)
    }

    // MARK: - Helpers

    /// A subscription instant whose monthly cycle (as of `now`) starts at `monthStart`.
    private static func anchor(for monthStart: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .month, value: -2, to: monthStart)!
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private func session(_ id: String, at date: Date) {
        XCTAssertNoThrow(try exec("""
        INSERT INTO session (id, time_created, model) \
        VALUES ('\(id)', \(Self.ms(date)), '{"id":"minimax-m3","providerID":"opencode-go"}')
        """))
    }

    private func message(
        _ sessionID: String,
        at date: Date,
        cost: Double,
        input: Int64 = 1,
        output: Int64 = 0,
        cacheRead: Int64 = 0,
        cacheWrite: Int64 = 0,
        model: String = "minimax-m3"
    ) {
        let data = """
        {"role":"assistant","cost":\(cost),"providerID":"opencode-go","modelID":"\(model)",\
        "tokens":{"input":\(input),"output":\(output),"cache":{"read":\(cacheRead),"write":\(cacheWrite)}}}
        """
        XCTAssertNoThrow(try exec("""
        INSERT INTO message VALUES ('\(UUID().uuidString)', '\(sessionID)', \(Self.ms(date)), \(Self.ms(date)), '\(data)')
        """))
    }

    private func exec(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { throw OpenCodeLocalStatsError.openFailed("test") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeLocalStatsError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }
}
