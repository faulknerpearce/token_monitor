@testable import TokenMon
import XCTest

/// The Claude model hover label's strings, and the row's VoiceOver label.
final class ClaudeModelHoverDetailTests: XCTestCase {
    private let utc = ClaudeCodeUsageLedger.dayCalendar
    private let opus = "claude-opus-5-5"

    private func now() throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter.parseFlexible("2026-11-09T12:00:00Z"))
    }

    /// Opus 5.5 output tokens worth `usd` at $20 per million.
    private func opusOutput(usd: Double) -> ClaudeModelTokens {
        ClaudeModelTokens(outputTokens: Int64(usd / 20 * 1_000_000), responseCount: 1)
    }

    /// The hover detail of `modelID` in a summary of `days`, made on 2026-11-09.
    private func detail(_ modelID: String, days: ClaudeDailyTokens) throws -> ClaudeModelHoverDetail {
        let summary = ClaudeCodeUsageSummary.make(days: days, now: try now(), calendar: utc)
        let model = try XCTUnwrap(summary.monthModels.first { $0.modelID == modelID })
        return ClaudeModelHoverDetail(model: model, summary: summary)
    }

    // MARK: - This month

    func testTitleTotalValueAndBreakdown() throws {
        let counts = ClaudeModelTokens(
            inputTokens: 1_200_000,
            outputTokens: 2_000_000,
            cacheReadTokens: 30_000_000,
            cacheWrite5mTokens: 400_000,
            cacheWrite1hTokens: 100_000,
            responseCount: 9
        )
        let detail = try detail(opus, days: ["2026-11-02": [opus: counts]])
        XCTAssertEqual(detail.title, "Opus 5.5 · November")
        XCTAssertEqual(detail.tokens, 33_700_000)
        // $4.80 in + $40 out + $6 cache read + $2 5-minute + $0.80 1-hour writes.
        XCTAssertEqual(detail.valueText, "≈ $53.60")
        XCTAssertEqual(detail.breakdown, [
            HoverLabelRow(label: "Input", value: "1.2M"),
            HoverLabelRow(label: "Output", value: "2.0M"),
            HoverLabelRow(label: "Cache read", value: "30M"),
            HoverLabelRow(label: "Cache write", value: "500K")
        ])
    }

    func testSpendUnderACentIsNotShownAsZero() throws {
        let haiku = "claude-haiku-5-5"
        // 10K input at $0.10 per million: $0.001.
        let detail = try detail(haiku, days: ["2026-11-02": [haiku: ClaudeModelTokens(inputTokens: 10_000)]])
        XCTAssertEqual(detail.valueText, "≈ <$0.01")
        XCTAssertEqual(ClaudeModelHoverDetail.usd(0), "$0.00")
        XCTAssertEqual(ClaudeModelHoverDetail.usd(1_712.45), "$1,712.45")
    }

    // MARK: - Against a fully recorded last month

    func testIncreaseAgainstLastMonth() throws {
        let detail = try detail(opus, days: [
            "2026-10-01": [opus: opusOutput(usd: 800)],
            "2026-11-02": [opus: opusOutput(usd: 1_000)]
        ])
        XCTAssertEqual(detail.previousLine, "October: 40M tokens · ≈ $800.00")
        XCTAssertEqual(detail.changeLine, "↑ 25% · +$200.00 vs October")
    }

    func testDecreaseAgainstLastMonth() throws {
        let detail = try detail(opus, days: [
            "2026-10-01": [opus: opusOutput(usd: 1_000)],
            "2026-11-02": [opus: opusOutput(usd: 600)]
        ])
        XCTAssertEqual(detail.previousLine, "October: 50M tokens · ≈ $1,000.00")
        XCTAssertEqual(detail.changeLine, "↓ 40% · \u{2212}$400.00 vs October")
    }

    func testUnchangedAgainstLastMonth() throws {
        let detail = try detail(opus, days: [
            "2026-10-01": [opus: opusOutput(usd: 100)],
            "2026-11-02": [opus: opusOutput(usd: 100)]
        ])
        XCTAssertEqual(detail.changeLine, "Same as October")
    }

    /// The ledger reaches back before October, so a model with no October
    /// usage really is new.
    func testModelUnusedLastMonthIsNew() throws {
        let detail = try detail("claude-fable-5-1", days: [
            "2026-09-20": [opus: opusOutput(usd: 5)],
            "2026-11-02": ["claude-fable-5-1": ClaudeModelTokens(outputTokens: 78_200)]
        ])
        XCTAssertNil(detail.previousLine)
        XCTAssertEqual(detail.changeLine, "New this month")
    }

    /// Last month's few tokens priced at $0.00 give a rise without a percent.
    func testRiseFromZeroSpendLastMonth() throws {
        let haiku = "claude-haiku-5-5"
        let detail = try detail(haiku, days: [
            "2026-10-01": [haiku: ClaudeModelTokens(inputTokens: 100)],
            "2026-11-02": [haiku: ClaudeModelTokens(outputTokens: 4_000_000)]
        ])
        XCTAssertEqual(detail.previousLine, "October: 100 tokens · ≈ <$0.01")
        XCTAssertEqual(detail.changeLine, "↑ $2.00 vs October")
    }

    func testUnpricedModelComparesTokens() throws {
        let unknown = "claude-unknown-9"
        let detail = try detail(unknown, days: [
            "2026-10-01": [unknown: ClaudeModelTokens(outputTokens: 1_000_000)],
            "2026-11-02": [unknown: ClaudeModelTokens(outputTokens: 1_500_000)]
        ])
        XCTAssertEqual(detail.valueText, "No price")
        XCTAssertEqual(detail.previousLine, "October: 1.0M tokens")
        XCTAssertEqual(detail.changeLine, "↑ 50% · +500K tokens vs October")
    }

    // MARK: - Against a partly recorded or unrecorded last month

    /// The record starts on October 9, so last month is named by the days
    /// it covers rather than passed off as all of October.
    func testPartlyRecordedMonthIsNamedByItsDays() throws {
        let detail = try detail(opus, days: [
            "2026-10-09": [opus: opusOutput(usd: 800)],
            "2026-11-02": [opus: opusOutput(usd: 1_000)]
        ])
        XCTAssertEqual(detail.previousLine, "Oct 9–31: 40M tokens · ≈ $800.00")
        XCTAssertEqual(detail.changeLine, "↑ 25% · +$200.00 vs Oct 9–31")
    }

    /// A model missing from a partly recorded month may have been used
    /// before the record starts, so it is not called new.
    func testModelMissingFromAPartlyRecordedMonthIsNotNew() throws {
        let detail = try detail("claude-fable-5-1", days: [
            "2026-10-09": [opus: opusOutput(usd: 5)],
            "2026-11-02": ["claude-fable-5-1": ClaudeModelTokens(outputTokens: 78_200)]
        ])
        XCTAssertNil(detail.previousLine)
        XCTAssertEqual(detail.changeLine, "No usage recorded Oct 9–31")
    }

    func testUnrecordedLastMonthGivesNoComparison() throws {
        let detail = try detail(opus, days: [
            "2026-11-04": [opus: opusOutput(usd: 1_000)]
        ])
        XCTAssertNil(detail.previousLine)
        XCTAssertEqual(detail.changeLine, "No October history (recorded since Nov 4)")
    }

    // MARK: - VoiceOver

    func testAccessibilityLabelSpeaksTheWholeLabel() throws {
        let detail = try detail(opus, days: [
            "2026-10-01": [opus: opusOutput(usd: 800)],
            "2026-11-02": [opus: opusOutput(usd: 1_000)]
        ])
        XCTAssertEqual(
            detail.accessibilityLabel,
            "Opus 5.5, November: 50M tokens, about $1,000.00. "
                + "Input 0, Output 50M, Cache read 0, Cache write 0. "
                + "October: 40M tokens, about $800.00. "
                + "Up 25%, $200.00 more than October"
        )
    }

    func testAccessibilityLabelWithoutAComparison() throws {
        let unknown = "claude-unknown-9"
        let detail = try detail(unknown, days: ["2026-11-04": [unknown: ClaudeModelTokens(outputTokens: 1_000)]])
        XCTAssertEqual(
            detail.accessibilityLabel,
            "Unknown 9, November: 1K tokens, no listed price. "
                + "Input 0, Output 1K, Cache read 0, Cache write 0. "
                + "No October history (recorded since Nov 4)"
        )
    }
}
