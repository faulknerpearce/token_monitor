@testable import TokenMon
import XCTest

/// Pricing of `$0` plan rows from the Go and Zen rate tables.
final class OpenCodePriceTableTests: XCTestCase {
    /// A model with a published rate, or with recorded cost, is priced.
    func testPricedModelsAreNotFlaggedUnpriced() {
        let estimated = OpenCodeZenCostEstimate.billableCostUSD(
            providerID: "opencode",
            modelID: "claude-haiku-5-5",
            recordedCostUSD: 0,
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0
        )
        XCTAssertEqual(estimated.cost, 0.10, accuracy: 1e-9)
        XCTAssertTrue(estimated.isEstimated)
        XCTAssertFalse(estimated.isUnpriced)
        let recorded = OpenCodeZenCostEstimate.billableCostUSD(
            providerID: "opencode",
            modelID: "totally-new-model",
            recordedCostUSD: 1.5,
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0
        )
        XCTAssertFalse(recorded.isUnpriced)
    }

    func testRatesCarryAVerificationDate() {
        XCTAssertNotNil(DayKey.startOfDay(for: OpenCodeZenCostEstimate.ratesVerifiedOn, calendar: .current))
    }
}
