import Combine
import Foundation

/// Tracks a provider's local-day quota growth per hour (percentage-point deltas
/// between polls), keyed by an arbitrary `storageKey` so each provider persists
/// its own file-backed series.
///
/// A drop in the raw `usedPercent` means a quota window reset; the post-reset
/// value is attributed as the current hour's growth in the new window.
@MainActor
final class HourlyDeltaActivityStore: ObservableObject {
    @Published private(set) var hourWeights: [Double]
    @Published private(set) var dayStart: Date

    private let store: FileBackedStringStore
    private let storageKey: String
    private var lastUsedPercent: Double?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private struct Payload: Codable {
        var dayStart: Date
        var hourWeights: [Double]
        var lastUsedPercent: Double?
    }

    convenience init(storageKey: String) {
        self.init(store: FileBackedStringStore(filenamePrefix: "activity_"), storageKey: storageKey)
    }

    init(store: FileBackedStringStore, storageKey: String) {
        self.store = store
        self.storageKey = storageKey
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        self.dayStart = today
        self.hourWeights = Array(repeating: 0, count: 24)
        loadOrReset(for: today)
    }

    /// Records a new `usedPercent` snapshot. Growth since the last sample is
    /// attributed to the current hour; a drop is treated as a quota-window reset
    /// and the new value is attributed as this hour's growth in the new window.
    func record(usedPercent: Double, at date: Date = Date()) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        if start != dayStart {
            dayStart = start
            hourWeights = Array(repeating: 0, count: 24)
            lastUsedPercent = nil
        }

        defer {
            lastUsedPercent = usedPercent
            persist()
        }

        let delta: Double
        if let previous = lastUsedPercent {
            delta = usedPercent >= previous ? usedPercent - previous : usedPercent
        } else {
            return
        }

        // Ignore tiny noise.
        guard delta >= 0.05 else { return }

        let hour = calendar.component(.hour, from: date)
        guard (0..<24).contains(hour) else { return }
        var next = hourWeights
        next[hour] += delta
        hourWeights = next
    }

    /// Drops the accumulated series and utilization baseline (e.g. on sign-out
    /// or account switch).
    func clear() {
        let today = Calendar.current.startOfDay(for: Date())
        dayStart = today
        hourWeights = Array(repeating: 0, count: 24)
        lastUsedPercent = nil
        persist()
    }

    /// Clears the finished window's hourly growth and resets the utilization
    /// baseline so the first sample of the new window is credited in full.
    func beginNewWindow() {
        hourWeights = Array(repeating: 0, count: 24)
        lastUsedPercent = 0
        persist()
    }

    private func loadOrReset(for today: Date) {
        let raw = store.value(forKey: storageKey)
        guard let raw,
              let data = raw.data(using: .utf8),
              let payload = try? decoder.decode(Payload.self, from: data)
        else {
            persist()
            return
        }

        if Calendar.current.isDate(payload.dayStart, inSameDayAs: today),
           payload.hourWeights.count == 24 {
            dayStart = Calendar.current.startOfDay(for: payload.dayStart)
            hourWeights = payload.hourWeights
            lastUsedPercent = payload.lastUsedPercent
        } else {
            dayStart = today
            hourWeights = Array(repeating: 0, count: 24)
            lastUsedPercent = nil
            persist()
        }
    }

    private func persist() {
        let payload = Payload(
            dayStart: dayStart,
            hourWeights: hourWeights,
            lastUsedPercent: lastUsedPercent
        )
        guard let data = try? encoder.encode(payload),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        store.set(raw, forKey: storageKey)
    }
}
