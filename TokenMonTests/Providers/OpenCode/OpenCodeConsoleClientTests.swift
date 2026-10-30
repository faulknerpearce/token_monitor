@testable import TokenMon
import XCTest

final class OpenCodeConsoleClientTests: XCTestCase {
    /// Captured console `/console/api/go/status` payload (values scaled for tests).
    private let goStatusJSON = """
    {"subscriberUserId":"acc_01KPBCG0RDD1NQBY7W03AVM6BV","useBalance":false,
     "access":{"startsAt":"2026-09-16T15:48:10.000Z","endsAt":"2026-10-16T15:48:10.000Z",
     "meters":{
       "fiveHour":{"startsAt":"2026-09-17T14:22:56.310Z","resetsAt":"2026-09-17T19:22:56.310Z","limitMicroCents":"1200000000","usedMicroCents":"16726299"},
       "week":{"startsAt":"2026-09-14T00:00:00.000Z","resetsAt":"2026-09-21T00:00:00.000Z","limitMicroCents":"3000000000","usedMicroCents":"359502844"},
       "month":{"limitMicroCents":"6000000000","usedMicroCents":"359502844"}}}}
    """

    func testParseGoMeters() throws {
        let meters = try OpenCodeConsoleClient.parseGoMeters(Data(goStatusJSON.utf8))
        XCTAssertTrue(meters.hasAny)
        XCTAssertEqual(try XCTUnwrap(meters.fiveHour?.limitUSD), 12, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(meters.fiveHour).usedUSD, 0.16726299, accuracy: 1e-9)
        XCTAssertNotNil(meters.fiveHour?.resetsAt)
        XCTAssertEqual(try XCTUnwrap(meters.week?.limitUSD), 30, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(meters.week).usedUSD, 3.59502844, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(meters.month?.limitUSD), 60, accuracy: 1e-9)
        XCTAssertNotNil(meters.monthResetsAt)
    }

    func testSnapshotPercentagesAndMonthlyResetFallback() throws {
        let meters = try OpenCodeConsoleClient.parseGoMeters(Data(goStatusJSON.utf8))
        let snapshot = OpenCodeConsoleClient.snapshot(from: meters, now: Date())
        XCTAssertEqual(snapshot.windows.map(\.kind), [.rolling5h, .weekly, .monthly])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 1.393858, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 11.983428, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[2].usedPercent, 5.991714, accuracy: 0.001)
        // The month meter has no reset of its own; the subscription end stands in.
        XCTAssertEqual(snapshot.windows[2].resetsAt, meters.monthResetsAt)
        XCTAssertEqual(snapshot.monthlyUsedPercent, snapshot.windows[2].usedPercent, accuracy: 1e-9)
    }

    func testParseGoMetersWithoutSubscriptionIsEmpty() throws {
        XCTAssertFalse(try OpenCodeConsoleClient.parseGoMeters(Data(#"{"access":null}"#.utf8)).hasAny)
        XCTAssertFalse(try OpenCodeConsoleClient.parseGoMeters(Data("{}".utf8)).hasAny)
    }

    func testParseOrgs() throws {
        let body = #"[{"id":"wrk_01KTEST123","name":"Austin"},{"name":"no id"}]"#
        XCTAssertEqual(try OpenCodeConsoleClient.parseOrgs(Data(body.utf8)), ["wrk_01KTEST123"])
    }

    func testParseSessionEmail() {
        let body = #"{"expiresAt":"2026-10-17T14:40:57.000Z","user":{"id":"acc_1","email":"a@b.com"}}"#
        XCTAssertEqual(OpenCodeConsoleClient.parseSessionEmail(Data(body.utf8)), "a@b.com")
        XCTAssertNil(OpenCodeConsoleClient.parseSessionEmail(Data("{}".utf8)))
    }

    func testMicroCentsToUSD() throws {
        XCTAssertEqual(try XCTUnwrap(OpenCodeConsoleClient.usd("3000000000")), 30, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(OpenCodeConsoleClient.usd(600_000_000)), 6, accuracy: 1e-9)
        XCTAssertNil(OpenCodeConsoleClient.usd(nil))
    }

    func testWorkspaceIDFromURL() {
        let console = URL(string: "https://opencode.ai/console/wrk_01KTEST123")!
        XCTAssertEqual(OpenCodeConsoleClient.workspaceID(from: console), "wrk_01KTEST123")
        let workspace = URL(string: "https://opencode.ai/workspace/wrk_01KTEST123/go")!
        XCTAssertEqual(OpenCodeConsoleClient.workspaceID(from: workspace), "wrk_01KTEST123")
        XCTAssertNil(OpenCodeConsoleClient.workspaceID(from: URL(string: "https://opencode.ai/auth")!))
    }

    /// An expired console session redirects to a login page rather than 401.
    func testLoginRedirectRecognizesConsoleLoginPages() {
        XCTAssertTrue(
            OpenCodeConsoleClient.isLoginRedirect(URL(string: "https://opencode.ai/console/login")!)
        )
        XCTAssertTrue(
            OpenCodeConsoleClient.isLoginRedirect(URL(string: "https://opencode.ai/auth/authorize")!)
        )
        XCTAssertTrue(
            OpenCodeConsoleClient.isLoginRedirect(URL(string: "https://opencode.ai/auth/login")!)
        )
        XCTAssertFalse(
            OpenCodeConsoleClient.isLoginRedirect(
                URL(string: "https://opencode.ai/console/wrk_01KTEST123")!
            )
        )
    }
}

/// Workspace selection and error mapping for the console client.
final class OpenCodeConsoleWorkspaceTests: XCTestCase {
    private static let seated = Data(#"{"access": {"meters": {"month": {"limitMicroCents": 6000000000, "usedMicroCents": 600000000}}}}"#.utf8)
    private static let unseated = Data(#"{"access": {}}"#.utf8)

    func testPreferredWorkspaceWithSeatIsUsedWithoutListing() async throws {
        let recorder = PathRecorder()
        let client = OpenCodeConsoleClient { path, orgID in
            await recorder.record(path, orgID)
            return Self.seated
        }
        let (_, org) = try await client.fetchGoUsageSnapshot(knownOrgID: "wrk_redirect")
        XCTAssertEqual(org, "wrk_redirect")
        let paths = await recorder.paths
        XCTAssertFalse(paths.contains("/console/api/orgs"))
    }

    func testOtherWorkspacesAreTriedForAGoSeat() async throws {
        let client = OpenCodeConsoleClient { path, orgID in
            if path == "/console/api/orgs" {
                return Data(#"[{"id": "wrk_first"}, {"id": "wrk_redirect"}, {"id": "wrk_go"}]"#.utf8)
            }
            return orgID == "wrk_go" ? Self.seated : Self.unseated
        }
        let (snap, org) = try await client.fetchGoUsageSnapshot(knownOrgID: "wrk_redirect")
        XCTAssertEqual(org, "wrk_go")
        XCTAssertEqual(snap.monthlyUsedPercent, 10, accuracy: 0.001)
    }

    func testForbiddenEverywhereReportsDeniedWorkspace() async {
        let client = OpenCodeConsoleClient { path, _ in
            if path == "/console/api/orgs" { return Data(#"[{"id": "wrk_a"}]"#.utf8) }
            throw OpenCodeConsoleError.orgForbidden
        }
        do {
            _ = try await client.fetchGoUsageSnapshot(knownOrgID: "wrk_a")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .badResponse(.openCode, "The OpenCode console denied access to this workspace."))
        }
    }

    func testResolveOrgIDKeepsPreferredWorkspace() async throws {
        let client = OpenCodeConsoleClient { _, _ in Data(#"[{"id": "wrk_first"}]"#.utf8) }
        let preferred = try await client.resolveOrgID(preferred: "wrk_redirect")
        XCTAssertEqual(preferred, "wrk_redirect")
        let listed = try await client.resolveOrgID(preferred: nil)
        XCTAssertEqual(listed, "wrk_first")
    }

    func testServerErrorMessageCarriesNoBodyBytes() throws {
        let url = try XCTUnwrap(URL(string: "https://opencode.ai/console/api/go/status"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil))
        XCTAssertThrowsError(try OpenCodeConsoleClient.check(response, data: Data("secret-token".utf8), orgID: nil)) { error in
            XCTAssertEqual(error as? ProviderError, .badResponse(.openCode, "HTTP 500"))
        }
    }
}

private actor PathRecorder {
    private(set) var paths: [String] = []

    func record(_ path: String, _: String?) {
        paths.append(path)
    }
}
