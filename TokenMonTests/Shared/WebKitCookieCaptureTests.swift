@testable import TokenMon
import XCTest

/// Pure email extraction from captured cookies.
final class WebKitCookieCaptureTests: XCTestCase {
    private func cookie(name: String, value: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: "example.com",
            .path: "/",
            .name: name,
            .value: value
        ])!
    }

    private func cookie(name: String, value: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: domain,
            .path: "/",
            .name: name,
            .value: value
        ])!
    }

    /// Allowlisted policy standing in for Cursor: one session cookie matters.
    private func narrowPolicy(essential: Set<String>) -> WebKitCookieCapture.Policy {
        WebKitCookieCapture.Policy(
            isDomain: { $0.contains("example.com") },
            isPreferredSessionCookie: { $0.name.lowercased() == "sessiontoken" },
            looksLikeAuthCookie: { $0.name.lowercased().contains("auth") },
            includeAllDomainCookiesWhenSessionFound: true,
            essentialCookieNames: essential,
            failureMessage: "none"
        )
    }

    private let jar = [
        "sessionToken": "secret",
        "orgId": "org_123",
        "_ga": "GA1.2.analytics",
        "intercom-session": "tracking",
        "featureFlags": "a,b,c"
    ]

    private var allCookies: [HTTPCookie] {
        jar.map { cookie(name: $0.key, value: $0.value, domain: "example.com") }
    }

    /// Only the allowlisted cookies reach disk — the analytics and flag cookies
    /// in the same jar are dropped.
    func testEssentialNamesNarrowWhatIsStored() {
        let chosen = WebKitCookieCapture.select(
            from: allCookies,
            policy: narrowPolicy(essential: ["sessiontoken", "orgid"])
        )
        XCTAssertEqual(Set(chosen?.map(\.name) ?? []), ["sessionToken", "orgId"])
    }

    /// An allowlist that misses the session cookie must not persist a useless
    /// subset — it falls back to the previous broad capture.
    func testAllowlistWithoutSessionCookieFallsBackToFullJar() {
        let chosen = WebKitCookieCapture.select(
            from: allCookies,
            policy: narrowPolicy(essential: ["orgid"])
        )
        XCTAssertEqual(chosen?.count, jar.count)
    }

    /// Empty allowlist keeps the pre-existing behaviour untouched.
    func testEmptyAllowlistKeepsBroadCapture() {
        let chosen = WebKitCookieCapture.select(
            from: allCookies,
            policy: narrowPolicy(essential: [])
        )
        XCTAssertEqual(chosen?.count, jar.count)
    }

    /// Cookies from other domains are never considered.
    func testOtherDomainCookiesAreIgnored() {
        let foreign = cookie(name: "sessionToken", value: "other", domain: "evil.test")
        let chosen = WebKitCookieCapture.select(
            from: allCookies + [foreign],
            policy: narrowPolicy(essential: ["sessiontoken"])
        )
        XCTAssertEqual(chosen?.map(\.value), ["secret"])
    }

    func testExtractsEmailNamedCookie() {
        let cookies = [cookie(name: "email", value: "dev%40example.com")]
        XCTAssertEqual(WebKitCookieCapture.extractEmail(from: cookies), "dev@example.com")
    }

    func testExtractsUserEmailNamedCookie() {
        let cookies = [cookie(name: "user_email", value: "someone@example.org")]
        XCTAssertEqual(WebKitCookieCapture.extractEmail(from: cookies), "someone@example.org")
    }

    func testFallsBackToShortValueContainingAt() {
        let cookies = [cookie(name: "track", value: "fallback@example.io")]
        XCTAssertEqual(WebKitCookieCapture.extractEmail(from: cookies), "fallback@example.io")
    }

    func testIgnoresLongValuesWithSpaces() {
        let cookies = [cookie(name: "session", value: "a b c d e f g h i j k l m n o p q r s t u v w x y z @ long token value here padding padding")]
        XCTAssertNil(WebKitCookieCapture.extractEmail(from: cookies))
    }

    func testReturnsNilWithoutEmailLikeCookies() {
        let cookies = [cookie(name: "theme", value: "dark")]
        XCTAssertNil(WebKitCookieCapture.extractEmail(from: cookies))
    }

    func testPrefersExplicitEmailCookieOverFallback() {
        let cookies = [
            cookie(name: "track", value: "fallback@example.com"),
            cookie(name: "email", value: "primary@example.com")
        ]
        XCTAssertEqual(WebKitCookieCapture.extractEmail(from: cookies), "primary@example.com")
    }
}
