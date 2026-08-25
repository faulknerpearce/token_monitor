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

    func testCursorDomainFilter() {
        XCTAssertTrue(CursorAuthSession.isCursorDomain("cursor.com"))
        XCTAssertTrue(CursorAuthSession.isCursorDomain(".cursor.com"))
        XCTAssertTrue(CursorAuthSession.isCursorDomain("www.cursor.com"))
        XCTAssertTrue(CursorAuthSession.isCursorDomain("authenticator.cursor.sh"))
        XCTAssertFalse(CursorAuthSession.isCursorDomain("opencode.ai"))
        XCTAssertFalse(CursorAuthSession.isCursorDomain("grok.com"))
    }

    // MARK: - Daily budget (quota scale)

    private func utcCalendar() -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return gregorian
    }

    private func utcDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 12,
        minute: Int = 0,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func event(at date: Date, chargedCents: Double) -> [String: Any] {
        [
            "timestamp": String(Int64(date.timeIntervalSince1970 * 1000)),
            "chargedCents": chargedCents
        ]
    }

    func testQuotaPercentsByDayScalesListPriceToUsedPercent() {
        let calendar = utcCalendar()
        let saturday = calendar.startOfDay(for: utcDate(2026, 8, 22, calendar: calendar))
        let sunday = calendar.startOfDay(for: utcDate(2026, 8, 23, calendar: calendar))
        let percents = CursorUsageClient.quotaPercentsByDay(
            usdSpends: [saturday: 3.0, sunday: 12.2],
            usedPercent: 4
        )
        let cycleUSD = 15.2
        XCTAssertEqual(percents[saturday] ?? -1, 3.0 / cycleUSD * 4, accuracy: 0.001)
        XCTAssertEqual(percents[sunday] ?? -1, 12.2 / cycleUSD * 4, accuracy: 0.001)
        XCTAssertEqual(percents.values.reduce(0, +), 4, accuracy: 0.001)
    }

    func testQuotaPercentsByDayEmptyWhenNoSpendOrNoUsage() {
        let day = utcCalendar().startOfDay(for: Date(timeIntervalSince1970: 1_754_236_800))
        XCTAssertTrue(CursorUsageClient.quotaPercentsByDay(usdSpends: [day: 10], usedPercent: 0).isEmpty)
        XCTAssertTrue(CursorUsageClient.quotaPercentsByDay(usdSpends: [:], usedPercent: 4).isEmpty)
    }

    func testDailySpendByDayClipsEventsBeforeCycleStart() {
        let calendar = utcCalendar()
        let cycleStart = utcDate(2026, 8, 22, hour: 17, minute: 57, calendar: calendar)
        let cycleEnd = utcDate(2026, 9, 22, hour: 17, minute: 57, calendar: calendar)
        let previousCycleSameMorning = utcDate(2026, 8, 22, hour: 10, calendar: calendar)
        let afterReset = utcDate(2026, 8, 22, hour: 20, calendar: calendar)
        let sunday = utcDate(2026, 8, 23, calendar: calendar)

        let byDay = CursorUsageClient.dailySpendByDay(
            events: [
                event(at: previousCycleSameMorning, chargedCents: 5000),
                event(at: afterReset, chargedCents: 300),
                event(at: sunday, chargedCents: 1220)
            ],
            cycleStart: cycleStart,
            cycleEnd: cycleEnd,
            calendar: calendar
        )

        XCTAssertEqual(byDay[calendar.startOfDay(for: cycleStart)] ?? -1, 3.0, accuracy: 0.001)
        XCTAssertEqual(byDay[calendar.startOfDay(for: sunday)] ?? -1, 12.2, accuracy: 0.001)
        XCTAssertEqual(byDay.values.reduce(0, +), 15.2, accuracy: 0.001)
    }

    func testDailyBudgetDaysUsesQuotaNotPlanLimitDollars() {
        let calendar = utcCalendar()
        let cycleStart = utcDate(2026, 8, 22, hour: 17, minute: 57, calendar: calendar)
        let cycleEnd = utcDate(2026, 9, 22, hour: 17, minute: 57, calendar: calendar)
        let now = utcDate(2026, 8, 23, hour: 20, calendar: calendar)
        let previousCycleSameMorning = utcDate(2026, 8, 22, hour: 10, calendar: calendar)

        let days = CursorUsageClient.dailyBudgetDays(
            events: [
                event(at: previousCycleSameMorning, chargedCents: 5000),
                event(at: utcDate(2026, 8, 22, hour: 20, calendar: calendar), chargedCents: 300),
                event(at: utcDate(2026, 8, 23, calendar: calendar), chargedCents: 1220)
            ],
            planLimitUSD: 20,
            usedPercent: 4,
            billingCycleStart: cycleStart,
            billingCycleEnd: cycleEnd,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(days?.count, 7)
        let saturday = days?.first { calendar.isDate($0.date, inSameDayAs: cycleStart) }
        let sunday = days?.first { calendar.isDate($0.date, inSameDayAs: now) }
        XCTAssertEqual(saturday?.spentUSD ?? -1, 3.0 / 15.2 * 4, accuracy: 0.001)
        XCTAssertEqual(sunday?.spentUSD ?? -1, 12.2 / 15.2 * 4, accuracy: 0.001)
        XCTAssertEqual((saturday?.spentUSD ?? 0) + (sunday?.spentUSD ?? 0), 4, accuracy: 0.001)

        let expectedDaily = 100.0 / Double(DailyBudget.daysInBillingCycle(
            start: cycleStart,
            end: cycleEnd,
            calendar: calendar
        ))
        XCTAssertEqual(saturday?.budgetUSD ?? -1, expectedDaily, accuracy: 0.001)
        XCTAssertEqual(Int((saturday?.budgetUSD ?? 0).rounded()), 3)

        // Old dollar-ratio math would have called Saturday 15% of the $20 limit.
        XCTAssertLessThan(saturday?.spentUSD ?? 100, 2)
        XCTAssertFalse(sunday?.isOverBudget ?? true)
    }

    /// A payload whose billingCycleEnd already passed must paint the running
    /// cycle (today), not the last 7 days of the closed month.
    func testDailyBudgetDaysAdvancesStaleBillingCycle() {
        let calendar = utcCalendar()
        let now = utcDate(2026, 8, 25, hour: 12, calendar: calendar)
        let days = CursorUsageClient.dailyBudgetDays(
            events: [],
            planLimitUSD: 20,
            usedPercent: 0,
            billingCycleStart: utcDate(2026, 6, 16, hour: 17, minute: 57, calendar: calendar),
            billingCycleEnd: utcDate(2026, 7, 16, hour: 17, minute: 57, calendar: calendar),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(days?.count, 7)
        XCTAssertTrue(days?.contains { calendar.isDate($0.date, inSameDayAs: now) } ?? false)
        XCTAssertFalse(days?.contains { $0.date < calendar.startOfDay(for: utcDate(2026, 8, 16, calendar: calendar)) } ?? true)
    }

    /// No billing-cycle signal → no Daily Budget at all. A calendar-month
    /// fallback would silently paint the wrong pool.
    func testDailyBudgetDaysNilWithoutCycleDates() {
        let calendar = utcCalendar()
        let days = CursorUsageClient.dailyBudgetDays(
            events: [event(at: utcDate(2026, 8, 23, hour: 10, calendar: calendar), chargedCents: 100)],
            planLimitUSD: 20,
            usedPercent: 4,
            billingCycleStart: nil,
            billingCycleEnd: nil,
            now: utcDate(2026, 8, 23, hour: 12, calendar: calendar),
            calendar: calendar
        )
        XCTAssertNil(days)
    }
}
