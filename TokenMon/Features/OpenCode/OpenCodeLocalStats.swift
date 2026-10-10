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

    /// Real user home outside the sandbox container (`NSHomeDirectory` resolves
    /// to the app container). Resolved once with the reentrant `getpwuid_r`, so
    /// detached readers avoid sharing `getpwuid`'s static buffer.
    static let realHomeDirectory: URL = {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let suggested = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
        var buffer = [CChar](repeating: 0, count: suggested > 0 ? suggested : 4096)
        if getpwuid_r(getuid(), &record, &buffer, buffer.count, &result) == 0,
           result != nil, let dir = record.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }()

    static var databaseDirectory: URL {
        realHomeDirectory
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

    /// Grok used through the OpenCode harness (counts toward Overview Grok).
    static func grokViaOpenCode(providerID: String, modelID: String = "") -> Bool {
        let provider = providerID.lowercased()
        if provider == "xai" { return true }
        return modelID.lowercased().contains("grok")
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
        var billable: (cost: Double, isEstimated: Bool) {
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

    private static func inWindow(_ row: SessionRow, start: Date, end: Date) -> Bool {
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

    /// Opens a readonly connection. The plain path (no URI parsing) avoids a
    /// home directory containing `#`, `?`, or `%` truncating a `file:` URI;
    /// `SQLITE_OPEN_READONLY` already implies the `mode=ro` behavior.
    private static func openConnection(at dbURL: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw OpenCodeLocalStatsError.openFailed(message)
        }
        sqlite3_busy_timeout(db, 2000)
        return db!
    }

    /// First unarchived Go session: the subscription anchor for the monthly window.
    private static func earliestGoSessionDate(db: OpaquePointer) throws -> Date? {
        let sql = """
        SELECT MIN(time_created) FROM session \
        WHERE time_archived IS NULL \
          AND lower(CASE WHEN json_valid(model) THEN json_extract(model, '$.providerID') END) = 'opencode-go'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OpenCodeLocalStatsError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw OpenCodeLocalStatsError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)) / 1000)
    }

    /// Assistant messages created at or after `startMS`. Assistant messages carry
    /// the real per-turn model and cost (a session stores only one model), and
    /// SQLite extracts just the needed JSON fields.
    private static func readAssistantMessageRows(from db: OpaquePointer, startMS: Int64) throws -> [SessionRow] {
        let sql = """
        SELECT time_created, session_id, \
          json_extract(data, '$.providerID'), json_extract(data, '$.modelID'), \
          json_extract(data, '$.cost'), \
          json_extract(data, '$.tokens.input'), json_extract(data, '$.tokens.output'), \
          json_extract(data, '$.tokens.cache.read'), json_extract(data, '$.tokens.cache.write') \
        FROM message \
        WHERE time_created >= ? \
          AND (CASE WHEN json_valid(data) THEN json_extract(data, '$.role') END) = 'assistant'
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OpenCodeLocalStatsError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, startMS)

        func text(_ column: Int32) -> String {
            sqlite3_column_text(stmt, column)
                .map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }

        var rows: [SessionRow] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            // `defer` advances the cursor even on the `continue` path below, so
            // a skipped row still moves the loop forward.
            defer { step = sqlite3_step(stmt) }
            let providerID = text(2)
            let modelID = text(3)
            guard !providerID.isEmpty, !modelID.isEmpty else { continue }
            rows.append(SessionRow(
                timeCreatedMS: sqlite3_column_int64(stmt, 0),
                costUSD: sqlite3_column_double(stmt, 4),
                inputTokens: sqlite3_column_int64(stmt, 5),
                outputTokens: sqlite3_column_int64(stmt, 6),
                cacheReadTokens: sqlite3_column_int64(stmt, 7),
                cacheWriteTokens: sqlite3_column_int64(stmt, 8),
                providerID: providerID,
                modelID: modelID,
                sessionID: text(1)
            ))
        }
        // A terminal error (e.g. SQLITE_BUSY past the timeout, or a corrupt page)
        // throws, so a partial read that undercounts surfaces as a failure.
        guard step == SQLITE_DONE else {
            throw OpenCodeLocalStatsError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        return rows
    }

    // MARK: - Daily budget

    /// Daily USD spend per calendar day for the current monthly period, counting
    /// only Go-plan usage (Zen is free and tracked separately in the models and
    /// overview sections).
    static func fetchMonthDailySpends(now: Date = Date()) throws -> [Date: Double] {
        try fetchMonthDailySpends(dbURL: databaseURL, now: now)
    }

    /// Daily Go spend for the subscription-anchored month from `opencode.db`.
    static func fetchMonthDailySpends(dbURL: URL, now: Date) throws -> [Date: Double] {
        let scan = try loadScan(dbURL: dbURL, since: scanStart(now: now))
        let month = monthlyBounds(now: now, subscribedAt: scan.subscribedAt ?? now)
        return dailySpendsByDay(rows: scan.rows.filter {
            goEligibleProvider($0.providerID) && inWindow($0, start: month.start, end: month.end)
        })
    }

    /// Go-plan USD spend per calendar day within an explicit window, so the
    /// per-day shape matches the console billing window.
    static func fetchDailySpends(
        from start: Date,
        to end: Date,
        dbURL: URL = databaseURL,
        calendar: Calendar = .current
    ) -> [Date: Double] {
        guard let scan = try? loadScan(dbURL: dbURL, since: start) else { return [:] }
        return dailySpendsByDay(
            rows: scan.rows.filter { goEligibleProvider($0.providerID) && inWindow($0, start: start, end: end) },
            calendar: calendar
        )
    }

    /// Sums billable Go spend per calendar day, skipping `$0` rows.
    static func dailySpendsByDay(rows: [SessionRow], calendar: Calendar = .current) -> [Date: Double] {
        var byDay: [Date: Double] = [:]
        for row in rows {
            let billable = row.billable.cost
            guard billable > 0 else { continue }
            let dayKey = calendar.startOfDay(for: row.date)
            byDay[dayKey, default: 0] += billable
        }
        return byDay
    }

    /// Scaled in-period spends plus unscaled history so the panel can re-slice
    /// an earlier Monday week without reading SQLite again.
    struct OpenCodeMonthBudget: Sendable {
        var days: [DailyBudgetDay]
        var periodStart: Date
        /// Percent of the monthly pool, scaled so in-period days sum to the headline used %.
        var spentPercentByDay: [Date: Double]
        /// Percent of the monthly limit for days before the period, unscaled.
        var historyPercentByDay: [Date: Double]
        var knownStart: Date?
        var resetsAt: Date?
        var referenceNow: Date
    }

    /// Builds the last-7 daily-budget bars for the Go **subscription** month,
    /// plus that period's start for pace captions.
    ///
    /// Console `periodResetsAt` is authoritative when present; the local
    /// first-Go-session anniversary is the fallback. Returns nil when neither
    /// signal exists.
    ///
    /// `weekOffset` selects an earlier Monday week. Days before the billing
    /// period come from local history and stay outside the headline scale.
    static func monthDailyBudgetDays(
        limitUSD: Double,
        usedPercent: Double = 0,
        periodResetsAt: Date? = nil,
        weekOffset: Int = 0,
        now: Date = Date(),
        spentByDay: [Date: Double]? = nil,
        dbURL: URL = databaseURL,
        calendar: Calendar = .current
    ) -> OpenCodeMonthBudget? {
        // Prefer the console billing window when present. The per-day shares
        // cover exactly the days the monthly percent was measured over, so the
        // rescale below spreads the console total only across days in the window.
        let consoleBounds = DailyBudget.subscriptionMonth(
            knownStart: nil,
            resetsAt: periodResetsAt,
            now: now,
            calendar: calendar
        )

        let usdSpends: [Date: Double]
        var historyUSD: [Date: Double] = [:]
        if let spentByDay {
            usdSpends = spentByDay
        } else if let consoleBounds {
            let split = spendHistory(
                periodStart: consoleBounds.start,
                periodEnd: consoleBounds.end,
                dbURL: dbURL,
                calendar: calendar
            )
            usdSpends = split.period
            historyUSD = split.history
        } else {
            usdSpends = (try? fetchMonthDailySpends(dbURL: dbURL, now: now)) ?? [:]
        }
        // Convert USD spends → percent of monthly allocation for the usage chart
        let spendsPercent: [Date: Double] = limitUSD > 0
            ? usdSpends.mapValues { $0 / limitUSD * 100 }
            : [:]
        // Anchor the bars to the consumed monthly usage: local events shape how
        // the budget spread across days, while the monthly total sets the scale.
        var anchoredPercent = scaledSpendsPercent(spendsPercent, to: usedPercent)
        // No local rows for the console window (OpenCode not installed here, DB
        // path changed, or usage not flushed yet): spread the console total over
        // the elapsed days so the bars match the headline caption.
        if anchoredPercent.isEmpty, usedPercent > 0, let consoleBounds {
            let elapsed = max(1, (calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: consoleBounds.start),
                to: calendar.startOfDay(for: now)
            ).day ?? 0) + 1)
            let perDay = usedPercent / Double(elapsed)
            for offset in 0..<elapsed {
                guard let day = calendar.date(byAdding: .day, value: offset, to: consoleBounds.start) else {
                    continue
                }
                anchoredPercent[calendar.startOfDay(for: day)] = perDay
            }
        }
        let percentLimit: Double = 100 // monthly allocation = 100%

        func packaged(knownStart: Date?, resetsAt: Date?, historyUSD: [Date: Double]) -> OpenCodeMonthBudget? {
            let historyPercent: [Date: Double] = limitUSD > 0
                ? historyUSD.mapValues { $0 / limitUSD * 100 }
                : [:]
            guard let built = DailyBudget.buildSubscriptionMonthLast7Days(
                limitUSD: percentLimit,
                spentByDay: anchoredPercent,
                knownStart: knownStart,
                resetsAt: resetsAt,
                historyByDay: historyPercent,
                weekOffset: weekOffset,
                now: now,
                calendar: calendar
            ) else { return nil }
            return OpenCodeMonthBudget(
                days: built.days,
                periodStart: built.periodStart,
                spentPercentByDay: anchoredPercent,
                historyPercentByDay: historyPercent,
                knownStart: knownStart,
                resetsAt: resetsAt,
                referenceNow: now
            )
        }

        // Console monthly reset wins: signed-in bars must agree with the Monthly bar.
        if let periodResetsAt {
            return packaged(knownStart: nil, resetsAt: periodResetsAt, historyUSD: historyUSD)
        }

        guard let subscribedAt = (try? loadScan(dbURL: dbURL, since: scanStart(now: now)))?.subscribedAt else {
            return nil
        }
        let month = monthlyBounds(now: now, subscribedAt: subscribedAt)
        if spentByDay == nil, historyUSD.isEmpty {
            historyUSD = spendHistory(
                periodStart: month.start,
                periodEnd: month.end,
                dbURL: dbURL,
                calendar: calendar
            ).history
        }
        return packaged(knownStart: month.start, resetsAt: month.end, historyUSD: historyUSD)
    }

    /// Days of local Go spend kept so the daily-budget arrows can show weeks
    /// before the current billing period. Matches the quota store's ~30-day
    /// horizon closely enough for four earlier weeks.
    private static let priorWeekHistoryDays = 28

    /// Period spends stay inside the billing window so the headline percent
    /// covers only that window. Earlier days are returned separately for week browsing.
    private static func spendHistory(
        periodStart: Date,
        periodEnd: Date,
        dbURL: URL,
        calendar: Calendar
    ) -> (period: [Date: Double], history: [Date: Double]) {
        let startDay = calendar.startOfDay(for: periodStart)
        let lookback = calendar.date(byAdding: .day, value: -priorWeekHistoryDays, to: startDay) ?? startDay
        let all = fetchDailySpends(from: lookback, to: periodEnd, dbURL: dbURL, calendar: calendar)
        let period = all.filter { $0.key >= startDay && $0.key < periodEnd }
        let history = all.filter { $0.key < startDay }
        return (period, history)
    }

    /// Scales per-day percentage-point spends so their sum equals the consumed
    /// monthly usage (`usedPercent`). Returns the spends unchanged when there is
    /// nothing to anchor to.
    static func scaledSpendsPercent(
        _ spendsPercent: [Date: Double],
        to usedPercent: Double
    ) -> [Date: Double] {
        let total = spendsPercent.values.reduce(0, +)
        guard total > 0, usedPercent > 0 else { return spendsPercent }
        let scale = usedPercent / total
        return spendsPercent.mapValues { $0 * scale }
    }
}

/// One read of `opencode.db`: assistant messages since `since` and the first
/// unarchived Go session (the subscription anchor).
struct OpenCodeLocalScan: Sendable {
    var since: Date
    var subscribedAt: Date?
    var rows: [OpenCodeLocalStats.SessionRow]
}

/// Last ``OpenCodeLocalScan`` per database, reused while the database file and
/// its WAL keep the same modification time and size.
///
/// Every local figure in a poll (snapshot, hourly chart, daily bars) derives
/// from one scan, and an idle database is read only once.
final class OpenCodeLocalScanCache: @unchecked Sendable {
    /// Modification time and size of the database and its `-wal` file.
    struct Fingerprint: Equatable {
        var databaseModified: Date?
        var databaseSize: Int64?
        var walModified: Date?
        var walSize: Int64?

        init(dbURL: URL) {
            let manager = FileManager.default
            let database = try? manager.attributesOfItem(atPath: dbURL.path)
            let wal = try? manager.attributesOfItem(atPath: dbURL.path + "-wal")
            databaseModified = database?[.modificationDate] as? Date
            databaseSize = (database?[.size] as? NSNumber)?.int64Value
            walModified = wal?[.modificationDate] as? Date
            walSize = (wal?[.size] as? NSNumber)?.int64Value
        }
    }

    private let lock = NSLock()
    private var entry: (path: String, fingerprint: Fingerprint, scan: OpenCodeLocalScan)?

    /// The cached scan when it is for `dbURL`, unchanged on disk, and reaches
    /// back to `since`; otherwise the result of `load`, which replaces it.
    func scan(dbURL: URL, since: Date, load: () throws -> OpenCodeLocalScan) rethrows -> OpenCodeLocalScan {
        lock.lock()
        defer { lock.unlock() }
        let fingerprint = Fingerprint(dbURL: dbURL)
        if let entry, entry.path == dbURL.path, entry.fingerprint == fingerprint, entry.scan.since <= since {
            return entry.scan
        }
        let scan = try load()
        entry = (dbURL.path, fingerprint, scan)
        return scan
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
    }
}
