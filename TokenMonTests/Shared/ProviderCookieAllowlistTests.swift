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

    func testOpenCodePolicyKeepsAuthCookieOnly() {
        let cookies = [
            cookie("auth", value: "tok", domain: "opencode.ai"),
            cookie("_ga", value: "tracker", domain: "opencode.ai")
        ]
        XCTAssertEqual(
            selectedNames(cookies, policy: OpenCodeAuthSession.openCodePolicy()),
            ["auth"]
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

    /// Grok sign-in can leave an X/Twitter session in the same WebKit store;
    /// only the grok.com session cookie may be persisted.
    func testGrokPolicyDropsXSessionCookies() {
        let cookies = [
            cookie("sso", value: "grok-session", domain: "grok.com"),
            cookie("auth_token", value: "x-session", domain: "x.com"),
            cookie("ct0", value: "x-csrf", domain: "x.com"),
            cookie("_ga", value: "tracker", domain: "grok.com")
        ]
        XCTAssertEqual(
            selectedNames(cookies, policy: AuthSessionService.grokPolicy()),
            ["sso"]
        )
    }

    /// The OpenAI jar carries analytics and device cookies; only the next-auth
    /// session cookie is needed for the usage token exchange.
    func testChatGPTPolicyStoresOnlyTheSessionCookie() {
        let cookies = [
            cookie("__Secure-next-auth.session-token", value: "sess", domain: "chatgpt.com"),
            cookie("_ga", value: "tracker", domain: "chatgpt.com"),
            cookie("oai-did", value: "device", domain: "chatgpt.com")
        ]
        XCTAssertEqual(
            selectedNames(cookies, policy: ChatGPTAuthSession.chatgptPolicy()),
            ["__Secure-next-auth.session-token"]
        )
    }
}
