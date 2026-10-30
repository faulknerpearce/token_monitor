import Foundation
import SQLite3

/// Read-only SQLite access to `opencode.db`.
extension OpenCodeLocalStats {
    /// Opens a readonly connection. The plain path (no URI parsing) avoids a
    /// home directory containing `#`, `?`, or `%` truncating a `file:` URI;
    /// `SQLITE_OPEN_READONLY` already implies the `mode=ro` behavior.
    static func openConnection(at dbURL: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw OpenCodeLocalStatsError.openFailed(message)
        }
        sqlite3_busy_timeout(db, 2000)
        return db
    }

    /// First unarchived Go session: the subscription anchor for the monthly window.
    static func earliestGoSessionDate(db: OpaquePointer) throws -> Date? {
        let sql = """
        SELECT MIN(time_created) FROM session \
        WHERE time_archived IS NULL \
          AND lower(CASE WHEN json_valid(model) THEN json_extract(model, '$.providerID') END) = 'opencode-go'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OpenCodeLocalStatsError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw OpenCodeLocalStatsError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)) / 1000)
    }

    /// Assistant messages created at or after `startMS`. Assistant messages carry
    /// the real per-turn model and cost (a session stores only one model), and
    /// SQLite extracts just the needed JSON fields.
    static func readAssistantMessageRows(from db: OpaquePointer, startMS: Int64) throws -> [SessionRow] {
        let sql = """
        SELECT time_created, session_id, \
          json_extract(data, '$.providerID'), json_extract(data, '$.modelID'), \
          json_extract(data, '$.cost'), \
          json_extract(data, '$.tokens.input'), json_extract(data, '$.tokens.output'), \
          json_extract(data, '$.tokens.cache.read'), json_extract(data, '$.tokens.cache.write') \
        FROM message \
        WHERE time_created >= ? \
          AND (CASE WHEN json_valid(data) THEN json_extract(data, '$.role') END) = 'assistant'
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OpenCodeLocalStatsError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, startMS)

        func text(_ column: Int32) -> String {
            sqlite3_column_text(stmt, column)
                .map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }

        var rows: [SessionRow] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            // `defer` advances the cursor even on the `continue` path below, so
            // a skipped row still moves the loop forward.
            defer { step = sqlite3_step(stmt) }
            let providerID = text(2)
            let modelID = text(3)
            guard !providerID.isEmpty, !modelID.isEmpty else { continue }
            rows.append(SessionRow(
                timeCreatedMS: sqlite3_column_int64(stmt, 0),
                costUSD: sqlite3_column_double(stmt, 4),
                inputTokens: sqlite3_column_int64(stmt, 5),
                outputTokens: sqlite3_column_int64(stmt, 6),
                cacheReadTokens: sqlite3_column_int64(stmt, 7),
                cacheWriteTokens: sqlite3_column_int64(stmt, 8),
                providerID: providerID,
                modelID: modelID,
                sessionID: text(1)
            ))
        }
        // A terminal error (e.g. SQLITE_BUSY past the timeout, or a corrupt page)
        // throws, so a partial read that undercounts surfaces as a failure.
        guard step == SQLITE_DONE else {
            throw OpenCodeLocalStatsError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        return rows
    }
}
