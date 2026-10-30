import Foundation
import SQLite3

/// Local OpenCode SQLite failures (missing DB, open, or query).
enum OpenCodeLocalStatsError: LocalizedError {
    case databaseMissing(URL)
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case let .databaseMissing(url):
            return "OpenCode usage database not found at \(url.path). Install and use OpenCode to track usage."
        case let .openFailed(message):
            return "Could not open the OpenCode usage database: \(message)"
        case let .queryFailed(message):
            return "Could not read OpenCode usage: \(message)"
        }
    }
}

/// Local OpenCode SQLite usage (fallback when the console is unreachable).
enum OpenCodeLocalStats {
    static let rolling5hSeconds: TimeInterval = 5 * 3600

    static var databaseDirectory: URL {
        AppSupport.realHomeDirectory
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    static var databaseURL: URL {
        databaseDirectory.appendingPathComponent("opencode.db")
    }

    /// OpenCode Go subscription usage only (`opencode-go`); only these count
    /// toward the Go $12 / $30 / $60 limits.
    static func goEligibleProvider(_ providerID: String) -> Bool {
        providerID.lowercased() == "opencode-go"
    }

    /// Go or Zen plan providers shown in the OpenCode models list / heatmap.
    /// Direct BYOK keys (`deepseek`, `xai`, `openai`, …) are excluded.
    static func planEligibleProvider(_ providerID: String) -> Bool {
        OpenCodeZenCostEstimate.isPlanProvider(providerID)
    }

    /// UTC Monday–Sunday week, matching OpenCode server `getWeekBounds`.
    static func weeklyBounds(now: Date = Date()) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcNow = now
        let day = calendar.component(.weekday, from: utcNow) // 1=Sun … 7=Sat
        // Convert to Monday-based offset: Mon=0 … Sun=6
        let offset = (day + 5) % 7
        let startOfDay = calendar.startOfDay(for: utcNow)
        let start = calendar.date(byAdding: .day, value: -offset, to: startOfDay) ?? startOfDay
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        return (start, end)
    }

    /// Subscription-anchored month, matching OpenCode server `getMonthlyBounds(now, subscribed)`.
    /// `subscribedAt` is the Go plan start (UTC components of that instant).
    static func monthlyBounds(now: Date = Date(), subscribedAt: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let day = calendar.component(.day, from: subscribedAt)
        let hour = calendar.component(.hour, from: subscribedAt)
        let minute = calendar.component(.minute, from: subscribedAt)
        let second = calendar.component(.second, from: subscribedAt)
        let nanosecond = calendar.component(.nanosecond, from: subscribedAt)

        func anchor(year: Int, month: Int) -> Date {
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            let maxDay = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? now)?.count ?? 28
            comps.day = min(day, maxDay)
            comps.hour = hour
            comps.minute = minute
            comps.second = second
            comps.nanosecond = nanosecond
            return calendar.date(from: comps) ?? now
        }

        func shift(year: Int, month: Int, delta: Int) -> (Int, Int) {
            let total = year * 12 + (month - 1) + delta
            let shiftedYear = Int(floor(Double(total) / 12.0))
            let shiftedMonth = ((total % 12) + 12) % 12 + 1
            return (shiftedYear, shiftedMonth)
        }

        var y = calendar.component(.year, from: now)
        var month = calendar.component(.month, from: now)
        var start = anchor(year: y, month: month)
        if start > now {
            (y, month) = shift(year: y, month: month, delta: -1)
            start = anchor(year: y, month: month)
        }
        let (nextYear, nextMonth) = shift(year: y, month: month, delta: 1)
        let end = anchor(year: nextYear, month: nextMonth)
        return (start, end)
    }

    /// One assistant `message` record: the per-turn model, cost, and tokens.
    struct SessionRow: Sendable {
        var timeCreatedMS: Int64
        var costUSD: Double
        var inputTokens: Int64
        var outputTokens: Int64
        var cacheReadTokens: Int64
        var cacheWriteTokens: Int64
        var providerID: String
        var modelID: String
        var sessionID: String = ""

        var date: Date { Date(timeIntervalSince1970: TimeInterval(timeCreatedMS) / 1000) }

        var totalTokens: Int64 { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }

        /// Recorded cost, or a token-based estimate for a `$0` plan row.
        var billable: (cost: Double, isEstimated: Bool, isUnpriced: Bool) {
            OpenCodeZenCostEstimate.billableCostUSD(
                providerID: providerID,
                modelID: modelID,
                recordedCostUSD: costUSD,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens
            )
        }
    }

    /// Shared cache of the last database read (see ``OpenCodeLocalScanCache``).
    static let scanCache = OpenCodeLocalScanCache()

    /// Days of messages one scan covers: the longest subscription month plus
    /// the four weeks of history the daily-budget arrows browse, with slack.
    static let scanLookbackDays = 62

    /// Earliest message instant the standard scan for `now` reads.
    static func scanStart(now: Date) -> Date {
        now.addingTimeInterval(-TimeInterval(scanLookbackDays) * 86400)
    }

    /// Assistant messages since `since` plus the first Go session, from the
    /// cache when the database and its WAL are unchanged and the cached scan
    /// reaches back far enough; otherwise one read on one connection.
    static func loadScan(
        dbURL: URL,
        since: Date,
        cache: OpenCodeLocalScanCache = scanCache
    ) throws -> OpenCodeLocalScan {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw OpenCodeLocalStatsError.databaseMissing(dbURL)
        }
        return try cache.scan(dbURL: dbURL, since: since) {
            let db = try openConnection(at: dbURL)
            defer { sqlite3_close(db) }
            return try OpenCodeLocalScan(
                since: since,
                subscribedAt: earliestGoSessionDate(db: db),
                rows: readAssistantMessageRows(from: db, startMS: milliseconds(since))
            )
        }
    }

    static func fetchSnapshot(now: Date = Date()) throws -> OpenCodeSnapshot {
        try fetchSnapshot(dbURL: databaseURL, now: now)
    }

    /// Builds rolling, weekly, and monthly usage from `opencode.db`.
    static func fetchSnapshot(dbURL: URL, now: Date = Date()) throws -> OpenCodeSnapshot {
        try snapshot(from: loadScan(dbURL: dbURL, since: scanStart(now: now)), now: now)
    }

    /// Rolling, weekly, and monthly Go usage, the weekly model breakdown, and
    /// monthly plan totals, all bucketed by message time.
    ///
    /// The monthly figures come from the month's own messages only, so total
    /// tokens always equal input + output + cache tokens.
    static func snapshot(from scan: OpenCodeLocalScan, now: Date) -> OpenCodeSnapshot {
        let rollingStart = now.addingTimeInterval(-rolling5hSeconds)
        let week = weeklyBounds(now: now)
        let month = monthlyBounds(now: now, subscribedAt: scan.subscribedAt ?? now)

        var rollingRows: [SessionRow] = []
        var weekRows: [SessionRow] = []
        var monthRows: [SessionRow] = []
        for row in scan.rows {
            let date = row.date
            if date >= rollingStart { rollingRows.append(row) }
            if date >= week.start, date < week.end { weekRows.append(row) }
            if date >= month.start, date < month.end { monthRows.append(row) }
        }

        let windows = [
            windowUsage(kind: .rolling5h, rows: rollingRows, resetsAt: rollingReset(rows: rollingRows)),
            windowUsage(kind: .weekly, rows: weekRows, resetsAt: week.end),
            windowUsage(kind: .monthly, rows: monthRows, resetsAt: month.end)
        ]
        let models = modelUsage(rows: weekRows.filter { planEligibleProvider($0.providerID) })
        let monthPlanRows = monthRows.filter { planEligibleProvider($0.providerID) }
        let monthTotals = tokenTotals(rows: monthPlanRows)

        return OpenCodeSnapshot(
            fetchedAt: now,
            windows: windows,
            models: models,
            isEstimated: true,
            monthlyTokens: monthTotals.input + monthTotals.output + monthTotals.cacheRead + monthTotals.cacheWrite,
            monthlyEstimatedUSD: monthPlanRows.reduce(0) { $0 + $1.billable.cost },
            monthlyInputTokens: monthTotals.input,
            monthlyOutputTokens: monthTotals.output
        )
    }

    static func fetchDayHourlyUsage(now: Date = Date()) throws -> OpenCodeDayHourlyUsage {
        try fetchDayHourlyUsage(dbURL: databaseURL, now: now)
    }

    /// Builds today's 24 hourly model-cost stacks from `opencode.db`.
    static func fetchDayHourlyUsage(dbURL: URL, now: Date = Date()) throws -> OpenCodeDayHourlyUsage {
        try buildDayHourlyUsage(rows: loadScan(dbURL: dbURL, since: scanStart(now: now)).rows, now: now)
    }

    /// Local-calendar day, 24 hourly stacks of model cost (all providers).
    /// Mutable per-hour accumulator keyed by `provider/model` while building day usage.
    private struct HourlyBucket {
        let providerID: String
        let modelID: String
        var cost: Double
        var quotaCost: Double
        var inputTokens: Int64
        var outputTokens: Int64
        var cacheReadTokens: Int64
        var cacheWriteTokens: Int64
        var messages: Int

        init(providerID: String, modelID: String) {
            self.providerID = providerID
            self.modelID = modelID
            cost = 0
            quotaCost = 0
            inputTokens = 0
            outputTokens = 0
            cacheReadTokens = 0
            cacheWriteTokens = 0
            messages = 0
        }
    }

    /// Groups message rows into 24 hourly stacks with quota costs and legend.
    static func buildDayHourlyUsage(
        rows: [SessionRow],
        now: Date = Date(),
        maxLegendModels: Int = 8
    ) -> OpenCodeDayHourlyUsage {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        let dayRows = rows.filter { inWindow($0, start: dayStart, end: dayEnd) }

        // hour → modelKey → accumulated usage
        var byHour: [Int: [String: HourlyBucket]] = [:]
        var modelTotals: [String: (providerID: String, modelID: String, cost: Double)] = [:]
        var hourMessageCounts: [Int: Int] = [:]

        for row in dayRows {
            let time = Date(timeIntervalSince1970: TimeInterval(row.timeCreatedMS) / 1000)
            let hour = calendar.component(.hour, from: time)
            let key = "\(row.providerID)/\(row.modelID)"
            var hourMap = byHour[hour] ?? [:]
            var entry = hourMap[key] ?? HourlyBucket(providerID: row.providerID, modelID: row.modelID)
            entry.cost += row.costUSD
            entry.quotaCost += row.billable.cost
            entry.inputTokens += row.inputTokens
            entry.outputTokens += row.outputTokens
            entry.cacheReadTokens += row.cacheReadTokens
            entry.cacheWriteTokens += row.cacheWriteTokens
            entry.messages += 1
            hourMap[key] = entry
            byHour[hour] = hourMap
            hourMessageCounts[hour, default: 0] += 1

            var total = modelTotals[key] ?? (row.providerID, row.modelID, 0)
            total.cost += row.costUSD
            modelTotals[key] = total
        }

        let hours: [OpenCodeHourUsage] = (0..<24).map { hour in
            let segs = (byHour[hour] ?? [:]).values
                .filter { $0.cost > 0 || $0.messages > 0 }
                .sorted { lhs, rhs in
                    if lhs.cost != rhs.cost { return lhs.cost > rhs.cost }
                    return lhs.messages > rhs.messages
                }
                .map {
                    OpenCodeHourSegment(
                        providerID: $0.providerID,
                        modelID: $0.modelID,
                        costUSD: $0.cost,
                        quotaCostUSD: $0.quotaCost,
                        inputTokens: $0.inputTokens,
                        outputTokens: $0.outputTokens,
                        cacheReadTokens: $0.cacheReadTokens,
                        cacheWriteTokens: $0.cacheWriteTokens,
                        messageCount: $0.messages
                    )
                }
            return OpenCodeHourUsage(
                hour: hour,
                segments: segs,
                messageCount: hourMessageCounts[hour] ?? 0
            )
        }

        let legend = modelTotals.values
            .sorted { $0.cost > $1.cost }
            .prefix(maxLegendModels)
            .map {
                OpenCodeHourLegendItem(
                    id: "\($0.providerID)/\($0.modelID)",
                    label: $0.modelID,
                    providerID: $0.providerID,
                    modelID: $0.modelID
                )
            }

        return OpenCodeDayHourlyUsage(dayStart: dayStart, hours: hours, legend: Array(legend))
    }

    static func inWindow(_ row: SessionRow, start: Date, end: Date) -> Bool {
        let time = row.date
        return time >= start && time < end
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    /// Go usage in one window: billable cost (recorded, or estimated for a `$0`
    /// row, matching the daily bars) and distinct sessions.
    private static func windowUsage(kind: OpenCodeWindowKind, rows: [SessionRow], resetsAt: Date?) -> OpenCodeWindowUsage {
        let eligible = rows.filter { goEligibleProvider($0.providerID) }
        let used = eligible.reduce(0) { $0 + $1.billable.cost }
        return OpenCodeWindowUsage(
            kind: kind,
            usedUSD: used,
            limitUSD: kind.defaultLimitUSD,
            resetsAt: resetsAt,
            sessionCount: sessionCount(eligible)
        )
    }

    /// Distinct sessions among `rows`; a row without a session id counts alone.
    private static func sessionCount(_ rows: [SessionRow]) -> Int {
        var ids = Set<String>()
        var anonymous = 0
        for row in rows {
            if row.sessionID.isEmpty {
                anonymous += 1
            } else {
                ids.insert(row.sessionID)
            }
        }
        return ids.count + anonymous
    }

    /// Last Go message in the rolling window plus the rolling duration.
    private static func rollingReset(rows: [SessionRow]) -> Date? {
        let eligible = rows.filter { goEligibleProvider($0.providerID) }
        guard let last = eligible.map(\.date).max() else { return nil }
        return last.addingTimeInterval(rolling5hSeconds)
    }

    private static func modelUsage(rows: [SessionRow]) -> [OpenCodeModelUsage] {
        var byKey: [String: OpenCodeModelUsage] = [:]
        var sessionsByKey: [String: Set<String>] = [:]
        for row in rows {
            let key = "\(row.providerID)/\(row.modelID)"
            var usage = byKey[key] ?? OpenCodeModelUsage(
                providerID: row.providerID,
                modelID: row.modelID,
                sessionCount: 0,
                inputTokens: 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                costUSD: 0,
                percentOfWindow: 0,
                isCostEstimated: false
            )
            if row.sessionID.isEmpty {
                usage.sessionCount += 1
            } else {
                var ids = sessionsByKey[key] ?? []
                ids.insert(row.sessionID)
                sessionsByKey[key] = ids
                usage.sessionCount = ids.count
            }
            usage.inputTokens += row.inputTokens
            usage.outputTokens += row.outputTokens
            usage.cacheReadTokens += row.cacheReadTokens
            usage.cacheWriteTokens += row.cacheWriteTokens

            let billable = row.billable
            usage.costUSD += billable.cost
            if billable.isEstimated {
                usage.isCostEstimated = true
            }
            if billable.isUnpriced {
                usage.isCostUnpriced = true
            }
            byKey[key] = usage
        }
        let used = byKey.values.filter { usage in
            usage.sessionCount > 0
                && (usage.costUSD > 0
                        || usage.inputTokens > 0
                        || usage.outputTokens > 0
                        || usage.cacheReadTokens > 0
                        || usage.cacheWriteTokens > 0)
        }
        let totalCost = used.reduce(0) { $0 + $1.costUSD }
        return used
            .sorted { lhs, rhs in
                if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
                return lhs.outputTokens > rhs.outputTokens
            }
            .map { usage in
                var copy = usage
                copy.percentOfWindow = totalCost > 0 ? copy.costUSD / totalCost * 100 : 0
                return copy
            }
    }

    private static func tokenTotals(rows: [SessionRow]) -> (input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64) {
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheWrite: Int64 = 0
        for row in rows {
            input += row.inputTokens
            output += row.outputTokens
            cacheRead += row.cacheReadTokens
            cacheWrite += row.cacheWriteTokens
        }
        return (input, output, cacheRead, cacheWrite)
    }
}
