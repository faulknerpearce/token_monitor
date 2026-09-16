import Combine
import Foundation

/// File-backed per-calendar-day accumulation of a provider's quota-window
/// growth, in percentage points of that window.
///
/// A drop in the window's utilization means a new window started; the post-reset
/// value is credited to the sampled day rather than discarded.
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

    /// Records a new window utilization snapshot. Growth since the last sample is
    /// added to the sampled calendar day; a drop large enough to be a window reset
    /// credits the post-reset value to the day, while a small downward tick is
    /// treated as rounding noise and ignored.
    func record(windowUsedPercent: Double, at date: Date = Date()) {
        defer { persist() }

        guard let previous = lastUsedPercent else {
            lastUsedPercent = windowUsedPercent
            return
        }

        let delta: Double
        if windowUsedPercent >= previous {
            delta = windowUsedPercent - previous
        } else if previous - windowUsedPercent >= Percent.resetDropFloor {
            delta = windowUsedPercent
        } else {
            // A small downward tick is noise, not a reset. Crediting it as one
            // would add the whole pool percent to the day.
            delta = 0
        }
        lastUsedPercent = windowUsedPercent

        // Ignore tiny noise.
        guard delta >= Percent.noiseFloor else { return }

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

    /// Drops all accumulated day totals after the tracked quota window rolls over
    /// (e.g. a weekly pool reset) and zeros the utilization baseline so the first
    /// sample of the fresh window is credited in full.
    func beginNewWindow() {
        spentByDay = [:]
        lastUsedPercent = 0
        persist()
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
