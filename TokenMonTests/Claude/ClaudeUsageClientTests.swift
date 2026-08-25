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

    func testParsePerModelWindows() throws {
        let data = Data("""
        {
          "five_hour": { "utilization": 33.0, "resets_at": "2026-04-11T07:00:00.528743+00:00" },
          "seven_day": { "utilization": 13.0, "resets_at": "2026-04-17T00:59:59.951713+00:00" },
          "seven_day_opus": null,
          "seven_day_sonnet": { "utilization": 1.0, "resets_at": "2026-04-16T03:00:00.951719+00:00" },
          "seven_day_haiku": { "utilization": 5.5, "resets_at": "2026-04-16T05:00:00.000000+00:00" }
        }
        """.utf8)
        let response = try ClaudeUsageResponse.parse(data)
        XCTAssertNil(response.sevenDayOpus)
        XCTAssertEqual(response.sevenDaySonnet?.usedPercent ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(response.sevenDayHaiku?.usedPercent ?? -1, 5.5, accuracy: 0.001)
        XCTAssertEqual(response.perModelWindows.count, 2)
        XCTAssertEqual(response.perModelWindows[0].label, "Sonnet")
        XCTAssertEqual(response.perModelWindows[1].label, "Haiku")

        let snap = ClaudeSnapshot(
            fetchedAt: Date(), fiveHour: response.fiveHour, sevenDay: response.sevenDay,
            sevenDayOpus: response.sevenDayOpus, sevenDaySonnet: response.sevenDaySonnet,
            sevenDayHaiku: response.sevenDayHaiku, accountEmail: nil
        )
        XCTAssertEqual(snap.perModelWindows.count, 2)
    }

    func testParsePerModelWindowsAllNull() throws {
        let data = Data("""
        { "five_hour": { "utilization": 10, "resets_at": "2026-04-11T07:00:00+00:00" },
          "seven_day": { "utilization": 20, "resets_at": "2026-04-17T00:00:00+00:00" },
          "seven_day_opus": null, "seven_day_sonnet": null, "seven_day_haiku": null }
        """.utf8)
        let response = try ClaudeUsageResponse.parse(data)
        XCTAssertTrue(response.perModelWindows.isEmpty)
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
