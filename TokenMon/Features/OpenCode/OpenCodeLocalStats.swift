import Foundation
import SQLite3

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

enum OpenCodeLocalStats {
    static let rolling5hSeconds: TimeInterval = 5 * 3600

    /// Single-letter UTC weekday labels for the heatmap ("EEEEE"), built once.
    private static let dayLetterFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEEEE"
        return formatter
    }()

    /// Real user home, not the sandbox container home (`NSHomeDirectory` would
    /// resolve to the app container).
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static var databaseDirectory: URL {
        realHomeDirectory
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    static var databaseURL: URL {
        databaseDirectory.appendingPathComponent("opencode.db")
    }

    /// OpenCode Go subscription usage only (`opencode-go`). Zen (`opencode`)
    /// and direct provider keys do not count toward Go $12 / $30 / $60 limits.
    static func goEligibleProvider(_ providerID: String) -> Bool {
        providerID.lowercased() == "opencode-go"
    }

    /// Go or Zen plan providers shown in the OpenCode models list / heatmap.
    /// Direct BYOK keys (`deepseek`, `xai`, `openai`, …) are excluded.
    static func planEligibleProvider(_ providerID: String) -> Bool {
        OpenCodeZenCostEstimate.isPlanProvider(providerID)
    }

    /// Grok used through the OpenCode harness (counts toward Overview Grok, not OpenCode).
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

    struct SessionRow: Sendable {
        var timeCreatedMS: Int64
        var costUSD: Double
        var inputTokens: Int64
        var outputTokens: Int64
        var cacheReadTokens: Int64
        var cacheWriteTokens: Int64
        var providerID: String
        var modelID: String
        /// Present for message-level rows; empty for session-table rows.
        var sessionID: String = ""
    }

    static func fetchSnapshot(now: Date = Date()) throws -> OpenCodeSnapshot {
        try fetchSnapshot(dbURL: databaseURL, now: now)
    }

    static func fetchSnapshot(dbURL: URL, now: Date = Date()) throws -> OpenCodeSnapshot {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw OpenCodeLocalStatsError.databaseMissing(dbURL)
        }
        // Open the DB once and share the connection across the session + two
        // message scans (was 3 separate opens per snapshot).
        let db = try openConnection(at: dbURL)
        defer { sqlite3_close(db) }

        let rows = try readRows(db: db)

        let rollingStart = now.addingTimeInterval(-rolling5hSeconds)
        let rollingStartMS = Int64(rollingStart.timeIntervalSince1970 * 1000)
        let week = weeklyBounds(now: now)
        let subscribedAt = earliestGoSessionDate(in: rows) ?? now
        let month = monthlyBounds(now: now, subscribedAt: subscribedAt)

        // Single pass: bucket each session row into the windows it belongs to.
        var rollingRows: [SessionRow] = []
        var weekRows: [SessionRow] = []
        var monthRows: [SessionRow] = []
        for row in rows {
            if row.timeCreatedMS >= rollingStartMS { rollingRows.append(row) }
            if inWindow(row, start: week.start, end: week.end) { weekRows.append(row) }
            if inWindow(row, start: month.start, end: month.end) { monthRows.append(row) }
        }

        let rollingUsage = windowUsage(
            kind: .rolling5h,
            rows: rollingRows,
            limitUSD: OpenCodeWindowKind.rolling5h.defaultLimitUSD,
            resetsAt: rollingReset(rows: rollingRows, now: now)
        )
        let weekUsage = windowUsage(kind: .weekly, rows: weekRows, limitUSD: OpenCodeWindowKind.weekly.defaultLimitUSD, resetsAt: week.end)
        let monthUsage = windowUsage(kind: .monthly, rows: monthRows, limitUSD: OpenCodeWindowKind.monthly.defaultLimitUSD, resetsAt: month.end)

        // Model breakdown from assistant messages so mid-session model switches are counted.
        let rawWeekEvents = try readAssistantMessageRows(
            from: db,
            startMS: Int64(week.start.timeIntervalSince1970 * 1000),
            endMS: Int64(week.end.timeIntervalSince1970 * 1000)
        ).filter { planEligibleProvider($0.providerID) }
        let models = modelUsage(rows: rawWeekEvents)
        // Weekly tokens for stats clipped to billing month so weekly ≤ monthly at cycle start.
        let weeklyForStats = rawWeekEvents.filter { inWindow($0, start: month.start, end: month.end) }
        let totals = tokenTotals(rows: weeklyForStats)

        let monthEvents = try readAssistantMessageRows(
            from: db,
            startMS: Int64(month.start.timeIntervalSince1970 * 1000),
            endMS: Int64(month.end.timeIntervalSince1970 * 1000)
        ).filter { planEligibleProvider($0.providerID) }
        let monthTotals = tokenTotals(rows: monthEvents)
        let monthEstimated = estimatedCostUSD(rows: monthEvents)
        // Ensure monthly stats never appear smaller than the weekly models total at cycle start
        // (week can include a day before billing month, e.g. Aug 17 vs billing Aug 18).
        let weeklyModelsCost = models.reduce(0) { $0 + $1.costUSD }
        let modelsTokensSum = models.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheWriteTokens }
        let modelsInputSum = models.reduce(0) { $0 + $1.inputTokens }
        let modelsOutputSum = models.reduce(0) { $0 + $1.outputTokens }
        let monthlyTokensSum = monthTotals.input + monthTotals.output + monthTotals.cacheRead + monthTotals.cacheWrite
        let displayMonthlyTokens = max(monthlyTokensSum, modelsTokensSum)
        let displayMonthlyUSD = max(monthEstimated, weeklyModelsCost)
        let displayMonthlyInput = max(monthTotals.input, modelsInputSum)
        let displayMonthlyOutput = max(monthTotals.output, modelsOutputSum)

        return OpenCodeSnapshot(
            fetchedAt: now,
            windows: [rollingUsage, weekUsage, monthUsage],
            models: models,
            modelsWindowLabel: "All models this week",
            inputTokens: totals.input,
            outputTokens: totals.output,
            cacheReadTokens: totals.cacheRead,
            cacheWriteTokens: totals.cacheWrite,
            totalSessions: Set(weeklyForStats.map(\.sessionID)).filter { !$0.isEmpty }.count,
            isEstimated: true,
            monthlyTokens: displayMonthlyTokens,
            monthlyEstimatedUSD: displayMonthlyUSD,
            monthlyInputTokens: displayMonthlyInput,
            monthlyOutputTokens: displayMonthlyOutput
        )
    }

    static func fetchWeekHeatmap(now: Date = Date()) throws -> OpenCodeWeekHeatmap {
        try fetchWeekHeatmap(dbURL: databaseURL, now: now)
    }

    static func fetchWeekHeatmap(dbURL: URL, now: Date = Date()) throws -> OpenCodeWeekHeatmap {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw OpenCodeLocalStatsError.databaseMissing(dbURL)
        }
        let week = weeklyBounds(now: now)
        let db = try openConnection(at: dbURL)
        defer { sqlite3_close(db) }
        let rows = try readAssistantMessageRows(
            from: db,
            startMS: Int64(week.start.timeIntervalSince1970 * 1000),
            endMS: Int64(week.end.timeIntervalSince1970 * 1000)
        )
        return buildWeekHeatmap(rows: rows, now: now)
    }

    static func fetchDayHourlyUsage(now: Date = Date()) throws -> OpenCodeDayHourlyUsage {
        try fetchDayHourlyUsage(dbURL: databaseURL, now: now)
    }

    static func fetchDayHourlyUsage(dbURL: URL, now: Date = Date()) throws -> OpenCodeDayHourlyUsage {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw OpenCodeLocalStatsError.databaseMissing(dbURL)
        }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        // Per-message model/cost — session.model only stores one model and misses switches (e.g. ChatGPT).
        let db = try openConnection(at: dbURL)
        defer { sqlite3_close(db) }
        let rows = try readAssistantMessageRows(
            from: db,
            startMS: Int64(dayStart.timeIntervalSince1970 * 1000),
            endMS: Int64(dayEnd.timeIntervalSince1970 * 1000)
        )
        return buildDayHourlyUsage(rows: rows, now: now)
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
            entry.quotaCost += OpenCodeZenCostEstimate.billableCostUSD(
                providerID: row.providerID,
                modelID: row.modelID,
                recordedCostUSD: row.costUSD,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheReadTokens: row.cacheReadTokens,
                cacheWriteTokens: row.cacheWriteTokens
            ).cost
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

    static func buildWeekHeatmap(rows: [SessionRow], now: Date = Date(), maxRows: Int = 6) -> OpenCodeWeekHeatmap {
        let week = weeklyBounds(now: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let dayStarts: [Date] = (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: week.start)
        }
        let dayLabels = dayStarts.map { Self.dayLetterFormatter.string(from: $0) }

        let weekRows = rows
            .filter { inWindow($0, start: week.start, end: week.end) }
            .filter { planEligibleProvider($0.providerID) }

        // Aggregate cost (or sessions) per model per day index.
        var byModel: [String: (providerID: String, modelID: String, days: [Double], sessions: [Double])] = [:]
        for row in weekRows {
            let key = "\(row.providerID)/\(row.modelID)"
            var entry = byModel[key] ?? (row.providerID, row.modelID, Array(repeating: 0, count: 7), Array(repeating: 0, count: 7))
            let time = Date(timeIntervalSince1970: TimeInterval(row.timeCreatedMS) / 1000)
            let dayStart = calendar.startOfDay(for: time)
            guard let dayIndex = dayStarts.firstIndex(of: dayStart) else { continue }
            entry.days[dayIndex] += OpenCodeZenCostEstimate.billableCostUSD(
                providerID: row.providerID,
                modelID: row.modelID,
                recordedCostUSD: row.costUSD,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheReadTokens: row.cacheReadTokens,
                cacheWriteTokens: row.cacheWriteTokens
            ).cost
            entry.sessions[dayIndex] += 1
            byModel[key] = entry
        }

        let useSessions = byModel.values.allSatisfy { $0.days.allSatisfy { $0 <= 0 } }
        var heatmapRows: [OpenCodeHeatmapRow] = byModel.values.compactMap { entry in
            let values = useSessions ? entry.sessions : entry.days
            let hasUsage = values.contains { $0 > 0 }
            guard hasUsage else { return nil }
            return OpenCodeHeatmapRow(
                providerID: entry.providerID,
                modelID: entry.modelID,
                dayValues: values
            )
        }
        heatmapRows.sort { $0.weekTotal > $1.weekTotal }
        if heatmapRows.count > maxRows {
            heatmapRows = Array(heatmapRows.prefix(maxRows))
        }

        return OpenCodeWeekHeatmap(
            weekStart: week.start,
            dayLabels: dayLabels,
            rows: heatmapRows
        )
    }

    private static func earliestGoSessionDate(in rows: [SessionRow]) -> Date? {
        rows
            .filter { goEligibleProvider($0.providerID) }
            .map { Date(timeIntervalSince1970: TimeInterval($0.timeCreatedMS) / 1000) }
            .min()
    }

    private static func inWindow(_ row: SessionRow, start: Date, end: Date) -> Bool {
        let time = Date(timeIntervalSince1970: TimeInterval(row.timeCreatedMS) / 1000)
        return time >= start && time < end
    }

    private static func windowUsage(kind: OpenCodeWindowKind, rows: [SessionRow], limitUSD: Double, resetsAt: Date?) -> OpenCodeWindowUsage {
        let eligible = rows.filter { goEligibleProvider($0.providerID) }
        let used = eligible.reduce(0) { $0 + $1.costUSD }
        return OpenCodeWindowUsage(
            kind: kind,
            usedUSD: used,
            limitUSD: limitUSD,
            resetsAt: resetsAt,
            sessionCount: eligible.count
        )
    }

    private static func rollingReset(rows: [SessionRow], now: Date) -> Date? {
        let eligible = rows.filter { goEligibleProvider($0.providerID) }
        // Match server-style reset: last Go activity in the window + rolling duration.
        guard let last = eligible.map({ Date(timeIntervalSince1970: TimeInterval($0.timeCreatedMS) / 1000) }).max() else {
            return nil
        }
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

            let billable = OpenCodeZenCostEstimate.billableCostUSD(
                providerID: row.providerID,
                modelID: row.modelID,
                recordedCostUSD: row.costUSD,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheReadTokens: row.cacheReadTokens,
                cacheWriteTokens: row.cacheWriteTokens
            )
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

    private static func estimatedCostUSD(rows: [SessionRow]) -> Double {
        rows.reduce(0) { sum, row in
            sum + OpenCodeZenCostEstimate.billableCostUSD(
                providerID: row.providerID,
                modelID: row.modelID,
                recordedCostUSD: row.costUSD,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheReadTokens: row.cacheReadTokens,
                cacheWriteTokens: row.cacheWriteTokens
            ).cost
        }
    }

    private static func readRows(db: OpaquePointer) throws -> [SessionRow] {
        let sql = """
        SELECT time_created, cost, tokens_input, tokens_output, \
        tokens_cache_read, tokens_cache_write, model \
        FROM session WHERE time_archived IS NULL
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OpenCodeLocalStatsError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [SessionRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let (providerID, modelID) = modelParts(sqlite3_column_text(stmt, 6))
            rows.append(SessionRow(
                timeCreatedMS: sqlite3_column_int64(stmt, 0),
                costUSD: sqlite3_column_double(stmt, 1),
                inputTokens: sqlite3_column_int64(stmt, 2),
                outputTokens: sqlite3_column_int64(stmt, 3),
                cacheReadTokens: sqlite3_column_int64(stmt, 4),
                cacheWriteTokens: sqlite3_column_int64(stmt, 5),
                providerID: providerID,
                modelID: modelID
            ))
        }
        return rows
    }

    /// Opens a readonly connection (URI so concurrent OpenCode WAL writers stay readable).
    private static func openConnection(at dbURL: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        let uri = "file:\(dbURL.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw OpenCodeLocalStatsError.openFailed(message)
        }
        sqlite3_busy_timeout(db, 2000)
        return db!
    }

    /// Assistant messages carry the real per-turn model + cost (sessions only store one model).
    private static func readAssistantMessageRows(
        from db: OpaquePointer,
        startMS: Int64,
        endMS: Int64
    ) throws -> [SessionRow] {
        let sql = """
        SELECT time_created, session_id, data \
        FROM message \
        WHERE time_created >= ? AND time_created < ? \
          AND json_extract(data, '$.role') = 'assistant'
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OpenCodeLocalStatsError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, startMS)
        sqlite3_bind_int64(stmt, 2, endMS)

        var rows: [SessionRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dataText = sqlite3_column_text(stmt, 2),
                  let data = String(cString: dataText).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let providerID = (json["providerID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelID = (json["modelID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let providerID, !providerID.isEmpty, let modelID, !modelID.isEmpty else { continue }

            let tokens = json["tokens"] as? [String: Any]
            let cache = tokens?["cache"] as? [String: Any]
            let sessionID = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""

            rows.append(SessionRow(
                timeCreatedMS: sqlite3_column_int64(stmt, 0),
                costUSD: (json["cost"] as? Double) ?? (json["cost"] as? NSNumber)?.doubleValue ?? 0,
                inputTokens: int64Value(tokens?["input"]),
                outputTokens: int64Value(tokens?["output"]),
                cacheReadTokens: int64Value(cache?["read"]),
                cacheWriteTokens: int64Value(cache?["write"]),
                providerID: providerID,
                modelID: modelID,
                sessionID: sessionID
            ))
        }
        return rows
    }

    private static func int64Value(_ value: Any?) -> Int64 {
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? Double { return Int64(n) }
        if let n = value as? NSNumber { return n.int64Value }
        return 0
    }

    private static func modelParts(_ text: UnsafePointer<UInt8>?) -> (providerID: String, modelID: String) {
        guard let text,
              let data = String(cString: text).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ("other", "unknown")
        }
        let modelID = json["id"] as? String ?? "unknown"
        let providerID = json["providerID"] as? String ?? "other"
        return (providerID, modelID)
    }

    // MARK: - Daily budget

    /// Daily USD spend per calendar day for the current monthly period, counting
    /// only Go-plan usage (Zen is free and tracked separately in the models and
    /// overview sections).
    static func fetchMonthDailySpends(now: Date = Date()) throws -> [Date: Double] {
        try fetchMonthDailySpends(dbURL: databaseURL, now: now)
    }

    static func fetchMonthDailySpends(dbURL: URL, now: Date) throws -> [Date: Double] {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw OpenCodeLocalStatsError.databaseMissing(dbURL)
        }
        let db = try openConnection(at: dbURL)
        defer { sqlite3_close(db) }
        let rows = try readRows(db: db)
        let subscribedAt = earliestGoSessionDate(in: rows) ?? now
        let month = monthlyBounds(now: now, subscribedAt: subscribedAt)
        let monthRows = try readAssistantMessageRows(
            from: db,
            startMS: Int64(month.start.timeIntervalSince1970 * 1000),
            endMS: Int64(month.end.timeIntervalSince1970 * 1000)
        ).filter { goEligibleProvider($0.providerID) }
        return dailySpendsByDay(rows: monthRows)
    }

    static func dailySpendsByDay(rows: [SessionRow], calendar: Calendar = .current) -> [Date: Double] {
        var byDay: [Date: Double] = [:]
        for row in rows {
            let billable = OpenCodeZenCostEstimate.billableCostUSD(
                providerID: row.providerID,
                modelID: row.modelID,
                recordedCostUSD: row.costUSD,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheReadTokens: row.cacheReadTokens,
                cacheWriteTokens: row.cacheWriteTokens
            ).cost
            guard billable > 0 else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(row.timeCreatedMS) / 1000)
            let dayKey = calendar.startOfDay(for: date)
            byDay[dayKey, default: 0] += billable
        }
        return byDay
    }

    /// Builds the last-7 daily-budget bars for the Go **subscription** month,
    /// plus that period's start for pace captions.
    ///
    /// Console `periodResetsAt` is authoritative when present — signed-in bars
    /// must match the console Monthly bar. The local first-Go-session
    /// anniversary is only a fallback for the local-estimate path. Returns nil
    /// when neither signal exists — never invents a calendar month of `now`.
    static func monthDailyBudgetDays(
        limitUSD: Double,
        usedPercent: Double = 0,
        periodResetsAt: Date? = nil,
        now: Date = Date(),
        spentByDay: [Date: Double]? = nil,
        dbURL: URL = databaseURL,
        calendar: Calendar = .current
    ) -> (days: [DailyBudgetDay], periodStart: Date)? {
        let usdSpends: [Date: Double]
        if let spentByDay {
            usdSpends = spentByDay
        } else {
            usdSpends = (try? fetchMonthDailySpends(dbURL: dbURL, now: now)) ?? [:]
        }
        // Convert USD spends → percent of monthly allocation for the usage chart
        let spendsPercent: [Date: Double] = limitUSD > 0
            ? usdSpends.mapValues { $0 / limitUSD * 100 }
            : [:]
        // Anchor the bars to the consumed monthly usage (the Monthly bar): local
        // events only shape *how* the budget was spread across days, while the
        // authoritative monthly total sets the scale so the bars reconcile with it.
        let anchoredPercent = scaledSpendsPercent(spendsPercent, to: usedPercent)
        let percentLimit: Double = 100 // monthly allocation = 100%

        // Console monthly reset wins: signed-in bars must agree with the Monthly bar.
        if let periodResetsAt {
            return DailyBudget.buildSubscriptionMonthLast7Days(
                limitUSD: percentLimit,
                spentByDay: anchoredPercent,
                knownStart: nil,
                resetsAt: periodResetsAt,
                now: now,
                calendar: calendar
            )
        }

        if FileManager.default.fileExists(atPath: dbURL.path),
           let db = try? openConnection(at: dbURL) {
            defer { sqlite3_close(db) }
            if let rows = try? readRows(db: db),
               let subscribedAt = earliestGoSessionDate(in: rows) {
                let month = monthlyBounds(now: now, subscribedAt: subscribedAt)
                return DailyBudget.buildSubscriptionMonthLast7Days(
                    limitUSD: percentLimit,
                    spentByDay: anchoredPercent,
                    knownStart: month.start,
                    resetsAt: month.end,
                    now: now,
                    calendar: calendar
                )
            }
        }

        return nil
    }

    /// Scales per-day percentage-point spends so their sum equals the consumed
    /// monthly usage (`usedPercent`) — the same anchor Cursor uses. Prior weeks'
    /// usage stays counted in the monthly total while only the latest days are
    /// drawn, so the 7 visible bars are a consistent slice of the Monthly bar.
    /// Returns the spends unchanged when there is nothing to anchor to.
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
