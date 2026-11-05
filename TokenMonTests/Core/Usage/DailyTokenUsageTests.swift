@testable import TokenMon
import XCTest

/// The shared per-day token tally behind every provider's hover label, and
/// the OpenCode and Cursor sources that feed it.
final class DailyTokenUsageTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    func testAddMergesModelsAndSortsByTokens() {
        var usage = DailyTokenUsage()
        usage.add(model: "A", input: 10, output: 5, costUSD: 1)
        usage.add(model: "B", cacheRead: 100, costUSD: 2)
        usage.add(model: "A", cacheWrite: 1, costUSD: 0.5)
        XCTAssertEqual(usage.totalTokens, 116)
        XCTAssertEqual(usage.costUSD, 3.5)
        XCTAssertFalse(usage.hasUnpriced)
        XCTAssertEqual(usage.models, [.init(name: "B", tokens: 100), .init(name: "A", tokens: 16)])
    }

    /// Unpriced usage is flagged and left out of the cost; with no priced
    /// usage at all the cost stays unknown.
    func testUnpricedUsageIsFlagged() {
        var usage = DailyTokenUsage()
        usage.add(model: "X", output: 3, costUSD: nil)
        XCTAssertNil(usage.costUSD)
        XCTAssertTrue(usage.hasUnpriced)
        usage.add(model: "", input: 2, costUSD: 0.25)
        XCTAssertEqual(usage.costUSD, 0.25)
        XCTAssertEqual(usage.models.map(\.name), ["X"])
    }

    func testTallyGroupsByLocalDayAndAttachesToBars() throws {
        var tally = DailyTokenUsageTally(calendar: utc)
        tally.add(at: try date("2026-11-03T23:59:00Z"), model: "A", input: 1, costUSD: nil)
        tally.add(at: try date("2026-11-04T00:01:00Z"), model: "A", input: 2, costUSD: nil)
        XCTAssertEqual(tally.days["2026-11-03"]?.inputTokens, 1)
        XCTAssertEqual(tally.days["2026-11-04"]?.inputTokens, 2)

        let bars = [
            DailyBudgetDay(date: try date("2026-11-04T00:00:00Z"), spentUSD: 1, budgetUSD: 2),
            DailyBudgetDay(date: try date("2026-11-05T00:00:00Z"), spentUSD: 0, budgetUSD: 2)
        ].attachingTokens(tally.days, calendar: utc)
        XCTAssertEqual(bars[0].tokens?.inputTokens, 2)
        XCTAssertNil(bars[1].tokens)
    }

    /// OpenCode's per-day tokens carry each row's billable cost and display name.
    func testOpenCodeDailyTokens() throws {
        let row = OpenCodeLocalStats.SessionRow(
            timeCreatedMS: Int64(try date("2026-11-04T12:00:00Z").timeIntervalSince1970 * 1000),
            costUSD: 0.5,
            inputTokens: 10,
            outputTokens: 20,
            cacheReadTokens: 300,
            cacheWriteTokens: 4,
            providerID: "opencode-go",
            modelID: "minimax-m3"
        )
        let day = try XCTUnwrap(OpenCodeLocalStats.dailyTokens(rows: [row, row], calendar: utc)["2026-11-04"])
        XCTAssertEqual(day.totalTokens, 668)
        XCTAssertEqual(day.cacheReadTokens, 600)
        XCTAssertEqual(day.costUSD, 1)
        XCTAssertEqual(day.models.map(\.name), [OpenCodeModelName.display("minimax-m3")])
    }

    /// Cursor events keep their model and cache splits, and roll up per day
    /// with their charged cost.
    func testCursorEventsRollUpPerDay() throws {
        let json: [String: Any] = [
            "timestamp": "\(Int(try date("2026-11-04T12:00:00Z").timeIntervalSince1970 * 1000))",
            "model": "claude-4.5-sonnet",
            "chargedCents": 150,
            "tokenUsage": [
                "inputTokens": 10,
                "outputTokens": 20,
                "cacheReadTokens": 300,
                "cacheWriteTokens": 4
            ]
        ]
        let event = try XCTUnwrap(CursorUsageEvent(json: json))
        XCTAssertEqual(event.model, "claude-4.5-sonnet")
        XCTAssertEqual(event.cacheReadTokens, 300)
        XCTAssertEqual(event.cacheWriteTokens, 4)

        let day = try XCTUnwrap(CursorUsageClient.dailyTokens(events: [event], calendar: utc)["2026-11-04"])
        XCTAssertEqual(day.totalTokens, event.totalTokens)
        XCTAssertEqual(day.costUSD, 1.5)
        XCTAssertEqual(day.models, [.init(name: "claude-4.5-sonnet", tokens: 334)])
    }
}
