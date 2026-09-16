@testable import TokenMon
import XCTest

final class CursorUsageClientTests: XCTestCase {
    func testParseSummaryUsesTotalAutoAPIPercents() throws {
        let json = Data("""
        {
          "billingCycleStart": "2026-07-13T00:00:00.000Z",
          "billingCycleEnd": "2026-08-14T12:00:00.000Z",
          "membershipType": "ultra",
          "individualUsage": {            "plan": {
              "enabled": true,
              "used": 7600,
              "limit": 40000,
              "remaining": 32400,
              "totalPercentUsed": 19,
              "autoPercentUsed": 16,
              "apiPercentUsed": 30
            },
            "onDemand": {
              "enabled": true,
              "used": 2309,
              "limit": null,
              "remaining": null
            }
          }
        }
        """.utf8)

        let now = ISO8601DateFormatter().date(from: "2026-08-03T18:00:00Z")!
        let snap = try CursorUsageClient.parseSummary(data: json, fetchedAt: now)
        XCTAssertEqual(snap.usedPercent, 19, accuracy: 0.01)
        XCTAssertEqual(snap.pools.count, 3)
        XCTAssertEqual(snap.pools[0].kind, .total)
        XCTAssertEqual(snap.pools[0].remainingPercent, 81, accuracy: 0.01)
        XCTAssertEqual(snap.pools[1].kind, .auto)
        XCTAssertEqual(snap.pools[1].remainingPercent, 84, accuracy: 0.01)
        XCTAssertEqual(snap.pools[2].kind, .api)
        XCTAssertEqual(snap.pools[2].remainingPercent, 70, accuracy: 0.01)
        XCTAssertEqual(snap.planUsedUSD ?? -1, 76, accuracy: 0.01)
        XCTAssertEqual(snap.planLimitUSD ?? -1, 400, accuracy: 0.01)
        XCTAssertEqual(snap.membershipType, "ultra")
        XCTAssertEqual(snap.displayPlanName, "Cursor Ultra")
        XCTAssertNotNil(snap.pools[0].pace)
        XCTAssertEqual(snap.pools[0].pace?.isReserve, true)

        // Daily Budget and event clipping key off these parsed dates, so assert
        // them rather than only the percents.
        XCTAssertNotNil(snap.billingCycleStart)
        XCTAssertEqual(
            snap.billingCycleStart,
            ISO8601DateFormatter.parseFlexible("2026-07-13T00:00:00.000Z")
        )
        XCTAssertEqual(
            snap.billingCycleEnd,
            ISO8601DateFormatter.parseFlexible("2026-08-14T12:00:00.000Z")
        )
        XCTAssertEqual(snap.resetsAt, snap.billingCycleEnd)
    }

    /// A summary without billing-cycle fields must leave the dates nil rather than
    /// substituting a calendar month.
    func testParseSummaryLeavesCycleDatesNilWhenOmitted() throws {
        let json = Data(
            #"{"individualUsage":{"plan":{"enabled":true,"used":0,"limit":0,"totalPercentUsed":12}}}"#.utf8
        )
        let snap = try CursorUsageClient.parseSummary(data: json)
        XCTAssertNil(snap.billingCycleStart)
        XCTAssertNil(snap.billingCycleEnd)
        XCTAssertNil(snap.resetsAt)
    }

    func testParseSummaryAveragesAutoAndAPIWhenTotalMissing() throws {
        let json = Data("""
        {
          "individualUsage": {
            "plan": {
              "enabled": true,
              "used": 0,
              "limit": 0,
              "autoPercentUsed": 10,
              "apiPercentUsed": 30
            },
            "onDemand": { "enabled": false }
          }
        }
        """.utf8)

        let snap = try CursorUsageClient.parseSummary(data: json)
        XCTAssertEqual(snap.usedPercent, 20, accuracy: 0.01)
        XCTAssertEqual(snap.pools.count, 3)
    }

    func testParseSummaryFallsBackToUsedOverLimitCents() throws {
        let json = Data("""
        {
          "individualUsage": {
            "plan": {
              "enabled": true,
              "used": 2500,
              "limit": 10000
            },
            "onDemand": { "enabled": false }
          }
        }
        """.utf8)

        let snap = try CursorUsageClient.parseSummary(data: json)
        XCTAssertEqual(snap.usedPercent, 25, accuracy: 0.01)
        XCTAssertEqual(snap.planUsedUSD ?? -1, 25, accuracy: 0.01)
        XCTAssertEqual(snap.planLimitUSD ?? -1, 100, accuracy: 0.01)
        XCTAssertEqual(snap.pools.count, 1)
    }

    func testPaceReserveMath() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 100)
        // 50% elapsed → expected 50% used. Actual 20% → 30% reserve.
        let now = Date(timeIntervalSince1970: 50)
        let pace = CursorPace.compute(usedPercent: 20, cycleStart: start, cycleEnd: end, now: now)
        XCTAssertEqual(pace?.expectedUsedPercent ?? -1, 50, accuracy: 0.01)
        XCTAssertEqual(pace?.deltaPercent ?? -1, 30, accuracy: 0.01)
        XCTAssertEqual(pace?.paceLabel, "30% in reserve")
        XCTAssertEqual(pace?.willLastUntilReset, true)
    }

    func testAggregateCostStats() {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 3
        components.hour = 12
        let now = calendar.date(from: components)!
        let dayStart = calendar.startOfDay(for: now)
        let cycleStart = calendar.date(byAdding: .day, value: -20, to: dayStart)!

        let events: [[String: Any]] = [
            [
                "timestamp": String(Int64(now.timeIntervalSince1970 * 1000)),
                "chargedCents": 1202,
                "tokenUsage": ["inputTokens": 1_000_000, "outputTokens": 500_000, "cacheWriteTokens": 0, "cacheReadTokens": 0]
            ],
            [
                "timestamp": String(Int64(dayStart.addingTimeInterval(-2 * 86400).timeIntervalSince1970 * 1000)),
                "chargedCents": 5000,
                "tokenUsage": ["inputTokens": 2_000_000, "outputTokens": 0, "cacheWriteTokens": 0, "cacheReadTokens": 0]
            ]
        ]

        let stats = CursorUsageClient.aggregateCostStats(
            events: events,
            cycleStart: cycleStart,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(stats.todayUSD, 12.02, accuracy: 0.01)
        XCTAssertEqual(stats.meteredCycleUSD, 62.02, accuracy: 0.01)
        XCTAssertEqual(stats.cycleTokens, 3_500_000)
        XCTAssertEqual(stats.last20dUSD, 62.02, accuracy: 0.01)
        XCTAssertEqual(stats.todayTokens, 1_500_000)
        XCTAssertEqual(stats.last20dTokens, 3_500_000)
    }

    func testHourWeightsBucketByRequestsCosts() {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 3
        components.hour = 0
        components.minute = 0
        let dayStart = calendar.date(from: components)!

        let events: [[String: Any]] = [
            [
                "timestamp": String(Int64(dayStart.addingTimeInterval(10 * 3600).timeIntervalSince1970 * 1000)),
                "requestsCosts": 2.5
            ],
            [
                "timestamp": String(Int64(dayStart.addingTimeInterval(10 * 3600 + 60).timeIntervalSince1970 * 1000)),
                "requestsCosts": 1.5
            ],
            [
                "timestamp": String(Int64(dayStart.addingTimeInterval(14 * 3600).timeIntervalSince1970 * 1000)),
                "tokenUsage": [
                    "inputTokens": 100,
                    "outputTokens": 50,
                    "cacheWriteTokens": 0,
                    "cacheReadTokens": 0
                ]
            ]
        ]

        let weights = CursorUsageClient.hourWeights(fromEvents: events, dayStart: dayStart, calendar: calendar)
        XCTAssertEqual(weights.count, 24)
        XCTAssertEqual(weights[10], 4.0, accuracy: 0.01)
        XCTAssertEqual(weights[14], 150, accuracy: 0.01)
        XCTAssertEqual(weights[9], 0, accuracy: 0.01)
    }

    func testQuotaHourWeightsUseChargedCentsAndPlanLimit() {
        let calendar = Calendar(identifier: .gregorian)
        let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_754_236_800))
        let events: [[String: Any]] = [
            [
                "timestamp": String(Int64(dayStart.addingTimeInterval(10 * 3600).timeIntervalSince1970 * 1000)),
                "chargedCents": 100
            ],
            [
                "timestamp": String(Int64(dayStart.addingTimeInterval(10 * 3600 + 60).timeIntervalSince1970 * 1000)),
                "chargedCents": 300
            ]
        ]

        let weights = CursorUsageClient.quotaHourWeights(
            fromEvents: events,
            dayStart: dayStart,
            planLimitUSD: 400,
            calendar: calendar
        )

        XCTAssertEqual(
            weights[10],
            QuotaNormalization.averageWeeksPerMonth,
            accuracy: 0.001
        )
        XCTAssertEqual(weights[9], 0, accuracy: 0.001)
    }

    func testTokenHourWeightsAggregateEventTokens() {
        let calendar = Calendar(identifier: .gregorian)
        let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_754_236_800))
        let events: [[String: Any]] = [
            [
                "timestamp": String(Int64(dayStart.addingTimeInterval(10 * 3600).timeIntervalSince1970 * 1000)),
                "tokenUsage": [
                    "inputTokens": 100,
                    "outputTokens": 50,
                    "cacheReadTokens": 25,
                    "cacheWriteTokens": 5
                ]
            ]
        ]

        let weights = CursorUsageClient.tokenHourWeights(
            fromEvents: events,
            dayStart: dayStart,
            calendar: calendar
        )

        XCTAssertEqual(weights[10], 180)
        XCTAssertEqual(weights[9], 0)
    }

    func testParseUsageEventsPage() throws {
        let json = Data("""
        {
          "totalUsageEventsCount": 2,
          "usageEventsDisplay": [
            { "timestamp": "1775418973898", "requestsCosts": 1 },
            { "timestamp": "1775418973899", "requestsCosts": 2 }
          ]
        }
        """.utf8)

        let (events, total) = try CursorUsageClient.parseUsageEventsPage(data: json)
        XCTAssertEqual(total, 2)
        XCTAssertEqual(events.count, 2)
    }

    /// A renamed/omitted total must read as unknown (0), not silently stop after
    /// one page, and a numeric string must still parse.
    func testParseUsageEventsPageCoercesTotal() throws {
        let stringTotal = Data(#"{"totalUsageEventsCount":"1234","usageEventsDisplay":[]}"#.utf8)
        XCTAssertEqual(try CursorUsageClient.parseUsageEventsPage(data: stringTotal).total, 1234)

        let missing = Data(#"{"usageEventsDisplay":[]}"#.utf8)
        XCTAssertEqual(try CursorUsageClient.parseUsageEventsPage(data: missing).total, 0)
    }

    /// Out-of-range/NaN token counts must clamp instead of trapping in `Int64`.
    func testSafeIntegerConversionDoesNotTrap() {
        XCTAssertEqual(CursorUsageClient.safeInt64(1e30), Int64.max)
        XCTAssertEqual(CursorUsageClient.safeInt64(-1e30), Int64.min)
        XCTAssertEqual(CursorUsageClient.safeInt64(.nan), 0)
        XCTAssertEqual(CursorUsageClient.safeInt64(.infinity), 0)
        XCTAssertEqual(CursorUsageClient.safeInt(1e30), Int.max)
    }

    func testTokenCountHandlesHugeValues() {
        let event: [String: Any] = ["tokenUsage": ["inputTokens": 1e30, "outputTokens": 2.0]]
        XCTAssertEqual(CursorUsageClient.tokenCount(event), Int64.max)
    }

    /// The String timestamp branch must honour the same seconds/ms heuristic as
    /// the numeric branches, and reject implausible values.
    func testEventTimestampStringUnits() {
        let ms = CursorUsageClient.eventTimestamp(["timestamp": "1775418973898"])
        XCTAssertEqual(ms?.timeIntervalSince1970 ?? 0, 1_775_418_973.898, accuracy: 0.01)

        let seconds = CursorUsageClient.eventTimestamp(["timestamp": "1775418973"])
        XCTAssertEqual(seconds?.timeIntervalSince1970 ?? 0, 1_775_418_973, accuracy: 0.01)

        XCTAssertNil(CursorUsageClient.eventTimestamp(["timestamp": "0"]))
        XCTAssertNil(CursorUsageClient.eventTimestamp(["timestamp": "-5"]))
    }

    func testCursorDomainFilter() {
        XCTAssertTrue(CursorAuthSession.isCursorDomain("cursor.com"))
        XCTAssertTrue(CursorAuthSession.isCursorDomain(".cursor.com"))
        XCTAssertTrue(CursorAuthSession.isCursorDomain("www.cursor.com"))
        XCTAssertTrue(CursorAuthSession.isCursorDomain("authenticator.cursor.sh"))
        XCTAssertFalse(CursorAuthSession.isCursorDomain("opencode.ai"))
        XCTAssertFalse(CursorAuthSession.isCursorDomain("grok.com"))
    }

    /// The pool-estimate back-fill is token-weighted, clips to the half-open
    /// billing cycle, and ignores Cursor Bot (`grok-bot-*`) usage — which has its
    /// own allowance and is not part of the Cursor plan pool.
    func testDailyEstimateWeightByDayExcludesBotAndClipsToCycle() {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let calendar = gregorian
        func event(_ date: Date, _ model: String, _ inputTokens: Double) -> [String: Any] {
            [
                "timestamp": String(Int64(date.timeIntervalSince1970 * 1000)),
                "model": model,
                "tokenUsage": ["inputTokens": inputTokens, "outputTokens": 0]
            ]
        }
        func date(_ day: Int, hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour))!
        }

        let cycleStart = date(22, hour: 17)
        let cycleEnd = date(23, hour: 17)
        let byDay = CursorUsageClient.dailyEstimateWeightByDay(
            events: [
                event(date(22, hour: 10), "default", 5000),
                event(date(22, hour: 20), "default", 300),
                event(date(22, hour: 21), "grok-bot-default", 999_999),
                event(date(23, hour: 12), "composer-2.5-fast", 1220)
            ],
            cycleStart: cycleStart,
            cycleEnd: cycleEnd,
            calendar: calendar
        )

        XCTAssertEqual(byDay[calendar.startOfDay(for: cycleStart)] ?? -1, 300, accuracy: 0.001)
        XCTAssertEqual(byDay[calendar.startOfDay(for: date(23, hour: 12))] ?? -1, 1220, accuracy: 0.001)
        XCTAssertEqual(byDay.values.reduce(0, +), 1520, accuracy: 0.001)
    }

    /// An expired session can 200 with an HTML sign-in page instead of JSON; that
    /// is an expired session, not a decode failure.
    func testRejectUnauthorizedBodyTreatsHTMLAsUnauthorized() {
        let html = Data("<!doctype html><html><body>Sign in to Cursor</body></html>".utf8)
        XCTAssertThrowsError(try CursorUsageClient.rejectUnauthorizedBody(html)) { error in
            XCTAssertEqual(error as? ProviderError, .unauthorized(.cursor))
        }
    }

    /// A 200 body can also carry a `not_authenticated` / `unauthorized` error.
    func testRejectUnauthorizedBodyMapsErrorString() {
        for message in ["not_authenticated", "unauthorized"] {
            let data = Data(#"{"error":"\#(message)"}"#.utf8)
            XCTAssertThrowsError(try CursorUsageClient.rejectUnauthorizedBody(data)) { error in
                XCTAssertEqual(error as? ProviderError, .unauthorized(.cursor))
            }
        }
    }

    /// A truncated body must stay transient so the poller keeps the last-good
    /// snapshot instead of signing the user out.
    func testRejectUnauthorizedBodyTreatsMalformedAsBadResponse() {
        let truncated = Data(#"{"individualUsage":"#.utf8)
        XCTAssertThrowsError(try CursorUsageClient.rejectUnauthorizedBody(truncated)) { error in
            guard let providerError = error as? ProviderError, case .badResponse = providerError else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    /// A normal summary body must pass through untouched.
    func testRejectUnauthorizedBodyPassesNormalSummary() throws {
        let data = Data(#"{"individualUsage":{"plan":{"enabled":true,"used":0,"limit":0}}}"#.utf8)
        XCTAssertNoThrow(try CursorUsageClient.rejectUnauthorizedBody(data))
    }

    /// Cursor Bot (`grok-bot-*`) usage belongs to the Grokbot allowance, not the
    /// Cursor plan pool, so it must be excluded from every Cursor aggregation.
    func testGrokBotEventsAreExcludedFromAggregations() {
        let calendar = Calendar(identifier: .gregorian)
        let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_754_236_800))
        let now = dayStart.addingTimeInterval(10 * 3600)
        let cycleStart = dayStart.addingTimeInterval(-20 * 86400)

        func event(_ model: String, cents: Double, tokens: Double) -> [String: Any] {
            [
                "timestamp": String(Int64(now.timeIntervalSince1970 * 1000)),
                "model": model,
                "chargedCents": cents,
                "tokenUsage": ["inputTokens": tokens, "outputTokens": 0]
            ]
        }

        let events = [
            event("default", cents: 100, tokens: 1000),
            event("grok-bot-default", cents: 900, tokens: 9000)
        ]

        let stats = CursorUsageClient.aggregateCostStats(
            events: events,
            cycleStart: cycleStart,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(stats.meteredCycleUSD, 1.0, accuracy: 0.001)
        XCTAssertEqual(stats.cycleTokens, 1000)
        XCTAssertEqual(stats.todayTokens, 1000)

        let hour = calendar.component(.hour, from: now)
        let tokens = CursorUsageClient.tokenHourWeights(
            fromEvents: events,
            dayStart: dayStart,
            calendar: calendar
        )
        XCTAssertEqual(tokens[hour], 1000)

        let quota = CursorUsageClient.quotaHourWeights(
            fromEvents: events,
            dayStart: dayStart,
            planLimitUSD: 400,
            calendar: calendar
        )
        XCTAssertLessThan(quota[hour], 2.0)
    }
}
