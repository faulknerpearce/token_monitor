@testable import TokenMon
import XCTest

final class AppVersionTests: XCTestCase {
    func testParsesPlainAndTaggedVersions() {
        XCTAssertEqual(AppVersion("1.4.2")?.description, "1.4.2")
        XCTAssertEqual(AppVersion("v1.4.2")?.description, "1.4.2")
        XCTAssertEqual(AppVersion("V2.0")?.description, "2.0")
    }

    func testRejectsUnparseableTags() {
        XCTAssertNil(AppVersion("nightly"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1.x.2"))
    }

    /// String comparison would put 1.10.0 below 1.9.0 — the whole reason this
    /// type exists.
    func testComparesNumericallyNotLexically() {
        XCTAssertTrue(AppVersion("1.10.0")! > AppVersion("1.9.0")!)
        XCTAssertTrue(AppVersion("1.4.2")! < AppVersion("1.4.10")!)
        XCTAssertTrue(AppVersion("2.0.0")! > AppVersion("1.99.99")!)
    }

    /// Missing trailing components are zero, so 1.4 and 1.4.0 are the same release.
    func testShorterVersionsPadWithZero() {
        XCTAssertEqual(AppVersion("1.4")!, AppVersion("1.4.0")!)
        XCTAssertTrue(AppVersion("1.4")! < AppVersion("1.4.1")!)
    }

    func testPrereleaseSortsBelowItsFinalRelease() {
        XCTAssertTrue(AppVersion("1.5.0-beta.1")! < AppVersion("1.5.0")!)
        XCTAssertTrue(AppVersion("1.5.0-beta.1")!.isPrerelease)
        XCTAssertFalse(AppVersion("1.5.0")!.isPrerelease)
    }
}
