import Foundation

/// One read of `opencode.db`: assistant messages since `since` and the first
/// unarchived Go session (the subscription anchor).
struct OpenCodeLocalScan: Sendable {
    var since: Date
    var subscribedAt: Date?
    var rows: [OpenCodeLocalStats.SessionRow]
}

/// Last ``OpenCodeLocalScan`` per database, reused while the database file and
/// its WAL keep the same modification time and size.
///
/// Every local figure in a poll (snapshot, hourly chart, daily bars) derives
/// from one scan, and an idle database is read only once.
final class OpenCodeLocalScanCache: @unchecked Sendable {
    /// Modification time and size of the database and its `-wal` file.
    struct Fingerprint: Equatable {
        var databaseModified: Date?
        var databaseSize: Int64?
        var walModified: Date?
        var walSize: Int64?

        init(dbURL: URL) {
            let manager = FileManager.default
            let database = try? manager.attributesOfItem(atPath: dbURL.path)
            let wal = try? manager.attributesOfItem(atPath: dbURL.path + "-wal")
            databaseModified = database?[.modificationDate] as? Date
            databaseSize = (database?[.size] as? NSNumber)?.int64Value
            walModified = wal?[.modificationDate] as? Date
            walSize = (wal?[.size] as? NSNumber)?.int64Value
        }
    }

    private let lock = NSLock()
    private var entry: (path: String, fingerprint: Fingerprint, scan: OpenCodeLocalScan)?

    /// The cached scan when it is for `dbURL`, unchanged on disk, and reaches
    /// back to `since`; otherwise the result of `load`, which replaces it.
    func scan(dbURL: URL, since: Date, load: () throws -> OpenCodeLocalScan) rethrows -> OpenCodeLocalScan {
        lock.lock()
        defer { lock.unlock() }
        let fingerprint = Fingerprint(dbURL: dbURL)
        if let entry, entry.path == dbURL.path, entry.fingerprint == fingerprint, entry.scan.since <= since {
            return entry.scan
        }
        let scan = try load()
        entry = (dbURL.path, fingerprint, scan)
        return scan
    }
}
