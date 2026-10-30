@testable import TokenMon
import XCTest

final class ClaudeCodeUsageLedgerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeLedger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> FileBackedStringStore {
        FileBackedStringStore(directory: directory, filenamePrefix: "claude_code_")
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }

    private func tokens(input: Int64 = 0, output: Int64 = 0, responses: Int = 1) -> ClaudeModelTokens {
        ClaudeModelTokens(inputTokens: input, outputTokens: output, responseCount: responses)
    }

    // MARK: - Pricing

    func testCostUsesEachRateIncludingBothCacheLifetimes() throws {
        let counts = ClaudeModelTokens(
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            cacheWrite5mTokens: 1_000_000,
            cacheWrite1hTokens: 1_000_000
        )
        // Opus 5.5: $4 in, $20 out, $0.20 cache read, $5 5-minute write, $8 1-hour write.
        let cost = try XCTUnwrap(ClaudeAPIPricing.cost(of: counts, modelID: "claude-opus-5-5"))
        XCTAssertEqual(cost, 37.20, accuracy: 0.0001)
    }

    func testPricingIgnoresSnapshotDateSuffix() {
        XCTAssertEqual(ClaudeAPIPricing.baseModelID("claude-haiku-4-5-20251001"), "claude-haiku-4-5")
        XCTAssertEqual(ClaudeAPIPricing.baseModelID("claude-opus-5-5"), "claude-opus-5-5")
        XCTAssertNotNil(ClaudeAPIPricing.rates(for: "claude-haiku-4-5-20251001"))
    }

    func testUnknownModelHasNoPrice() {
        XCTAssertNil(ClaudeAPIPricing.rates(for: "claude-unknown-9"))
        XCTAssertNil(ClaudeAPIPricing.cost(of: tokens(input: 10), modelID: "claude-unknown-9"))
    }

    func testModelDisplayNames() {
        XCTAssertEqual(ClaudeModelName.display("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ClaudeModelName.display("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(ClaudeModelName.display("claude-haiku-4-5-20251001"), "Haiku 4.5")
    }

    // MARK: - Ledger

    func testMergeKeepsTheLargerCountsAndDaysNoLongerScanned() {
        let saved: ClaudeDailyTokens = [
            "2026-09-01": ["claude-opus-5-5": tokens(input: 50)],
            "2026-10-01": ["claude-opus-5-5": tokens(input: 10, output: 90)]
        ]
        let scanned: ClaudeDailyTokens = [
            "2026-10-01": [
                "claude-opus-5-5": tokens(input: 30, output: 40),
                "claude-sonnet-5-5": tokens(input: 5)
            ]
        ]
        let merged = ClaudeCodeUsageLedger.merge(saved: saved, scanned: scanned)
        XCTAssertEqual(merged["2026-09-01"]?["claude-opus-5-5"]?.inputTokens, 50)
        XCTAssertEqual(merged["2026-10-01"]?["claude-opus-5-5"]?.inputTokens, 30)
        XCTAssertEqual(merged["2026-10-01"]?["claude-opus-5-5"]?.outputTokens, 90)
        XCTAssertEqual(merged["2026-10-01"]?["claude-sonnet-5-5"]?.inputTokens, 5)
    }

    func testLedgerKeepsDaysAfterTheirTranscriptsAreDeleted() {
        let first = ClaudeCodeUsageLedger(store: store())
        _ = first.merge(["2026-09-01": ["claude-opus-5-5": tokens(input: 50)]])

        // A new ledger reads the saved file; the September transcript is gone.
        let second = ClaudeCodeUsageLedger(store: store())
        let merged = second.merge(["2026-10-01": ["claude-opus-5-5": tokens(input: 7)]])
        XCTAssertEqual(merged["2026-09-01"]?["claude-opus-5-5"]?.inputTokens, 50)
        XCTAssertEqual(merged["2026-10-01"]?["claude-opus-5-5"]?.inputTokens, 7)
    }

    /// A file from the earlier format, keyed by local days, is discarded so
    /// its days are not counted beside the same responses keyed by UTC day.
    func testLedgerDiscardsAnEarlierFormat() {
        store().set(#"{"version":1,"days":{"2026-10-01":{"claude-opus-5-5":{"inputTokens":99}}}}"#, forKey: "daily_tokens")
        let merged = ClaudeCodeUsageLedger(store: store()).merge(["2026-10-02": ["claude-opus-5-5": tokens(input: 1)]])
        XCTAssertNil(merged["2026-10-01"])
        XCTAssertEqual(merged["2026-10-02"]?["claude-opus-5-5"]?.inputTokens, 1)
    }

    func testLedgerDaysAreUTC() {
        XCTAssertEqual(ClaudeCodeUsageLedger.dayCalendar.timeZone.secondsFromGMT(), 0)
    }

    func testSpendMarksLeftOutUnpricedUsage() {
        XCTAssertEqual(ClaudeCodeUsageSection.spend(ClaudeUsageTotals(tokens: 1, costUSD: 12.5)), "$12.50")
        XCTAssertEqual(
            ClaudeCodeUsageSection.spend(ClaudeUsageTotals(tokens: 1, costUSD: 12.5, hasUnpriced: true)),
            "$12.50+"
        )
    }

    func testLedgerStartsEmptyWhenTheSavedFileIsUnreadable() {
        store().set("not json", forKey: "daily_tokens")
        let merged = ClaudeCodeUsageLedger(store: store()).merge(["2026-10-01": ["claude-opus-5-5": tokens(input: 1)]])
        XCTAssertEqual(merged.count, 1)
    }

    // MARK: - Summary

    func testSummarySplitsMonthFromAllTimeAndRanksModelsByValue() throws {
        let days: ClaudeDailyTokens = [
            "2026-09-30": ["claude-opus-5-5": tokens(output: 1_000_000)],
            "2026-10-01": [
                "claude-opus-5-5": tokens(output: 1_000_000),
                "claude-sonnet-5-5": tokens(output: 1_000_000)
            ],
            "2026-10-22": ["claude-sonnet-5-5": tokens(output: 1_000_000)]
        ]
        let now = try XCTUnwrap(ISO8601DateFormatter.parseFlexible("2026-10-22T12:00:00Z"))
        let summary = ClaudeCodeUsageSummary.make(days: days, now: now, calendar: utcCalendar)

        XCTAssertEqual(summary.month.tokens, 3_000_000)
        XCTAssertEqual(summary.month.costUSD, 40, accuracy: 0.0001)
        XCTAssertEqual(summary.allTime.tokens, 4_000_000)
        XCTAssertEqual(summary.allTime.costUSD, 60, accuracy: 0.0001)
        XCTAssertEqual(summary.monthModels.map(\.modelID), ["claude-sonnet-5-5", "claude-opus-5-5"])
        XCTAssertEqual(summary.monthModels.map(\.sharePercent), [50, 50])
        XCTAssertEqual(summary.monthModels.first?.costUSD ?? 0, 20, accuracy: 0.0001)
    }

    func testSummaryFlagsUnpricedModels() throws {
        let days: ClaudeDailyTokens = [
            "2026-10-01": [
                "claude-opus-5-5": tokens(output: 1_000_000),
                "claude-unknown-9": tokens(output: 500)
            ]
        ]
        let now = try XCTUnwrap(ISO8601DateFormatter.parseFlexible("2026-10-02T00:00:00Z"))
        let summary = ClaudeCodeUsageSummary.make(days: days, now: now, calendar: utcCalendar)

        XCTAssertTrue(summary.month.hasUnpriced)
        let unpriced = try XCTUnwrap(summary.monthModels.first { $0.modelID == "claude-unknown-9" })
        XCTAssertTrue(unpriced.isUnpriced)
        XCTAssertEqual(unpriced.sharePercent, 0)
        XCTAssertEqual(summary.monthModels.first?.sharePercent ?? 0, 100, accuracy: 0.0001)
    }

    func testSummaryIsEmptyAtTheStartOfAMonth() throws {
        let days: ClaudeDailyTokens = ["2026-09-30": ["claude-opus-5-5": tokens(output: 10)]]
        let now = try XCTUnwrap(ISO8601DateFormatter.parseFlexible("2026-10-01T00:30:00Z"))
        let summary = ClaudeCodeUsageSummary.make(days: days, now: now, calendar: utcCalendar)

        XCTAssertEqual(summary.month.tokens, 0)
        XCTAssertTrue(summary.monthModels.isEmpty)
        XCTAssertEqual(summary.allTime.tokens, 10)
    }
}
