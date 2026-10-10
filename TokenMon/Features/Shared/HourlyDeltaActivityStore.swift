import Combine
import Foundation

/// Tracks a provider's local-day quota growth per hour (percentage-point deltas
/// between polls), keyed by an arbitrary `storageKey` so each provider persists
/// its own file-backed series.
///
/// A drop in the raw `usedPercent` means a quota window reset; the post-reset
/// value is attributed as the current hour's growth in the new window.
///
/// The day is persisted as a ``DayKey`` so it keeps its calendar date across
/// time-zone changes. The utilization baseline carries over midnight, so growth
/// between the last sample of one day and the first of the next is credited to
/// the new day's first hour.
@MainActor
final class HourlyDeltaActivityStore: ObservableObject {
    @Published private(set) var hourWeights: [Double]
    @Published private(set) var dayStart: Date

    private let store: FileBackedStringStore
    private let storageKey: String
    private let calendar: Calendar
    private var lastUsedPercent: Double?
    /// `DayKey` of the day `hourWeights` belongs to.
    private var dayKey: String
    private var timeZoneObserver: NSObjectProtocol?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// `dayKey` names the day. `dayStart` is kept for readers of the older
    /// format, which named the day by its start-of-day instant only.
    private struct Payload: Codable, Equatable {
        var dayKey: String?
        var dayStart: Date
        var hourWeights: [Double]
        var lastUsedPercent: Double?
    }

    /// Last payload read from or written to disk; `persist()` skips identical writes.
    private var persisted: Payload?

    convenience init(storageKey: String) {
        self.init(store: FileBackedStringStore(filenamePrefix: "activity_"), storageKey: storageKey)
    }

    /// - Parameters:
    ///   - calendar: Calendar whose days and hours bucket the series. The
    ///     default follows system time-zone changes.
    ///   - now: The moment the store loads at (tests inject a fixed one).
    init(
        store: FileBackedStringStore,
        storageKey: String,
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = Date()
    ) {
        self.store = store
        self.storageKey = storageKey
        self.calendar = calendar
        self.dayStart = calendar.startOfDay(for: now)
        self.dayKey = DayKey.key(for: now, calendar: calendar)
        self.hourWeights = Array(repeating: 0, count: 24)
        loadOrReset(at: now)
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDayStart() }
        }
    }

    deinit {
        if let timeZoneObserver {
            NotificationCenter.default.removeObserver(timeZoneObserver)
        }
    }

    /// Re-derives `dayStart` from `dayKey` in the current zone of `calendar`.
    private func refreshDayStart() {
        if let start = DayKey.startOfDay(for: dayKey, calendar: calendar), start != dayStart {
            dayStart = start
        }
    }

    /// Records a new `usedPercent` snapshot. Growth since the last sample is
    /// attributed to the current hour; a drop large enough to be a quota-window
    /// reset credits the new value to this hour, while a small downward tick is
    /// treated as rounding noise and ignored.
    func record(usedPercent: Double, at date: Date = Date()) {
        let key = DayKey.key(for: date, calendar: calendar)
        if key != dayKey {
            dayKey = key
            dayStart = calendar.startOfDay(for: date)
            hourWeights = Array(repeating: 0, count: 24)
        }

        defer {
            lastUsedPercent = usedPercent
            persist()
        }

        let delta: Double
        if let previous = lastUsedPercent {
            if usedPercent >= previous {
                delta = usedPercent - previous
            } else if previous - usedPercent >= Percent.resetDropFloor {
                delta = usedPercent
            } else {
                // A small downward tick is noise, not a reset.
                delta = 0
            }
        } else {
            return
        }

        // Ignore tiny noise.
        guard delta >= Percent.noiseFloor else { return }

        let hour = calendar.component(.hour, from: date)
        guard (0..<24).contains(hour) else { return }
        var next = hourWeights
        next[hour] += delta
        hourWeights = next
    }

    /// Drops the accumulated series and utilization baseline (e.g. on sign-out
    /// or account switch).
    func clear(at date: Date = Date()) {
        dayKey = DayKey.key(for: date, calendar: calendar)
        dayStart = calendar.startOfDay(for: date)
        hourWeights = Array(repeating: 0, count: 24)
        lastUsedPercent = nil
        persist()
    }

    /// Clears the finished window's hourly growth and resets the utilization
    /// baseline so the first sample of the new window is credited in full.
    ///
    /// After an early provider reset pass `keepingHours: true`: the hours already
    /// recorded today are real activity from before the reset, so only the
    /// baseline restarts and the hourly chart keeps them.
    func beginNewWindow(keepingHours: Bool = false) {
        if !keepingHours {
            hourWeights = Array(repeating: 0, count: 24)
        }
        lastUsedPercent = 0
        persist()
    }

    private func loadOrReset(at now: Date) {
        let raw = store.value(forKey: storageKey)
        guard let raw,
              let data = raw.data(using: .utf8),
              let payload = try? decoder.decode(Payload.self, from: data)
        else {
            persist()
            return
        }
        persisted = payload

        let storedKey = payload.dayKey ?? DayKey.key(
            forStoredStartOfDay: payload.dayStart,
            preferredOffset: calendar.timeZone.secondsFromGMT(for: payload.dayStart)
        )
        if storedKey == dayKey, payload.hourWeights.count == 24 {
            hourWeights = payload.hourWeights
            lastUsedPercent = payload.lastUsedPercent
        } else {
            hourWeights = Array(repeating: 0, count: 24)
            lastUsedPercent = nil
        }
        // An older-format payload is rewritten once with its `dayKey`.
        persist()
    }

    private func persist() {
        let payload = Payload(
            dayKey: dayKey,
            dayStart: dayStart,
            hourWeights: hourWeights,
            lastUsedPercent: lastUsedPercent
        )
        guard payload != persisted,
              let data = try? encoder.encode(payload),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        store.set(raw, forKey: storageKey)
        persisted = payload
    }
}
