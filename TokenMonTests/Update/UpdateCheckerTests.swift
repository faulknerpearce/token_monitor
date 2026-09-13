@testable import TokenMon
import XCTest

/// Serves a canned response (or throws) for every request.
private class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var session: URLSession!

    override func setUp() async throws {
        suiteName = "UpdateCheckerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        StubURLProtocol.handler = nil
        StubURLProtocol.requestCount = 0
    }

    override func tearDown() async throws {
        StubURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeChecker(currentVersion: AppVersion? = AppVersion("1.5.0")) -> UpdateChecker {
        UpdateChecker(
            settings: AppSettings(defaults: defaults),
            currentVersion: currentVersion,
            session: session
        )
    }

    private func respond(status: Int, body: String) {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
    }

    func testNewerReleaseIsPublished() async {
        respond(status: 200, body: """
        {"tag_name":"v1.5.1","draft":false,"prerelease":false,
         "html_url":"https://github.com/faulknerpearce/token_monitor/releases/tag/v1.5.1"}
        """)
        let checker = makeChecker()
        await checker.checkNow()
        XCTAssertEqual(checker.availableRelease?.version.description, "1.5.1")
        XCTAssertNil(checker.lastError)
    }

    func testSameOrOlderReleaseIsIgnored() async {
        respond(status: 200, body: #"{"tag_name":"v1.5.0","draft":false,"prerelease":false}"#)
        let checker = makeChecker()
        await checker.checkNow()
        XCTAssertNil(checker.availableRelease)
    }

    func testDraftAndPrereleaseAreIgnored() async {
        respond(status: 200, body: #"{"tag_name":"v9.9.9","draft":true,"prerelease":false}"#)
        let checker = makeChecker()
        await checker.checkNow()
        XCTAssertNil(checker.availableRelease)

        respond(status: 200, body: #"{"tag_name":"v9.9.9","draft":false,"prerelease":true}"#)
        await checker.checkNow()
        XCTAssertNil(checker.availableRelease)
    }

    func testRateLimit403ReportsFriendlyError() async {
        respond(status: 403, body: "rate limited")
        let checker = makeChecker()
        await checker.checkNow()
        XCTAssertEqual(checker.lastError, "Update check failed: GitHub rate limit reached; will retry later")
        XCTAssertNil(checker.availableRelease)
    }

    func testServerErrorIsReported() async {
        respond(status: 500, body: "boom")
        let checker = makeChecker()
        await checker.checkNow()
        XCTAssertEqual(checker.lastError, "Update check failed: HTTP 500")
    }

    func testMissingBundleVersionSkipsCheck() async {
        respond(status: 200, body: #"{"tag_name":"v9.9.9"}"#)
        let checker = makeChecker(currentVersion: nil)
        await checker.checkNow()
        XCTAssertNil(checker.availableRelease)
        XCTAssertNil(checker.lastError)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testChecksDisabledSkipsRequest() async {
        defaults.set(false, forKey: "checksForUpdates")
        respond(status: 200, body: #"{"tag_name":"v9.9.9"}"#)
        let checker = makeChecker()
        await checker.checkNow()
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }
}
