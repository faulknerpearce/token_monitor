@testable import TokenMon
import XCTest

final class AuthenticatedRequestTests: XCTestCase {
    private func response(_ status: Int, url: String = "https://example.com/path") -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testBuildsRequestWithCookieHeader() throws {
        var request = URLRequest(url: URL(string: "https://example.com/path")!)
        request.httpMethod = "POST"
        AuthenticatedRequest.applyHeaders(
            to: &request,
            cookieHeader: "sid=abc",
            bearerToken: nil,
            referer: "https://example.com"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sid=abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://example.com")
    }

    func testAddsBearerTokenWhenPresent() throws {
        var request = URLRequest(url: URL(string: "https://example.com/path")!)
        AuthenticatedRequest.applyHeaders(
            to: &request,
            cookieHeader: nil,
            bearerToken: "tok123",
            referer: nil
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
    }

    func testUnauthorizedStatusMapsToUnauthorized() throws {
        XCTAssertEqual(
            AuthenticatedRequest.mapError(for: self.response(401), data: Data()),
            UsageError.unauthorized
        )
        XCTAssertEqual(
            AuthenticatedRequest.mapError(for: self.response(403), data: Data()),
            UsageError.unauthorized
        )
    }

    func testTooManyRequestsMapsToRateLimitedWithRetryAfterSeconds() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "120"]
        )!
        XCTAssertEqual(
            AuthenticatedRequest.mapError(for: response, data: Data()),
            UsageError.rateLimited(retryAfter: 120)
        )
        XCTAssertEqual(UsageError.rateLimited(retryAfter: 120).retryAfter, 120)
    }

    func testTooManyRequestsWithoutRetryAfter() throws {
        XCTAssertEqual(
            AuthenticatedRequest.mapError(for: self.response(429), data: Data()),
            UsageError.rateLimited(retryAfter: nil)
        )
    }

    func testRetryAfterParsesHTTPDate() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"]
        )!
        let now = Date(timeIntervalSince1970: 1_445_412_420) // 07:27:00 GMT
        let delay = try XCTUnwrap(AuthenticatedRequest.retryAfter(from: response, now: now))
        XCTAssertEqual(delay, 60, accuracy: 0.001)
    }

    func testRateLimitedProviderErrorKeepsRetryAfter() {
        let error = ProviderError(.rateLimited(retryAfter: 30), context: .cursor)
        XCTAssertEqual(error.usageError, .rateLimited(retryAfter: 30))
        XCTAssertEqual(error.localizedDescription, "Cursor is rate limiting requests. Retrying later.")
    }

    func testNon2xxMapsToBadResponse() throws {
        XCTAssertEqual(
            AuthenticatedRequest.mapError(for: self.response(500), data: Data()),
            UsageError.badResponse("HTTP 500")
        )
    }

    /// The raw response body must never reach the user-facing error message.
    func testNon2xxDoesNotLeakResponseBody() throws {
        let body = Data("{\"token\":\"secret-value\"}".utf8)
        guard case let .badResponse(message)? = AuthenticatedRequest.mapError(for: self.response(500), data: body) else {
            return XCTFail("expected badResponse")
        }
        XCTAssertFalse(message.contains("secret-value"))
        XCTAssertEqual(message, "HTTP 500")
    }

    func testNoErrorOnSuccessRange() {
        XCTAssertNil(AuthenticatedRequest.mapError(for: response(200), data: Data()))
        XCTAssertNil(AuthenticatedRequest.mapError(for: response(204), data: Data()))
    }
}
