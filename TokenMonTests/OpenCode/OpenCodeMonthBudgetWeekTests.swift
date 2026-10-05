import SQLite3
@testable import TokenMon
import XCTest

/// Week-arrow coverage for the OpenCode month budget. Split from OpenCodeStatsTests
/// so the length gates stay at the current maxima.
final class OpenCodeMonthBudgetWeekTests: XCTestCase {
    private var dbURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmon-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("opencode.db")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE session (
            time_created INTEGER NOT NULL,
            cost REAL NOT NULL,
            tokens_input INTEGER NOT NULL,
            tokens_output INTEGER NOT NULL,
            tokens_cache_read INTEGER NOT NULL,
            tokens_cache_write INTEGER NOT NULL,
            time_archived INTEGER,
            model TEXT NOT NULL,
            id TEXT
        );
        CREATE TABLE message (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
    }

    override func tearDownWithError() throws {
        if let dbURL {
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
        }
        dbURL = nil
    }

    private func insertAssistantMessage(
        sessionID: String,
        timeCreated: Date,
        cost: Double,
        input: Int64,
        output: Int64 = 0,
        cacheRead: Int64 = 0,
        cacheWrite: Int64 = 0,
        providerID: String,
        modelID: String
    ) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let data = """
        {"role":"assistant","cost":\(cost),"providerID":"\(providerID)","modelID":"\(modelID)",\
        "tokens":{"input":\(input),"output":\(output),"cache":{"read":\(cacheRead),"write":\(cacheWrite)}}}
        """
        let sql = """
        INSERT INTO message (id, session_id, time_created, time_updated, data) \
        VALUES (?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        let ms = Int64(timeCreated.timeIntervalSince1970 * 1000)
        sqlite3_bind_text(stmt, 1, "msg_\(UUID().uuidString)", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, sessionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 3, ms)
        sqlite3_bind_int64(stmt, 4, ms)
        sqlite3_bind_text(stmt, 5, data, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }

    /// Spend before the console window must not dilute the current week's scale,
    /// and chevron-left still paints that earlier week from local history.
    func testMonthDailyBudgetWeekOffsetKeepsHistoryOutOfHeadlineScale() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        func day(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }

        // Aug 20 2026 is a Thursday, so the current Monday week starts Aug 17.
        // Jul 20 is four Mondays earlier and before the Aug 5 period start.
        insertAssistantMessage(
            sessionID: "ses_hist",
            timeCreated: day(7, 20),
            cost: 6,
            input: 1_000,
            providerID: "opencode-go",
            modelID: "m"
        )
        insertAssistantMessage(
            sessionID: "ses_hist",
            timeCreated: day(8, 18),
            cost: 4,
            input: 1_000,
            providerID: "opencode-go",
            modelID: "m"
        )

        let now = day(8, 20)
        let resetsAt = day(9, 5, hour: 0)
        let current = try XCTUnwrap(
            OpenCodeLocalStats.monthDailyBudgetDays(
                limitUSD: 60,
                usedPercent: 20,
                periodResetsAt: resetsAt,
                now: now,
                dbURL: dbURL,
                calendar: calendar
            )
        )
        XCTAssertEqual(current.days.map(\.spentUSD).reduce(0, +), 20, accuracy: 0.01)
        XCTAssertEqual(
            current.days.first { calendar.isDate($0.date, inSameDayAs: day(8, 18)) }?.spentUSD ?? 0,
            20,
            accuracy: 0.01
        )

        let previous = try XCTUnwrap(
            OpenCodeLocalStats.monthDailyBudgetDays(
                limitUSD: 60,
                usedPercent: 20,
                periodResetsAt: resetsAt,
                weekOffset: -4,
                now: now,
                dbURL: dbURL,
                calendar: calendar
            )
        )
        XCTAssertTrue(calendar.isDate(previous.days[0].date, inSameDayAs: day(7, 20)))
        XCTAssertEqual(previous.days[0].spentUSD, 10, accuracy: 0.01) // 6 / 60 * 100
        XCTAssertFalse(previous.days[0].isPriorWindow)
    }
}
