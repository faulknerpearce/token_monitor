import Foundation

/// Reading usage events and the figures derived from them.
extension CursorUsageClient {
    /// Sums billing-cycle cost and tokens.
    static func aggregateCostStats(events: [CursorUsageEvent], cycleStart: Date) -> CursorCostStats {
        var meteredCycleCents = 0.0
        var cycleTokens: Int64 = 0
        var cycleInput: Int64 = 0
        var cycleOutput: Int64 = 0

        for event in events where event.date >= cycleStart {
            meteredCycleCents += event.chargedCents
            cycleTokens += event.totalTokens
            cycleInput += event.inputTokens
            cycleOutput += event.outputTokens
        }

        return CursorCostStats(
            meteredCycleUSD: meteredCycleCents / 100,
            cycleTokens: cycleTokens,
            cycleInputTokens: cycleInput,
            cycleOutputTokens: cycleOutput
        )
    }

    /// Bucket event activity into 24 hourly weights (see ``CursorUsageEvent/weight``).
    static func hourWeights(
        fromEvents events: [CursorUsageEvent],
        dayStart: Date,
        calendar: Calendar = .current
    ) -> [Double] {
        var weights = Array(repeating: 0.0, count: 24)
        for (hour, event) in hourlyEvents(events, dayStart: dayStart, calendar: calendar) {
            weights[hour] += event.weight
        }
        return weights
    }

    /// Convert charged cents into percentage points of the Cursor plan quota.
    static func quotaHourWeights(
        fromEvents events: [CursorUsageEvent],
        dayStart: Date,
        planLimitUSD: Double?,
        calendar: Calendar = .current
    ) -> [Double] {
        var weights = Array(repeating: 0.0, count: 24)
        guard let planLimitUSD, planLimitUSD > 0 else { return weights }
        let planLimitCents = planLimitUSD * 100 / QuotaNormalization.averageWeeksPerMonth
        for (hour, event) in hourlyEvents(events, dayStart: dayStart, calendar: calendar) where event.chargedCents > 0 {
            weights[hour] += event.chargedCents / planLimitCents * 100
        }
        return weights
    }

    /// Sums input/output/cache tokens per hour.
    static func tokenHourWeights(
        fromEvents events: [CursorUsageEvent],
        dayStart: Date,
        calendar: Calendar = .current
    ) -> [Int64] {
        var weights = Array(repeating: Int64(0), count: 24)
        for (hour, event) in hourlyEvents(events, dayStart: dayStart, calendar: calendar) {
            weights[hour] += event.totalTokens
        }
        return weights
    }

    /// The events on the day starting at `dayStart`, with their hour of day.
    /// The day's bounds are computed once, so only that day's events need a
    /// calendar lookup.
    static func hourlyEvents(
        _ events: [CursorUsageEvent],
        dayStart: Date,
        calendar: Calendar
    ) -> [(hour: Int, event: CursorUsageEvent)] {
        let start = calendar.startOfDay(for: dayStart)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return events.compactMap { event in
            guard event.date >= start, event.date < end else { return nil }
            return (calendar.component(.hour, from: event.date), event)
        }
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
    static func date(fromEpochNumber value: Double) -> Date? {
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

    /// Per-day token weight for the pool-estimate back-fill, within the
    /// half-open billing cycle when its bounds are known.
    static func dailyEstimateWeightByDay(
        events: [CursorUsageEvent],
        cycleStart: Date? = nil,
        cycleEnd: Date? = nil,
        calendar: Calendar = .current
    ) -> [Date: Double] {
        var byDay: [Date: Double] = [:]
        for event in events where event.totalTokens > 0 {
            if let cycleStart, event.date < cycleStart { continue }
            if let cycleEnd, event.date >= cycleEnd { continue }
            byDay[calendar.startOfDay(for: event.date), default: 0] += Double(event.totalTokens)
        }
        return byDay
    }
}
