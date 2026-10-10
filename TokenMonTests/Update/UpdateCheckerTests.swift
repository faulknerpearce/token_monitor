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
        openedURLs = []
    }

    override func tearDown() async throws {
        StubURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var openedURLs: [URL] = []

    private func makeChecker(
        currentVersion: AppVersion? = AppVersion("1.5.0"),
        installedAppURL: URL = URL(fileURLWithPath: "/nonexistent/TokenMon.app")
    ) -> UpdateChecker {
        UpdateChecker(
            settings: AppSettings(defaults: defaults),
            currentVersion: currentVersion,
            session: session,
            bundleIdentifier: "com.modelmonitor.app",
            installedAppURL: installedAppURL,
            openURL: { [weak self] in self?.openedURLs.append($0) }
        )
    }

    /// An `.app` folder inside a temporary folder; read-only when `writable` is false.
    private func makeInstalledApp(writable: Bool) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCheckerTests-\(UUID().uuidString)", isDirectory: true)
        let app = folder.appendingPathComponent("TokenMon.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        if !writable {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        }
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        return app
    }

    private static let releaseWithAssets = """
    {"tag_name":"v1.6.0","draft":false,"prerelease":false,
     "html_url":"https://github.com/faulknerpearce/token_monitor/releases/tag/v1.6.0",
     "assets":[
       {"name":"TokenMon-1.6.0.zip",
        "browser_download_url":"https://github.com/faulknerpearce/token_monitor/releases/download/v1.6.0/TokenMon-1.6.0.zip"},
       {"name":"TokenMon-1.6.0.pkg",
        "browser_download_url":"https://github.com/faulknerpearce/token_monitor/releases/download/v1.6.0/TokenMon-1.6.0.pkg"}
     ]}
    """

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

    func testManualCheckRunsWhenAutomaticChecksAreOff() async {
        defaults.set(false, forKey: "checksForUpdates")
        respond(status: 200, body: #"{"tag_name":"v1.5.0","draft":false,"prerelease":false}"#)
        let checker = makeChecker()
        await checker.checkManually()
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertEqual(checker.statusMessage, "You're up to date.")
    }

    func testManualCheckSurfacesANewerRelease() async {
        respond(status: 200, body: """
        {"tag_name":"v1.5.1","draft":false,"prerelease":false,
         "html_url":"https://github.com/faulknerpearce/token_monitor/releases/tag/v1.5.1",
         "assets":[{"name":"TokenMon-1.5.1.zip",
           "browser_download_url":"https://github.com/faulknerpearce/token_monitor/releases/download/v1.5.1/TokenMon-1.5.1.zip"}]}
        """)
        let checker = makeChecker()
        await checker.checkManually()
        XCTAssertEqual(checker.actionTitle, "Update to 1.5.1…")
        XCTAssertEqual(
            checker.availableRelease?.archiveURL?.lastPathComponent,
            "TokenMon-1.5.1.zip"
        )
        XCTAssertNil(checker.statusMessage)
    }

    func testChecksDisabledSkipsRequest() async {
        defaults.set(false, forKey: "checksForUpdates")
        respond(status: 200, body: #"{"tag_name":"v9.9.9"}"#)
        let checker = makeChecker()
        await checker.checkNow()
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    /// A copy that cannot replace itself is offered the installer package.
    func testNotWritableInstallOffersInstallerPackage() async throws {
        respond(status: 200, body: Self.releaseWithAssets)
        let checker = try makeChecker(installedAppURL: makeInstalledApp(writable: false))
        await checker.checkNow()
        await checker.installAvailableUpdate()
        XCTAssertEqual(openedURLs.map(\.lastPathComponent), ["TokenMon-1.6.0.pkg"])
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "nothing is downloaded in-app")
        XCTAssertFalse(checker.isInstalling)
    }

    /// Without the asset digest the zip cannot be verified, so it is not installed.
    func testMissingDigestOpensReleasePageInsteadOfInstalling() async throws {
        respond(status: 200, body: Self.releaseWithAssets)
        let checker = try makeChecker(installedAppURL: makeInstalledApp(writable: true))
        await checker.checkNow()
        await checker.installAvailableUpdate()
        XCTAssertEqual(openedURLs.map(\.lastPathComponent), ["v1.6.0"])
        XCTAssertEqual(checker.statusMessage, "The release has no checksum to verify — opening the release page.")
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "the zip is never requested")
    }
}
