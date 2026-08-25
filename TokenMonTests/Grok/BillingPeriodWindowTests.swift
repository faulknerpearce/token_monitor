@testable import TokenMon
import XCTest

/// Billing-period window behavior for the SuperGrok weekly pool:
/// reset-anchored bounds, refusal without a provider reset, rollover,
/// and server-daily fallback rules.
final class BillingPeriodWindowTests: XCTestCase {
    func testBillingPeriodWeekStartsOnPeriodStartDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2
        // Reset Thu Jul 16 → period bars Thu Jul 9 – Wed Jul 15 (mid-period).
        let now = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z")!
        let resetsAt = ISO8601DateFormatter().date(from: "2026-07-16T18:57:00Z")!
        let bounds = try XCTUnwrap(DailyUsageBuilder.billingPeriodWeekBounds(
            resetsAt: resetsAt,
            weekOffset: 0,
            calendar: cal,
            now: now
        ))
        XCTAssertEqual(cal.component(.weekday, from: bounds.start), 5) // Thursday
        XCTAssertEqual(cal.component(.weekday, from: bounds.end), 4) // Wednesday
        XCTAssertEqual(cal.component(.day, from: bounds.start), 9)
        XCTAssertEqual(cal.component(.day, from: bounds.end), 15)
        XCTAssertEqual(cal.dateComponents([.day], from: bounds.start, to: bounds.end).day, 6)

        // Still before reset on that Thursday morning: stay on old week (one Thursday only).
        let resetMorning = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
        let onResetDayMorning = try XCTUnwrap(DailyUsageBuilder.billingPeriodWeekBounds(
            resetsAt: resetsAt,
            weekOffset: 0,
            calendar: cal,
            now: resetMorning
        ))
        XCTAssertEqual(cal.component(.day, from: onResetDayMorning.start), 9)
        XCTAssertEqual(cal.component(.day, from: onResetDayMorning.end), 15)
        XCTAssertEqual(cal.dateComponents([.day], from: onResetDayMorning.start, to: onResetDayMorning.end).day, 6)

        // After reset fires (API may lag): roll entire window — single new Thursday, not two.
        let afterReset = ISO8601DateFormatter().date(from: "2026-07-16T20:00:00Z")!
        let rolled = try XCTUnwrap(DailyUsageBuilder.billingPeriodWeekBounds(
            resetsAt: resetsAt,
            weekOffset: 0,
            calendar: cal,
            now: afterReset
        ))
        XCTAssertEqual(cal.component(.day, from: rolled.start), 16)
        XCTAssertEqual(cal.component(.day, from: rolled.end), 22)
        XCTAssertEqual(cal.dateComponents([.day], from: rolled.start, to: rolled.end).day, 6)
        // Only one Thursday in the 7-day window (the start).
        let thuCount = (0..<7).filter { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: rolled.start) else { return false }
            return cal.component(.weekday, from: day) == 5
        }.count
        XCTAssertEqual(thuCount, 1)

        // After API advances resetsAt: same new-period window.
        let nextResets = ISO8601DateFormatter().date(from: "2026-07-23T18:57:00Z")!
        let next = try XCTUnwrap(DailyUsageBuilder.billingPeriodWeekBounds(
            resetsAt: nextResets,
            weekOffset: 0,
            calendar: cal,
            now: afterReset
        ))
        XCTAssertEqual(cal.component(.day, from: next.start), 16)
        XCTAssertEqual(cal.component(.day, from: next.end), 22)

        let previous = try XCTUnwrap(DailyUsageBuilder.billingPeriodWeekBounds(
            resetsAt: resetsAt,
            weekOffset: -1,
            calendar: cal,
            now: now
        ))
        XCTAssertEqual(cal.component(.day, from: previous.start), 2)
        XCTAssertEqual(cal.component(.day, from: previous.end), 8)
    }

    /// A snapshot without a provider reset must yield no chart window at all —
    /// never a calendar Mon–Sun week invented from `now`.
    func testWeeklyChartRefusedWithoutResetsAt() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let now = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z")!
        let history = [
            WeeklyUsageSnapshot(
                fetchedAt: now.addingTimeInterval(-3600),
                usedPercent: 40,
                resetsAt: nil,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 40)
                ]
            )
        ]
        XCTAssertNil(DailyUsageBuilder.week(
            history: history,
            current: history.last,
            weekOffset: 0,
            resetsAt: nil,
            calendar: cal,
            now: now
        ))
    }

    func testPeriodStartThursdayShowsUsage() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2
        // New period: resets next Thu Jul 23 → window starts Thu Jul 16.
        let now = ISO8601DateFormatter().date(from: "2026-07-16T20:00:00Z")!
        let resetsAt = ISO8601DateFormatter().date(from: "2026-07-23T18:57:00Z")!
        let history = [
            WeeklyUsageSnapshot(
                fetchedAt: now,
                usedPercent: 12,
                resetsAt: resetsAt,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 8),
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 4)
                ]
            )
        ]
        let week = try XCTUnwrap(DailyUsageBuilder.week(
            history: history,
            current: history.last,
            weekOffset: 0,
            resetsAt: resetsAt,
            calendar: cal,
            now: now
        ))
        XCTAssertEqual(cal.component(.weekday, from: week.weekStart), 5) // Thursday
        let thursday = week.days.first { cal.isDate($0.dayStart, inSameDayAs: now) }
        XCTAssertEqual(thursday?.totalPercent ?? 0, 12, accuracy: 0.5)
        XCTAssertFalse(thursday?.segments.isEmpty ?? true)
    }

    func testCrossResetDeltasDoNotInventDropBar() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2
        // Calendar week Mon Jul 13 – Sun Jul 19; reset Thu Jul 16.
        let now = ISO8601DateFormatter().date(from: "2026-07-17T15:00:00Z")! // Friday
        let wed = ISO8601DateFormatter().date(from: "2026-07-15T18:00:00Z")!
        let fri = ISO8601DateFormatter().date(from: "2026-07-17T12:00:00Z")!
        let oldResets = ISO8601DateFormatter().date(from: "2026-07-16T18:57:00Z")!
        let newResets = ISO8601DateFormatter().date(from: "2026-07-23T18:57:00Z")!
        let history = [
            WeeklyUsageSnapshot(
                fetchedAt: wed,
                usedPercent: 90,
                resetsAt: oldResets,
                products: [
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 90)
                ]
            ),
            WeeklyUsageSnapshot(
                fetchedAt: fri,
                usedPercent: 8,
                resetsAt: newResets,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 8)
                ]
            )
        ]
        let week = try XCTUnwrap(DailyUsageBuilder.week(
            history: history,
            current: history.last,
            weekOffset: 0,
            resetsAt: newResets,
            calendar: cal,
            now: now
        ))
        let friDay = week.days.first { cal.isDate($0.dayStart, inSameDayAs: fri) }
        let wedDay = week.days.first { cal.isDate($0.dayStart, inSameDayAs: wed) }
        // Whole week has flipped to the new period; Wed (old period) is outside the window.
        XCTAssertNil(wedDay)
        // Single post-reset sample day: no invented 90→8 drop bar; wait for a second day.
        XCTAssertEqual(friDay?.totalPercent ?? 0, 0, accuracy: 0.5)
        XCTAssertFalse(friDay?.segments.contains { $0.percentOfWeekly > 50 } ?? true)
        XCTAssertTrue(week.isEstimated)
    }

    /// After weekly rollover, chevron-left (`weekOffset: -1`) must still show last period’s bars.
    func testPreviousWeekKeepsPriorPeriodDailyUsageAfterRollover() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2
        // Live week is the new period (started Thu Jul 16); next reset Jul 23.
        let now = ISO8601DateFormatter().date(from: "2026-07-17T15:00:00Z")!
        let mon = ISO8601DateFormatter().date(from: "2026-07-13T18:00:00Z")!
        let tue = ISO8601DateFormatter().date(from: "2026-07-14T18:00:00Z")!
        let wed = ISO8601DateFormatter().date(from: "2026-07-15T18:00:00Z")!
        let fri = ISO8601DateFormatter().date(from: "2026-07-17T12:00:00Z")!
        let oldResets = ISO8601DateFormatter().date(from: "2026-07-16T18:57:00Z")!
        let newResets = ISO8601DateFormatter().date(from: "2026-07-23T18:57:00Z")!
        let history = [
            WeeklyUsageSnapshot(
                fetchedAt: mon,
                usedPercent: 40,
                resetsAt: oldResets,
                products: [
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 40)
                ]
            ),
            WeeklyUsageSnapshot(
                fetchedAt: tue,
                usedPercent: 55,
                resetsAt: oldResets,
                products: [
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 55)
                ]
            ),
            WeeklyUsageSnapshot(
                fetchedAt: wed,
                usedPercent: 70,
                resetsAt: oldResets,
                products: [
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 70)
                ]
            ),
            WeeklyUsageSnapshot(
                fetchedAt: fri,
                usedPercent: 8,
                resetsAt: newResets,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 8)
                ]
            )
        ]
        let week = try XCTUnwrap(DailyUsageBuilder.week(
            history: history,
            current: history.last,
            weekOffset: -1,
            resetsAt: newResets,
            calendar: cal,
            now: now
        ))
        // Prior billing window: Thu Jul 9 – Wed Jul 15.
        XCTAssertEqual(cal.component(.day, from: week.weekStart), 9)
        XCTAssertEqual(cal.component(.day, from: week.weekEnd), 15)
        let tueDay = week.days.first { cal.isDate($0.dayStart, inSameDayAs: tue) }
        let wedDay = week.days.first { cal.isDate($0.dayStart, inSameDayAs: wed) }
        // Day-over-day growth from local samples must survive rollover when browsing back.
        XCTAssertEqual(tueDay?.totalPercent ?? 0, 15, accuracy: 0.5)
        XCTAssertEqual(wedDay?.totalPercent ?? 0, 15, accuracy: 0.5)
        XCTAssertTrue(week.hasDailyData)
    }

    func testServerDailySeriesUsedOnlyWhenLocalHistoryEmpty() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let now = Date()
        // No provider reset → no window and no chart, even with a server daily series.
        XCTAssertNil(DailyUsageBuilder.billingPeriodWeekBounds(
            resetsAt: nil,
            weekOffset: 0,
            calendar: cal,
            now: now
        ))
        XCTAssertNil(DailyUsageBuilder.week(
            history: [],
            current: nil,
            serverDaily: [
                DailyUsageSnapshot(
                    dayStart: cal.startOfDay(for: now),
                    percentOfWeekly: 10,
                    products: []
                )
            ],
            weekOffset: 0,
            calendar: cal,
            now: now
        ))

        // Provider reset supplied: derive the window from it.
        let resetsAt = now.addingTimeInterval(3 * 24 * 3600)
        let weekStart = try XCTUnwrap(DailyUsageBuilder.billingPeriodWeekBounds(
            resetsAt: resetsAt,
            weekOffset: 0,
            calendar: cal,
            now: now
        )).start
        guard let wed = cal.date(byAdding: .day, value: 2, to: weekStart) else {
            return XCTFail("date math")
        }
        let server = [
            DailyUsageSnapshot(dayStart: wed, percentOfWeekly: 10, products: [
                ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 10)
            ])
        ]
        let fromServerOnly = try XCTUnwrap(DailyUsageBuilder.week(
            history: [],
            current: nil,
            serverDaily: server,
            weekOffset: 0,
            resetsAt: resetsAt,
            calendar: cal,
            now: now
        ))
        XCTAssertTrue(fromServerOnly.hasDailyData)
        let wedDay = fromServerOnly.days.first { cal.isDate($0.dayStart, inSameDayAs: wed) }
        XCTAssertEqual(wedDay?.totalPercent ?? 0, 10, accuracy: 0.2)

        // Local deltas win when both are present (do not let sparse server rows wipe history).
        guard let tue = cal.date(byAdding: .day, value: 1, to: weekStart) else {
            return XCTFail("date math")
        }
        let history = [
            WeeklyUsageSnapshot(fetchedAt: tue, usedPercent: 20, products: [
                ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 20)
            ]),
            WeeklyUsageSnapshot(fetchedAt: wed, usedPercent: 35, products: [
                ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 35)
            ])
        ]
        let fromLocal = try XCTUnwrap(DailyUsageBuilder.week(
            history: history,
            current: history.last,
            serverDaily: server,
            weekOffset: 0,
            resetsAt: resetsAt,
            calendar: cal,
            now: now
        ))
        XCTAssertTrue(fromLocal.hasDailyData)
        let localWed = fromLocal.days.first { cal.isDate($0.dayStart, inSameDayAs: wed) }
        XCTAssertEqual(localWed?.totalPercent ?? 0, 15, accuracy: 0.2)
    }
}
