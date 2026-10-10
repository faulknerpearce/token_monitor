import Foundation
import os

/// Fetches Cursor dashboard usage via cookie-authenticated unofficial endpoints.
///
/// The usage summary is fetched on every call. Usage events (paged, up to a
/// whole billing cycle) only feed the cost stats, the hourly chart and the
/// daily back-fill, so their aggregates are cached in ``CursorEventCache`` and
/// re-fetched at most every ``eventsRefreshInterval``, or sooner when the day
/// or billing cycle changes. A failed events fetch reuses the cached aggregates.
struct CursorUsageClient: Sendable {
    static let baseURL = URL(staticString: "https://cursor.com")
    private static let log = Logger(category: "Cursor")

    /// Minimum age of cached event aggregates before events are paged again.
    static let eventsRefreshInterval: TimeInterval = 5 * 60

    /// Network seam: a GET of a dashboard path and one page of usage events.
    struct Transport: Sendable {
        var get: @Sendable (_ path: String) async throws -> Data
        var eventsPage: @Sendable (_ startMs: Int64, _ endMs: Int64, _ page: Int, _ pageSize: Int) async throws -> Data
    }

    private let transport: Transport
    private let cacheKey: String
    private let eventCache: CursorEventCache?

    /// Live client for `cookieHeader`; `eventCache` keeps event aggregates
    /// between calls (nil fetches events on every call).
    init(cookieHeader: String, eventCache: CursorEventCache? = nil) {
        self.init(transport: .live(cookieHeader: cookieHeader), cacheKey: cookieHeader, eventCache: eventCache)
    }

    init(transport: Transport, cacheKey: String, eventCache: CursorEventCache?) {
        self.transport = transport
        self.cacheKey = cacheKey
        self.eventCache = eventCache
    }

    /// Fetches the summary and account email, plus event aggregates for `now`
    /// (cached, see the type documentation).
    ///
    /// `costStats` is nil when no event aggregates are available for this
    /// billing cycle; the hourly usage and back-fill weights are then empty.
    func fetchSnapshot(now: Date = Date()) async throws -> (CursorSnapshot, CursorDayHourlyUsage, [Date: Double]) {
        async let summaryData = get(path: "/api/usage-summary")
        async let meData = try? get(path: "/api/auth/me")
        let summary = try await summaryData
        var snap = try Self.parseSummary(data: summary, fetchedAt: now)
        if let meData = await meData,
           let email = Self.parseEmail(from: meData) {
            snap.accountEmail = email
        }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let windowStart = Self.eventsWindowStart(cycleStart: snap.billingCycleStart, now: now, calendar: calendar)
        guard let aggregates = await eventAggregates(for: snap, windowStart: windowStart, now: now, calendar: calendar),
              aggregates.windowStart == windowStart
        else {
            return (snap, .empty(dayStart: dayStart), [:])
        }
        snap.costStats = aggregates.costStats
        let hourly = calendar.isDate(aggregates.hourly.dayStart, inSameDayAs: dayStart)
            ? aggregates.hourly
            : .empty(dayStart: dayStart)
        return (snap, hourly, aggregates.estimatedWeightByDay)
    }

    /// Cached aggregates when fresh, else freshly paged events; on a paging
    /// failure the cached aggregates (possibly stale) or nil.
    private func eventAggregates(
        for snap: CursorSnapshot,
        windowStart: Date,
        now: Date,
        calendar: Calendar
    ) async -> CursorEventAggregates? {
        let cached = eventCache?.value(forKey: cacheKey)
        if let cached, cached.isFresh(windowStart: windowStart, now: now, calendar: calendar) {
            return cached
        }
        do {
            let events = try await fetchAllEvents(from: windowStart, to: now)
            let aggregates = Self.aggregate(events: events, snap: snap, windowStart: windowStart, now: now, calendar: calendar)
            eventCache?.store(aggregates, forKey: cacheKey)
            return aggregates
        } catch {
            Self.log.error("Cursor events fetch failed: \(error.localizedDescription, privacy: .public)")
            return cached
        }
    }

    /// Builds every event-derived figure for one poll.
    static func aggregate(
        events: [[String: Any]],
        snap: CursorSnapshot,
        windowStart: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> CursorEventAggregates {
        let dayStart = calendar.startOfDay(for: now)
        let hourly = CursorDayHourlyUsage(
            dayStart: dayStart,
            hourWeights: hourWeights(fromEvents: events, dayStart: dayStart, calendar: calendar),
            quotaHourWeights: quotaHourWeights(
                fromEvents: events,
                dayStart: dayStart,
                planLimitUSD: snap.planLimitUSD,
                calendar: calendar
            ),
            hourTokenWeights: tokenHourWeights(fromEvents: events, dayStart: dayStart, calendar: calendar)
        )
        // Per-day pool-estimate weights, used only to back-fill days the app
        // did not observe directly (see `CursorUsagePoller.buildDailyBudgetDays`).
        let bounds = DailyBudget.subscriptionMonth(
            knownStart: snap.billingCycleStart,
            resetsAt: snap.billingCycleEnd,
            now: now,
            calendar: calendar
        )
        return CursorEventAggregates(
            fetchedAt: now,
            windowStart: windowStart,
            costStats: aggregateCostStats(events: events, cycleStart: snap.billingCycleStart ?? windowStart),
            hourly: hourly,
            estimatedWeightByDay: dailyEstimateWeightByDay(
                events: events,
                cycleStart: bounds?.start ?? snap.billingCycleStart,
                cycleEnd: bounds?.end ?? snap.billingCycleEnd,
                calendar: calendar
            )
        )
    }

    // MARK: - Parsing (testable)

    /// Parses `usage-summary` into a snapshot, preferring dashboard `totalPercentUsed`.
    static func parseSummary(data: Data, fetchedAt: Date = Date()) throws -> CursorSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse(.cursor, "Expected JSON object")
        }

        let cycleStart = parseISO8601(root["billingCycleStart"] as? String)
        let cycleEnd = parseISO8601(root["billingCycleEnd"] as? String)
        let membership = root["membershipType"] as? String

        let individual = root["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        let overall = individual?["overall"] as? [String: Any]
        let onDemand = individual?["onDemand"] as? [String: Any]
        let team = root["teamUsage"] as? [String: Any]
        let pooled = team?["pooled"] as? [String: Any]

        let planUsedCents = JSON.number(plan?["used"]) ?? 0
        let planLimitCents = JSON.number(plan?["limit"]) ?? 0
        let overallUsed = JSON.number(overall?["used"])
        let overallLimit = JSON.number(overall?["limit"])
        let pooledUsed = JSON.number(pooled?["used"])
        let pooledLimit = JSON.number(pooled?["limit"])

        // Cursor percent fields are in percentage units: 0.36 means 0.36%, under one percent.
        let autoPercent = displayPercent(JSON.number(plan?["autoPercentUsed"]))
        let apiPercent = displayPercent(JSON.number(plan?["apiPercentUsed"]))

        // Total precedence follows the Cursor dashboard.
        let totalPercent: Double = {
            if let total = displayPercent(JSON.number(plan?["totalPercentUsed"])) {
                return total
            }
            if let autoPercent, let apiPercent {
                return Percent.clamp((autoPercent + apiPercent) / 2)
            }
            if let apiPercent { return apiPercent }
            if let autoPercent { return autoPercent }
            if planLimitCents > 0 {
                return Percent.clamp(planUsedCents / planLimitCents * 100)
            }
            if let used = overallUsed, let limit = overallLimit, limit > 0 {
                return Percent.clamp(used / limit * 100)
            }
            if let used = pooledUsed, let limit = pooledLimit, limit > 0 {
                return Percent.clamp(used / limit * 100)
            }
            return 0
        }()

        let planUsedUSD: Double?
        let planLimitUSD: Double?
        if planLimitCents > 0 || planUsedCents > 0 {
            planUsedUSD = planUsedCents / 100
            planLimitUSD = planLimitCents / 100
        } else if let used = overallUsed, let limit = overallLimit {
            planUsedUSD = used / 100
            planLimitUSD = limit / 100
        } else if let used = pooledUsed, let limit = pooledLimit {
            planUsedUSD = used / 100
            planLimitUSD = limit / 100
        } else {
            planUsedUSD = nil
            planLimitUSD = nil
        }

        let onDemandEnabled = (onDemand?["enabled"] as? Bool) ?? false
        let onDemandUsedUSD = JSON.number(onDemand?["used"]).map { $0 / 100 }
        let onDemandLimitUSD = JSON.number(onDemand?["limit"]).map { $0 / 100 }

        var pools: [CursorPoolUsage] = [
            CursorPoolUsage(
                kind: .total,
                usedPercent: totalPercent,
                resetsAt: cycleEnd
            )
        ]
        if let autoPercent {
            pools.append(
                CursorPoolUsage(
                    kind: .auto,
                    usedPercent: autoPercent,
                    resetsAt: cycleEnd
                )
            )
        }
        if let apiPercent {
            pools.append(
                CursorPoolUsage(
                    kind: .api,
                    usedPercent: apiPercent,
                    resetsAt: cycleEnd
                )
            )
        }

        return CursorSnapshot(
            fetchedAt: fetchedAt,
            usedPercent: totalPercent,
            pools: pools,
            billingCycleStart: cycleStart,
            billingCycleEnd: cycleEnd,
            membershipType: membership,
            planUsedUSD: planUsedUSD,
            planLimitUSD: planLimitUSD,
            onDemandEnabled: onDemandEnabled,
            onDemandUsedUSD: onDemandUsedUSD,
            onDemandLimitUSD: onDemandLimitUSD,
            costStats: nil,
            accountEmail: nil
        )
    }

    static func parseEmail(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let email = root["email"] as? String, email.contains("@") {
            return email
        }
        return nil
    }

    /// Parses one usage-events page; a missing count yields `0`, meaning unknown.
    static func parseUsageEventsPage(data: Data) throws -> (events: [[String: Any]], total: Int) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse(.cursor, "Expected events JSON object")
        }
        // Coerce strings and numbers alike; a missing/renamed field yields 0,
        // which the pager treats as unknown and keeps paging.
        let total = JSON.number(root["totalUsageEventsCount"]).map(safeInt) ?? 0
        let events = (root["usageEventsDisplay"] as? [[String: Any]]) ?? []
        return (events, total)
    }

    /// Clamps a JSON number into `Int` (NaN/infinity → 0, out-of-range → the bound);
    /// compares against the `Double` bounds first because `Double(Int.max)` rounds up to 2^63.
    static func safeInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }

    /// Clamps a JSON number into `Int64` (NaN/infinity → 0, out-of-range → the bound).
    static func safeInt64(_ value: Double) -> Int64 {
        guard value.isFinite else { return 0 }
        if value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value)
    }

    /// Cursor Bot (`grok-bot-*`) usage has its own allowance (tracked by the
    /// Grokbot provider) outside the Cursor plan pool; every Cursor aggregation
    /// excludes it.
    static func isGrokBotEvent(_ event: [String: Any]) -> Bool {
        ((event["model"] as? String) ?? "").hasPrefix("grok-bot")
    }

    /// Sums billing-cycle cost and tokens, excluding `grok-bot-*` events.
    static func aggregateCostStats(events: [[String: Any]], cycleStart: Date) -> CursorCostStats {
        var meteredCycleCents = 0.0
        var cycleTokens: Int64 = 0
        var cycleInput: Int64 = 0
        var cycleOutput: Int64 = 0

        for event in events {
            guard !isGrokBotEvent(event) else { continue }
            guard let date = eventTimestamp(event), date >= cycleStart else { continue }
            meteredCycleCents += chargedCents(event)
            cycleTokens += tokenCount(event)
            cycleInput += inputTokenCount(event)
            cycleOutput += outputTokenCount(event)
        }

        return CursorCostStats(
            meteredCycleUSD: meteredCycleCents / 100,
            cycleTokens: cycleTokens,
            cycleInputTokens: cycleInput,
            cycleOutputTokens: cycleOutput
        )
    }

    /// Bucket event activity into 24 hourly weights using requestsCosts, else
    /// token totals, excluding `grok-bot-*` events.
    static func hourWeights(
        fromEvents events: [[String: Any]],
        dayStart: Date,
        calendar: Calendar = .current
    ) -> [Double] {
        var weights = Array(repeating: 0.0, count: 24)
        for event in events {
            guard !isGrokBotEvent(event) else { continue }
            guard let hour = hourIndex(for: event, dayStart: dayStart, calendar: calendar) else {
                continue
            }
            weights[hour] += eventWeight(event)
        }
        return weights
    }

    /// Convert charged cents into percentage points of the Cursor plan quota.
    static func quotaHourWeights(
        fromEvents events: [[String: Any]],
        dayStart: Date,
        planLimitUSD: Double?,
        calendar: Calendar = .current
    ) -> [Double] {
        var weights = Array(repeating: 0.0, count: 24)
        guard let planLimitUSD, planLimitUSD > 0 else { return weights }
        let planLimitCents = planLimitUSD * 100 / QuotaNormalization.averageWeeksPerMonth
        for event in events {
            guard !isGrokBotEvent(event) else { continue }
            guard let hour = hourIndex(for: event, dayStart: dayStart, calendar: calendar) else {
                continue
            }
            let cents = chargedCents(event)
            guard cents > 0 else { continue }
            weights[hour] += cents / planLimitCents * 100
        }
        return weights
    }

    /// Sums input/output/cache tokens per hour, excluding `grok-bot-*` events.
    static func tokenHourWeights(
        fromEvents events: [[String: Any]],
        dayStart: Date,
        calendar: Calendar = .current
    ) -> [Int64] {
        var weights = Array(repeating: Int64(0), count: 24)
        for event in events {
            guard !isGrokBotEvent(event) else { continue }
            guard let hour = hourIndex(for: event, dayStart: dayStart, calendar: calendar) else {
                continue
            }
            weights[hour] += tokenCount(event)
        }
        return weights
    }

    /// Event weight: `requestsCosts`, else token total, else charged cents, else `1`.
    static func eventWeight(_ event: [String: Any]) -> Double {
        if let requests = JSON.number(event["requestsCosts"]), requests > 0 {
            return requests
        }
        let tokens = Double(tokenCount(event))
        if tokens > 0 { return tokens }
        let cents = chargedCents(event)
        if cents > 0 { return cents }
        return 1
    }

    /// Hour of day for events on `dayStart`; `nil` for other days or bad timestamps.
    static func hourIndex(
        for event: [String: Any],
        dayStart: Date,
        calendar: Calendar
    ) -> Int? {
        guard let date = eventTimestamp(event) else { return nil }
        guard calendar.isDate(date, inSameDayAs: dayStart) else { return nil }
        return calendar.component(.hour, from: date)
    }

    /// Event `timestamp` as a `Date`; accepts string/double/int epoch values.
    static func eventTimestamp(_ event: [String: Any]) -> Date? {
        if let msString = event["timestamp"] as? String, let raw = Double(msString) {
            return date(fromEpochNumber: raw)
        }
        if let ms = event["timestamp"] as? Double {
            return date(fromEpochNumber: ms)
        }
        if let ms = event["timestamp"] as? Int {
            return date(fromEpochNumber: Double(ms))
        }
        return nil
    }

    /// Accepts seconds or milliseconds (heuristic on magnitude); returns nil for
    /// implausible/negative values.
    private static func date(fromEpochNumber value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 1_000_000_000_000 ? value / 1000 : value
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Charged cents (`chargedCents`, else `tokenUsage.totalCents`, else `0`).
    static func chargedCents(_ event: [String: Any]) -> Double {
        if let cents = JSON.number(event["chargedCents"]), cents > 0 {
            return cents
        }
        if let tokenUsage = event["tokenUsage"] as? [String: Any],
           let cents = JSON.number(tokenUsage["totalCents"]), cents > 0 {
            return cents
        }
        return 0
    }

    /// Input + output + cache-write + cache-read tokens for one event.
    static func tokenCount(_ event: [String: Any]) -> Int64 {
        guard let tokenUsage = event["tokenUsage"] as? [String: Any] else { return 0 }
        let input = JSON.number(tokenUsage["inputTokens"]) ?? 0
        let output = JSON.number(tokenUsage["outputTokens"]) ?? 0
        let cacheWrite = JSON.number(tokenUsage["cacheWriteTokens"]) ?? 0
        let cacheRead = JSON.number(tokenUsage["cacheReadTokens"]) ?? 0
        return safeInt64(input + output + cacheWrite + cacheRead)
    }

    static func inputTokenCount(_ event: [String: Any]) -> Int64 {
        guard let tokenUsage = event["tokenUsage"] as? [String: Any] else { return 0 }
        return safeInt64(JSON.number(tokenUsage["inputTokens"]) ?? 0)
    }

    static func outputTokenCount(_ event: [String: Any]) -> Int64 {
        guard let tokenUsage = event["tokenUsage"] as? [String: Any] else { return 0 }
        return safeInt64(JSON.number(tokenUsage["outputTokens"]) ?? 0)
    }

    // MARK: - HTTP

    private func fetchAllEvents(from start: Date, to end: Date) async throws -> [[String: Any]] {
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let endMs = Int64(end.timeIntervalSince1970 * 1000)
        var allEvents: [[String: Any]] = []
        var page = 1
        let pageSize = 500
        let pageCap = 40
        while page <= pageCap {
            let data = try await Self.rejectUnauthorizedBody(transport.eventsPage(startMs, endMs, page, pageSize))
            let (events, total) = try Self.parseUsageEventsPage(data: data)
            allEvents.append(contentsOf: events)
            if events.count < pageSize { break }
            // `total <= 0` means the field was absent/unknown — keep paging on
            // the short-page signal.
            if total > 0, allEvents.count >= total { break }
            if page == pageCap {
                Self.log.warning("Cursor event page cap (\(pageCap)) reached; totals may be truncated")
                break
            }
            page += 1
        }
        return allEvents
    }

    private func get(path: String) async throws -> Data {
        try await Self.rejectUnauthorizedBody(transport.get(path))
    }

    /// A 200 response can still signal an expired session: either a
    /// `not_authenticated` error body, or an HTML page served after a redirect to
    /// the WorkOS sign-in flow.
    static func rejectUnauthorizedBody(_ data: Data) throws -> Data {
        let object = try ProviderHTTP.jsonObject(data, context: .cursor)
        if let err = object["error"] as? String, ProviderHTTP.isUnauthorizedMessage(err) {
            throw ProviderError.unauthorized(.cursor)
        }
        return data
    }

    // MARK: - Helpers

    /// Earliest event fetch date: the billing-cycle start, capped at 31
    /// days back (the longest calendar-month cycle); 31 days back without a
    /// known cycle start.
    static func eventsWindowStart(cycleStart: Date?, now: Date, calendar: Calendar = .current) -> Date {
        let dayStart = calendar.startOfDay(for: now)
        let cap = calendar.date(byAdding: .day, value: -31, to: dayStart) ?? now.addingTimeInterval(-31 * 86400)
        guard let cycleStart else { return cap }
        return max(cycleStart, cap)
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return ISO8601DateFormatter.parseFlexible(value)
    }

    /// Clamp dashboard percent fields (already in %-units).
    private static func displayPercent(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return Percent.clamp(value)
    }

    /// Per-day token weight for the pool-estimate back-fill.
    ///
    /// Excludes Cursor Bot (`grok-bot-*`) usage: it has its own allowance (tracked
    /// by the Grokbot provider) outside the Cursor plan pool, so the estimate
    /// reflects plan-pool usage only.
    static func dailyEstimateWeightByDay(
        events: [[String: Any]],
        cycleStart: Date? = nil,
        cycleEnd: Date? = nil,
        calendar: Calendar = .current
    ) -> [Date: Double] {
        var byDay: [Date: Double] = [:]
        for event in events {
            guard let date = eventTimestamp(event) else { continue }
            if let cycleStart, date < cycleStart { continue }
            if let cycleEnd, date >= cycleEnd { continue }
            guard !Self.isGrokBotEvent(event) else { continue }
            let tokens = Double(tokenCount(event))
            guard tokens > 0 else { continue }
            let dayKey = calendar.startOfDay(for: date)
            byDay[dayKey, default: 0] += tokens
        }
        return byDay
    }
}

extension CursorUsageClient.Transport {
    /// Cookie-authenticated requests against cursor.com.
    static func live(cookieHeader: String) -> Self {
        Self(
            get: { path in
                try await ProviderHTTP.get(
                    path,
                    baseURL: CursorUsageClient.baseURL,
                    context: .cursor,
                    cookieHeader: cookieHeader,
                    referer: "https://cursor.com"
                )
            },
            eventsPage: { startMs, endMs, page, pageSize in
                try await ProviderHTTP.post(
                    "/api/dashboard/get-filtered-usage-events",
                    baseURL: CursorUsageClient.baseURL,
                    context: .cursor,
                    json: [
                        "startDate": String(startMs),
                        "endDate": String(endMs),
                        "page": page,
                        "pageSize": pageSize
                    ],
                    cookieHeader: cookieHeader,
                    referer: "https://cursor.com",
                    origin: "https://cursor.com"
                )
            }
        )
    }
}
