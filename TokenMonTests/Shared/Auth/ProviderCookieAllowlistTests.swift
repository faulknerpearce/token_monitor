@testable import TokenMon
import XCTest

/// Exercises the *real* provider capture allowlists.
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

    /// The console API sends the console session (`__Host-console_session`) plus
    /// the site cookies; all are kept and analytics cookies are dropped.
    func testOpenCodePolicyKeepsConsoleAndSiteCookies() {
        let cookies = [
            cookie("__Host-console_session", value: "console", domain: "opencode.ai"),
            cookie("auth", value: "tok", domain: "opencode.ai"),
            cookie("provider", value: "wrk_abc", domain: "opencode.ai"),
            cookie("_ga", value: "tracker", domain: "opencode.ai")
        ]
        XCTAssertEqual(
            selectedNames(cookies, policy: OpenCodeAuthSession.openCodePolicy()),
            ["__Host-console_session", "auth", "provider"]
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

    /// NextAuth chunks a large session JWT into `…session-token.0`, `.1`, …. The
    /// whole family is captured, and the CSRF cookie that shares the sign-in
    /// page is not taken for the session.
    func testChatGPTPolicyKeepsChunkedSessionAndDropsCSRF() {
        let cookies = [
            cookie("__Host-next-auth.csrf-token", value: "csrf", domain: "chatgpt.com"),
            cookie("__Secure-next-auth.session-token.0", value: "chunk-a", domain: "chatgpt.com"),
            cookie("__Secure-next-auth.session-token.1", value: "chunk-b", domain: "chatgpt.com"),
            cookie("_ga", value: "tracker", domain: "chatgpt.com")
        ]
        XCTAssertEqual(
            selectedNames(cookies, policy: ChatGPTAuthSession.chatgptPolicy()),
            ["__Secure-next-auth.session-token.0", "__Secure-next-auth.session-token.1"]
        )
    }

    /// The CSRF-only jar present while the sign-in page renders is not captured
    /// as a session.
    func testChatGPTPolicyRejectsCSRFOnlyJar() {
        let cookies = [
            cookie("__Host-next-auth.csrf-token", value: "csrf", domain: "chatgpt.com"),
            cookie("_ga", value: "tracker", domain: "chatgpt.com")
        ]
        XCTAssertNil(WebKitCookieCapture.select(from: cookies, policy: ChatGPTAuthSession.chatgptPolicy()))
    }

    /// X/Twitter hosts are not part of the Grok session at all.
    func testGrokDomainExcludesXAndTwitter() {
        XCTAssertFalse(AuthSessionService.isGrokDomain("x.com"))
        XCTAssertFalse(AuthSessionService.isGrokDomain(".twitter.com"))
        XCTAssertTrue(AuthSessionService.isGrokDomain(".grok.com"))
        XCTAssertTrue(SignInView.isAuthHost("x.com"))
    }

    /// A Grok jar without `sso` is not captured, even with auth-looking cookies.
    func testGrokPolicyWithoutSessionCookieCapturesNothing() {
        let cookies = [
            cookie("x-session-hint", value: "v", domain: "grok.com"),
            cookie("_ga", value: "tracker", domain: "grok.com")
        ]
        XCTAssertNil(WebKitCookieCapture.select(from: cookies, policy: AuthSessionService.grokPolicy()))
    }
}
