import Foundation

/// Tokens used on one day, shown in the daily bars' hover label.
///
/// Providers that can count tokens per request (Claude Code transcripts,
/// OpenCode's local database, Cursor usage events) build one per local day
/// with ``DailyTokenUsageTally`` and attach it to their bars with
/// ``Swift/Array/attachingTokens(_:calendar:)``.
struct DailyTokenUsage: Hashable, Sendable {
    /// One model's share of the day.
    struct Model: Hashable, Sendable {
        var name: String
        var tokens: Int64
    }

    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var cacheWriteTokens: Int64 = 0
    /// Cost of the priced usage; `nil` when none of it has a price.
    var costUSD: Double?
    /// True when some usage has no price, so `costUSD` leaves it out.
    var hasUnpriced = false
    /// Models by tokens, most first.
    var models: [Model] = []

    var totalTokens: Int64 {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    /// Adds one request's (or one model's summed) usage.
    ///
    /// - Parameters:
    ///   - model: Display name the usage is listed under; usage with the same
    ///     name is merged. Empty names count toward the totals only.
    ///   - costUSD: Its cost, or `nil` when it has no price.
    mutating func add(
        model: String,
        input: Int64 = 0,
        output: Int64 = 0,
        cacheRead: Int64 = 0,
        cacheWrite: Int64 = 0,
        costUSD cost: Double?
    ) {
        let tokens = input + output + cacheRead + cacheWrite
        inputTokens += input
        outputTokens += output
        cacheReadTokens += cacheRead
        cacheWriteTokens += cacheWrite
        if let cost {
            costUSD = (costUSD ?? 0) + cost
        } else if tokens > 0 {
            hasUnpriced = true
        }
        guard tokens > 0, !model.isEmpty else { return }
        if let index = models.firstIndex(where: { $0.name == model }) {
            models[index].tokens += tokens
        } else {
            models.append(Model(name: model, tokens: tokens))
        }
        models.sort { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.name < $1.name }
    }
}

/// ``DailyTokenUsage`` per local day (``DayKey`` in `calendar`), built one
/// request at a time.
struct DailyTokenUsageTally {
    let calendar: Calendar
    private(set) var days: [String: DailyTokenUsage] = [:]

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Adds usage made at `date` to its local day; see ``DailyTokenUsage/add(model:input:output:cacheRead:cacheWrite:costUSD:)``.
    mutating func add(
        at date: Date,
        model: String,
        input: Int64 = 0,
        output: Int64 = 0,
        cacheRead: Int64 = 0,
        cacheWrite: Int64 = 0,
        costUSD: Double?
    ) {
        days[DayKey.key(for: date, calendar: calendar), default: DailyTokenUsage()].add(
            model: model,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            costUSD: costUSD
        )
    }
}

extension [DailyBudgetDay] {
    /// The bars with each day's tokens from `tokensForDay`, which is asked
    /// for the ``DayKey`` of each bar's local day in `calendar`; a day it
    /// has nothing for keeps `tokens` nil.
    func attachingTokens(
        calendar: Calendar = .current,
        _ tokensForDay: (String) -> DailyTokenUsage?
    ) -> [DailyBudgetDay] {
        map { day in
            var copy = day
            if let tokens = tokensForDay(DayKey.key(for: day.date, calendar: calendar)) {
                copy.tokens = tokens
            }
            return copy
        }
    }

    /// The bars with each day's tokens from `byDay`, keyed by ``DayKey``.
    func attachingTokens(_ byDay: [String: DailyTokenUsage], calendar: Calendar = .current) -> [DailyBudgetDay] {
        guard !byDay.isEmpty else { return self }
        return attachingTokens(calendar: calendar) { byDay[$0] }
    }
}
