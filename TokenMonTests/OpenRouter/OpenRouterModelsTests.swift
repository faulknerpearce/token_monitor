@testable import TokenMon
import XCTest

final class OpenRouterModelsTests: XCTestCase {
    func testParseKeyPayload() throws {
        let data = Data("""
        {
          "data": {
            "label": "TokenMon Key",
            "usage": 25.5,
            "usage_daily": 2.5,
            "usage_weekly": 10.0,
            "usage_monthly": 20.0,
            "limit": 100,
            "limit_remaining": 74.5,
            "limit_reset": "monthly",
            "is_free_tier": false,
            "is_management_key": true
          }
        }
        """.utf8)
        let key = try OpenRouterUsageClient.parseKey(data).data
        XCTAssertEqual(key.label, "TokenMon Key")
        XCTAssertEqual(key.usage, 25.5, accuracy: 0.001)
        XCTAssertEqual(key.usageDaily ?? -1, 2.5, accuracy: 0.001)
        XCTAssertEqual(key.limit ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(key.isManagementKey ?? false, true)
    }

    func testParseCreditsPayload() throws {
        let data = Data("""
        {"data": {"total_credits": 100.5, "total_usage": 25.75}}
        """.utf8)
        let credits = try OpenRouterUsageClient.parseCredits(data).data
        XCTAssertEqual(credits.totalCredits, 100.5, accuracy: 0.001)
        XCTAssertEqual(credits.totalUsage, 25.75, accuracy: 0.001)
    }

    /// Budget = credits the user put in (management key → account balance).
    func testBudgetPrefersAccountCredits() {
        let snapshot = OpenRouterSnapshot.build(
            key: Self.key(usage: 20, limit: 50),
            credits: .init(totalCredits: 120, totalUsage: 30)
        )
        XCTAssertEqual(snapshot.budgetSource, .accountCredits)
        XCTAssertEqual(snapshot.budgetUSD ?? -1, 120, accuracy: 0.001)
        XCTAssertEqual(snapshot.usedUSD, 30, accuracy: 0.001)
        XCTAssertEqual(snapshot.remainingUSD ?? -1, 90, accuracy: 0.001)
        XCTAssertEqual(snapshot.usedPercent ?? -1, 25, accuracy: 0.001)
    }

    /// Inference key without /credits access falls back to its own credit limit.
    func testBudgetFallsBackToKeyLimit() {
        var key = Self.key(usage: 25, limit: 100)
        key.isManagementKey = false
        let snapshot = OpenRouterSnapshot.build(key: key, credits: nil)
        XCTAssertEqual(snapshot.budgetSource, .keyLimit)
        XCTAssertEqual(snapshot.budgetUSD ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(snapshot.usedUSD, 25, accuracy: 0.001)
        XCTAssertEqual(snapshot.remainingUSD ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(snapshot.usedPercent ?? -1, 25, accuracy: 0.001)
    }

    /// Unlimited key with no credits endpoint access has no denominator.
    func testNoBudgetYieldsNilPercent() {
        var key = Self.key(usage: 12.5, limit: nil)
        key.limitRemaining = nil
        let snapshot = OpenRouterSnapshot.build(key: key, credits: nil)
        XCTAssertNil(snapshot.budgetSource)
        XCTAssertNil(snapshot.budgetUSD)
        XCTAssertNil(snapshot.remainingUSD)
        XCTAssertNil(snapshot.usedPercent)
        XCTAssertEqual(snapshot.usedUSD, 12.5, accuracy: 0.001)
    }

    /// With a provider-declared reset window, the bar must reflect spend in the
    /// *current window* (`limit - limit_remaining`) — not all-time usage — so the
    /// bar and the "left" caption reconcile.
    func testKeyLimitWindowUsesLimitRemainingWhenResetSet() {
        var key = Self.key(usage: 25, limit: 100)
        key.limitRemaining = 90 // only 10 spent in the current monthly window
        key.limitReset = "monthly"
        let snapshot = OpenRouterSnapshot.build(key: key, credits: nil)
        XCTAssertEqual(snapshot.budgetSource, .keyLimit)
        XCTAssertEqual(snapshot.usedUSD, 10, accuracy: 0.001)
        XCTAssertEqual(snapshot.remainingUSD ?? -1, 90, accuracy: 0.001)
        // Bar % must equal remaining-derived consumption exactly.
        XCTAssertEqual(
            snapshot.usedPercent ?? -1,
            (100 - (snapshot.remainingUSD ?? 0)) / 100 * 100,
            accuracy: 0.001
        )
    }

    /// No `limit_remaining` but a matching windowed usage field: use it.
    func testKeyLimitWindowFallsBackToMatchingUsageField() {
        var key = Self.key(usage: 25, limit: 100)
        key.limitRemaining = nil
        key.usageWeekly = 14
        key.limitReset = "weekly"
        let snapshot = OpenRouterSnapshot.build(key: key, credits: nil)
        XCTAssertEqual(snapshot.usedUSD, 14, accuracy: 0.001)
        XCTAssertEqual(snapshot.remainingUSD ?? -1, 86, accuracy: 0.001)
    }

    /// Unrecognized reset token with no remaining/usage signal keeps all-time usage.
    func testKeyLimitUnknownResetKeepsAllTimeUsage() {
        var key = Self.key(usage: 25, limit: 100)
        key.limitRemaining = nil
        key.usageDaily = nil
        key.usageWeekly = nil
        key.usageMonthly = nil
        key.limitReset = "hourly"
        let snapshot = OpenRouterSnapshot.build(key: key, credits: nil)
        XCTAssertEqual(snapshot.usedUSD, 25, accuracy: 0.001)
        XCTAssertEqual(snapshot.remainingUSD ?? -1, 75, accuracy: 0.001)
    }

    func testZeroCreditBalanceHasNoDenominator() {
        let snapshot = OpenRouterSnapshot.build(
            key: Self.key(usage: 5, limit: nil),
            credits: .init(totalCredits: 0, totalUsage: 0)
        )
        XCTAssertNil(snapshot.budgetSource)
        XCTAssertNil(snapshot.usedPercent)
    }

    func testNegativeUsageClampsToZero() {
        // Overdrawn accounts report negative balances; the bar must not underfill.
        let snapshot = OpenRouterSnapshot.build(
            key: Self.key(usage: 10, limit: 8),
            credits: .init(totalCredits: 8, totalUsage: -0.5)
        )
        XCTAssertEqual(snapshot.usedUSD, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.usedPercent ?? -1, 0, accuracy: 0.001)
    }

    func testKeyParsingDefaults() throws {
        let data = Data(#"{"data": {"usage": 3}}"#.utf8)
        let key = try OpenRouterUsageClient.parseKey(data).data
        XCTAssertNil(key.label)
        XCTAssertNil(key.limit)
        let snapshot = OpenRouterSnapshot.build(key: key, credits: nil)
        XCTAssertFalse(snapshot.isManagementKey)
        XCTAssertEqual(snapshot.keyUsageDailyUSD, 0, accuracy: 0.001)
        XCTAssertFalse(snapshot.isFreeTier)
    }
    func testParseActivityPayload() throws {
        let data = Data("""
        {"data": [
          {
            "date": "2026-09-20",
            "model": "z-ai/glm-5.3-flash",
            "provider_name": "Z.ai",
            "usage": 2.5,
            "requests": 10,
            "prompt_tokens": 1000,
            "completion_tokens": 200,
            "reasoning_tokens": 0
          },
          {
            "date": "2026-09-20",
            "model": "stealth/ox-alpha",
            "provider_name": "Stealth",
            "usage": 0,
            "requests": 284,
            "prompt_tokens": 3489882,
            "completion_tokens": 110726,
            "reasoning_tokens": 0
          }
        ]}
        """.utf8)
        let rows = try OpenRouterUsageClient.parseActivity(data).data
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].model, "z-ai/glm-5.3-flash")
        XCTAssertEqual(rows[0].usage, 2.5, accuracy: 0.001)
        XCTAssertEqual(rows[1].model, "stealth/ox-alpha")
        XCTAssertEqual(rows[1].promptTokens, 3_489_882)
        XCTAssertEqual(rows[1].completionTokens, 110_726)
    }

    /// A stealth model later revealed as a public one is renamed and valued at
    /// the public model's rate.
    func testStealthModelRevealedAndValued() throws {
        let rows = [
            OpenRouterActivityRow(
                date: "2026-09-20",
                model: "stealth/ox-alpha",
                providerName: "Stealth",
                usage: 0,
                requests: 284,
                promptTokens: 1_000_000,
                completionTokens: 1_000_000,
                reasoningTokens: 0
            )
        ]
        let ox = try XCTUnwrap(OpenRouterModelUsage.models(from: rows).first)
        XCTAssertEqual(ox.modelID, "z-ai/glm-5.3-flash")
        XCTAssertEqual(ox.activitySlug, "stealth/ox-alpha")
        XCTAssertTrue(ox.isRevealed)
        XCTAssertTrue(ox.isCostEstimated)
        // glm-5.3-flash $0.045 in + $0.14 out per 1M token.
        XCTAssertEqual(ox.costUSD, 0.185, accuracy: 0.001)
    }

    /// Paid rows keep the exact cost OpenRouter reports; rows for one model
    /// aggregate across the window.
    func testReportedCostIsNotEstimatedAndAggregates() throws {
        let rows = [
            OpenRouterActivityRow(
                date: "2026-09-20",
                model: "z-ai/glm-5.3-flash",
                providerName: "Z.ai",
                usage: 2.1292,
                requests: 498,
                promptTokens: 7_926_964,
                completionTokens: 71_931,
                reasoningTokens: 0
            ),
            OpenRouterActivityRow(
                date: "2026-09-21",
                model: "z-ai/glm-5.3-flash",
                providerName: "Z.ai",
                usage: 0.5,
                requests: 2,
                promptTokens: 10,
                completionTokens: 5,
                reasoningTokens: 0
            )
        ]
        let glm = try XCTUnwrap(OpenRouterModelUsage.models(from: rows).first)
        XCTAssertEqual(glm.costUSD, 2.6292, accuracy: 0.0001)
        XCTAssertFalse(glm.isCostEstimated)
        XCTAssertEqual(glm.requests, 500)
        XCTAssertEqual(glm.percentOfWindow, 100, accuracy: 0.001)
    }

    /// A free slug with no price entry stays at $0 rather than inventing value.
    func testUnpricedFreeSlugStaysZero() throws {
        let rows = [
            OpenRouterActivityRow(
                date: "2026-09-20",
                model: "moonshotai/kimi-k2.6:free",
                providerName: "Moonshot",
                usage: 0,
                requests: 3,
                promptTokens: 39_644,
                completionTokens: 71,
                reasoningTokens: 0
            )
        ]
        let free = try XCTUnwrap(OpenRouterModelUsage.models(from: rows).first)
        XCTAssertEqual(free.costUSD, 0, accuracy: 1e-9)
        XCTAssertFalse(free.isCostEstimated)
    }

    private static func key(usage: Double, limit: Double?) -> OpenRouterKeyData {
        OpenRouterKeyData(
            label: "Test Key",
            usage: usage,
            usageDaily: 1,
            usageWeekly: 2,
            usageMonthly: 3,
            limit: limit,
            limitRemaining: limit.map { $0 - usage },
            limitReset: nil,
            isFreeTier: false,
            isManagementKey: true
        )
    }
}
