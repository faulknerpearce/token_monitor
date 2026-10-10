@testable import TokenMon
import XCTest

final class OpenRouterUsageClientTests: XCTestCase {
    func testEndpointURLsResolveUnderAPIVersionPath() {
        XCTAssertEqual(OpenRouterUsageClient.url(for: .key)?.absoluteString, "https://openrouter.ai/api/v1/key")
        XCTAssertEqual(OpenRouterUsageClient.url(for: .credits)?.absoluteString, "https://openrouter.ai/api/v1/credits")
        XCTAssertEqual(OpenRouterUsageClient.url(for: .activity)?.absoluteString, "https://openrouter.ai/api/v1/activity")
    }

    func testResolveTreatsBaseWithoutTrailingSlashAsDirectory() throws {
        let base = try XCTUnwrap(URL(string: "https://example.com/api/v1"))
        XCTAssertEqual(ProviderHTTP.resolve("key", baseURL: base)?.absoluteString, "https://example.com/api/v1/key")
        let slashed = try XCTUnwrap(URL(string: "https://example.com/api/v1/"))
        XCTAssertEqual(ProviderHTTP.resolve("key", baseURL: slashed)?.absoluteString, "https://example.com/api/v1/key")
    }

    func testResolveKeepsRootRelativeAndHostOnlyPaths() throws {
        let host = try XCTUnwrap(URL(string: "https://claude.ai"))
        XCTAssertEqual(
            ProviderHTTP.resolve("/api/organizations/x/usage", baseURL: host)?.absoluteString,
            "https://claude.ai/api/organizations/x/usage"
        )
        XCTAssertEqual(
            ProviderHTTP.resolve("api/auth/session", baseURL: host)?.absoluteString,
            "https://claude.ai/api/auth/session"
        )
        let nested = try XCTUnwrap(URL(string: "https://example.com/api/v1"))
        XCTAssertEqual(ProviderHTTP.resolve("/root", baseURL: nested)?.absoluteString, "https://example.com/root")
    }

    func testNonManagementKeySkipsAccountEndpoints() async throws {
        let recorder = EndpointRecorder()
        let client = OpenRouterUsageClient { endpoint in
            await recorder.record(endpoint)
            return Self.keyBody(isManagement: false)
        }
        let snapshot = try await client.fetchSnapshot()
        let requested = await recorder.endpoints
        XCTAssertEqual(requested, [.key])
        XCTAssertFalse(snapshot.isManagementKey)
        XCTAssertEqual(snapshot.budgetSource, .keyLimit)
    }

    func testManagementKeyFetchesCreditsAndActivity() async throws {
        let recorder = EndpointRecorder()
        let client = OpenRouterUsageClient { endpoint in
            await recorder.record(endpoint)
            switch endpoint {
            case .key: return Self.keyBody(isManagement: true)
            case .credits: return Data(#"{"data":{"total_credits":40,"total_usage":10}}"#.utf8)
            case .activity: return Data(#"{"data":[]}"#.utf8)
            }
        }
        let snapshot = try await client.fetchSnapshot()
        let requested = await recorder.endpoints
        XCTAssertEqual(Set(requested), Set(OpenRouterUsageClient.Endpoint.allCases))
        XCTAssertEqual(snapshot.budgetSource, .accountCredits)
        XCTAssertEqual(snapshot.budgetUSD ?? -1, 40, accuracy: 0.001)
    }

    func testAccountEndpointFailureDegradesToKeyLimit() async throws {
        let client = OpenRouterUsageClient { endpoint in
            guard endpoint == .key else { throw ProviderError.unauthorized(.openRouter) }
            return Self.keyBody(isManagement: true)
        }
        let snapshot = try await client.fetchSnapshot()
        XCTAssertEqual(snapshot.budgetSource, .keyLimit)
        XCTAssertTrue(snapshot.models.isEmpty)
    }

    private static func keyBody(isManagement: Bool) -> Data {
        Data("""
        {"data":{"usage":5,"limit":20,"is_management_key":\(isManagement)}}
        """.utf8)
    }
}

private actor EndpointRecorder {
    private(set) var endpoints: [OpenRouterUsageClient.Endpoint] = []

    func record(_ endpoint: OpenRouterUsageClient.Endpoint) {
        endpoints.append(endpoint)
    }
}
