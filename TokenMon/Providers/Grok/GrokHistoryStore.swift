import Foundation
import Observation
import os

/// Persists one snapshot per calendar day and account in a JSON file, and
/// publishes the recent window for the active account.
@MainActor
@Observable
final class GrokHistoryStore {
    private static let logger = Logger(category: "GrokHistoryStore")
    private static let storageKey = "history"

    /// Saved file layout.
    private struct Payload: Codable {
        var version = 1
        var rows: [WeeklyUsageSnapshot]
    }

    /// Where the history is saved; nil keeps it in memory only.
    @ObservationIgnored private let store: FileBackedStringStore?
    /// Every saved row, oldest first.
    @ObservationIgnored private var rows: [WeeklyUsageSnapshot] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var dirty = false

    /// Rows for `activeAccount`, newest first.
    private(set) var recent: [WeeklyUsageSnapshot] = []

    /// Account email whose rows `recent` holds and same-day collapsing
    /// matches. Rows of other accounts stay on disk (and in exports) and feed
    /// only their own account's chart. `nil` is the account whose email is unknown.
    private(set) var activeAccount: String?

    /// True when the saved history could not be read. History then runs
    /// session-only and the file is not overwritten; Settings surfaces this
    /// so the user knows the data is not kept on relaunch.
    private(set) var storeFailed = false

    /// The app's history (`grok_history.dat` in Application Support), or an
    /// in-memory history for tests.
    convenience init(inMemory: Bool = false) {
        if inMemory {
            self.init(store: nil, legacyStoreURL: nil)
        } else {
            self.init(
                store: FileBackedStringStore(filenamePrefix: "grok_"),
                legacyStoreURL: AppSupport.directory().appendingPathComponent("history.store")
            )
        }
    }

    /// - Parameters:
    ///   - store: Where the history is saved; nil keeps it in memory.
    ///   - legacyStoreURL: A SwiftData store whose rows are imported when no
    ///     history has been saved to `store` yet.
    init(store: FileBackedStringStore?, legacyStoreURL: URL?) {
        self.store = store
        guard let store else { return }
        if let text = store.value(forKey: Self.storageKey) {
            if let payload = try? JSONDecoder().decode(Payload.self, from: Data(text.utf8)) {
                rows = payload.rows.sorted { $0.fetchedAt < $1.fetchedAt }
            } else {
                storeFailed = true
                Self.logger.error("Saved history could not be read; using in-memory history.")
            }
        } else if let legacyStoreURL, let imported = GrokHistoryImport.snapshots(at: legacyStoreURL) {
            rows = imported
            dirty = true
            flushIfNeeded()
        }
        reload()
    }

    /// Switches `recent` to `account`'s rows.
    func setActiveAccount(_ account: String?) {
        guard account != activeAccount else { return }
        activeAccount = account
        reload()
    }

    /// Appends `snapshot`, collapsing same-day polls of the same account into
    /// one end-of-day row, and makes its account the active one.
    func append(_ snapshot: WeeklyUsageSnapshot) {
        setActiveAccount(snapshot.accountEmail)
        let cal = Calendar.current

        if let last = recent.first,
           cal.isDate(last.fetchedAt, inSameDayAs: snapshot.fetchedAt),
           abs(last.usedPercent - snapshot.usedPercent) < 0.05,
           abs(last.fetchedAt.timeIntervalSince(snapshot.fetchedAt)) < 60 {
            return
        }
        // An idle poll that reports the same usage as today's row leaves the
        // row (and the disk) untouched.
        if let last = recent.first,
           cal.isDate(last.fetchedAt, inSameDayAs: snapshot.fetchedAt),
           Self.hasSameUsage(last, snapshot) {
            return
        }

        // Each calendar day keeps one end-of-day row per account.
        rows.removeAll {
            $0.accountEmail == snapshot.accountEmail && cal.isDate($0.fetchedAt, inSameDayAs: snapshot.fetchedAt)
        }
        let index = rows.firstIndex { $0.fetchedAt > snapshot.fetchedAt } ?? rows.endIndex
        rows.insert(snapshot, at: index)
        reload()
        scheduleFlush()
    }

    /// True when `next` records nothing new over `current`: same usage (within
    /// rounding), reset instant, product split, credits and account.
    private static func hasSameUsage(_ current: WeeklyUsageSnapshot, _ next: WeeklyUsageSnapshot) -> Bool {
        abs(current.usedPercent - next.usedPercent) < 0.05
            && abs(current.remainingPercent - next.remainingPercent) < 0.05
            && current.resetsAt == next.resetsAt
            && current.products == next.products
            && current.extraCreditsBalance == next.extraCreditsBalance
            && current.accountEmail == next.accountEmail
    }

    /// Synchronous save, called on terminate so the coalesced write reaches disk.
    func flush() {
        flushIfNeeded()
        saveTask?.cancel()
        saveTask = nil
    }

    /// Coalesces disk writes from frequent poll appends into one save.
    private func scheduleFlush() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.flushIfNeeded()
        }
    }

    /// Writes the rows when they changed. A history that could not be read is
    /// never written over.
    private func flushIfNeeded() {
        guard dirty, let store, !storeFailed else { return }
        guard let data = try? JSONEncoder().encode(Payload(rows: rows)),
              let text = String(bytes: data, encoding: .utf8)
        else {
            Self.logger.error("History encode failed")
            return
        }
        // `dirty` stays set when the write fails, so the next append or the
        // terminate flush retries it.
        if store.set(text, forKey: Self.storageKey) {
            dirty = false
        }
    }

    /// Every saved row, oldest first.
    func allSnapshots() -> [WeeklyUsageSnapshot] {
        rows
    }

    func clear() {
        rows = []
        recent = []
        dirty = true
        flush()
    }

    /// Rebuilds `recent`: the active account's newest 200 rows.
    private func reload() {
        recent = Array(rows.reversed().lazy.filter { $0.accountEmail == self.activeAccount }.prefix(200))
    }
}
