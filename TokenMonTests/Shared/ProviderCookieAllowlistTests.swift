@testable import TokenMon
import XCTest

/// Exercises the *real* provider capture allowlists rather than a synthetic
/// policy.
@MainActor
final class ProviderCookieAllowlistTests: XCTestCase {
    private func cookie(_ name: String, value: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: domain,
            .path: "/",
            .name: name,
            .value: value
        ])!
    }

    private func selectedNames(_ cookies: [HTTPCookie], policy: WebKitCookieCapture.Policy) -> Set<String> {
        Set(WebKitCookieCapture.select(from: cookies, policy: policy)?.map(\.name) ?? [])
    }

    func testCursorPolicyStoresOnlyTheSessionToken() {
        let cookies = [
            cookie("WorkosCursorSessionToken", value: "sess", domain: "cursor.com"),
            cookie("_ga", value: "tracker", domain: "cursor.com"),
            cookie("featureFlags", value: "a,b", domain: "cursor.com")
        ]
        XCTAssertEqual(
            selectedNames(cookies, policy: CursorAuthSession.cursorPolicy()),
            ["WorkosCursorSessionToken"]
        )
    }

    func testClaudePolicyKeepsSessionKeyAndOrg() {
        let cookies = [
            cookie("sessionKey", value: "sess", domain: "claude.ai"),
            cookie("lastActiveOrg", value: "org-uuid", domain: "claude.ai"),
            cookie("__cf_bm", value: "bot", domain: "claude.ai")
        ]
        XCTAssertEqual(
            selectedNames(cookies, policy: ClaudeAuthSession.claudePolicy()),
            ["sessionKey", "lastActiveOrg"]
        )
    }

    /// The console usage request sends `auth` and `provider`; both must be kept
    /// while unrelated analytics cookies are dropped.
    func testOpenCodePolicyKeepsAuthAndProviderCookies() {
        let cookies = [
            cookie("auth", value: "tok", domain: "opencode.ai"),
            cookie("provider", value: "wrk_abc", domain: "opencode.ai"),
            cookie("_ga", value: "tracker", domain: "opencode.ai")
        ]
        XCTAssertEqual(
            selectedNames(cookies, policy: OpenCodeAuthSession.openCodePolicy()),
            ["auth", "provider"]
        )
    }

    func testForeignDomainCookiesAreIgnored() {
        let cookies = [
            cookie("WorkosCursorSessionToken", value: "sess", domain: "cursor.com"),
            cookie("WorkosCursorSessionToken", value: "evil", domain: "evil.test")
        ]
        let chosen = WebKitCookieCapture.select(from: cookies, policy: CursorAuthSession.cursorPolicy())
        XCTAssertEqual(chosen?.map(\.value), ["sess"])
    }
}
