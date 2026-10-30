@testable import TokenMon
import XCTest

/// AppModel polling wiring under the test host (pollers never start, files and
/// defaults are isolated): menu-open state reaches every poller.
@MainActor
final class AppModelPollingTests: XCTestCase {
    func testMenuOpenStateReachesEveryPoller() {
        let model = AppModel()
        model.setMenuOpen(true)
        XCTAssertTrue(model.providers.all.allSatisfy(\.poller.menuIsOpen))
        model.setMenuOpen(false)
        XCTAssertTrue(model.providers.all.allSatisfy { !$0.poller.menuIsOpen })
    }

    /// Grokbot signs in with Cursor's session, so a Cursor sign-in refreshes
    /// both; every other provider has its own session.
    func testSessionSharingFollowsTheRegistry() {
        let model = AppModel()
        XCTAssertEqual(model.providers.pollers(sharingSessionWith: .cursor).count, 2)
        XCTAssertEqual(model.providers.pollers(sharingSessionWith: .grokbot).count, 2)
        XCTAssertEqual(model.providers.pollers(sharingSessionWith: .claude).count, 1)
        XCTAssertEqual(model.providers.sessions.count, MonitorProvider.usageProviders.count - 1)
    }
}
