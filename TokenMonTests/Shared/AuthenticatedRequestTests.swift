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

    // MARK: - Bot-protection challenges

    private func response(_ status: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(staticString: "https://example.com/path"), statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    private let challengeHTML = Data("<!DOCTYPE html><html><head><title>Just a moment...</title></head></html>".utf8)

    /// A Cloudflare 403 challenge is transient, not a rejected session.
    func testForbiddenHTMLIsTransientChallenge() {
        XCTAssertEqual(
            AuthenticatedRequest.responseError(for: response(403), data: challengeHTML),
            .badResponse(ProviderHTTP.botChallengeMessage(status: 403))
        )
    }

    func testCloudflareMitigatedHeaderIsTransientChallenge() {
        let mitigated = response(403, headers: ["cf-mitigated": "challenge", "Content-Type": "application/json"])
        XCTAssertEqual(
            AuthenticatedRequest.responseError(for: mitigated, data: Data("{}".utf8)),
            .badResponse(ProviderHTTP.botChallengeMessage(status: 403))
        )
    }

    /// A JSON 403 and any 401 still reject the session.
    func testForbiddenJSONAndUnauthorizedStillRejectSession() {
        XCTAssertEqual(
            AuthenticatedRequest.responseError(for: response(403), data: Data("{\"error\":\"forbidden\"}".utf8)),
            .unauthorized
        )
        XCTAssertEqual(AuthenticatedRequest.responseError(for: response(401), data: challengeHTML), .unauthorized)
    }

    /// A 2xx HTML sign-in page is a rejection; other 2xx HTML is transient.
    func testTwoHundredHTMLIsUnauthorizedOnlyForLoginPages() {
        let login = Data("<html><head><title>Sign in</title></head><form><input type=\"password\"></form></html>".utf8)
        XCTAssertThrowsError(try ProviderHTTP.jsonObject(login, context: .cursor)) { error in
            XCTAssertEqual(error as? ProviderError, .unauthorized(.cursor))
        }
        XCTAssertThrowsError(try ProviderHTTP.jsonObject(challengeHTML, context: .cursor)) { error in
            XCTAssertEqual((error as? ProviderError)?.usageError, .badResponse("Unexpected HTML response"))
        }
        let maintenance = Data("<html><body>Service temporarily unavailable</body></html>".utf8)
        XCTAssertThrowsError(try ProviderHTTP.jsonObject(maintenance, context: .cursor)) { error in
            XCTAssertEqual((error as? ProviderError)?.usageError, .badResponse("Unexpected HTML response"))
        }
    }

    // MARK: - Session and headers

    /// Provider calls never use the shared cookie jar or the URL cache.
    func testProviderSessionHasNoCookieJarOrCache() {
        let configuration = ProviderURLSession.shared.configuration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCache)
    }

    func testAppliesAppUserAgent() {
        var request = URLRequest(url: URL(staticString: "https://example.com/path"))
        AuthenticatedRequest.applyHeaders(to: &request, cookieHeader: nil, bearerToken: nil, referer: nil)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), AppIdentity.userAgent)
    }

    func testStaticURLParsesLiteral() {
        XCTAssertEqual(URL(staticString: "https://grok.com/rest/usage").host, "grok.com")
    }
}
