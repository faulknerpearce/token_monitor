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
}
