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
