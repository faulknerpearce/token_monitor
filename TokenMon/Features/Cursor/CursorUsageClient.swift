import Foundation

enum CursorUsageError: LocalizedError, ProviderUsageError {
    case notSignedIn
    case unauthorized
    case badResponse(String)
    case network(String)

    var usageError: UsageError {
        switch self {
        case .notSignedIn: return .notSignedIn
        case .unauthorized: return .unauthorized
        case let .badResponse(message): return .badResponse(message)
        case let .network(message): return .network(message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to Cursor to load usage."
        case .unauthorized:
            return "Cursor session expired. Sign in again."
        case let .badResponse(message):
            return "Cursor response error: \(message)"
        case let .network(message):
            return "Cursor network error: \(message)"
        }
    }
}

/// Fetches Cursor dashboard usage via cookie-authenticated unofficial endpoints.
struct CursorUsageClient: Sendable {
    static let baseURL = URL(string: "https://cursor.com")!

    private let cookieHeader: String

    init(cookieHeader: String) {
        self.cookieHeader = cookieHeader
    }

    func fetchSnapshot(now: Date = Date()) async throws -> (CursorSnapshot, CursorDayHourlyUsage, [DailyBudgetDay]?) {
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
        let windowStart = Self.eventsWindowStart(
            cycleStart: snap.billingCycleStart,
            now: now,
            calendar: calendar
        )
        var hourly = CursorDayHourlyUsage(
            dayStart: dayStart,
            hourWeights: Array(repeating: 0, count: 24),
            quotaHourWeights: Array(repeating: 0, count: 24)
        )
        var dailyBudgetDays: [DailyBudgetDay]?
        if let events = try? await fetchAllEvents(from: windowStart, to: now) {
            snap.costStats = Self.aggregateCostStats(
                events: events,
                cycleStart: snap.billingCycleStart ?? windowStart,
                now: now,
                calendar: calendar
            )
            hourly = CursorDayHourlyUsage(
                dayStart: dayStart,
                hourWeights: Self.hourWeights(fromEvents: events, dayStart: dayStart, calendar: calendar),
                quotaHourWeights: Self.quotaHourWeights(
                    fromEvents: events,
                    dayStart: dayStart,
                    planLimitUSD: snap.planLimitUSD,
                    calendar: calendar
                ),
                hourTokenWeights: Self.tokenHourWeights(
                    fromEvents: events,
                    dayStart: dayStart,
                    calendar: calendar
                )
            )
            dailyBudgetDays = Self.dailyBudgetDays(
                events: events,
                planLimitUSD: snap.planLimitUSD,
                usedPercent: snap.usedPercent,
                billingCycleStart: snap.billingCycleStart,
                billingCycleEnd: snap.billingCycleEnd,
                now: now,
                calendar: calendar
            )
        } else if snap.planLimitUSD != nil {
            // No events yet — still show empty 7-bar budget when we know the
            // subscription/billing month (never invent a calendar month).
            let percentLimit: Double = 100
            if let built = DailyBudget.buildSubscriptionMonthLast7Days(
                limitUSD: percentLimit,
                spentByDay: [:],
                knownStart: snap.billingCycleStart,
                resetsAt: snap.billingCycleEnd,
                now: now,
                calendar: calendar
            ) {
                dailyBudgetDays = built.days
            }
        }
        return (snap, hourly, dailyBudgetDays)
    }

    func fetchDayHourlyUsage(now: Date = Date()) async throws -> CursorDayHourlyUsage {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return CursorDayHourlyUsage(
                dayStart: dayStart,
                hourWeights: Array(repeating: 0, count: 24),
                quotaHourWeights: Array(repeating: 0, count: 24)
            )
        }
        let events = try await fetchAllEvents(from: dayStart, to: dayEnd.addingTimeInterval(-0.001))
        let weights = Self.hourWeights(fromEvents: events, dayStart: dayStart, calendar: calendar)
        return CursorDayHourlyUsage(
            dayStart: dayStart,
            hourWeights: weights,
            quotaHourWeights: Array(repeating: 0, count: 24),
            hourTokenWeights: Self.tokenHourWeights(fromEvents: events, dayStart: dayStart, calendar: calendar)
        )
    }

    // MARK: - Parsing (testable)

    static func parseSummary(data: Data, fetchedAt: Date = Date()) throws -> CursorSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorUsageError.badResponse("Expected JSON object")
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

        // Cursor percent fields are already in percentage units (0.36 means 0.36%, not 36%).
        let autoPercent = displayPercent(JSON.number(plan?["autoPercentUsed"]))
        let apiPercent = displayPercent(JSON.number(plan?["apiPercentUsed"]))

        // Total precedence mirrors CodexBar / Cursor dashboard.
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
                resetsAt: cycleEnd,
                pace: CursorPace.compute(usedPercent: totalPercent, cycleStart: cycleStart, cycleEnd: cycleEnd, now: fetchedAt)
            )
        ]
        if let autoPercent {
            pools.append(
                CursorPoolUsage(
                    kind: .auto,
                    usedPercent: autoPercent,
                    resetsAt: cycleEnd,
                    pace: CursorPace.compute(usedPercent: autoPercent, cycleStart: cycleStart, cycleEnd: cycleEnd, now: fetchedAt)
                )
            )
        }
        if let apiPercent {
            pools.append(
                CursorPoolUsage(
                    kind: .api,
                    usedPercent: apiPercent,
                    resetsAt: cycleEnd,
                    pace: CursorPace.compute(usedPercent: apiPercent, cycleStart: cycleStart, cycleEnd: cycleEnd, now: fetchedAt)
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

    static func parseUsageEventsPage(data: Data) throws -> (events: [[String: Any]], total: Int) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorUsageError.badResponse("Expected events JSON object")
        }
        let total = (root["totalUsageEventsCount"] as? Int)
            ?? (root["totalUsageEventsCount"] as? Double).map(Int.init)
            ?? 0
        let events = (root["usageEventsDisplay"] as? [[String: Any]]) ?? []
        return (events, total)
    }

    static func aggregateCostStats(
        events: [[String: Any]],
        cycleStart: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> CursorCostStats {
        let dayStart = calendar.startOfDay(for: now)
        let twentyDaysAgo = calendar.date(byAdding: .day, value: -20, to: dayStart) ?? dayStart.addingTimeInterval(-20 * 86400)

        var meteredCycleCents = 0.0
        var cycleTokens: Int64 = 0
        var cycleInput: Int64 = 0
        var cycleOutput: Int64 = 0
        var todayCents = 0.0
        var last20dCents = 0.0
        var todayTokens: Int64 = 0
        var last20dTokens: Int64 = 0

        for event in events {
            guard let date = eventTimestamp(event) else { continue }
            let cents = chargedCents(event)
            let tokens = tokenCount(event)
            let input = inputTokenCount(event)
            let output = outputTokenCount(event)

            if date >= cycleStart {
                meteredCycleCents += cents
                cycleTokens += tokens
                cycleInput += input
                cycleOutput += output
            }
            if date >= dayStart {
                todayCents += cents
                todayTokens += tokens
            }
            if date >= twentyDaysAgo {
                last20dCents += cents
                last20dTokens += tokens
            }
        }

        return CursorCostStats(
            meteredCycleUSD: meteredCycleCents / 100,
            cycleTokens: cycleTokens,
            cycleInputTokens: cycleInput,
            cycleOutputTokens: cycleOutput,
            todayUSD: todayCents / 100,
            last20dUSD: last20dCents / 100,
            todayTokens: todayTokens,
            last20dTokens: last20dTokens
        )
    }

    /// Bucket event activity into 24 hourly weights using requestsCosts, else token totals.
    static func hourWeights(
        fromEvents events: [[String: Any]],
        dayStart: Date,
        calendar: Calendar = .current
    ) -> [Double] {
        var weights = Array(repeating: 0.0, count: 24)
        for event in events {
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
            guard let hour = hourIndex(for: event, dayStart: dayStart, calendar: calendar) else {
                continue
            }
            let cents = chargedCents(event)
            guard cents > 0 else { continue }
            weights[hour] += cents / planLimitCents * 100
        }
        return weights
    }

    static func tokenHourWeights(
        fromEvents events: [[String: Any]],
        dayStart: Date,
        calendar: Calendar = .current
    ) -> [Int64] {
        var weights = Array(repeating: Int64(0), count: 24)
        for event in events {
            guard let hour = hourIndex(for: event, dayStart: dayStart, calendar: calendar) else {
                continue
            }
            weights[hour] += tokenCount(event)
        }
        return weights
    }

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

    static func hourIndex(
        for event: [String: Any],
        dayStart: Date,
        calendar: Calendar
    ) -> Int? {
        guard let date = eventTimestamp(event) else { return nil }
        guard calendar.isDate(date, inSameDayAs: dayStart) else { return nil }
        return calendar.component(.hour, from: date)
    }

    static func eventTimestamp(_ event: [String: Any]) -> Date? {
        if let msString = event["timestamp"] as? String, let ms = Double(msString) {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        if let ms = event["timestamp"] as? Double {
            let seconds = ms > 1_000_000_000_000 ? ms / 1000 : ms
            return Date(timeIntervalSince1970: seconds)
        }
        if let ms = event["timestamp"] as? Int {
            let value = Double(ms)
            let seconds = value > 1_000_000_000_000 ? value / 1000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

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

    static func tokenCount(_ event: [String: Any]) -> Int64 {
        guard let tokenUsage = event["tokenUsage"] as? [String: Any] else { return 0 }
        let input = JSON.number(tokenUsage["inputTokens"]) ?? 0
        let output = JSON.number(tokenUsage["outputTokens"]) ?? 0
        let cacheWrite = JSON.number(tokenUsage["cacheWriteTokens"]) ?? 0
        let cacheRead = JSON.number(tokenUsage["cacheReadTokens"]) ?? 0
        return Int64(input + output + cacheWrite + cacheRead)
    }

    static func inputTokenCount(_ event: [String: Any]) -> Int64 {
        guard let tokenUsage = event["tokenUsage"] as? [String: Any] else { return 0 }
        return Int64(JSON.number(tokenUsage["inputTokens"]) ?? 0)
    }

    static func outputTokenCount(_ event: [String: Any]) -> Int64 {
        guard let tokenUsage = event["tokenUsage"] as? [String: Any] else { return 0 }
        return Int64(JSON.number(tokenUsage["outputTokens"]) ?? 0)
    }

    private static func modelIdentifier(from event: [String: Any]) -> String? {
        let directKeys = ["model", "modelName", "modelID", "modelId", "modelSlug", "model_name", "model_id"]
        for key in directKeys {
            if let value = event[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let object = event[key] as? [String: Any] {
                for nestedKey in ["name", "id", "model", "modelName", "modelID", "modelId"] {
                    if let value = object[nestedKey] as? String,
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        return nil
    }

    // MARK: - HTTP

    private func fetchAllEvents(from start: Date, to end: Date) async throws -> [[String: Any]] {
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let endMs = Int64(end.timeIntervalSince1970 * 1000)
        var allEvents: [[String: Any]] = []
        var page = 1
        let pageSize = 500
        while page <= 40 {
            let body: [String: Any] = [
                "startDate": String(startMs),
                "endDate": String(endMs),
                "page": page,
                "pageSize": pageSize
            ]
            let data = try await post(path: "/api/dashboard/get-filtered-usage-events", json: body)
            let (events, total) = try Self.parseUsageEventsPage(data: data)
            allEvents.append(contentsOf: events)
            if allEvents.count >= total || events.count < pageSize {
                break
            }
            page += 1
        }
        return allEvents
    }

    private func get(path: String) async throws -> Data {
        guard let resolved = URL(string: path, relativeTo: Self.baseURL)?.absoluteURL else {
            throw CursorUsageError.badResponse("Invalid path \(path)")
        }
        var request = URLRequest(url: resolved)
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request)
        return try await perform(request)
    }

    private func post(path: String, json: [String: Any]) async throws -> Data {
        guard let resolved = URL(string: path, relativeTo: Self.baseURL)?.absoluteURL else {
            throw CursorUsageError.badResponse("Invalid path \(path)")
        }
        var request = URLRequest(url: resolved)
        request.httpMethod = "POST"
        applyCommonHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await perform(request)
    }

    private func applyCommonHeaders(to request: inout URLRequest) {
        AuthenticatedRequest.applyHeaders(
            to: &request,
            cookieHeader: cookieHeader,
            bearerToken: nil,
            referer: "https://cursor.com"
        )
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data = try await AuthenticatedRequest.perform(request) { usageError in
            switch usageError {
            case .notSignedIn: return CursorUsageError.notSignedIn
            case .unauthorized: return CursorUsageError.unauthorized
            case let .network(message): return CursorUsageError.network(message)
            case let .badResponse(message): return CursorUsageError.badResponse(message)
            }
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? String,
           err.lowercased().contains("not_authenticated") || err.lowercased().contains("unauthor") {
            throw CursorUsageError.unauthorized
        }
        return data
    }

    // MARK: - Helpers

    static func eventsWindowStart(cycleStart: Date?, now: Date, calendar: Calendar = .current) -> Date {
        let dayStart = calendar.startOfDay(for: now)
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: dayStart) ?? now.addingTimeInterval(-30 * 86400)
        if let cycleStart {
            return min(cycleStart, thirtyDaysAgo)
        }
        return thirtyDaysAgo
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

    // MARK: - Daily budget aggregation

    /// USD spend per calendar day (startOfDay → cents/100).
    ///
    /// When `cycleStart`/`cycleEnd` are set, events outside that half-open
    /// window are dropped so a reset day's bar does not inherit the previous cycle.
    static func dailySpendByDay(
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
            let cents = chargedCents(event)
            guard cents > 0 else { continue }
            let dayKey = calendar.startOfDay(for: date)
            byDay[dayKey, default: 0] += cents / 100
        }
        return byDay
    }

    /// Map list-price USD weights onto Cursor's usage-quota percent.
    ///
    /// Event `chargedCents` is token list price, not plan consumption — `$15` of
    /// charged cost can be `4%` of the included pool. Days are scaled so the
    /// cycle total equals `usedPercent` (the Usage bar), using relative USD
    /// only to split that quota across calendar days.
    static func quotaPercentsByDay(
        usdSpends: [Date: Double],
        usedPercent: Double
    ) -> [Date: Double] {
        let cycleUSD = usdSpends.values.reduce(0, +)
        guard cycleUSD > 0, usedPercent > 0 else { return [:] }
        let scale = usedPercent / cycleUSD
        return usdSpends.mapValues { $0 * scale }
    }

    /// Builds 7-bar daily budget days for the current **billing cycle**.
    /// Daily cap = `100% / daysInPeriod`. Each bar is that day's share of
    /// `usedPercent`, not `chargedUSD / planLimit`. Returns nil when the
    /// subscription month cannot be resolved (no calendar-month fallback).
    static func dailyBudgetDays(
        events: [[String: Any]],
        planLimitUSD: Double?,
        usedPercent: Double,
        billingCycleStart: Date?,
        billingCycleEnd: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyBudgetDay]? {
        guard let planLimitUSD, planLimitUSD > 0 else { return nil }
        let percentLimit: Double = 100
        guard let bounds = DailyBudget.subscriptionMonth(
            knownStart: billingCycleStart,
            resetsAt: billingCycleEnd,
            now: now,
            calendar: calendar
        ) else { return nil }
        let usdSpends = dailySpendByDay(
            events: events,
            cycleStart: bounds.start,
            cycleEnd: bounds.end,
            calendar: calendar
        )
        return DailyBudget.buildLast7Days(
            periodStart: bounds.start,
            periodEnd: bounds.end,
            limitUSD: percentLimit,
            spentByDay: quotaPercentsByDay(usdSpends: usdSpends, usedPercent: usedPercent),
            now: now,
            calendar: calendar
        )
    }
}
