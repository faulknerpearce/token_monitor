@testable import TokenMon
import XCTest

/// Serves canned responses per URL path; no request leaves the process.
private final class GrokStubProtocol: URLProtocol {
    typealias Reply = (status: Int, headers: [String: String], body: Data)

    private static let lock = NSLock()
    private static var replies: [String: Reply] = [:]
    private static var paths: [String] = []

    static func reset(_ replies: [String: Reply]) {
        lock.lock()
        defer { lock.unlock() }
        self.replies = replies
        paths = []
    }

    static var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.paths.append(url.path)
        let reply = Self.replies[url.path] ?? (404, [:], Data())
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class UsageClientTests: XCTestCase {
    private let billingPath = UsageClient.billingEndpoint.path
    private let grpcHex = "000000005f0a5d0d0000104212001a00220b08b1debfd20610b8efb07f2a0b08b1d3e4d20610b8efb07f" +
        "3a070804150000b8413a07080215000050413a020806421c0802120b08b1debfd20610b8efb07f1a0b08b1d3e4d20610b8efb07f" +
        "580162006801800000000f677270632d7374617475733a300d0a"

    private func client() -> UsageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokStubProtocol.self]
        return UsageClient(cookieHeader: "sso=x", accountEmail: nil, session: URLSession(configuration: configuration))
    }

    /// A fetch cancelled mid-request surfaces as `CancellationError`.
    func testCancelledFetchThrowsCancellationError() async {
        let client = UsageClient(cookieHeader: "sso=x", accountEmail: nil, session: NeverRespondingURLProtocol.session())
        let task = Task { try await client.fetchUsage() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    override func tearDown() {
        GrokStubProtocol.reset([:])
        super.tearDown()
    }

    private var restPaths: [String] {
        UsageClient.restCandidates.map(\.path)
    }

    /// gRPC billing answers first; the guessed REST paths are never requested.
    func testBillingSuccessSkipsRESTProbes() async throws {
        let body = try XCTUnwrap(Data(hexString: grpcHex))
        GrokStubProtocol.reset([billingPath: (200, ["Content-Type": "application/grpc-web+proto"], body)])

        let snapshot = try await client().fetchUsage()

        XCTAssertEqual(snapshot.usedPercent, 36, accuracy: 0.01)
        XCTAssertEqual(GrokStubProtocol.requestedPaths, [billingPath])
    }

    func testBillingUnauthorizedRejectsWithoutProbing() async {
        GrokStubProtocol.reset([billingPath: (401, [:], Data())])

        do {
            _ = try await client().fetchUsage()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? ProviderError)?.usageError, .unauthorized)
        }
        XCTAssertEqual(GrokStubProtocol.requestedPaths, [billingPath])
    }

    /// A trailers-only UNAUTHENTICATED reply (status in the HTTP headers, empty
    /// body) is a rejected session, not an empty response.
    func testTrailersOnlyUnauthenticatedIsUnauthorized() async {
        GrokStubProtocol.reset([billingPath: (200, ["grpc-status": "16", "grpc-message": "unauthenticated"], Data())])

        do {
            _ = try await client().fetchUsage()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? ProviderError)?.usageError, .unauthorized)
        }
    }

    /// A Cloudflare 403 page on billing is transient.
    func testBillingChallengeIsTransient() async {
        let html = Data("<html><title>Just a moment...</title></html>".utf8)
        GrokStubProtocol.reset([billingPath: (403, ["Content-Type": "text/html"], html)])

        do {
            _ = try await client().fetchUsage()
            XCTFail("expected an error")
        } catch {
            XCTAssertNotEqual((error as? ProviderError)?.usageError, .unauthorized)
        }
    }

    /// A REST 401 while billing is down never signs the user out.
    func testRESTProbeRejectionNeverInvalidates() async {
        var replies: [String: GrokStubProtocol.Reply] = [billingPath: (500, [:], Data())]
        for path in restPaths {
            replies[path] = (401, [:], Data())
        }
        GrokStubProtocol.reset(replies)

        do {
            _ = try await client().fetchUsage()
            XCTFail("expected an error")
        } catch {
            XCTAssertNotEqual((error as? ProviderError)?.usageError, .unauthorized)
        }
        XCTAssertEqual(GrokStubProtocol.requestedPaths, [billingPath] + restPaths)
    }

    func testRESTProbeSuppliesUsageWhenBillingFails() async throws {
        GrokStubProtocol.reset([
            billingPath: (503, [:], Data()),
            restPaths[2]: (200, ["Content-Type": "application/json"], Data(#"{"usage":{"usedPercent":42}}"#.utf8))
        ])

        let snapshot = try await client().fetchUsage()

        XCTAssertEqual(snapshot.usedPercent, 42, accuracy: 0.01)
    }

    // MARK: - REST JSON strictness

    /// An unrelated 200 with a bare `percent` is not usage.
    func testUnrelatedPercentKeyIsNotUsage() {
        let json = Data(#"{"data":{"percent":50,"name":"profile completion"}}"#.utf8)
        XCTAssertNil(UsageResponseParser.parseJSON(json, accountEmail: nil))
    }

    func testOutOfRangeUsageIsRejected() {
        XCTAssertNil(UsageResponseParser.parseJSON(Data(#"{"usedPercent":1500}"#.utf8), accountEmail: nil))
        XCTAssertNil(UsageResponseParser.parseJSON(Data(#"{"usedPercent":-3}"#.utf8), accountEmail: nil))
    }

    /// Product rows count only with a usage-specific percent key.
    func testProductsWithoutUsageKeysAreIgnored() {
        let json = Data(#"{"products":[{"id":"chat","value":30},{"id":"build","percent":20}]}"#.utf8)
        XCTAssertNil(UsageResponseParser.parseJSON(json, accountEmail: nil))
    }
}
