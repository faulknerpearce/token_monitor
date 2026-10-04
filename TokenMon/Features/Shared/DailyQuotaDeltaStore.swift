import Combine
import Foundation

/// Provider-reported bounds of a quota window. Both ends are optional because
/// providers differ: Grokbot and Cursor send a start *and* a reset instant,
/// Claude sends only `resets_at`. A bound is never invented from the calendar.
struct QuotaWindow: Hashable, Sendable {
    var start: Date?
    var resetsAt: Date?
}

/// How the provider's quota window changed between two consecutive samples.
enum QuotaWindowTransition: Hashable, Sendable {
    /// Same window (or not enough provider metadata to tell).
    case none
    /// The old window ran to its reset instant and the next one began on schedule.
    case rollover
    /// The provider began a new window **before** the old one's expected end
    /// (a free or manual reset pushed to everyone mid-cycle).
    case earlyReset

    /// Clock skew tolerated when deciding the old reset instant is still ahead.
    private static let skew: TimeInterval = 5 * 60
    /// Smallest move of the period start / reset instant that counts as a moved
    /// window rather than payload jitter.
    private static let movedThreshold: TimeInterval = 3600

    /// True when `nextResetsAt` is a genuinely new period rather than the same
    /// period's reset instant creeping forward: a rollover advances the instant
    /// by at least half the period.
    static func isRollover(previousResetsAt: Date?, nextResetsAt: Date?, periodDays: Int) -> Bool {
        guard let previous = previousResetsAt, let next = nextResetsAt, next > previous else { return false }
        return next.timeIntervalSince(previous) >= TimeInterval(max(1, periodDays)) * 86_400 * 0.5
    }

    /// Classifies `next` against `previous` from the provider's own metadata.
    ///
    /// - A reset instant that advances by at least half a period once the old
    ///   instant has passed is a normal ``rollover``.
    /// - While the old reset instant is still in the future, a drop of at least
    ///   `Percent.resetDropFloor` **together with** a moved period start or reset
    ///   instant is an ``earlyReset``. A drop alone (same window metadata) is a
    ///   rebase and is left to the store's drop-as-reset credit; moved metadata
    ///   alone (no drop) is not a reset of the pool, so nothing is rewound.
    static func classify(
        from previous: QuotaWindow,
        previousUsedPercent: Double?,
        to next: QuotaWindow,
        usedPercent: Double,
        periodDays: Int,
        now: Date
    ) -> QuotaWindowTransition {
        guard let previousReset = previous.resetsAt, let nextReset = next.resetsAt else { return .none }
        let oldWindowStillRunning = previousReset > now.addingTimeInterval(skew)
        if !oldWindowStillRunning {
            return isRollover(previousResetsAt: previousReset, nextResetsAt: nextReset, periodDays: periodDays)
                ? .rollover
                : .none
        }
        guard let previousUsed = previousUsedPercent,
              previousUsed - usedPercent >= Percent.resetDropFloor
        else { return .none }
        var startMoved = false
        if let previousStart = previous.start, let nextStart = next.start {
            startMoved = nextStart.timeIntervalSince(previousStart) >= movedThreshold
        }
        let resetMoved = abs(nextReset.timeIntervalSince(previousReset)) >= movedThreshold
        return startMoved || resetMoved ? .earlyReset : .none
    }
}

/// File-backed per-calendar-day accumulation of a provider's quota-window
/// growth, in percentage points of that window.
///
/// A drop in the window's utilization means a new window started; the post-reset
/// value is credited to the sampled day rather than discarded.
///
/// Day totals survive window changes: a new window only discards the entries on
/// or after its own start day (usage that belongs to the old window but shares a
/// calendar day with the new one), so the days *before* the new window stay
/// available as history. See ``beginNewWindow(startingAt:interruptedWindowStart:)``.
@MainActor
final class DailyQuotaDeltaStore: ObservableObject {
    /// Local-start-of-day → percentage-point growth of the tracked window.
    @Published private(set) var spentByDay: [Date: Double]

    /// Start of the window that began at the most recent rollover or early
    /// reset, when one was observed. Charts anchor to it when it is later than
    /// the start implied by the reset instant.
    private(set) var windowStart: Date?
    /// Start of the window an early reset cut short; nil unless the current
    /// window began from an early reset. Marks which preserved days are history.
    private(set) var interruptedWindowStart: Date?
    /// Last provider-reported period start and reset instant seen. They are the
    /// "previous window" the next sample is compared against, and persisting them
    /// lets a relaunch still recognize a reset that happened while the app was
    /// closed. Unlike `windowStart` they are never used to anchor charts.
    private(set) var observedStart: Date?
    private(set) var windowResetsAt: Date?
    /// Last recorded utilization of the tracked window.
    private(set) var lastUsedPercent: Double?

    private let store: FileBackedStringStore
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Optional fields decode as nil from payloads written before window
    /// metadata existed, so old stores keep loading unchanged.
    private struct Payload: Codable {
        var days: [Date: Double]
        var lastUsedPercent: Double?
        var windowStart: Date?
        var interruptedWindowStart: Date?
        var observedStart: Date?
        var windowResetsAt: Date?
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
    ///
    /// Pass the provider's `window` bounds to let the store recognize a normal
    /// rollover or an early reset (see ``QuotaWindowTransition``). The detected
    /// transition has already been applied when this returns, so callers only
    /// need it to reset their own per-window state (e.g. hourly deltas).
    @discardableResult
    func record(
        windowUsedPercent: Double,
        at date: Date = Date(),
        window: QuotaWindow? = nil,
        periodDays: Int = 7,
        calendar: Calendar = .current
    ) -> QuotaWindowTransition {
        defer { persist() }

        let transition = window.map {
            QuotaWindowTransition.classify(
                from: QuotaWindow(start: observedStart, resetsAt: windowResetsAt),
                previousUsedPercent: lastUsedPercent,
                to: $0,
                usedPercent: windowUsedPercent,
                periodDays: periodDays,
                now: date
            )
        } ?? .none
        if let window, transition != .none {
            applyTransition(transition, to: window, periodDays: periodDays, at: date, calendar: calendar)
        }
        if let start = window?.start { observedStart = start }
        if let resetsAt = window?.resetsAt { windowResetsAt = resetsAt }

        guard let previous = lastUsedPercent else {
            lastUsedPercent = windowUsedPercent
            return transition
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
        guard delta >= Percent.noiseFloor else { return transition }

        let dayKey = calendar.startOfDay(for: date)
        var next = spentByDay
        next[dayKey, default: 0] += delta
        Self.prune(&next)
        spentByDay = next
        return transition
    }

    func clear() {
        lastUsedPercent = nil
        windowStart = nil
        interruptedWindowStart = nil
        observedStart = nil
        windowResetsAt = nil
        spentByDay = [:]
        persist()
    }

    /// Starts a fresh tracked window at `windowStart` and zeros the utilization
    /// baseline so the first sample of that window is credited in full.
    ///
    /// History is **preserved**: only entries on or after `windowStart`'s day are
    /// dropped. Those hold old-window usage that shares a calendar day with the
    /// new window, and keeping them would inflate the new window's first bar
    /// (day totals cannot be split inside a day). Earlier days are untouched.
    ///
    /// Pass `interruptedWindowStart` when the old window was cut short by an early
    /// reset so charts can show the preserved days as prior-window history.
    func beginNewWindow(
        startingAt windowStart: Date = Date(),
        interruptedWindowStart: Date? = nil,
        calendar: Calendar = .current
    ) {
        let boundary = calendar.startOfDay(for: windowStart)
        spentByDay = spentByDay.filter { $0.key < boundary }
        lastUsedPercent = 0
        self.windowStart = windowStart
        self.interruptedWindowStart = interruptedWindowStart
        persist()
    }

    /// Resolves where the new window began and applies it. Preference order:
    /// the payload's own start; for a rollover the old reset instant (the moment
    /// the old window ended); otherwise the new reset instant minus one period,
    /// the same anchor the weekly bars already use. Never later than `date`.
    private func applyTransition(
        _ transition: QuotaWindowTransition,
        to window: QuotaWindow,
        periodDays: Int,
        at date: Date,
        calendar: Calendar
    ) {
        func impliedStart(_ resetsAt: Date?) -> Date? {
            resetsAt.flatMap { calendar.date(byAdding: .day, value: -max(1, periodDays), to: $0) }
        }
        let oldWindowEnd = transition == .rollover ? windowResetsAt : nil
        let candidate = window.start ?? oldWindowEnd ?? impliedStart(window.resetsAt)
        let interrupted = transition == .earlyReset ? observedStart ?? impliedStart(windowResetsAt) : nil
        beginNewWindow(
            startingAt: min(candidate ?? date, date),
            interruptedWindowStart: interrupted,
            calendar: calendar
        )
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
        windowStart = payload.windowStart
        interruptedWindowStart = payload.interruptedWindowStart
        observedStart = payload.observedStart
        windowResetsAt = payload.windowResetsAt
        spentByDay = days
    }

    private func persist() {
        let payload = Payload(
            days: spentByDay,
            lastUsedPercent: lastUsedPercent,
            windowStart: windowStart,
            interruptedWindowStart: interruptedWindowStart,
            observedStart: observedStart,
            windowResetsAt: windowResetsAt
        )
        guard let data = try? encoder.encode(payload),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        store.set(raw, forKey: storageKey)
    }
}
