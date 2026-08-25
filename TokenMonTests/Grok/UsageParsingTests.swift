@testable import TokenMon
import XCTest

final class UsageParsingTests: XCTestCase {
    func testParseFixtureJSON() throws {
        let json = Data("""
        {
          "usedPercent": 35,
          "remainingPercent": 65,
          "resetsAt": "2026-07-16T20:25:00Z",
          "products": [
            { "id": "build", "displayName": "Grok Build", "percentOfPool": 25 },
            { "id": "api", "displayName": "API", "percentOfPool": 9 },
            { "id": "chat", "displayName": "Chat", "percentOfPool": 1 }
          ]
        }
        """.utf8)

        let snap = try XCTUnwrap(UsageResponseParser.parseJSON(json, accountEmail: nil))
        XCTAssertEqual(snap.usedPercent, 35, accuracy: 0.01)
        XCTAssertEqual(snap.remainingPercent, 65, accuracy: 0.01)
        XCTAssertEqual(snap.products.count, 3)
        XCTAssertEqual(snap.products[0].id, "build")
        XCTAssertEqual(snap.products[0].colorToken, .build)
    }

    func testRemainingDefaultsFromUsed() {
        let snap = WeeklyUsageSnapshot(usedPercent: 40)
        XCTAssertEqual(snap.remainingPercent, 60, accuracy: 0.01)
    }

    func testUsageValuesAreClampedAtModelBoundary() {
        let snapshot = WeeklyUsageSnapshot(
            usedPercent: 140,
            remainingPercent: -20,
            products: [ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 140)]
        )

        XCTAssertEqual(snapshot.usedPercent, 100, accuracy: 0.001)
        XCTAssertEqual(snapshot.remainingPercent, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.products[0].percentOfPool, 100, accuracy: 0.001)
    }

    func testGrokDomainMatchingDoesNotAcceptLookalikes() {
        XCTAssertTrue(AuthSessionService.isGrokDomain(".grok.com"))
        XCTAssertTrue(AuthSessionService.isGrokDomain("accounts.x.ai"))
        XCTAssertFalse(AuthSessionService.isGrokDomain("evilgrok.com"))
        XCTAssertFalse(AuthSessionService.isGrokDomain("x.ai.evil.example"))
    }

    func testCLIBillingParse() throws {
        let json = Data("""
        {
          "monthlyLimit": { "val": 1000 },
          "usage": { "totalUsed": { "val": 350 } },
          "billingCycle": { "billingPeriodEnd": "2026-07-16T20:25:00Z" }
        }
        """.utf8)
        let snap = try XCTUnwrap(UsageResponseParser.parseCLIBilling(json, accountEmail: "a@b.com"))
        XCTAssertEqual(snap.usedPercent, 35, accuracy: 0.01)
        XCTAssertEqual(snap.accountEmail, "a@b.com")
        XCTAssertNotNil(snap.resetsAt)
    }

    func testProductColorMapping() {
        XCTAssertEqual(ProductColor.from(productID: "build"), .build)
        XCTAssertEqual(ProductColor.from(productID: "API"), .api)
        XCTAssertEqual(ProductColor.from(productID: "imagine"), .imagine)
    }

    func testExportCSVContainsHeader() throws {
        let data = try ExportService.export([.preview], format: .csv)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.contains("fetchedAt,usedPercent"))
        XCTAssertTrue(text.contains("build:25"))
    }

    func testExportJSONRoundTrip() throws {
        let data = try ExportService.export([.preview], format: .json)
        let obj = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(obj is [Any])
    }

    func testByProductMapParse() throws {
        let json = Data("""
        {
          "usedPercent": 35,
          "byProduct": { "build": 25, "api": 9, "chat": 1 }
        }
        """.utf8)
        let snap = try XCTUnwrap(UsageResponseParser.parseJSON(json, accountEmail: nil))
        XCTAssertEqual(snap.products.count, 3)
    }

    func testGRPCProductBreakdown() throws {
        let grpcHex = "000000005f0a5d0d0000104212001a00220b08b1debfd20610b8efb07f2a0b08b1d3e4d20610b8efb07f" +
            "3a070804150000b8413a07080215000050413a020806421c0802120b08b1debfd20610b8efb07f1a0b08b1d3e4d20610b8efb07f" +
            "580162006801800000000f677270632d7374617475733a300d0a"
        let data = try XCTUnwrap(Data(hexString: grpcHex))
        let parsed = try GRPCWebParser.parseUsage(data)
        XCTAssertEqual(parsed.usedPercent ?? -1, 36, accuracy: 0.01)
        XCTAssertEqual(parsed.products.count, 2)
        XCTAssertTrue(parsed.products.contains { $0.id == "chat" && abs($0.percentOfPool - 23) < 0.01 })
        XCTAssertTrue(parsed.products.contains { $0.id == "build" && abs($0.percentOfPool - 13) < 0.01 })
    }

    /// Live SuperGrok payload (2026-07-28): Build 30, Chat 21, Imagine 12, Other 1.
    /// Regression: enum 5 must be Imagine (not Voice); enum 3 must be Other (not Imagine).
    func testGRPCLiveCreditsConfigEnumMap() throws {
        let grpcHex = """
        000000006d0a6b0d0000804212001a00220b08b1c889d30610b8efb07f\
        2a0b08b1bdaed30610b8efb07f3a070802150000f0413a070804150000a841\
        3a07080515000040413a070803150000803f421c0802120b08b1c889d306\
        10b8efb07f1a0b08b1bdaed30610b8efb07f580162006801\
        800000000f677270632d7374617475733a300d0a
        """.replacingOccurrences(of: "\n", with: "")
        let data = try XCTUnwrap(Data(hexString: grpcHex))
        let parsed = try GRPCWebParser.parseUsage(data)
        XCTAssertEqual(parsed.usedPercent ?? -1, 64, accuracy: 0.01)

        let byID = Dictionary(uniqueKeysWithValues: parsed.products.map { ($0.id, $0.percentOfPool) })
        XCTAssertEqual(byID["build"] ?? -1, 30, accuracy: 0.01)
        XCTAssertEqual(byID["chat"] ?? -1, 21, accuracy: 0.01)
        XCTAssertEqual(byID["imagine"] ?? -1, 12, accuracy: 0.01)
        XCTAssertEqual(byID["other"] ?? -1, 1, accuracy: 0.01)
        XCTAssertNil(byID["voice"], "Voice must not receive Imagine’s 12%")
        XCTAssertEqual(parsed.products.count, 4)
        // Display order: Chat, Build, Imagine, Other
        XCTAssertEqual(parsed.products.map(\.id), ["chat", "build", "imagine", "other"])
    }

    /// Voice enum present at 0% must not steal Imagine’s percent (sub-message pairing).
    func testGRPCProductBreakdownWithVoiceGap() throws {
        let frame = makeCreditsConfigFrame(
            usedPercent: 64.0,
            products: [
                (2, 30.0),  // build
                (4, 21.0),  // chat
                (6, nil),   // voice — enum only, no percent
                (5, 12.0),  // imagine
                (3, 1.0)    // other
            ]
        )

        let parsed = try GRPCWebParser.parseUsage(frame)
        XCTAssertEqual(parsed.usedPercent ?? -1, 64, accuracy: 0.01)
        XCTAssertEqual(parsed.products.count, 4)

        let byID = Dictionary(uniqueKeysWithValues: parsed.products.map { ($0.id, $0.percentOfPool) })
        XCTAssertEqual(byID["build"] ?? -1, 30, accuracy: 0.01)
        XCTAssertEqual(byID["chat"] ?? -1, 21, accuracy: 0.01)
        XCTAssertEqual(byID["imagine"] ?? -1, 12, accuracy: 0.01)
        XCTAssertEqual(byID["other"] ?? -1, 1, accuracy: 0.01)
        XCTAssertNil(byID["voice"], "Voice (0%) must not steal Imagine’s percent")
    }

    /// Same gap scenario but Voice includes an explicit fixed32 0 percent field.
    func testGRPCProductBreakdownWithExplicitZeroVoicePercent() throws {
        let frame = makeCreditsConfigFrame(
            usedPercent: 64.0,
            products: [
                (2, 30.0),
                (4, 21.0),
                (6, 0.0),   // voice with explicit 0%
                (5, 12.0),
                (3, 1.0)
            ]
        )

        let parsed = try GRPCWebParser.parseUsage(frame)
        let byID = Dictionary(uniqueKeysWithValues: parsed.products.map { ($0.id, $0.percentOfPool) })
        XCTAssertEqual(byID["imagine"] ?? -1, 12, accuracy: 0.01)
        XCTAssertEqual(byID["other"] ?? -1, 1, accuracy: 0.01)
        XCTAssertNil(byID["voice"])
        XCTAssertEqual(parsed.products.count, 4)
    }

    // MARK: - Helpers for programmatic protobuf construction

    private func makeCreditsConfigFrame(
        usedPercent: Float,
        products: [(enumValue: UInt64, percent: Float?)],
        resetAt: UInt64 = 2_000_000_000
    ) -> Data {
        var inner = Data()
        // [1,1] usedPercent (fixed32)
        inner.append(contentsOf: [0x0d])
        inner.append(fixed32Bytes(usedPercent))
        for product in products {
            inner.append(makeProductSubMessage(enum: product.enumValue, percent: product.percent))
        }
        // [1,5,1] resetAt (varint unix seconds)
        var resetMsg = Data()
        resetMsg.append(contentsOf: [0x08])
        resetMsg.append(varintBytes(resetAt))
        inner.append(contentsOf: [0x2a, UInt8(resetMsg.count)])
        inner.append(resetMsg)

        var payload = Data()
        payload.append(contentsOf: [0x0a, UInt8(inner.count)])
        payload.append(inner)

        var frame = Data()
        frame.append(contentsOf: [0x00])
        let plen = UInt32(payload.count)
        frame.append(contentsOf: [
            UInt8((plen >> 24) & 0xFF),
            UInt8((plen >> 16) & 0xFF),
            UInt8((plen >> 8) & 0xFF),
            UInt8(plen & 0xFF)
        ])
        frame.append(payload)
        return frame
    }

    private func makeProductSubMessage(enum value: UInt64, percent: Float?) -> Data {
        var msg = Data()
        // field 1 = enum (varint)
        msg.append(contentsOf: [0x08])
        msg.append(varintBytes(value))
        // field 2 = percent (fixed32) when present, including explicit 0
        if let pct = percent {
            msg.append(contentsOf: [0x15])
            msg.append(fixed32Bytes(pct))
        }
        // Outer field-7 tag + length
        var outer = Data()
        outer.append(contentsOf: [0x3a, UInt8(msg.count)])
        outer.append(msg)
        return outer
    }

    private func varintBytes(_ value: UInt64) -> Data {
        var remaining = value
        var bytes = Data()
        while remaining >= 0x80 {
            bytes.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
        return bytes
    }

    private func fixed32Bytes(_ value: Float) -> Data {
        let bits = value.bitPattern
        return Data([
            UInt8(bits & 0xFF),
            UInt8((bits >> 8) & 0xFF),
            UInt8((bits >> 16) & 0xFF),
            UInt8((bits >> 24) & 0xFF)
        ])
    }

    func testDailyUsageBuilderDeltas() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2
        // Fixed mid-week pair so both samples sit inside the billing window.
        let now = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z")!
        let today = cal.startOfDay(for: now)
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else {
            return XCTFail("date math")
        }
        let resetsAt = ISO8601DateFormatter().date(from: "2026-07-16T18:57:00Z")!

        let history = [
            WeeklyUsageSnapshot(
                fetchedAt: yesterday.addingTimeInterval(3600 * 12),
                usedPercent: 10,
                resetsAt: resetsAt,
                products: [
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 7),
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 3)
                ]
            ),
            WeeklyUsageSnapshot(
                fetchedAt: today.addingTimeInterval(3600 * 10),
                usedPercent: 30,
                resetsAt: resetsAt,
                products: [
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 20),
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 10)
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
        XCTAssertEqual(week.days.count, 7)
        XCTAssertTrue(week.hasDailyData)
        XCTAssertFalse(week.isEstimated)

        let yesterdayDay = week.days.first { cal.isDate($0.dayStart, inSameDayAs: yesterday) }
        let todayDay = week.days.first { cal.isDate($0.dayStart, inSameDayAs: today) }
        // First sample day stays empty; today is the day-over-day delta only.
        XCTAssertEqual(yesterdayDay?.totalPercent ?? 0, 0, accuracy: 0.2)
        XCTAssertEqual(todayDay?.totalPercent ?? 0, 20, accuracy: 0.2)
        XCTAssertEqual(todayDay?.segments.count, 2)
    }

    func testDailyUsageOnlyShowsProductsThatGrew() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let now = ISO8601DateFormatter().date(from: "2026-07-12T12:00:00Z")!
        let today = cal.startOfDay(for: now)
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else {
            return XCTFail("date math")
        }
        // Monday-morning reset keeps the running window Mon Jul 6 – Sun Jul 12,
        // so both sample days sit inside one provider-anchored billing period.
        let resetsAt = ISO8601DateFormatter().date(from: "2026-07-13T09:00:00Z")!

        let history = [
            WeeklyUsageSnapshot(
                fetchedAt: yesterday.addingTimeInterval(3600 * 18),
                usedPercent: 39,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 23),
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 13),
                    ProductUsage(id: "api", displayName: "API", percentOfPool: 3)
                ]
            ),
            WeeklyUsageSnapshot(
                fetchedAt: today.addingTimeInterval(3600 * 10),
                usedPercent: 42,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 26),
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 13),
                    ProductUsage(id: "api", displayName: "API", percentOfPool: 3)
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

        let todayDay = week.days.first { cal.isDate($0.dayStart, inSameDayAs: today) }
        XCTAssertEqual(todayDay?.totalPercent ?? 0, 3, accuracy: 0.2)
        XCTAssertEqual(todayDay?.segments.count, 1)
        XCTAssertEqual(todayDay?.segments.first?.productID, "chat")
        // Legend for the week still includes yesterday’s products, but today’s bar is chat-only.
        XCTAssertTrue(todayDay?.segments.allSatisfy { $0.percentOfWeekly > 0 } ?? false)
    }

    func testDailyUsageShowsYesterdayAfterDayRollover() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        // Sunday now with a Monday reset: the running billing window is Mon–Sun
        // because the provider anchored it there, not because a calendar week was guessed.
        let now = ISO8601DateFormatter().date(from: "2026-07-12T10:00:00Z")!
        let today = cal.startOfDay(for: now)
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else {
            return XCTFail("date math")
        }
        let resetsAt = ISO8601DateFormatter().date(from: "2026-07-13T09:00:00Z")!

        let products = [
            ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 23),
            ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 16)
        ]
        // App tracked all day Saturday; Sunday morning has not used more yet.
        let history = [
            WeeklyUsageSnapshot(
                fetchedAt: yesterday.addingTimeInterval(3600 * 20),
                usedPercent: 39,
                products: products
            ),
            WeeklyUsageSnapshot(
                fetchedAt: today.addingTimeInterval(3600 * 9),
                usedPercent: 39,
                products: products
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

        let yesterdayDay = week.days.first { cal.isDate($0.dayStart, inSameDayAs: yesterday) }
        let todayDay = week.days.first { cal.isDate($0.dayStart, inSameDayAs: today) }
        // First sample is a baseline only; flat day-over-day → empty bars.
        XCTAssertEqual(yesterdayDay?.totalPercent ?? 0, 0, accuracy: 0.2)
        XCTAssertEqual(todayDay?.totalPercent ?? 0, 0, accuracy: 0.2)
        XCTAssertFalse(week.isEstimated)
        XCTAssertFalse(week.hasDailyData)
    }

    func testDailyUsageEmptyUntilSecondSampleDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let now = ISO8601DateFormatter().date(from: "2026-07-11T18:00:00Z")!
        let resetsAt = ISO8601DateFormatter().date(from: "2026-07-16T18:57:00Z")!
        let history = [
            WeeklyUsageSnapshot(
                fetchedAt: now,
                usedPercent: 39,
                resetsAt: resetsAt,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 23),
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 16)
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
        // Single sample: do not paint week-to-date product % onto "today".
        XCTAssertFalse(week.hasDailyData)
        XCTAssertTrue(week.isEstimated)
        XCTAssertTrue(week.days.allSatisfy(\.segments.isEmpty))
    }

    func testDailyUsageExcludesFlatBuildFromToday() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2
        let now = ISO8601DateFormatter().date(from: "2026-07-13T12:00:00Z")!
        let today = cal.startOfDay(for: now)
        guard
            let day1 = cal.date(byAdding: .day, value: -2, to: today),
            let day2 = cal.date(byAdding: .day, value: -1, to: today)
        else {
            return XCTFail("date math")
        }
        let resetsAt = ISO8601DateFormatter().date(from: "2026-07-16T18:57:00Z")!
        let history = [
            WeeklyUsageSnapshot(
                fetchedAt: day1.addingTimeInterval(3600 * 20),
                usedPercent: 46,
                resetsAt: resetsAt,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 27),
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 16),
                    ProductUsage(id: "api", displayName: "API", percentOfPool: 3)
                ]
            ),
            WeeklyUsageSnapshot(
                fetchedAt: day2.addingTimeInterval(3600 * 14),
                usedPercent: 51,
                resetsAt: resetsAt,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 31),
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 16),
                    ProductUsage(id: "api", displayName: "API", percentOfPool: 4)
                ]
            ),
            WeeklyUsageSnapshot(
                fetchedAt: today.addingTimeInterval(3600 * 8),
                usedPercent: 58,
                resetsAt: resetsAt,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 34),
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 16),
                    ProductUsage(id: "api", displayName: "API", percentOfPool: 7),
                    ProductUsage(id: "voice", displayName: "Voice", percentOfPool: 1)
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
        let todayDay = week.days.first { cal.isDate($0.dayStart, inSameDayAs: today) }
        XCTAssertEqual(todayDay?.totalPercent ?? 0, 7, accuracy: 0.2)
        XCTAssertFalse(todayDay?.segments.contains { $0.productID == "build" } ?? true)
        XCTAssertTrue(todayDay?.segments.contains { $0.productID == "chat" } ?? false)
        XCTAssertTrue(todayDay?.segments.contains { $0.productID == "api" } ?? false)
        XCTAssertTrue(todayDay?.segments.contains { $0.productID == "voice" } ?? false)
    }

    /// Mid-period server recalibration: used% drops but `resetsAt` stays the same.
    /// Invalidates pre-rebase samples so prior days do not keep inflated bars while
    /// the rebased week-to-date is painted on the recalibration day.
    func testDailyUsageMidPeriodRecalibrationRebasesOntoThatDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2
        let now = ISO8601DateFormatter().date(from: "2026-07-14T22:00:00Z")!
        let today = cal.startOfDay(for: now)
        guard
            let yesterday = cal.date(byAdding: .day, value: -1, to: today),
            let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: today)
        else {
            return XCTFail("date math")
        }
        // Same billing period as live history (reset still Jul 16).
        let resetsAt = ISO8601DateFormatter().date(from: "2026-07-16T18:57:00Z")!
        let history = [
            WeeklyUsageSnapshot(
                fetchedAt: twoDaysAgo.addingTimeInterval(3600 * 18),
                usedPercent: 51,
                resetsAt: resetsAt,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 31),
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 16),
                    ProductUsage(id: "api", displayName: "API", percentOfPool: 4)
                ]
            ),
            WeeklyUsageSnapshot(
                fetchedAt: yesterday.addingTimeInterval(3600 * 12),
                usedPercent: 71,
                resetsAt: resetsAt,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 34),
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 28),
                    ProductUsage(id: "api", displayName: "API", percentOfPool: 7),
                    ProductUsage(id: "voice", displayName: "Voice", percentOfPool: 2)
                ]
            ),
            WeeklyUsageSnapshot(
                fetchedAt: today.addingTimeInterval(3600 * 16),
                usedPercent: 28,
                resetsAt: resetsAt,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 1),
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 20),
                    ProductUsage(id: "api", displayName: "API", percentOfPool: 7)
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
        let todayDay = week.days.first { cal.isDate($0.dayStart, inSameDayAs: today) }
        let yesterdayDay = week.days.first { cal.isDate($0.dayStart, inSameDayAs: yesterday) }
        let olderDay = week.days.first { cal.isDate($0.dayStart, inSameDayAs: twoDaysAgo) }
        // Drop prior days; start tracking on the reset day with current week-to-date.
        XCTAssertTrue(todayDay?.isAfterReset ?? false)
        XCTAssertEqual(olderDay?.totalPercent ?? 0, 0, accuracy: 0.2)
        XCTAssertEqual(yesterdayDay?.totalPercent ?? 0, 0, accuracy: 0.2)
        XCTAssertEqual(todayDay?.totalPercent ?? 0, 28, accuracy: 0.5)
        XCTAssertTrue(todayDay?.segments.contains { $0.productID == "build" } ?? false)
        XCTAssertTrue(week.isEstimated)
    }

    /// Real period rollover: used% drops AND sample `resetsAt` advances — mark after-reset
    /// and attribute the new period total to that sample day.
    func testDailyUsageRealResetShowsPostResetUsage() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2
        // Hold the chart on the pre-reset billing window so both samples stay in-range.
        let now = ISO8601DateFormatter().date(from: "2026-07-15T20:00:00Z")!
        let today = cal.startOfDay(for: now)
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else {
            return XCTFail("date math")
        }
        let oldResets = ISO8601DateFormatter().date(from: "2026-07-16T18:57:00Z")!
        let newResets = ISO8601DateFormatter().date(from: "2026-07-23T18:57:00Z")!
        let history = [
            WeeklyUsageSnapshot(
                fetchedAt: yesterday.addingTimeInterval(3600 * 12),
                usedPercent: 90,
                resetsAt: oldResets,
                products: [
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 90)
                ]
            ),
            WeeklyUsageSnapshot(
                fetchedAt: today.addingTimeInterval(3600 * 8),
                usedPercent: 12,
                resetsAt: newResets,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 8),
                    ProductUsage(id: "api", displayName: "API", percentOfPool: 4)
                ]
            )
        ]
        let week = try XCTUnwrap(DailyUsageBuilder.week(
            history: history,
            current: history.last,
            weekOffset: 0,
            // Window Jul 9–15 (day before oldResets), not the post-reset week.
            resetsAt: oldResets,
            calendar: cal,
            now: now
        ))
        let todayDay = week.days.first { cal.isDate($0.dayStart, inSameDayAs: today) }
        XCTAssertNotNil(todayDay)
        XCTAssertTrue(todayDay?.isAfterReset ?? false)
        XCTAssertEqual(todayDay?.totalPercent ?? 0, 12, accuracy: 0.2)
        XCTAssertTrue(todayDay?.segments.contains { $0.productID == "chat" } ?? false)
    }

    func testDailyUsageIgnoresPriorBillingPeriodSample() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2
        let now = ISO8601DateFormatter().date(from: "2026-07-13T12:00:00Z")!
        let resetsAt = ISO8601DateFormatter().date(from: "2026-07-16T18:57:00Z")!
        // Prior period end (before week start Jul 9) plus a single in-week sample.
        let priorPeriod = ISO8601DateFormatter().date(from: "2026-07-08T18:00:00Z")!
        let inWeek = ISO8601DateFormatter().date(from: "2026-07-13T10:00:00Z")!
        let history = [
            WeeklyUsageSnapshot(
                fetchedAt: priorPeriod,
                usedPercent: 90,
                resetsAt: ISO8601DateFormatter().date(from: "2026-07-09T18:57:00Z"),
                products: [
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 90)
                ]
            ),
            WeeklyUsageSnapshot(
                fetchedAt: inWeek,
                usedPercent: 20,
                resetsAt: resetsAt,
                products: [
                    ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 12),
                    ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 8)
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
        // Prior period must not create a giant before-reset bar; single in-week sample → empty.
        XCTAssertTrue(week.days.allSatisfy(\.segments.isEmpty))
        XCTAssertTrue(week.isEstimated)
    }

    func testDailyCapFillFraction() {
        // 10% of weekly pool / (100/7) ≈ 0.70 of the daily track.
        let fraction = DailyUsageBuilder.fillFraction(forDayUsage: 10)
        XCTAssertEqual(fraction, 10.0 / (100.0 / 7.0), accuracy: 0.001)
        // Over daily cap clamps to full track.
        XCTAssertEqual(DailyUsageBuilder.fillFraction(forDayUsage: 21), 1.0, accuracy: 0.001)
        XCTAssertEqual(DailyUsageBuilder.fillFraction(forDayUsage: 0), 0, accuracy: 0.001)
    }

    /// A lagging gRPC payload whose canonical reset already passed must keep
    /// that timestamp — the window rolls instead of dropping the anchor.
    func testGRPCParseKeepsPastCanonicalReset() throws {
        // 2025-06-15T21:06:40Z — in the past relative to any realistic `now`.
        let pastResetUnix: UInt64 = 1_750_000_000
        let frame = makeCreditsConfigFrame(
            usedPercent: 40,
            products: [(4, 40.0)],
            resetAt: pastResetUnix
        )
        let parsed = try GRPCWebParser.parseUsage(frame)
        let resetsAt = try XCTUnwrap(parsed.resetsAt)
        XCTAssertEqual(resetsAt.timeIntervalSince1970, TimeInterval(pastResetUnix), accuracy: 1)
    }

    func testDailyUsagePreviewHasSevenDays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let week = DailyUsageBuilder.preview(calendar: cal)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertTrue(week.hasDailyData)
        // Billing period: first day is Thursday for the synthetic Jul 16 reset.
        XCTAssertEqual(cal.component(.weekday, from: week.weekStart), 5)
        XCTAssertEqual(cal.component(.weekday, from: week.weekEnd), 4)
    }
}

final class SharedHelpersTests: XCTestCase {
    func testPercentClampBounds() {
        XCTAssertEqual(Percent.clamp(0.0 as Double), 0.0)
        XCTAssertEqual(Percent.clamp(100.0 as Double), 100.0)
        XCTAssertEqual(Percent.clamp(-5.0 as Double), 0.0)
        XCTAssertEqual(Percent.clamp(140.0 as Double), 100.0)
        XCTAssertEqual(Percent.clamp(37.6 as Double), 37.6)
    }

    func testDomainMatchesAcceptedHosts() {
        XCTAssertTrue(Domain.matches("grok.com", hosts: ["grok.com", "x.ai"]))
        XCTAssertTrue(Domain.matches("www.grok.com", hosts: ["grok.com"]))
        XCTAssertTrue(Domain.matches("accounts.x.ai", hosts: ["x.ai"]))
        XCTAssertTrue(Domain.matches("opencode.ai", hosts: ["opencode.ai"]))
        XCTAssertTrue(Domain.matches("api.opencode.ai", hosts: ["opencode.ai"]))
        XCTAssertFalse(Domain.matches("evilgrok.com", hosts: ["grok.com"]))
        XCTAssertFalse(Domain.matches("grok.com.evil.example", hosts: ["grok.com"]))
        XCTAssertFalse(Domain.matches("notopencode.ai", hosts: ["opencode.ai"]))
        XCTAssertTrue(Domain.matches("x.com", hosts: ["twitter.com", "x.com"]))
    }

    func testFileBackedStringStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmon-store-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileBackedStringStore(directory: dir, filenamePrefix: "test_")

        XCTAssertNil(store.value(forKey: "session"))
        store.set("abc=123", forKey: "session")
        XCTAssertEqual(store.value(forKey: "session"), "abc=123")
        store.set("xyz=9", forKey: "session")
        XCTAssertEqual(store.value(forKey: "session"), "xyz=9")
        store.remove(forKey: "session")
        XCTAssertNil(store.value(forKey: "session"))
    }

    func testUsdCurrencyFormatter() {
        XCTAssertEqual(Format.usdCurrency.string(from: 410), "$410.00")
        XCTAssertEqual(Format.usdCurrency.string(from: 4.1), "$4.10")
    }
}
