import SQLite3
@testable import TokenMon
import XCTest

final class OpenCodeStatsTests: XCTestCase {
    private var dbURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmon-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("opencode.db")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE session (
            time_created INTEGER NOT NULL,
            cost REAL NOT NULL,
            tokens_input INTEGER NOT NULL,
            tokens_output INTEGER NOT NULL,
            tokens_cache_read INTEGER NOT NULL,
            tokens_cache_write INTEGER NOT NULL,
            time_archived INTEGER,
            model TEXT NOT NULL,
            id TEXT
        );
        CREATE TABLE message (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
    }

    override func tearDownWithError() throws {
        if let dbURL {
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
        }
        dbURL = nil
    }

    private func insert(
        timeCreated: Date,
        cost: Double,
        input: Int64,
        output: Int64 = 0,
        cacheRead: Int64 = 0,
        cacheWrite: Int64 = 0,
        model: String,
        archived: Bool = false
    ) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO session (id, time_created, cost, tokens_input, tokens_output, \
        tokens_cache_read, tokens_cache_write, time_archived, model) \
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        let sessionID = "ses_\(UUID().uuidString)"
        sqlite3_bind_text(stmt, 1, sessionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, Int64(timeCreated.timeIntervalSince1970 * 1000))
        sqlite3_bind_double(stmt, 3, cost)
        sqlite3_bind_int64(stmt, 4, input)
        sqlite3_bind_int64(stmt, 5, output)
        sqlite3_bind_int64(stmt, 6, cacheRead)
        sqlite3_bind_int64(stmt, 7, cacheWrite)
        if archived {
            sqlite3_bind_int64(stmt, 8, Int64(timeCreated.timeIntervalSince1970 * 1000))
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        sqlite3_bind_text(stmt, 9, model, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)

        // Mirror session totals onto an assistant message so model/hourly views see them.
        if !archived {
            let (provider, modelID) = parseModelJSON(model)
            insertAssistantMessage(
                sessionID: sessionID,
                timeCreated: timeCreated,
                cost: cost,
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                providerID: provider,
                modelID: modelID
            )
        }
    }

    private func insertAssistantMessage(
        sessionID: String,
        timeCreated: Date,
        cost: Double,
        input: Int64,
        output: Int64 = 0,
        cacheRead: Int64 = 0,
        cacheWrite: Int64 = 0,
        providerID: String,
        modelID: String
    ) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let data = """
        {"role":"assistant","cost":\(cost),"providerID":"\(providerID)","modelID":"\(modelID)",\
        "tokens":{"input":\(input),"output":\(output),"cache":{"read":\(cacheRead),"write":\(cacheWrite)}}}
        """
        let sql = """
        INSERT INTO message (id, session_id, time_created, time_updated, data) \
        VALUES (?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        let ms = Int64(timeCreated.timeIntervalSince1970 * 1000)
        sqlite3_bind_text(stmt, 1, "msg_\(UUID().uuidString)", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, sessionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 3, ms)
        sqlite3_bind_int64(stmt, 4, ms)
        sqlite3_bind_text(stmt, 5, data, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }

    private func parseModelJSON(_ model: String) -> (String, String) {
        guard let data = model.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("other", "unknown") }
        return (json["providerID"] as? String ?? "other", json["id"] as? String ?? "unknown")
    }

    private func modelJSON(provider: String, id: String) -> String {
        #"{"id":"\#(id)","providerID":"\#(provider)"}"#
    }

    func testAggregationWindowsAndModels() throws {
        let now = Date(timeIntervalSince1970: 1_785_592_600)
        let rollingStart = now.addingTimeInterval(-4 * 3600)

        insert(
            timeCreated: rollingStart,
            cost: 4,
            input: 10_000_000,
            output: 1_000_000,
            cacheRead: 2_000_000,
            model: modelJSON(provider: "opencode-go", id: "minimax-m3")
        )
        insert(
            timeCreated: rollingStart.addingTimeInterval(600),
            cost: 2,
            input: 5_000_000,
            cacheRead: 1_000_000,
            model: modelJSON(provider: "opencode-go", id: "minimax-m3")
        )
        insert(timeCreated: now.addingTimeInterval(-2 * 24 * 3600), cost: 90, input: 3_000_000, model: modelJSON(provider: "anthropic", id: "claude-4.5"))
        // Zen free tier must not count toward Go limits
        insert(timeCreated: rollingStart, cost: 3, input: 1_000_000, model: modelJSON(provider: "opencode", id: "deepseek-v4-flash-free"))
        insert(timeCreated: now.addingTimeInterval(-40 * 24 * 3600), cost: 500, input: 7_000_000, model: modelJSON(provider: "opencode-go", id: "kimi-k3"))
        insert(timeCreated: rollingStart, cost: 99, input: 9_000_000, model: modelJSON(provider: "opencode-go", id: "kimi-k3"), archived: true)

        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)

        let rolling = try XCTUnwrap(snap.windows.first { $0.kind == .rolling5h })
        XCTAssertEqual(rolling.usedUSD, 6, accuracy: 0.001)
        XCTAssertEqual(rolling.sessionCount, 2)
        XCTAssertEqual(rolling.usedPercent, 50, accuracy: 0.01)

        let week = try XCTUnwrap(snap.windows.first { $0.kind == .weekly })
        XCTAssertEqual(week.usedUSD, 6, accuracy: 0.001)
        XCTAssertEqual(week.sessionCount, 2)

        // Monthly is subscription-anchored to earliest Go session (−40d). That
        // session itself falls outside the current billing month, so only the
        // recent Go sessions count.
        let month = try XCTUnwrap(snap.windows.first { $0.kind == .monthly })
        XCTAssertEqual(month.usedUSD, 6, accuracy: 0.001)
        XCTAssertEqual(month.sessionCount, 2)

        // Model list shows Go/Zen plan activity only (BYOK like anthropic excluded).
        XCTAssertGreaterThanOrEqual(snap.models.count, 1)
        let goModel = try XCTUnwrap(snap.models.first { $0.providerID == "opencode-go" && $0.modelID == "minimax-m3" })
        XCTAssertEqual(goModel.sessionCount, 2)
        XCTAssertEqual(goModel.inputTokens, 15_000_000)
        XCTAssertEqual(goModel.outputTokens, 1_000_000)
        XCTAssertEqual(goModel.cacheReadTokens, 3_000_000)
        XCTAssertEqual(goModel.costUSD, 6, accuracy: 0.001)

        XCTAssertEqual(snap.modelsWindowLabel, "All models this week")
        XCTAssertNil(snap.models.first { $0.providerID == "anthropic" })
        let topModel = try XCTUnwrap(snap.models.first)
        XCTAssertEqual(topModel.providerID, "opencode-go")
        XCTAssertEqual(topModel.modelID, "minimax-m3")
        XCTAssertEqual(topModel.costUSD, 6, accuracy: 0.001)
        // Menu bar prefers monthly (6/60), not weekly (6/30) or rolling 5h (6/12).
        XCTAssertEqual(snap.primaryUsedPercent, 10, accuracy: 0.01)

        // Zen activity still appears in the model list when used.
        XCTAssertNotNil(snap.models.first { $0.providerID == "opencode" && $0.modelID == "deepseek-v4-flash-free" })
    }

    func testZenDoesNotCountTowardGoLimits() throws {
        let now = Date(timeIntervalSince1970: 1_785_592_600)
        insert(timeCreated: now.addingTimeInterval(-3600), cost: 8, input: 1, model: modelJSON(provider: "opencode", id: "free-model"))
        insert(timeCreated: now.addingTimeInterval(-1800), cost: 1, input: 1, model: modelJSON(provider: "opencode-go", id: "minimax-m3"))

        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)
        let rolling = try XCTUnwrap(snap.windows.first { $0.kind == .rolling5h })
        XCTAssertEqual(rolling.usedUSD, 1, accuracy: 0.001)
        XCTAssertEqual(rolling.sessionCount, 1)
        XCTAssertEqual(rolling.usedPercent, 1 / 12 * 100, accuracy: 0.01)
    }

    func testRollingResetTracksLastEligibleSession() throws {
        let now = Date(timeIntervalSince1970: 1_785_592_600)
        let last = now.addingTimeInterval(-3600)

        insert(timeCreated: now.addingTimeInterval(-4 * 3600), cost: 1, input: 1, model: modelJSON(provider: "opencode-go", id: "m"))
        insert(timeCreated: last, cost: 1, input: 1, model: modelJSON(provider: "opencode-go", id: "m"))
        // Zen activity should not drive the Go rolling reset clock
        insert(timeCreated: now.addingTimeInterval(-600), cost: 5, input: 1, model: modelJSON(provider: "opencode", id: "free"))

        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)
        let rolling = try XCTUnwrap(snap.windows.first { $0.kind == .rolling5h })
        let resetsAt = try XCTUnwrap(rolling.resetsAt)
        XCTAssertEqual(resetsAt.timeIntervalSince1970, last.timeIntervalSince1970 + 5 * 3600, accuracy: 1)
    }

    func testModelsUseWeeklyWindow() throws {
        let now = Date(timeIntervalSince1970: 1_785_592_600)
        insert(timeCreated: now.addingTimeInterval(-3 * 24 * 3600), cost: 2, input: 1, model: modelJSON(provider: "opencode-go", id: "m"))

        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)
        XCTAssertEqual(snap.modelsWindowLabel, "All models this week")
        XCTAssertEqual(snap.models.count, 1)
        XCTAssertEqual(snap.primaryUsedPercent, 2.0 / 60.0 * 100, accuracy: 0.01)
    }

    func testDatabaseMissingThrows() {
        XCTAssertThrowsError(try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL.appendingPathComponent("nope.db")))
    }

    func testClampedPercent() {
        XCTAssertEqual(OpenCodeWindowUsage.clampedPercent(usedUSD: 6, limitUSD: 12), 50, accuracy: 0.01)
        XCTAssertEqual(OpenCodeWindowUsage.clampedPercent(usedUSD: 15, limitUSD: 12), 100, accuracy: 0.01)
        XCTAssertEqual(OpenCodeWindowUsage.clampedPercent(usedUSD: 0, limitUSD: 12), 0, accuracy: 0.01)
        XCTAssertEqual(OpenCodeWindowUsage.clampedPercent(usedUSD: 3, limitUSD: 0), 0, accuracy: 0.01)
    }

    func testWindowLabelsAndLimits() {
        XCTAssertEqual(OpenCodeWindowKind.rolling5h.label, "5-Hour")
        XCTAssertEqual(OpenCodeWindowKind.weekly.label, "Weekly")
        XCTAssertEqual(OpenCodeWindowKind.monthly.label, "Monthly")
        XCTAssertEqual(OpenCodeWindowKind.rolling5h.defaultLimitUSD, 12)
        XCTAssertEqual(OpenCodeWindowKind.weekly.defaultLimitUSD, 30)
        XCTAssertEqual(OpenCodeWindowKind.monthly.defaultLimitUSD, 60)
    }

    func testWeeklyBoundsUTCMonday() throws {
        // Wednesday 2026-07-15 13:00 UTC → week Mon 2026-07-13 00:00 UTC … Mon 2026-07-20
        let now = Date(timeIntervalSince1970: 1_784_120_400) // 2026-07-15 13:00:00 UTC
        let week = OpenCodeLocalStats.weeklyBounds(now: now)
        XCTAssertEqual(week.start.timeIntervalSince1970, 1_783_900_800, accuracy: 1) // 2026-07-13 00:00 UTC
        XCTAssertEqual(week.end.timeIntervalSince(week.start), 7 * 24 * 3600, accuracy: 1)

        // Sunday should still roll back to prior Monday
        let sunday = Date(timeIntervalSince1970: 1_784_462_400) // 2026-07-19 12:00 UTC (Sunday)
        let weekSun = OpenCodeLocalStats.weeklyBounds(now: sunday)
        XCTAssertEqual(weekSun.start.timeIntervalSince1970, 1_783_900_800, accuracy: 1)
    }

    func testMonthlyBoundsSubscriptionAnchored() throws {
        // Subscribed 2026-05-18 14:24:41 UTC; "now" is 2026-08-01 15:00 UTC
        let subscribed = Date(timeIntervalSince1970: 1_779_114_281)
        let now = Date(timeIntervalSince1970: 1_785_596_400)
        let month = OpenCodeLocalStats.monthlyBounds(now: now, subscribedAt: subscribed)

        // Period should be 2026-07-18 14:24:41 … 2026-08-18 14:24:41 (not calendar Aug 1)
        XCTAssertEqual(month.start.timeIntervalSince1970, 1_784_384_681, accuracy: 2)
        XCTAssertEqual(month.end.timeIntervalSince1970, 1_787_063_081, accuracy: 2)
        XCTAssertLessThan(month.start, now)
        XCTAssertGreaterThan(month.end, now)
    }

    func testMonthlyAggregationUsesSubscriptionWindow() throws {
        // Subscribed via first Go session on 2026-05-18; "now" is 2026-08-01 15:00 UTC
        // → billing month 2026-07-18 … 2026-08-18
        let now = Date(timeIntervalSince1970: 1_785_596_400)
        let subscribed = Date(timeIntervalSince1970: 1_779_114_281)
        let inMonth = Date(timeIntervalSince1970: 1_784_500_000) // ~2026-07-19
        let beforeMonth = Date(timeIntervalSince1970: 1_784_000_000) // ~2026-07-13

        insert(timeCreated: subscribed, cost: 1, input: 1, model: modelJSON(provider: "opencode-go", id: "m"))
        insert(timeCreated: beforeMonth, cost: 20, input: 1, model: modelJSON(provider: "opencode-go", id: "m"))
        insert(timeCreated: inMonth, cost: 7, input: 1, model: modelJSON(provider: "opencode-go", id: "m"))
        insert(timeCreated: now.addingTimeInterval(-3600), cost: 3, input: 1, model: modelJSON(provider: "opencode-go", id: "m"))

        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)
        let month = try XCTUnwrap(snap.windows.first { $0.kind == .monthly })
        XCTAssertEqual(month.usedUSD, 10, accuracy: 0.001) // 7 + 3, not calendar-month $3
        XCTAssertEqual(month.sessionCount, 2)
        // Must not reset at calendar month start (would leave only $3)
        XCTAssertNotEqual(month.usedUSD, 3, accuracy: 0.001)
    }

    func testScaledSpendsPercentAnchorsTotalToUsedPercent() {
        let d1 = Date(timeIntervalSince1970: 1_700_000_000)
        let d2 = Date(timeIntervalSince1970: 1_700_086_400)
        let scaled = OpenCodeLocalStats.scaledSpendsPercent([d1: 5, d2: 15], to: 30)
        XCTAssertEqual(scaled[d1] ?? -1, 7.5, accuracy: 0.001)
        XCTAssertEqual(scaled[d2] ?? -1, 22.5, accuracy: 0.001)
        XCTAssertEqual(scaled.values.reduce(0, +), 30, accuracy: 0.001)
    }

    func testScaledSpendsPercentUnchangedWhenNothingToAnchor() {
        let d1 = Date(timeIntervalSince1970: 1_700_000_000)
        let scaled = OpenCodeLocalStats.scaledSpendsPercent([d1: 5], to: 0)
        XCTAssertEqual(scaled[d1] ?? -1, 5, accuracy: 0.001)
        XCTAssertTrue(OpenCodeLocalStats.scaledSpendsPercent([:], to: 30).isEmpty)
    }

    func testMonthDailyBudgetDaysAnchorsBarsToUsedPercent() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func d(_ y: Int, _ month: Int, _ day: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: month, day: day))!
        }
        // Subscription anchor: a Go session on 2026-08-01 sets the billing month start.
        insert(timeCreated: d(2026, 8, 1), cost: 0, input: 0, model: modelJSON(provider: "opencode-go", id: "m"))
        let now = d(2026, 8, 5).addingTimeInterval(12 * 3600) // midday Aug 5
        let spends: [Date: Double] = [
            cal.startOfDay(for: d(2026, 8, 4)): 3.0,
            cal.startOfDay(for: d(2026, 8, 5)): 7.0
        ]
        let days = OpenCodeLocalStats.monthDailyBudgetDays(
            limitUSD: 60,
            usedPercent: 30,
            now: now,
            spentByDay: spends,
            dbURL: dbURL,
            calendar: cal
        )
        XCTAssertEqual(days.count, 7)
        // Bars reconcile with the Monthly bar: recent-week total equals usedPercent.
        XCTAssertEqual(days.reduce(0) { $0 + $1.spentUSD }, 30, accuracy: 0.001)
        // Relative distribution preserved: 3 : 7.
        let aug4 = days.first { cal.isDate($0.date, inSameDayAs: d(2026, 8, 4)) }
        let aug5 = days.first { cal.isDate($0.date, inSameDayAs: d(2026, 8, 5)) }
        XCTAssertEqual(aug4?.spentUSD ?? -1, 9, accuracy: 0.001)   // 3/10 * 30
        XCTAssertEqual(aug5?.spentUSD ?? -1, 21, accuracy: 0.001)  // 7/10 * 30
    }

    func testMonthDailySpendsTrackGoOnly() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func d(_ y: Int, _ month: Int, _ day: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: month, day: day))!
        }
        // Go session anchors the billing month (Aug 1) and is the only spend counted.
        insert(timeCreated: d(2026, 8, 1), cost: 3, input: 1, model: modelJSON(provider: "opencode-go", id: "m"))
        // Zen and direct-provider usage must NOT count toward Go daily spend.
        insert(timeCreated: d(2026, 8, 2), cost: 5, input: 1, model: modelJSON(provider: "opencode", id: "m"))
        insert(timeCreated: d(2026, 8, 3), cost: 4, input: 1, model: modelJSON(provider: "deepseek", id: "m"))

        let spends = try OpenCodeLocalStats.fetchMonthDailySpends(dbURL: dbURL, now: d(2026, 8, 5).addingTimeInterval(12 * 3600))
        // Only the Go message counts; Zen and direct-provider usage are excluded.
        XCTAssertEqual(spends.count, 1)
        XCTAssertEqual(spends.values.reduce(0, +), 3, accuracy: 0.001)
        XCTAssertEqual(spends.values.first ?? -1, 3, accuracy: 0.001)
    }

    func testMonthlyBoundsClampsShortMonths() throws {
        // Subscribed on Jan 31 → period through Feb clamps end day to Feb 28 (2026 not leap)
        let subscribed = Date(timeIntervalSince1970: 1_769_817_600) // 2026-01-31 00:00 UTC
        let now = Date(timeIntervalSince1970: 1_771_113_600) // 2026-02-15 00:00 UTC
        let month = OpenCodeLocalStats.monthlyBounds(now: now, subscribedAt: subscribed)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(cal.component(.month, from: month.start), 1)
        XCTAssertEqual(cal.component(.day, from: month.start), 31)
        XCTAssertEqual(cal.component(.month, from: month.end), 2)
        XCTAssertEqual(cal.component(.day, from: month.end), 28)
    }

    func testGoEligibleProvider() {
        XCTAssertTrue(OpenCodeLocalStats.goEligibleProvider("opencode-go"))
        XCTAssertTrue(OpenCodeLocalStats.goEligibleProvider("OpenCode-Go"))
        XCTAssertFalse(OpenCodeLocalStats.goEligibleProvider("opencode"))
        XCTAssertFalse(OpenCodeLocalStats.goEligibleProvider("anthropic"))
        XCTAssertFalse(OpenCodeLocalStats.goEligibleProvider("deepseek"))
    }

    func testPlanEligibleProvider() {
        XCTAssertTrue(OpenCodeLocalStats.planEligibleProvider("opencode-go"))
        XCTAssertTrue(OpenCodeLocalStats.planEligibleProvider("opencode"))
        XCTAssertTrue(OpenCodeLocalStats.planEligibleProvider("OpenCode"))
        XCTAssertFalse(OpenCodeLocalStats.planEligibleProvider("deepseek"))
        XCTAssertFalse(OpenCodeLocalStats.planEligibleProvider("xai"))
        XCTAssertFalse(OpenCodeLocalStats.planEligibleProvider("openai"))
        XCTAssertFalse(OpenCodeLocalStats.planEligibleProvider("anthropic"))
    }

    func testGrokViaOpenCode() {
        XCTAssertTrue(OpenCodeLocalStats.grokViaOpenCode(providerID: "xai", modelID: "grok-4.5"))
        XCTAssertTrue(OpenCodeLocalStats.grokViaOpenCode(providerID: "XAI", modelID: "anything"))
        XCTAssertTrue(OpenCodeLocalStats.grokViaOpenCode(providerID: "openrouter", modelID: "x-ai/grok-4"))
        XCTAssertFalse(OpenCodeLocalStats.grokViaOpenCode(providerID: "deepseek", modelID: "deepseek-v4-pro"))
        XCTAssertFalse(OpenCodeLocalStats.grokViaOpenCode(providerID: "opencode-go", modelID: "minimax-m3"))
    }

    func testBYOKProvidersExcludedFromModelsAndHeatmap() throws {
        let now = Date(timeIntervalSince1970: 1_785_592_600)
        insert(timeCreated: now.addingTimeInterval(-3600), cost: 2, input: 1, model: modelJSON(provider: "opencode-go", id: "minimax-m3"))
        insert(timeCreated: now.addingTimeInterval(-1800), cost: 5, input: 1, model: modelJSON(provider: "deepseek", id: "deepseek-v4-pro"))
        insert(timeCreated: now.addingTimeInterval(-900), cost: 8, input: 1, model: modelJSON(provider: "xai", id: "grok-4.5"))
        insert(timeCreated: now.addingTimeInterval(-600), cost: 1, input: 1, model: modelJSON(provider: "opencode", id: "zen-free"))

        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)
        XCTAssertEqual(Set(snap.models.map(\.providerID)), Set(["opencode-go", "opencode"]))
        XCTAssertNil(snap.models.first { $0.providerID == "deepseek" })
        XCTAssertNil(snap.models.first { $0.providerID == "xai" })

        // Go limits still ignore Zen and BYOK.
        let rolling = try XCTUnwrap(snap.windows.first { $0.kind == .rolling5h })
        XCTAssertEqual(rolling.usedUSD, 2, accuracy: 0.001)

        let heat = try OpenCodeLocalStats.fetchWeekHeatmap(dbURL: dbURL, now: now)
        XCTAssertEqual(Set(heat.rows.map(\.providerID)), Set(["opencode-go", "opencode"]))
        XCTAssertFalse(heat.rows.contains { $0.providerID == "deepseek" || $0.providerID == "xai" })
    }

    func testOverviewSplitsGrokViaOpenCodeFromPlanUsage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_785_592_600))
        let now = calendar.date(byAdding: .hour, value: 15, to: dayStart)!
        let h10 = calendar.date(byAdding: .hour, value: 10, to: dayStart)!
        let h11 = calendar.date(byAdding: .hour, value: 11, to: dayStart)!
        let h12 = calendar.date(byAdding: .hour, value: 12, to: dayStart)!

        insert(timeCreated: h10, cost: 3, input: 1, model: modelJSON(provider: "opencode-go", id: "minimax-m3"))
        insert(timeCreated: h11, cost: 2, input: 1, model: modelJSON(provider: "xai", id: "grok-4.5"))
        insert(timeCreated: h12, cost: 9, input: 1, model: modelJSON(provider: "deepseek", id: "deepseek-v4-pro"))
        insert(timeCreated: h10.addingTimeInterval(120), cost: 1, input: 1, model: modelJSON(provider: "opencode", id: "zen-free"))

        let hourly = try OpenCodeLocalStats.fetchDayHourlyUsage(dbURL: dbURL, now: now)
        // Day hourly still retains all providers (Overview splits them).
        XCTAssertEqual(hourly.hours[10].segments.count, 2)
        XCTAssertTrue(hourly.hours[11].segments.contains { $0.providerID == "xai" })
        XCTAssertTrue(hourly.hours[12].segments.contains { $0.providerID == "deepseek" })

        let split = hourly.overviewProviderHourWeights()
        XCTAssertEqual(split.openCodeGo[10], 3, accuracy: 0.001)
        XCTAssertEqual(split.openCodeZen[10], 1, accuracy: 0.001)
        XCTAssertEqual(split.openCodeGo[11], 0, accuracy: 0.001)
        XCTAssertEqual(split.openCodeZen[11], 0, accuracy: 0.001)
        XCTAssertEqual(split.grokViaOpenCode[11], 2, accuracy: 0.001)
        XCTAssertEqual(split.grokViaOpenCode[10], 0, accuracy: 0.001)
        // Direct DeepSeek BYOK is excluded from Overview entirely.
        XCTAssertEqual(split.openCodeGo[12], 0, accuracy: 0.001)
        XCTAssertEqual(split.openCodeZen[12], 0, accuracy: 0.001)
        XCTAssertEqual(split.grokViaOpenCode[12], 0, accuracy: 0.001)

        let quotaSplit = hourly.overviewProviderQuotaHourWeights(monthlyLimitUSD: 10)
        XCTAssertEqual(
            quotaSplit.openCodeGo[10],
            30 * QuotaNormalization.averageWeeksPerMonth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            quotaSplit.openCodeZen[10],
            10 * QuotaNormalization.averageWeeksPerMonth,
            accuracy: 0.001
        )

        let tokenSplit = hourly.overviewProviderHourTokenCounts()
        XCTAssertEqual(tokenSplit.openCodeGo[10], 1)
        XCTAssertEqual(tokenSplit.openCodeZen[10], 1)

        let built = ProviderDayHourlyUsage.build(
            dayStart: dayStart,
            grokHourWeights: split.grokViaOpenCode,
            openCodeGoHourWeights: split.openCodeGo,
            openCodeZenHourWeights: split.openCodeZen
        )
        XCTAssertFalse(built.isEmpty)
        XCTAssertGreaterThan(built.hours[10].openCodeSharePercent, 99)
        XCTAssertGreaterThan(built.hours[10].openCodeGoSharePercent, 74)
        XCTAssertGreaterThan(built.hours[10].openCodeZenSharePercent, 24)
        XCTAssertGreaterThan(built.hours[11].grokSharePercent, 99)
        XCTAssertFalse(built.hours[12].hasActivity)
    }

    func testProviderHourlyUsageUsesQuotaDeltasWithoutDailyNormalization() {
        let zeros = Array(repeating: 0.0, count: 24)
        var grok = zeros
        var openCode = zeros
        grok[10] = 2
        openCode[10] = 1
        grok[11] = 0.5

        let usage = ProviderDayHourlyUsage.build(
            dayStart: Date(timeIntervalSince1970: 0),
            grokHourWeights: grok,
            openCodeGoHourWeights: openCode,
            openCodeZenHourWeights: zeros,
            cursorHourWeights: zeros
        )

        XCTAssertEqual(usage.hours[10].activity, 3, accuracy: 0.001)
        XCTAssertEqual(usage.hours[11].activity, 0.5, accuracy: 0.001)
        XCTAssertEqual(usage.hours[10].grokSharePercent, 2.0 / 3.0 * 100, accuracy: 0.001)
    }

    func testCatalogNames() {
        XCTAssertEqual(OpenCodeCatalog.providerShortName("opencode-go"), "Go")
        XCTAssertEqual(OpenCodeCatalog.providerShortName("opencode"), "Zen")
        XCTAssertEqual(OpenCodeCatalog.providerShortName("deepseek"), "DeepSeek")
        XCTAssertEqual(OpenCodeCatalog.modelDisplayName(providerID: "deepseek", modelID: "deepseek-v4-pro"), "DeepSeek · deepseek-v4-pro")
    }

    func testOverviewHourlyBarHeightIsProportional() {
        XCTAssertEqual(
            OverviewHourlyUsageChart.heightFraction(activity: 5, maxActivity: 10),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            OverviewHourlyUsageChart.heightFraction(activity: 10, maxActivity: 10),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(OverviewHourlyUsageChart.heightFraction(activity: 0, maxActivity: 10), 0)
        XCTAssertEqual(OverviewHourlyUsageChart.heightFraction(activity: 5, maxActivity: 0), 0)
        XCTAssertEqual(
            OverviewHourlyUsageChart.heightFraction(activity: 15, maxActivity: 10),
            1,
            accuracy: 0.001
        )
    }

    func testOverviewHourlyRelativeStackKeepsSmallProvidersVisible() {
        // Absolute Go quota is tiny vs Grok, but Go is at its own day peak.
        let hour = ProviderHourUsage(
            hour: 10,
            grokSharePercent: 99,
            openCodeGoSharePercent: 1,
            openCodeZenSharePercent: 0,
            cursorSharePercent: 0,
            claudeSharePercent: 0,
            activity: 10.1,
            costUSD: 0,
            openCodeGoTokens: 0,
            openCodeZenTokens: 0,
            cursorTokens: 0
        )
        // Simulate: Grok day max 20, Go day max 0.1 → this hour's Go weight is 1.0.
        let grokRel = OverviewHourlyUsageChart.heightFraction(activity: 10, maxActivity: 20)
        let goRel = OverviewHourlyUsageChart.heightFraction(activity: 0.1, maxActivity: 0.1)
        XCTAssertEqual(grokRel, 0.5, accuracy: 0.001)
        XCTAssertEqual(goRel, 1.0, accuracy: 0.001)
        // Stacked weight gives Go equal visual presence to a half-peak Grok hour.
        XCTAssertEqual(grokRel + goRel, 1.5, accuracy: 0.001)
        XCTAssertGreaterThan(goRel, grokRel)
        _ = hour
    }

    func testModelPaletteDeterministic() {
        let first = ModelPalette.sRGB(for: "deepseek/deepseek-v4-pro")
        let second = ModelPalette.sRGB(for: "deepseek/deepseek-v4-pro")
        XCTAssertEqual(first.red, second.red)
        XCTAssertEqual(first.green, second.green)
        XCTAssertEqual(first.blue, second.blue)
        XCTAssertTrue(first.red >= 0 && first.red <= 1)
        XCTAssertTrue(first.green >= 0 && first.green <= 1)
        XCTAssertTrue(first.blue >= 0 && first.blue <= 1)
    }

    func testModelPaletteProviderColors() {
        let go = ModelPalette.sRGB(forProvider: "opencode-go", seed: "x")
        XCTAssertEqual(go.red, ModelPalette.orange.red, accuracy: 0.001)
        XCTAssertEqual(go.green, ModelPalette.orange.green, accuracy: 0.001)
        XCTAssertEqual(go.blue, ModelPalette.orange.blue, accuracy: 0.001)

        let zen = ModelPalette.sRGB(forProvider: "opencode", seed: "x")
        XCTAssertEqual(zen.red, ModelPalette.purple.red, accuracy: 0.001)
        XCTAssertEqual(zen.green, ModelPalette.purple.green, accuracy: 0.001)
        XCTAssertEqual(zen.blue, ModelPalette.purple.blue, accuracy: 0.001)
    }

    func testUnusedModelsExcludedFromList() throws {
        let now = Date(timeIntervalSince1970: 1_785_592_600)
        insert(timeCreated: now.addingTimeInterval(-3600), cost: 2, input: 100, model: modelJSON(provider: "opencode-go", id: "used"))
        insert(timeCreated: now.addingTimeInterval(-1800), cost: 0, input: 0, output: 0, model: modelJSON(provider: "opencode-go", id: "empty"))

        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)
        XCTAssertEqual(snap.models.count, 1)
        XCTAssertEqual(snap.models.first?.modelID, "used")
    }

    func testWeekHeatmapAggregatesByDayAndModel() throws {
        // Wednesday 2026-07-15 13:00 UTC → week Mon 2026-07-13 … Mon 2026-07-20
        let now = Date(timeIntervalSince1970: 1_784_120_400)
        let monday = Date(timeIntervalSince1970: 1_783_900_800) // 2026-07-13 00:00 UTC
        let tuesday = monday.addingTimeInterval(24 * 3600)
        let wednesday = monday.addingTimeInterval(2 * 24 * 3600)

        insert(timeCreated: monday.addingTimeInterval(3600), cost: 3, input: 1, model: modelJSON(provider: "opencode-go", id: "minimax-m3"))
        insert(timeCreated: tuesday.addingTimeInterval(3600), cost: 1, input: 1, model: modelJSON(provider: "opencode-go", id: "minimax-m3"))
        insert(timeCreated: wednesday.addingTimeInterval(3600), cost: 5, input: 1, model: modelJSON(provider: "opencode", id: "zen-free"))
        insert(timeCreated: now.addingTimeInterval(-40 * 24 * 3600), cost: 9, input: 1, model: modelJSON(provider: "opencode-go", id: "old"))

        let heat = try OpenCodeLocalStats.fetchWeekHeatmap(dbURL: dbURL, now: now)
        XCTAssertEqual(heat.dayLabels.count, 7)
        XCTAssertEqual(heat.rows.count, 2)

        let go = try XCTUnwrap(heat.rows.first { $0.modelID == "minimax-m3" })
        XCTAssertEqual(go.dayValues[0], 3, accuracy: 0.001) // Monday
        XCTAssertEqual(go.dayValues[1], 1, accuracy: 0.001) // Tuesday
        XCTAssertEqual(go.weekTotal, 4, accuracy: 0.001)

        let zen = try XCTUnwrap(heat.rows.first { $0.modelID == "zen-free" })
        XCTAssertEqual(zen.dayValues[2], 5, accuracy: 0.001) // Wednesday
        XCTAssertFalse(heat.rows.contains { $0.modelID == "old" })
    }

    func testZenZeroCostUsesPublishedTokenValue() throws {
        let now = Date(timeIntervalSince1970: 1_785_592_600)
        insert(
            timeCreated: now.addingTimeInterval(-3600),
            cost: 0,
            input: 1_000_000,
            output: 500_000,
            model: modelJSON(provider: "opencode", id: "deepseek-v4-flash-free")
        )
        insert(
            timeCreated: now.addingTimeInterval(-1800),
            cost: 2,
            input: 100,
            model: modelJSON(provider: "opencode-go", id: "minimax-m3")
        )

        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)
        let zen = try XCTUnwrap(snap.models.first { $0.modelID == "deepseek-v4-flash-free" })
        // 1M * $0.14 + 0.5M * $0.28 = $0.28 of included-use value.
        XCTAssertEqual(zen.costUSD, 0.28, accuracy: 0.001)
        XCTAssertTrue(zen.isCostEstimated)

        let go = try XCTUnwrap(snap.models.first { $0.modelID == "minimax-m3" })
        XCTAssertEqual(go.costUSD, 2, accuracy: 0.001)
        XCTAssertFalse(go.isCostEstimated)
    }

    func testZenPublishedCostHelpers() {
        let billable = OpenCodeZenCostEstimate.billableCostUSD(
            providerID: "opencode",
            modelID: "deepseek-v4-flash-free",
            recordedCostUSD: 0,
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0
        )
        XCTAssertEqual(billable.cost, 0.14, accuracy: 0.001)
        XCTAssertTrue(billable.isEstimated)

        let recorded = OpenCodeZenCostEstimate.billableCostUSD(
            providerID: "opencode",
            modelID: "deepseek-v4-flash-free",
            recordedCostUSD: 1.5,
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0
        )
        XCTAssertEqual(recorded.cost, 1.5, accuracy: 0.001)
        XCTAssertFalse(recorded.isEstimated)
    }

    func testMonthlyTokensAndEstimatedValue() throws {
        // Subscribed 2026-05-18; now 2026-08-01 → billing month from Jul 18.
        let now = Date(timeIntervalSince1970: 1_785_596_400)
        let subscribed = Date(timeIntervalSince1970: 1_779_114_281)
        let inMonth = Date(timeIntervalSince1970: 1_784_500_000)

        insert(timeCreated: subscribed, cost: 1, input: 1, model: modelJSON(provider: "opencode-go", id: "m"))
        insert(
            timeCreated: inMonth,
            cost: 2,
            input: 1_000_000,
            output: 0,
            model: modelJSON(provider: "opencode-go", id: "minimax-m3")
        )
        insert(
            timeCreated: inMonth.addingTimeInterval(60),
            cost: 0,
            input: 1_000_000,
            output: 0,
            model: modelJSON(provider: "opencode", id: "deepseek-v4-flash-free")
        )

        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)
        // 1M + 1M input from the two in-month messages (session inserts also mirror messages).
        XCTAssertGreaterThanOrEqual(snap.monthlyTokens, 2_000_000)
        // Recorded Go $2 + DeepSeek V4 Flash included-use value $0.14.
        XCTAssertEqual(snap.monthlyEstimatedUSD, 2.14, accuracy: 0.02)
    }

    func testDayHourlyUsageStacksModelsByLocalHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_785_592_600))
        let now = calendar.date(byAdding: .hour, value: 15, to: dayStart)!

        let h9 = calendar.date(byAdding: .hour, value: 9, to: dayStart)!
        let h14 = calendar.date(byAdding: .hour, value: 14, to: dayStart)!
        let yesterday = dayStart.addingTimeInterval(-3600)

        insert(timeCreated: h9, cost: 2, input: 1, model: modelJSON(provider: "opencode-go", id: "minimax-m3"))
        insert(timeCreated: h9.addingTimeInterval(600), cost: 1, input: 1, model: modelJSON(provider: "opencode", id: "zen-free"))
        insert(timeCreated: h14, cost: 4, input: 1, model: modelJSON(provider: "opencode-go", id: "minimax-m3"))
        insert(timeCreated: yesterday, cost: 9, input: 1, model: modelJSON(provider: "opencode-go", id: "old"))

        let hourly = try OpenCodeLocalStats.fetchDayHourlyUsage(dbURL: dbURL, now: now)
        XCTAssertEqual(hourly.hours.count, 24)
        XCTAssertEqual(hourly.dayTotalUSD, 7, accuracy: 0.001)
        XCTAssertEqual(hourly.hours[9].totalUSD, 3, accuracy: 0.001)
        XCTAssertEqual(hourly.hours[9].segments.count, 2)
        XCTAssertEqual(hourly.hours[14].totalUSD, 4, accuracy: 0.001)
        XCTAssertTrue(hourly.hours[0].segments.isEmpty)
        XCTAssertFalse(hourly.legend.contains { $0.modelID == "old" })
        XCTAssertEqual(hourly.legend.first?.modelID, "minimax-m3")
    }

    func testHourlyAndModelsTrackMidSessionModelSwitch() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let dayStart = calendar.startOfDay(for: Date())
        let now = calendar.date(byAdding: .hour, value: 16, to: dayStart)!
        let at = calendar.date(byAdding: .hour, value: 15, to: dayStart)!

        // Session labeled as free DeepSeek, but assistant turns used ChatGPT.
        insert(timeCreated: at, cost: 1.6, input: 10, model: modelJSON(provider: "opencode", id: "deepseek-v4-flash-free"))
        insertAssistantMessage(
            sessionID: "ses_switch",
            timeCreated: at.addingTimeInterval(30),
            cost: 0.08,
            input: 100,
            output: 50,
            providerID: "opencode-go",
            modelID: "gpt-5.6-luna"
        )

        let hourly = try OpenCodeLocalStats.fetchDayHourlyUsage(dbURL: dbURL, now: now)
        XCTAssertTrue(hourly.hours[15].segments.contains { $0.modelID == "gpt-5.6-luna" })
        XCTAssertGreaterThan(hourly.hours[15].segments.first { $0.modelID == "gpt-5.6-luna" }?.costUSD ?? 0, 0)

        let snap = try OpenCodeLocalStats.fetchSnapshot(dbURL: dbURL, now: now)
        XCTAssertNotNil(snap.models.first { $0.modelID == "gpt-5.6-luna" })
    }

    func testPreviewSnapshot() {
        let preview = OpenCodeSnapshot.preview
        XCTAssertEqual(preview.windows.count, 3)
        XCTAssertEqual(preview.windows.first?.kind, .rolling5h)
        XCTAssertEqual(preview.modelsWindowLabel, "All models this week")
        XCTAssertEqual(preview.primaryUsedPercent, 16.9 / 60 * 100, accuracy: 0.01)
        XCTAssertGreaterThan(preview.inputTokens, 0)
    }
}
