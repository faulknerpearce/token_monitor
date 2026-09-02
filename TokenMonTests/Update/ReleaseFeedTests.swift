@testable import TokenMon
import XCTest

final class ReleaseFeedTests: XCTestCase {
    private let current = AppVersion("1.4.2")!

    private func parse(_ json: String, than version: AppVersion? = nil) throws -> AvailableRelease? {
        try ReleaseFeed.newerRelease(in: Data(json.utf8), than: version ?? current)
    }

    func testReportsNewerRelease() throws {
        let release = try parse("""
        {
          "tag_name": "v1.5.0",
          "html_url": "https://github.com/faulknerpearce/token_monitor/releases/tag/v1.5.0",
          "published_at": "2026-09-01T10:00:00Z",
          "draft": false,
          "prerelease": false
        }
        """)
        XCTAssertEqual(release?.version.description, "1.5.0")
        XCTAssertEqual(release?.pageURL.absoluteString.hasSuffix("v1.5.0"), true)
        XCTAssertNotNil(release?.publishedAt)
    }

    func testSameVersionIsNotAnUpdate() throws {
        XCTAssertNil(try parse(#"{"tag_name":"1.4.2"}"#))
    }

    func testOlderVersionIsNotAnUpdate() throws {
        XCTAssertNil(try parse(#"{"tag_name":"1.4.1"}"#))
    }

    /// A menu-bar app should not nudge people onto an unfinished build.
    func testDraftsAndPrereleasesAreIgnored() throws {
        XCTAssertNil(try parse(#"{"tag_name":"9.9.9","draft":true}"#))
        XCTAssertNil(try parse(#"{"tag_name":"9.9.9","prerelease":true}"#))
        XCTAssertNil(try parse(#"{"tag_name":"9.9.9-beta.1"}"#))
    }

    /// Falls back to the repository's releases page when the payload omits one.
    func testMissingPageURLFallsBackToReleasesPage() throws {
        let release = try parse(#"{"tag_name":"2.0.0"}"#)
        XCTAssertEqual(
            release?.pageURL.absoluteString,
            "https://github.com/faulknerpearce/token_monitor/releases/latest"
        )
    }

    /// An unusable tag is an error, not a silent "no update" — the check should
    /// surface that something changed upstream.
    func testUnparseableTagThrows() {
        XCTAssertThrowsError(try parse(#"{"tag_name":"nightly"}"#))
        XCTAssertThrowsError(try parse("not json at all"))
    }
}
