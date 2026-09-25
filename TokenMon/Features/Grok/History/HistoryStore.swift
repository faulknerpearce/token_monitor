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
    /// This is intentionally lossy (a display-only balance), so `4.10` may read
    /// back as `4.0999…`. Persisting it as a string would require a SwiftData
    /// schema migration for no user-visible benefit.
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

    /// `dailySeries` is deliberately not persisted: it is only ever non-empty
    /// when the server supplies a per-day series, which the local-delta path
    /// already supersedes, so round-tripping it would add schema weight for no
    /// visible effect.
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

/// Persists one snapshot per calendar day and publishes the recent window.
@MainActor
final class HistoryStore: ObservableObject {
    private static let logger = Logger(category: "HistoryStore")

    private var container: ModelContainer?
    private var context: ModelContext?
    private var saveTask: Task<Void, Never>?
    private var dirty = false

    @Published private(set) var recent: [WeeklyUsageSnapshot] = []

    /// True when the persistent store could not be opened. History then runs
    /// session-only (in-memory) instead of silently no-oping forever; Settings
    /// surfaces this so the user knows the data will not survive a relaunch.
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

    /// Appends `snapshot`, collapsing same-day polls into one end-of-day row.
    func append(_ snapshot: WeeklyUsageSnapshot) {
        guard let context else { return }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: snapshot.fetchedAt)

        if let last = recent.first,
           cal.isDate(last.fetchedAt, inSameDayAs: snapshot.fetchedAt),
           abs(last.usedPercent - snapshot.usedPercent) < 0.05,
           abs(last.fetchedAt.timeIntervalSince(snapshot.fetchedAt)) < 60 {
            return
        }

        let sameDay = findRecords(on: dayStart, calendar: cal)
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

    /// Synchronous save — call on terminate so the coalesced write cannot be lost.
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
            // Keep `dirty` set so the next append/poll or terminate-flush retries;
            // clearing it here would silently drop the last snapshots.
            Self.logger.error("SwiftData save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keep `recent` in sync without re-fetching (and re-decoding) up to 200 rows.
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
    /// no same-day entry exists. Matching by calendar day — not snapshot id — keeps
    /// `recent` aligned with the single per-day disk row even though every poll
    /// produces a fresh snapshot id.
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

    /// Same-day lookup: fetch a window, then filter with `Calendar` (more reliable than exact predicate bounds).
    private func findRecords(on dayStart: Date, calendar: Calendar) -> [UsageSnapshotRecord] {
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
        return candidates.filter { calendar.isDate($0.fetchedAt, inSameDayAs: dayStart) }
    }

    private func reload() {
        guard let context else { return }
        var descriptor = FetchDescriptor<UsageSnapshotRecord>(
            sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        let records = (try? context.fetch(descriptor)) ?? []
        recent = records.map { $0.toSnapshot() }
    }
}
