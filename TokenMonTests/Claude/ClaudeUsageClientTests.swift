@testable import TokenMon
import XCTest

final class ClaudeUsageClientTests: XCTestCase {
    private let fixture = Data("""
    {
      "five_hour": {
        "utilization": 42.5,
        "resets_at": "2026-08-21T14:00:00.127279+00:00"
      },
      "seven_day": {
        "utilization": 87.0,
        "resets_at": "2026-08-27T11:00:00+00:00"
      }
    }
    """.utf8)

    func testParseWindows() throws {
        let response = try ClaudeUsageResponse.parse(fixture)
        XCTAssertEqual(response.fiveHour?.usedPercent ?? -1, 42.5, accuracy: 0.001)
        XCTAssertEqual(response.sevenDay?.usedPercent ?? -1, 87.0, accuracy: 0.001)
    }

    func testParseResetDates() throws {
        let response = try ClaudeUsageResponse.parse(fixture)
        let fiveHourReset = try XCTUnwrap(response.fiveHour?.resetsAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.hour, .minute], from: fiveHourReset)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 0)

        // Weekly reset uses the plain (no-fraction) ISO-8601 form.
        let weeklyReset = try XCTUnwrap(response.sevenDay?.resetsAt)
        let weeklyComponents = calendar.dateComponents([.hour], from: weeklyReset)
        XCTAssertEqual(weeklyComponents.hour, 11)
    }

    func testParseMissingWindowsYieldsNil() throws {
        let data = Data("{}".utf8)
        let response = try ClaudeUsageResponse.parse(data)
        XCTAssertNil(response.fiveHour)
        XCTAssertNil(response.sevenDay)
    }

    func testParseClampsOutOfRangeUtilization() throws {
        let data = Data(#"{"five_hour": {"utilization": 130.0}}"#.utf8)
        let response = try ClaudeUsageResponse.parse(data)
        XCTAssertEqual(response.fiveHour?.usedPercent, 100)
    }

    func testParseInvalidPayloadThrows() {
        XCTAssertThrowsError(try ClaudeUsageResponse.parse(Data("not json".utf8)))
    }

    func testOrganizationIDFromCookieHeader() {
        let header = "__cf_bm=abc; lastActiveOrg=9d7a1b2c-1234-5678-90ab-cdef12345678; sessionKey=sk-ant-sid01-xyz"
        XCTAssertEqual(
            ClaudeUsageClient.organizationID(fromCookieHeader: header),
            "9d7a1b2c-1234-5678-90ab-cdef12345678"
        )
        XCTAssertNil(ClaudeUsageClient.organizationID(fromCookieHeader: "sessionKey=abc"))
        XCTAssertNil(ClaudeUsageClient.organizationID(fromCookieHeader: ""))
    }
}
