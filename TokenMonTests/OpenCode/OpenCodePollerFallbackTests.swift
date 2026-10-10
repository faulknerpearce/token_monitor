@testable import TokenMon
import XCTest

@MainActor
final class OpenCodePollerFallbackTests: XCTestCase {
    private var dir: URL!
    private var suiteName: String!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "OpenCodeFallback-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    /// Each rejected console poll still publishes the local estimate. The
    /// session is invalidated on the third consecutive rejection, and that poll
    /// labels the estimate as coming from an expired session.
    func testExpiredConsoleSessionFallsBackToLocalEstimate() async throws {
        let settings = try AppSettings(defaults: XCTUnwrap(UserDefaults(suiteName: suiteName)))
        settings.selectedProvider = .opencode
        let auth = OpenCodeAuthSession(directory: dir)
        auth.save(cookieHeader: "auth=live")
        let local = OpenCodeSnapshot(windows: [], models: [], isEstimated: true)
        let poller = OpenCodeUsagePoller(
            settings: settings,
            auth: auth,
            fetchConsole: { _, _ in throw ProviderError.unauthorized(.openCode) },
            fetchLocal: { (local, nil) }
        )
        await poller.refreshNow()
        XCTAssertFalse(auth.needsSignIn)
        XCTAssertEqual(poller.snapshot?.isEstimated, true)
        XCTAssertEqual(poller.lastError, "Console fetch failed — showing local estimate.")

        await poller.refreshNow()
        await poller.refreshNow()
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertEqual(poller.snapshot?.isEstimated, true)
        XCTAssertEqual(poller.dataSourceLabel, "Local estimate")
        XCTAssertEqual(
            poller.lastError,
            "Console session expired — showing local estimate. Sign in again for official numbers."
        )
    }
}
