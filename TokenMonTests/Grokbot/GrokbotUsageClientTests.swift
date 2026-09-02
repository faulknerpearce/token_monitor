@testable import TokenMon
import XCTest

/// Payload shape is `aiserver.v1.GetSandUsageStatusResponse`, reached via
/// `POST /api/dashboard/get-sand-usage-status`. Field names come from the
/// protobuf descriptor shipped in the Cursor dashboard bundle.
final class GrokbotUsageClientTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_787_000_000)

    private func parse(_ json: String) throws -> GrokbotSnapshot {
        try GrokbotUsageClient.parseUsageStatus(
            data: Data(json.utf8),
            accountEmail: "user@example.com",
            fetchedAt: fetchedAt
        )
    }

    func testParsesCursorFundedWeeklyAllowance() throws {
        let snapshot = try parse("""
        {
          "currentPeriodStart": "2026-08-20T11:00:00Z",
          "nextResetTimestampUtc": "2026-08-27T11:00:00Z",
          "usagePercent": 42.5,
          "includedLimitZero": false,
          "hasNonZeroIncludedLimit": true,
          "hasAvailableUsage": true
        }
        """)

        XCTAssertEqual(snapshot.usedPercent, 42.5, accuracy: 1e-9)
        XCTAssertEqual(snapshot.remainingPercent, 57.5, accuracy: 1e-9)
        XCTAssertEqual(snapshot.entitlement, .cursor)
        XCTAssertTrue(snapshot.hasIncludedAllowance)
        XCTAssertEqual(snapshot.resetsAt, ISO8601DateFormatter.parseFlexible("2026-08-27T11:00:00Z"))
        XCTAssertEqual(snapshot.accountEmail, "user@example.com")
    }

    /// The same endpoint serves SuperGrok-funded accounts; only the plan fields
    /// distinguish them, so the panel can say which subscription is paying.
    func testParsesSuperGrokFundedAllowance() throws {
        let snapshot = try parse("""
        {
          "nextResetTimestampUtc": "2026-08-27T11:00:00Z",
          "usagePercent": 12,
          "includedUsageSuperGrokPlan": "super_grok_heavy",
          "grokPlanLabel": "SuperGrok Heavy"
        }
        """)
        XCTAssertEqual(snapshot.entitlement, .superGrok(planLabel: "SuperGrok Heavy"))
        XCTAssertEqual(snapshot.entitlement.captionText, "via SuperGrok Heavy")
    }

    /// Falls back to the raw plan id when no display label ships with it.
    func testSuperGrokPlanWithoutLabelUsesPlanIdentifier() throws {
        let snapshot = try parse("""
        { "usagePercent": 5, "includedUsageSuperGrokPlan": "super_grok" }
        """)
        XCTAssertEqual(snapshot.entitlement, .superGrok(planLabel: "super_grok"))
    }

    /// A payload without the reset instant must not invent one — the snapshot
    /// carries `nil` and the panel withholds the weekly section.
    func testMissingResetYieldsNilRatherThanSubstitutedDate() throws {
        let snapshot = try parse("""
        { "usagePercent": 30, "currentPeriodStart": "2026-08-20T11:00:00Z" }
        """)
        XCTAssertNil(snapshot.resetsAt)
        // The bars-withheld consequence is covered in GrokbotUsagePollerTests.
    }

    /// Accept the proto field names too, so a transport change does not blank the panel.
    func testAcceptsSnakeCaseProtoFieldNames() throws {
        let snapshot = try parse("""
        {
          "current_period_start": "2026-08-20T11:00:00Z",
          "next_reset_timestamp_utc": "2026-08-27T11:00:00Z",
          "usage_percent": 77,
          "included_limit_zero": true
        }
        """)
        XCTAssertEqual(snapshot.usedPercent, 77, accuracy: 1e-9)
        XCTAssertNotNil(snapshot.resetsAt)
        XCTAssertFalse(snapshot.hasIncludedAllowance)
    }

    /// Protobuf `Timestamp` passed through unconverted.
    func testParsesStructuredTimestamps() throws {
        let snapshot = try parse("""
        {
          "usagePercent": 10,
          "nextResetTimestampUtc": { "seconds": 1787000000, "nanos": 500000000 }
        }
        """)
        XCTAssertEqual(snapshot.resetsAt?.timeIntervalSince1970 ?? 0, 1_787_000_000.5, accuracy: 1e-6)
    }

    /// An expired Cursor session redirects to WorkOS and lands on an HTML page,
    /// so a non-JSON body means "signed out", not "malformed response".
    func testHTMLBodyIsTreatedAsUnauthorized() {
        XCTAssertThrowsError(try parse("<!doctype html><html><body>Sign in</body></html>")) { error in
            XCTAssertEqual(error as? GrokbotUsageError, .unauthorized)
        }
    }

    func testNotAuthenticatedErrorPayloadIsUnauthorized() {
        XCTAssertThrowsError(try parse(#"{"error":"not_authenticated"}"#)) { error in
            XCTAssertEqual(error as? GrokbotUsageError, .unauthorized)
        }
    }

    /// An account with no Bot entitlement reports no percent at all.
    func testMissingUsagePercentReportsNoBotAccess() {
        XCTAssertThrowsError(try parse(#"{"hasAvailableUsage":false}"#)) { error in
            guard case .noBotAccess = error as? GrokbotUsageError else {
                return XCTFail("expected .noBotAccess, got \(error)")
            }
        }
    }

    /// proto3 JSON drops default-valued fields, so an unused period arrives with
    /// no `usagePercent` at all. That is 0% — the section must still draw its
    /// (empty) bars rather than falling back to the no-data placeholder.
    func testMissingUsagePercentWithAllowanceFieldsIsZero() throws {
        let snapshot = try parse("""
        {
          "currentPeriodStart": "2026-08-20T11:00:00Z",
          "nextResetTimestampUtc": "2026-08-27T11:00:00Z",
          "hasNonZeroIncludedLimit": true
        }
        """)
        XCTAssertEqual(snapshot.usedPercent, 0, accuracy: 1e-9)
        XCTAssertTrue(snapshot.hasIncludedAllowance)
        XCTAssertNotNil(snapshot.resetsAt)
    }

    /// Same tolerance on the snake_case proto spelling.
    func testMissingUsagePercentSnakeCaseAllowanceFieldsIsZero() throws {
        let snapshot = try parse("""
        { "next_reset_timestamp_utc": "2026-08-27T11:00:00Z" }
        """)
        XCTAssertEqual(snapshot.usedPercent, 0, accuracy: 1e-9)
    }

    func testPercentIsClampedToPoolBounds() throws {
        XCTAssertEqual(try parse(#"{"usagePercent": 140}"#).usedPercent, 100, accuracy: 1e-9)
        XCTAssertEqual(try parse(#"{"usagePercent": -8}"#).usedPercent, 0, accuracy: 1e-9)
    }
}
