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
