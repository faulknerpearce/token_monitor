@testable import TokenMon
import XCTest

final class ChatGPTUsageClientTests: XCTestCase {
    private let fixture = Data("""
    {
      "plan_type": "plus",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 12,
          "limit_window_seconds": 18000,
          "reset_after_seconds": 9000,
          "reset_at": 1787300000
        },
        "secondary_window": {
          "used_percent": 57.5,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 343143,
          "reset_at": 1787800000
        }
      }
    }
    """.utf8)

    func testParseWindows() throws {
        let response = try ChatGPTUsageResponse.parse(fixture)
        XCTAssertEqual(response.planName, "plus")
        XCTAssertTrue(response.allowed)
        XCTAssertFalse(response.limitReached)
        XCTAssertEqual(response.primary?.usedPercent ?? -1, 12, accuracy: 0.001)
        XCTAssertEqual(response.secondary?.usedPercent ?? -1, 57.5, accuracy: 0.001)
    }

    func testParseWindowMetadata() throws {
        let response = try ChatGPTUsageResponse.parse(fixture)
        XCTAssertEqual(response.primary?.windowSeconds, 18000)
        XCTAssertEqual(response.primary?.resetsAt?.timeIntervalSince1970 ?? -1, 1787300000, accuracy: 0.5)
        XCTAssertEqual(response.secondary?.windowSeconds, 604800)
    }

    func testParseLegacyFieldNames() throws {
        let data = Data(#"{"five_hour": {"used_percent": 30}, "weekly": {"utilization": 40}}"#.utf8)
        let response = try ChatGPTUsageResponse.parse(data)
        XCTAssertEqual(response.primary?.usedPercent, 30)
        XCTAssertEqual(response.secondary?.usedPercent, 40)
    }

    func testParseMissingWindowsYieldsNil() throws {
        let data = Data(#"{"plan_type": "free"}"#.utf8)
        let response = try ChatGPTUsageResponse.parse(data)
        XCTAssertNil(response.primary)
        XCTAssertNil(response.secondary)
        XCTAssertEqual(response.planName, "free")
    }

    func testParseClampsOutOfRangePercent() throws {
        let data = Data(#"{"rate_limit": {"primary_window": {"used_percent": 140}}}"#.utf8)
        let response = try ChatGPTUsageResponse.parse(data)
        XCTAssertEqual(response.primary?.usedPercent, 100)
    }

    func testParseInvalidPayloadThrows() {
        XCTAssertThrowsError(try ChatGPTUsageResponse.parse(Data("nope".utf8)))
    }

    func testSessionTokenParsing() throws {
        let ok = Data(#"{"accessToken": "tok-123", "user": {"email": "a@b.c"}}"#.utf8)
        XCTAssertEqual(try ChatGPTUsageClient.parseSessionToken(ok), "tok-123")
        XCTAssertThrowsError(try ChatGPTUsageClient.parseSessionToken(Data("{}".utf8)))
    }

    /// An HTML body is an edge challenge, not proof the stored session is dead;
    /// mapping it to `.unauthorized` would delete the credential.
    func testSessionTokenHTMLIsTransientNotUnauthorized() {
        let html = Data("<!DOCTYPE html><html><body>Just a moment...</body></html>".utf8)
        XCTAssertThrowsError(try ChatGPTUsageClient.parseSessionToken(html)) { error in
            guard let providerError = error as? ProviderError else {
                return XCTFail("expected ProviderError, got \(error)")
            }
            guard case .badResponse = providerError.usageError else {
                return XCTFail("HTML must stay transient, got \(providerError.usageError)")
            }
        }
    }

    func testAccountIDFromAccessToken() throws {
        // JWT header.payload.signature with the OpenAI auth claim.
        let payload = #"{"https://api.openai.com/auth": {"chatggpt_account_id": "acct_42"}, "sub": "user-1"}"#
        let token = "eyJhbGciOiJSUzI1NiJ9.\(Self.base64URL(payload)).sig"
        XCTAssertEqual(ChatGPTAccountID.fromAccessToken(token), "acct_42")

        // snake_case variant claim key.
        let altPayload = #"{"https://api.openai.com/auth": {"chatgpt_account_id": "acct_alt"}}"#
        let altToken = "h.\(Self.base64URL(altPayload)).s"
        XCTAssertEqual(ChatGPTAccountID.fromAccessToken(altToken), "acct_alt")

        XCTAssertNil(ChatGPTAccountID.fromAccessToken("garbage"))
    }

    private static func base64URL(_ string: String) -> String {
        Data(string.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
