import Combine
import Foundation

/// A provider series on the Overview hourly chart.
///
/// - Note: Raw values are saved in the history file; do not rename them.
enum OverviewSeries: String, Codable, CodingKeyRepresentable, CaseIterable, Hashable, Sendable {
    case grok
    case grokbot
    case cursor
    case claude
    case openCodeGo
    case openCodeZen
}

/// One day's Overview chart inputs: each provider's 24 hourly values in
/// percentage points of its allowance (Grok and Grokbot weekly, Claude its
/// 5-hour window, Cursor and OpenCode the weekly share of a monthly plan),
/// plus hourly token counts for the providers that report them.
struct OverviewDaySeries: Codable, Hashable, Sendable {
    var weights: [OverviewSeries: [Double]] = [:]
    var tokens: [OverviewSeries: [Int64]] = [:]

    var hasActivity: Bool {
        weights.values.contains { hours in hours.contains { $0 > 0 } }
    }

    /// The larger of each hourly value in `self` and `other`. A day's hourly
    /// usage only grows, so the larger value is the more complete record.
    func merging(_ other: Self) -> Self {
        Self(
            weights: weights.merging(other.weights) { Self.hourwiseMax($0, $1) },
            tokens: tokens.merging(other.tokens) { Self.hourwiseMax($0, $1) }
        )
    }

    /// Adds OpenCode Go and Zen hours from `hourly` when it covers the day
    /// starting at `dayStart`.
    mutating func addOpenCode(
        _ hourly: OpenCodeDayHourlyUsage,
        monthlyLimitUSD: Double,
        dayStart: Date,
        calendar: Calendar
    ) {
        guard calendar.isDate(hourly.dayStart, inSameDayAs: dayStart), hourly.hours.count == 24 else { return }
        let weights = hourly.overviewProviderQuotaHourWeights(monthlyLimitUSD: monthlyLimitUSD)
        let tokens = hourly.overviewProviderHourTokenCounts()
        self.weights[.openCodeGo] = weights.openCodeGo
        self.weights[.openCodeZen] = weights.openCodeZen
        self.tokens[.openCodeGo] = tokens.openCodeGo
        self.tokens[.openCodeZen] = tokens.openCodeZen
    }

    private static func hourwiseMax<T: Comparable & AdditiveArithmetic>(_ lhs: [T], _ rhs: [T]) -> [T] {
        (0..<max(lhs.count, rhs.count)).map { hour in
            max(hour < lhs.count ? lhs[hour] : .zero, hour < rhs.count ? rhs[hour] : .zero)
        }
    }
}

extension ProviderDayHourlyUsage {
    /// The chart's hours for `series` on the day starting at `dayStart`.
    static func build(dayStart: Date, series: OverviewDaySeries) -> ProviderDayHourlyUsage {
        let none = Array(repeating: 0.0, count: 24)
        let noTokens = Array(repeating: Int64(0), count: 24)
        return build(
            dayStart: dayStart,
            grokHourWeights: series.weights[.grok] ?? none,
            openCodeGoHourWeights: series.weights[.openCodeGo] ?? none,
            openCodeZenHourWeights: series.weights[.openCodeZen] ?? none,
            cursorHourWeights: series.weights[.cursor] ?? none,
            claudeHourWeights: series.weights[.claude] ?? none,
            grokbotHourWeights: series.weights[.grokbot] ?? none,
            openCodeGoHourTokens: series.tokens[.openCodeGo] ?? noTokens,
            openCodeZenHourTokens: series.tokens[.openCodeZen] ?? noTokens,
            cursorHourTokens: series.tokens[.cursor] ?? noTokens
        )
    }
}

/// Saved per-day Overview chart inputs, so the chart can show earlier days.
///
/// Today's inputs are recorded as they change. Most providers keep only the
/// current day's hours, so earlier days exist only from when they were
/// recorded here. Days older than `retentionDays` are dropped.
@MainActor
final class OverviewHourlyHistoryStore: ObservableObject {
    /// Number of days kept, including today.
    static let retentionDays = 30

    /// Saved days keyed by ``DayKey``.
    @Published private(set) var days: [String: OverviewDaySeries]

    private struct Payload: Codable, Equatable {
        var version = 1
        var days: [String: OverviewDaySeries]
    }

    private let store: FileBackedStringStore
    private let storageKey: String
    private let calendar: Calendar

    convenience init() {
        self.init(store: FileBackedStringStore(filenamePrefix: "activity_"))
    }

    /// - Parameters:
    ///   - store: Where the history is saved; tests pass a temporary directory.
    ///   - calendar: Calendar whose days key the history.
    init(
        store: FileBackedStringStore,
        storageKey: String = "overview_hourly_history",
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.store = store
        self.storageKey = storageKey
        self.calendar = calendar
        let saved = store.value(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode(Payload.self, from: Data($0.utf8)) }
        days = saved?.days ?? [:]
    }

    /// Merges `series` into the day containing `date`, drops days past the
    /// retention window, and saves when anything changed.
    func record(_ series: OverviewDaySeries, at date: Date) {
        let key = DayKey.key(for: date, calendar: calendar)
        var next = days
        if series.hasActivity || next[key] != nil {
            next[key] = (next[key] ?? OverviewDaySeries()).merging(series)
        }
        if let oldest = DayKey.adding(days: -(Self.retentionDays - 1), to: key, calendar: calendar) {
            next = next.filter { $0.key >= oldest }
        }
        guard next != days else { return }
        days = next
        save()
    }

    /// Saved inputs for the day containing `date`.
    func series(on date: Date) -> OverviewDaySeries? {
        days[DayKey.key(for: date, calendar: calendar)]
    }

    /// Start of the earliest saved day.
    var earliestDay: Date? {
        days.keys.min().flatMap { DayKey.startOfDay(for: $0, calendar: calendar) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(Payload(days: days)),
              let text = String(bytes: data, encoding: .utf8)
        else { return }
        store.set(text, forKey: storageKey)
    }
}

extension AppModel {
    /// Today's Overview chart inputs from the providers that are enabled and
    /// signed in (OpenCode needs only to be enabled), in the units
    /// ``OverviewDaySeries`` describes.
    func overviewSeries(on date: Date, calendar: Calendar = .current) -> OverviewDaySeries {
        let dayStart = calendar.startOfDay(for: date)
        var series = OverviewDaySeries()
        let enabled = settings.enabledProviderIDs

        func today(_ store: HourlyDeltaActivityStore) -> [Double]? {
            guard calendar.isDate(store.dayStart, inSameDayAs: dayStart), store.hourWeights.count == 24 else { return nil }
            return store.hourWeights
        }

        if enabled.contains(.grok), grokAuth.isSignedIn, !grokAuth.needsSignIn {
            series.weights[.grok] = today(grokHourly)
        }
        if enabled.contains(.claude), claudeAuth.isSignedIn, !claudeAuth.needsSignIn {
            series.weights[.claude] = today(claudeHourly)
        }
        if enabled.contains(.grokbot), cursorAuth.isSignedIn, !cursorAuth.needsSignIn {
            series.weights[.grokbot] = today(grokbotHourly)
        }
        if enabled.contains(.cursor), cursorAuth.isSignedIn, !cursorAuth.needsSignIn,
           let hourly = cursorPoller.dayHourlyUsage,
           calendar.isDate(hourly.dayStart, inSameDayAs: dayStart) {
            if hourly.quotaHourWeights.count == 24 { series.weights[.cursor] = hourly.quotaHourWeights }
            if hourly.hourTokenWeights.count == 24 { series.tokens[.cursor] = hourly.hourTokenWeights }
        }
        // OpenCode's hours come from the local database, which needs no
        // console session, so they count whether or not OpenCode is signed in.
        if enabled.contains(.opencode), let hourly = openCodePoller.dayHourlyUsage {
            let monthlyLimit = openCodePoller.snapshot?.windows
                .first { $0.kind == .monthly }?.limitUSD
                ?? OpenCodeWindowKind.monthly.defaultLimitUSD
            series.addOpenCode(hourly, monthlyLimitUSD: monthlyLimit, dayStart: dayStart, calendar: calendar)
        }
        return series
    }

    /// Saves today's Overview chart inputs into the history.
    func recordOverviewHistory(at date: Date = Date()) {
        overviewHistory.record(overviewSeries(on: date), at: date)
    }
}
