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

    /// Huge, infinite and far-future values are clamped so the poll wait stays finite.
    func testRetryAfterIsClamped() {
        func delay(_ header: String) -> TimeInterval? {
            let response = HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": header]
            )!
            return AuthenticatedRequest.retryAfter(from: response, now: Date(timeIntervalSince1970: 1_445_412_420))
        }
        XCTAssertEqual(delay("99999999999"), AuthenticatedRequest.maxRetryAfter)
        XCTAssertEqual(delay("inf"), AuthenticatedRequest.maxRetryAfter)
        XCTAssertEqual(delay("Fri, 31 Dec 9999 23:59:59 GMT"), AuthenticatedRequest.maxRetryAfter)
        XCTAssertEqual(delay("-5"), 0)
        XCTAssertNil(delay("nan"))
    }

    /// A request cancelled mid-flight surfaces as `CancellationError`, which pollers skip.
    func testCancelledRequestThrowsCancellationError() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeverRespondingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let task = Task {
            try await AuthenticatedRequest.perform(
                URLRequest(url: URL(string: "https://example.com/usage")!),
                session: session,
                map: { ProviderError($0, context: .cursor) }
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
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

/// Accepts every request and never answers, so only cancellation ends it.
private final class NeverRespondingURLProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
