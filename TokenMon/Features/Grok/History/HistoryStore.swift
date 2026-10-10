import Combine
import Foundation
import os
import SwiftData

/// SwiftData-backed row for one daily `WeeklyUsageSnapshot`.
@Model
final class UsageSnapshotRecord {
    @Attribute(.unique) var id: UUID
    var fetchedAt: Date
    var usedPercent: Double
    var remainingPercent: Double
    var resetsAt: Date?
    var productsJSON: Data
    /// Stored as Double for SwiftData schema stability; domain model uses Decimal.
    /// The conversion is lossy (a display-only balance), so `4.10` may read
    /// back as `4.0999…`.
    var extraCredits: Double?
    var accountEmail: String?

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    private static let logger = Logger(category: "History")

    init(from snapshot: WeeklyUsageSnapshot) {
        self.id = snapshot.id
        self.fetchedAt = snapshot.fetchedAt
        self.usedPercent = snapshot.usedPercent
        self.remainingPercent = snapshot.remainingPercent
        self.resetsAt = snapshot.resetsAt
        if let data = try? Self.encoder.encode(snapshot.products) {
            self.productsJSON = data
        } else {
            Self.logger.error("Failed to encode products for snapshot \(snapshot.id)")
            self.productsJSON = Data()
        }
        self.extraCredits = snapshot.extraCreditsBalance.map { NSDecimalNumber(decimal: $0).doubleValue }
        self.accountEmail = snapshot.accountEmail
    }

    func apply(_ snapshot: WeeklyUsageSnapshot) {
        fetchedAt = snapshot.fetchedAt
        usedPercent = snapshot.usedPercent
        remainingPercent = snapshot.remainingPercent
        resetsAt = snapshot.resetsAt
        if let data = try? Self.encoder.encode(snapshot.products) {
            productsJSON = data
        } else {
            Self.logger.error("Failed to encode products on apply for \(snapshot.id)")
        }
        extraCredits = snapshot.extraCreditsBalance.map { NSDecimalNumber(decimal: $0).doubleValue }
        accountEmail = snapshot.accountEmail
    }

    /// `dailySeries` is held in memory only: it is non-empty only when the
    /// server supplies a per-day series, which the local-delta path supersedes.
    func toSnapshot() -> WeeklyUsageSnapshot {
        let products: [ProductUsage]
        if let decoded = try? Self.decoder.decode([ProductUsage].self, from: productsJSON) {
            products = decoded
        } else {
            Self.logger.error("Failed to decode productsJSON for record \(self.id)")
            products = []
        }
        return WeeklyUsageSnapshot(
            id: id,
            fetchedAt: fetchedAt,
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            resetsAt: resetsAt,
            products: products,
            extraCreditsBalance: extraCredits.map { Decimal($0) },
            accountEmail: accountEmail
        )
    }
}

/// Persists one snapshot per calendar day and account, and publishes the
/// recent window for the active account.
@MainActor
final class HistoryStore: ObservableObject {
    private static let logger = Logger(category: "HistoryStore")

    private var container: ModelContainer?
    private var context: ModelContext?
    private var saveTask: Task<Void, Never>?
    private var dirty = false

    /// Rows for `activeAccount`, newest first.
    @Published private(set) var recent: [WeeklyUsageSnapshot] = []

    /// Account email whose rows `recent` holds and same-day collapsing
    /// matches. Rows of other accounts stay on disk (and in exports) and feed
    /// only their own account's chart. `nil` is the account whose email is unknown.
    private(set) var activeAccount: String?

    /// True when the persistent store could not be opened. History then runs
    /// session-only (in-memory); Settings surfaces this so the user knows the
    /// data is lost on relaunch.
    @Published private(set) var storeFailed = false

    init(inMemory: Bool = false) {
        if let container = Self.makeContainer(inMemory: inMemory) {
            self.container = container
            self.context = ModelContext(container)
            reload()
            return
        }
        // Persistent store unavailable: fall back to an in-memory store so
        // append/allSnapshots still work this session, and flag it for the UI.
        storeFailed = true
        if !inMemory, let fallback = Self.makeContainer(inMemory: true) {
            self.container = fallback
            self.context = ModelContext(fallback)
            Self.logger.error("Persistent history store unavailable; using in-memory history.")
        }
    }

    private static func makeContainer(inMemory: Bool) -> ModelContainer? {
        do {
            let config: ModelConfiguration
            if inMemory {
                config = ModelConfiguration(isStoredInMemoryOnly: true)
            } else {
                config = ModelConfiguration(url: persistentStoreURL())
            }
            return try ModelContainer(for: UsageSnapshotRecord.self, configurations: config)
        } catch {
            Self.logger.error("SwiftData init failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Stable Application Support store so history survives renames / sandbox toggles.
    private static func persistentStoreURL() -> URL {
        AppSupport.directory().appendingPathComponent("history.store")
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
        guard let context else { return }
        setActiveAccount(snapshot.accountEmail)
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: snapshot.fetchedAt)

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

        let sameDay = findRecords(on: dayStart, account: snapshot.accountEmail, calendar: cal)
        if let existing = sameDay.first {
            existing.apply(snapshot)
            // Collapse duplicates so each calendar day has one end-of-day row.
            if sameDay.count > 1 {
                for extra in sameDay.dropFirst() {
                    context.delete(extra)
                }
            }
            upsertRecentForDay(snapshot, calendar: cal)
        } else {
            let record = UsageSnapshotRecord(from: snapshot)
            context.insert(record)
            upsertRecent(snapshot)
        }
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
        guard context != nil else { return }
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.flushIfNeeded()
            }
        }
    }

    private func flushIfNeeded() {
        guard dirty, let context else { return }
        do {
            try context.save()
            dirty = false
        } catch {
            // `dirty` stays set so the next append/poll or terminate-flush retries
            // the save of the last snapshots.
            Self.logger.error("SwiftData save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Updates `recent` in place, skipping a re-fetch (and re-decode) of up to 200 rows.
    private func upsertRecent(_ snapshot: WeeklyUsageSnapshot, replacingID: UUID? = nil) {
        if let replacingID, let index = recent.firstIndex(where: { $0.id == replacingID }) {
            recent[index] = snapshot
            return
        }
        recent.insert(snapshot, at: 0)
        if recent.count > 200 {
            recent.removeLast(recent.count - 200)
        }
    }

    /// Replace the same-day entry in `recent` in place, or insert at the front when
    /// no same-day entry exists. Matching by calendar day keeps `recent` aligned
    /// with the single per-day disk row even though every poll produces a fresh
    /// snapshot id.
    private func upsertRecentForDay(_ snapshot: WeeklyUsageSnapshot, calendar: Calendar) {
        if let index = recent.firstIndex(where: { calendar.isDate($0.fetchedAt, inSameDayAs: snapshot.fetchedAt) }) {
            recent[index] = snapshot
            return
        }
        upsertRecent(snapshot)
    }

    func allSnapshots() -> [WeeklyUsageSnapshot] {
        guard let context else { return [] }
        let descriptor = FetchDescriptor<UsageSnapshotRecord>(
            sortBy: [SortDescriptor(\.fetchedAt, order: .forward)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        return records.map { $0.toSnapshot() }
    }

    func clear() {
        guard let context else { return }
        do {
            let records = try context.fetch(FetchDescriptor<UsageSnapshotRecord>())
            for record in records {
                context.delete(record)
            }
            try context.save()
            recent = []
        } catch {
            Self.logger.error("Clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Same-day lookup for one account: fetch a window, then filter with
    /// `Calendar` (more reliable than exact predicate bounds).
    private func findRecords(on dayStart: Date, account: String?, calendar: Calendar) -> [UsageSnapshotRecord] {
        guard let context else { return [] }
        let windowStart = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
        let windowEnd = calendar.date(byAdding: .day, value: 2, to: dayStart) ?? dayStart
        let descriptor = FetchDescriptor<UsageSnapshotRecord>(
            predicate: #Predicate { record in
                record.fetchedAt >= windowStart && record.fetchedAt < windowEnd
            },
            sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)]
        )
        let candidates = (try? context.fetch(descriptor)) ?? []
        return candidates.filter { $0.accountEmail == account && calendar.isDate($0.fetchedAt, inSameDayAs: dayStart) }
    }

    private func reload() {
        guard let context else { return }
        let descriptor = FetchDescriptor<UsageSnapshotRecord>(
            sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        recent = records.lazy
            .filter { $0.accountEmail == self.activeAccount }
            .prefix(200)
            .map { $0.toSnapshot() }
    }
}
