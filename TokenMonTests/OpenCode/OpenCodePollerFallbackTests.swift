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

    /// An expired console session still publishes the local estimate in the
    /// same poll, labelled as such.
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
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertEqual(poller.snapshot?.isEstimated, true)
        XCTAssertEqual(poller.dataSourceLabel, "Local estimate")
        XCTAssertEqual(
            poller.lastError,
            "Console session expired — showing local estimate. Sign in again for official numbers."
        )
    }
}
