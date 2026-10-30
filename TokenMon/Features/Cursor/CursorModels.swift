import Foundation

/// Cursor quota pool (`total` / `auto` / `api`).
enum CursorPoolKind: String, Codable, CaseIterable, Sendable {
    case total
    case auto
    case api

    var label: String {
        switch self {
        case .total: return "Total"
        case .auto: return "Auto"
        case .api: return "API"
        }
    }

    /// Usage-track label naming the models each pool covers.
    var trackLabel: String {
        switch self {
        case .total: return "Total"
        case .auto: return "Auto + Composer"
        case .api: return "API (Other Models)"
        }
    }
}

/// One Cursor quota pool (total / auto / API).
struct CursorPoolUsage: Identifiable, Hashable, Sendable {
    var kind: CursorPoolKind
    /// 0…100 used (matches Cursor dashboard percent fields).
    var usedPercent: Double
    var resetsAt: Date?

    var id: CursorPoolKind { kind }

    var remainingPercent: Double {
        Percent.clamp(100 - usedPercent)
    }
}

/// Metered cost and token totals derived from usage events.
struct CursorCostStats: Hashable, Sendable {
    /// Sum of Cursor `chargedCents` over the billing cycle (USD).
    var meteredCycleUSD: Double
    /// Token total over the billing cycle.
    var cycleTokens: Int64
    var cycleInputTokens: Int64 = 0
    var cycleOutputTokens: Int64 = 0
}

/// Per-hour activity, quota, and token weights for one calendar day.
struct CursorDayHourlyUsage: Hashable, Sendable {
    var dayStart: Date
    /// Raw event activity weights per hour (0…23), retained for diagnostics.
    var hourWeights: [Double]
    /// Percentage-point plan quota consumption per hour (0…23).
    var quotaHourWeights: [Double]
    /// Total input/output/cache tokens per hour (0…23).
    var hourTokenWeights: [Int64] = Array(repeating: 0, count: 24)

    var isEmpty: Bool {
        quotaHourWeights.allSatisfy { $0 <= 0 } && hourWeights.allSatisfy { $0 <= 0 }
    }

    /// All-zero weights for `dayStart`.
    static func empty(dayStart: Date) -> Self {
        Self(
            dayStart: dayStart,
            hourWeights: Array(repeating: 0, count: 24),
            quotaHourWeights: Array(repeating: 0, count: 24)
        )
    }
}

/// Every figure derived from one page-through of Cursor usage events.
struct CursorEventAggregates: Sendable {
    /// When the events were fetched.
    var fetchedAt: Date
    /// Earliest event instant requested (see `CursorUsageClient.eventsWindowStart`).
    var windowStart: Date
    var costStats: CursorCostStats
    /// Hourly weights for the calendar day of `fetchedAt`.
    var hourly: CursorDayHourlyUsage
    /// Per-day token weight for the daily back-fill.
    var estimatedWeightByDay: [Date: Double]

    /// True when these aggregates can stand in for a fresh fetch at `now`:
    /// same event window, same calendar day, and younger than
    /// `CursorUsageClient.eventsRefreshInterval`.
    func isFresh(windowStart: Date, now: Date, calendar: Calendar = .current) -> Bool {
        self.windowStart == windowStart
            && calendar.isDate(fetchedAt, inSameDayAs: now)
            && now.timeIntervalSince(fetchedAt) < CursorUsageClient.eventsRefreshInterval
            && now >= fetchedAt
    }
}

/// One Cursor usage event, read once from the events JSON.
struct CursorUsageEvent: Hashable, Sendable {
    var date: Date
    var chargedCents: Double
    var requestsCosts: Double
    var inputTokens: Int64
    var outputTokens: Int64
    /// Input + output + cache-write + cache-read tokens.
    var totalTokens: Int64

    /// Activity weight: `requestsCosts`, else the token total, else charged
    /// cents, else `1`.
    var weight: Double {
        if requestsCosts > 0 { return requestsCosts }
        if totalTokens > 0 { return Double(totalTokens) }
        if chargedCents > 0 { return chargedCents }
        return 1
    }

    /// Reads one `usageEventsDisplay` entry; nil without a usable timestamp,
    /// and nil for Cursor Bot (`grok-bot-*`) usage, which has its own
    /// allowance (tracked by the Grokbot provider) outside the Cursor plan pool.
    init?(json event: [String: Any]) {
        guard !((event["model"] as? String) ?? "").hasPrefix("grok-bot"),
              let date = CursorUsageClient.eventTimestamp(event)
        else { return nil }
        self.init(
            date: date,
            chargedCents: CursorUsageClient.chargedCents(event),
            requestsCosts: max(0, JSON.number(event["requestsCosts"]) ?? 0),
            inputTokens: CursorUsageClient.inputTokenCount(event),
            outputTokens: CursorUsageClient.outputTokenCount(event),
            totalTokens: CursorUsageClient.tokenCount(event)
        )
    }

    init(
        date: Date,
        chargedCents: Double = 0,
        requestsCosts: Double = 0,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        totalTokens: Int64 = 0
    ) {
        self.date = date
        self.chargedCents = chargedCents
        self.requestsCosts = requestsCosts
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

/// The parsed events of one event window, kept so a later fetch pages only
/// the events since `fetchedThrough`.
struct CursorEventLedger: Sendable {
    var windowStart: Date
    var events: [CursorUsageEvent]
    /// End of the last fetched range.
    var fetchedThrough: Date
    /// When every event of the window was last paged.
    var fullFetchAt: Date

    /// True when a fetch at `now` can page only the events since
    /// `fetchedThrough`: same window, and the last full page-through is younger
    /// than `CursorUsageClient.eventsFullRefreshInterval`.
    func canExtend(windowStart: Date, now: Date) -> Bool {
        self.windowStart == windowStart
            && now >= fetchedThrough
            && now.timeIntervalSince(fullFetchAt) < CursorUsageClient.eventsFullRefreshInterval
    }
}

/// In-memory cache of the last event aggregates and the events behind them,
/// keyed by session so each account sees only its own figures.
final class CursorEventCache: @unchecked Sendable {
    private struct Entry {
        var key: String
        var aggregates: CursorEventAggregates
        var ledger: CursorEventLedger?
    }

    private let lock = NSLock()
    private var entry: Entry?

    /// Cached aggregates for `key`, or nil.
    func value(forKey key: String) -> CursorEventAggregates? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.key == key else { return nil }
        return entry.aggregates
    }

    /// Cached events for `key`, or nil.
    func ledger(forKey key: String) -> CursorEventLedger? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.key == key else { return nil }
        return entry.ledger
    }

    /// Replaces the cached aggregates and events.
    func store(_ aggregates: CursorEventAggregates, ledger: CursorEventLedger? = nil, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        entry = Entry(key: key, aggregates: aggregates, ledger: ledger)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
    }
}

/// Headline Cursor quota snapshot plus plan and cost details.
struct CursorSnapshot: Identifiable, Hashable, Sendable {
    var id: Date { fetchedAt }
    var fetchedAt: Date
    /// Headline Total used % — Overview ring + primary metric.
    var usedPercent: Double
    var pools: [CursorPoolUsage]
    var billingCycleStart: Date?
    var billingCycleEnd: Date?
    var membershipType: String?
    /// Included plan spend in USD (cents ÷ 100).
    var planUsedUSD: Double?
    var planLimitUSD: Double?
    var onDemandEnabled: Bool
    var onDemandUsedUSD: Double?
    var onDemandLimitUSD: Double?
    var costStats: CursorCostStats?
    var accountEmail: String?

    var resetsAt: Date? { billingCycleEnd }

    var displayPlanName: String {
        guard let membershipType, !membershipType.isEmpty else { return "Cursor" }
        let trimmed = membershipType.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("cursor") {
            return trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased()
        }
        return "Cursor \(trimmed.prefix(1).uppercased())\(trimmed.dropFirst().lowercased())"
    }
}
