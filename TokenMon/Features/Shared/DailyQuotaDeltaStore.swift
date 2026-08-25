import Combine
import Foundation

/// File-backed per-calendar-day accumulation of a provider's quota-window
/// growth, in percentage points of that window.
///
/// Mirrors `HourlyDeltaActivityStore`'s reset handling: a drop in the window's
/// utilization means a new window started, so the post-reset value is credited
/// to the sampled day rather than discarded — dropping it would silently lose
/// whatever usage accrued between the reset and the next poll. This matters a
/// lot for windows that reset multiple times a day (Claude's five-hour window).
@MainActor
final class DailyQuotaDeltaStore: ObservableObject {
    /// Local-start-of-day → percentage-point growth of the tracked window.
    @Published private(set) var spentByDay: [Date: Double]

    private let store: FileBackedStringStore
    private let storageKey: String
    private var lastUsedPercent: Double?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private struct Payload: Codable {
        var days: [Date: Double]
        var lastUsedPercent: Double?
    }

    convenience init(storageKey: String) {
        self.init(store: FileBackedStringStore(filenamePrefix: "activity_"), storageKey: storageKey)
    }

    init(store: FileBackedStringStore, storageKey: String) {
        self.store = store
        self.storageKey = storageKey
        self.spentByDay = [:]
        load()
    }

    /// Record a new window utilization snapshot. Growth since the last sample is
    /// added to the sampled calendar day; a drop is treated as a window reset
    /// and the post-reset value is attributed to the day instead of being
    /// discarded (same semantics as `HourlyDeltaActivityStore`).
    func record(windowUsedPercent: Double, at date: Date = Date()) {
        defer { persist() }

        guard let previous = lastUsedPercent else {
            lastUsedPercent = windowUsedPercent
            return
        }

        let delta: Double
        if windowUsedPercent >= previous {
            delta = windowUsedPercent - previous
        } else {
            delta = windowUsedPercent
        }
        lastUsedPercent = windowUsedPercent

        // Ignore tiny noise.
        guard delta >= 0.05 else { return }

        let dayKey = Calendar.current.startOfDay(for: date)
        var next = spentByDay
        next[dayKey, default: 0] += delta
        Self.prune(&next)
        spentByDay = next
    }

    func clear() {
        lastUsedPercent = nil
        spentByDay = [:]
        persist()
    }

    /// Drops all accumulated day totals because the tracked quota window rolled
    /// over (e.g. a weekly pool reset), while keeping the utilization baseline.
    /// Keeping the baseline routes the next recorded sample through the usual
    /// drop-as-reset path, so whatever accrued in the fresh window before the
    /// next poll is credited to its day instead of lost.
    func beginNewWindow() {
        defer { persist() }
        spentByDay = [:]
    }

    private static func prune(_ days: inout [Date: Double]) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Calendar.current.startOfDay(for: Date())) ?? .distantPast
        days = days.filter { $0.key >= cutoff }
    }

    private func load() {
        guard let raw = store.value(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let payload = try? decoder.decode(Payload.self, from: data)
        else {
            persist()
            return
        }
        var days = payload.days
        Self.prune(&days)
        lastUsedPercent = payload.lastUsedPercent
        spentByDay = days
    }

    private func persist() {
        let payload = Payload(days: spentByDay, lastUsedPercent: lastUsedPercent)
        guard let data = try? encoder.encode(payload),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        store.set(raw, forKey: storageKey)
    }
}
