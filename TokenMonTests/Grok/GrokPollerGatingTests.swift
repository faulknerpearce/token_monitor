@testable import TokenMon
import XCTest

/// Grok poller gating and error surfacing: a disabled provider never fetches,
/// the loop parks while Grok is not needed, cancellation is not a failure, and
/// a failure after a good snapshot still reports its error.
@MainActor
final class GrokPollerGatingTests: XCTestCase {
    private var dir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "GrokGating-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makePoller(
        settings: AppSettings,
        fetch: @escaping (String?, String?) async throws -> WeeklyUsageSnapshot
    ) -> (UsagePoller, AuthSessionService) {
        let auth = AuthSessionService(directory: dir)
        auth.save(cookieHeader: "sso=live")
        let poller = UsagePoller(
            auth: auth,
            history: HistoryStore(inMemory: true),
            settings: settings,
            notifier: ThresholdNotifier(defaults: defaults, deliver: { _, _ in }),
            grokHourly: HourlyDeltaActivityStore(
                store: FileBackedStringStore(directory: dir, filenamePrefix: "hourly_"),
                storageKey: "grok"
            ),
            fetchUsage: fetch
        )
        return (poller, auth)
    }

    func testDisabledGrokNeverFetchesEvenWhenSignedIn() async {
        let settings = AppSettings(defaults: defaults)
        settings.enabledProviderIDs = [.cursor]
        var fetches = 0
        let (poller, _) = makePoller(settings: settings) { _, _ in
            fetches += 1
            return WeeklyUsageSnapshot(usedPercent: 10, remainingPercent: 90)
        }
        await poller.refreshNow()
        XCTAssertEqual(fetches, 0)
        XCTAssertNil(poller.pollingLoop.delayUntilDue(), "a disabled provider parks its loop")
    }

    func testLoopParksWhileGrokIsNotNeeded() {
        let settings = AppSettings(defaults: defaults)
        settings.selectedProvider = .cursor
        settings.showGrokBarInMenuBar = false
        settings.thresholdEnabled = false
        let (poller, _) = makePoller(settings: settings) { _, _ in
            WeeklyUsageSnapshot(usedPercent: 10, remainingPercent: 90)
        }
        XCTAssertNil(poller.pollingLoop.delayUntilDue())
        settings.showGrokBarInMenuBar = true
        XCTAssertEqual(poller.pollingLoop.delayUntilDue(), 0)
    }

    func testCancellationIsNotReportedAsAFailure() async {
        let settings = AppSettings(defaults: defaults)
        settings.selectedProvider = .grok
        let (poller, auth) = makePoller(settings: settings) { _, _ in throw CancellationError() }
        await poller.refreshNow()
        XCTAssertNil(poller.lastError)
        XCTAssertFalse(auth.needsSignIn)
    }

    func testFailureAfterASnapshotStillReportsTheError() async {
        let settings = AppSettings(defaults: defaults)
        settings.selectedProvider = .grok
        var fail = false
        let (poller, _) = makePoller(settings: settings) { _, _ in
            if fail { throw ProviderError.network(.grok, "offline") }
            return WeeklyUsageSnapshot(usedPercent: 10, remainingPercent: 90)
        }
        await poller.refreshNow()
        XCTAssertNotNil(poller.snapshot)
        fail = true
        await poller.refreshNow()
        XCTAssertNotNil(poller.snapshot, "stale data stays visible")
        XCTAssertEqual(poller.lastError, "Grok network error: offline")
    }

    /// A manual refresh (e.g. right after signing in from Settings) loads data
    /// for an enabled provider even when its tab is not selected.
    func testManualRefreshFetchesWhenEnabledButNotShown() async {
        let settings = AppSettings(defaults: defaults)
        settings.selectedProvider = .cursor
        settings.showGrokBarInMenuBar = false
        var fetches = 0
        let (poller, _) = makePoller(settings: settings) { _, _ in
            fetches += 1
            return WeeklyUsageSnapshot(usedPercent: 10, remainingPercent: 90)
        }
        await poller.refreshNow()
        XCTAssertEqual(fetches, 1)
        XCTAssertNotNil(poller.snapshot)
    }
}
