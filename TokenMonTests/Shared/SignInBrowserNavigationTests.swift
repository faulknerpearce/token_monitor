import Combine
@testable import TokenMon
import WebKit
import XCTest

final class SignInBrowserNavigationTests: XCTestCase {
    func testBackGoesBackWhenHistoryExists() {
        XCTAssertEqual(
            SignInPopupStack.backAction(canGoBack: true, popupDepth: 0),
            .goBack
        )
        XCTAssertEqual(
            SignInPopupStack.backAction(canGoBack: true, popupDepth: 1),
            .goBack
        )
    }

    func testBackClosesPopupWhenPopupHasNoHistory() {
        XCTAssertEqual(
            SignInPopupStack.backAction(canGoBack: false, popupDepth: 1),
            .closePopup
        )
        XCTAssertEqual(
            SignInPopupStack.backAction(canGoBack: false, popupDepth: 2),
            .closePopup
        )
    }

    func testBackDoesNothingOnMainPageWithoutHistory() {
        XCTAssertEqual(
            SignInPopupStack.backAction(canGoBack: false, popupDepth: 0),
            .none
        )
    }

    func testBackActionRawValuesRoundTrip() {
        for action in SignInBackAction.allCases {
            XCTAssertEqual(SignInBackAction(rawValue: action.rawValue), action)
            XCTAssertFalse(action.displayName.isEmpty)
        }
        XCTAssertNil(SignInBackAction(rawValue: "not-an-action"))
    }

    func testReturnGateIgnoresStartURLUntilAuthHost() {
        var gate = SignInReturnGate(
            isAuthHost: { host, _ in host.contains("accounts.google") },
            isReturnPage: { $0.host?.contains("cursor.com") ?? false }
        )
        let start = URL(string: "https://cursor.com/dashboard/usage")!
        XCTAssertEqual(gate.note(url: start), .none)
        XCTAssertFalse(gate.matchesReturnPage(start))

        let auth = URL(string: "https://accounts.google.com/o/oauth2/auth")!
        XCTAssertEqual(gate.note(url: auth), .authHost)
        XCTAssertTrue(gate.didSeeAuth)

        XCTAssertEqual(gate.note(url: start), .returnPage)
        XCTAssertTrue(gate.matchesReturnPage(start))
    }

    func testReturnGateDoesNotCaptureBeforeAuth() {
        var gate = SignInReturnGate(
            isAuthHost: { host, path in path.contains("/login") || host.contains("github.com") },
            isReturnPage: { url in
                (url.host ?? "").contains("claude.ai") && url.path != "/login"
            }
        )
        let home = URL(string: "https://claude.ai/new")!
        XCTAssertEqual(gate.note(url: home), .none)

        let login = URL(string: "https://claude.ai/login")!
        XCTAssertEqual(gate.note(url: login), .authHost)
        XCTAssertEqual(gate.note(url: home), .returnPage)
    }

    func testChatGPTReturnPageExcludesLoginAndAuth() {
        XCTAssertTrue(ChatGPTSignInView.isAuthHost(host: "auth.openai.com", path: "/"))
        XCTAssertTrue(ChatGPTSignInView.isAuthHost(host: "chatgpt.com", path: "/auth/login"))
        XCTAssertTrue(
            ChatGPTSignInView.isReturnPage(URL(string: "https://chatgpt.com/")!)
        )
        XCTAssertTrue(
            ChatGPTSignInView.isReturnPage(URL(string: "https://chatgpt.com/c/abc")!)
        )
        XCTAssertFalse(
            ChatGPTSignInView.isReturnPage(URL(string: "https://chatgpt.com/auth/login")!)
        )
        XCTAssertFalse(
            ChatGPTSignInView.isReturnPage(URL(string: "https://chatgpt.com/login")!)
        )
        XCTAssertFalse(
            ChatGPTSignInView.isReturnPage(URL(string: "https://auth.openai.com/")!)
        )
    }

    // MARK: - Controller publishing

    /// Regression: the sheet observes this controller and SwiftUI re-runs
    /// `updateNSView` on every publish, so an unconditional `apply` spun the main
    /// thread forever and the sign-in window appeared to hang.
    @MainActor
    func testApplyDoesNotPublishWhenNothingChanged() {
        let controller = SignInBrowserController()
        var changes = 0
        let token = controller.objectWillChange.sink { _ in changes += 1 }
        defer { token.cancel() }

        controller.apply(
            canGoBack: true,
            canGoForward: false,
            isLoading: true,
            currentURL: "https://chatgpt.com/",
            popupDepth: 1
        )
        let afterFirst = changes
        XCTAssertGreaterThan(afterFirst, 0)

        for _ in 0..<5 {
            controller.apply(
                canGoBack: true,
                canGoForward: false,
                isLoading: true,
                currentURL: "https://chatgpt.com/",
                popupDepth: 1
            )
        }
        XCTAssertEqual(changes, afterFirst)
    }

    @MainActor
    func testApplyPublishesOnceForEachRealChange() {
        let controller = SignInBrowserController()
        controller.apply(
            canGoBack: false,
            canGoForward: false,
            isLoading: false,
            currentURL: "https://cursor.com/",
            popupDepth: 0
        )
        XCTAssertFalse(controller.hasPopup)
        XCTAssertFalse(controller.backIsEnabled)

        var changes = 0
        let token = controller.objectWillChange.sink { _ in changes += 1 }
        defer { token.cancel() }

        controller.apply(
            canGoBack: false,
            canGoForward: false,
            isLoading: false,
            currentURL: "https://cursor.com/",
            popupDepth: 1
        )
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(controller.hasPopup)
        XCTAssertTrue(controller.backIsEnabled, "Back must dismiss a popup with no history")

        controller.apply(
            canGoBack: false,
            canGoForward: false,
            isLoading: false,
            currentURL: "https://accounts.google.com/",
            popupDepth: 1
        )
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(controller.currentURL, "https://accounts.google.com/")
    }

    @MainActor
    func testAttachIsIdempotent() {
        let controller = SignInBrowserController()
        let browser = SignInBrowserView(
            startURL: URL(string: "https://cursor.com/dashboard")!,
            dataStore: .nonPersistent(),
            isAuthHost: { _, _ in false },
            isReturnPage: { _ in false },
            onAuthHostSeen: {},
            onReturned: { _ in }
        )
        controller.attach(browser)

        var changes = 0
        let token = controller.objectWillChange.sink { _ in changes += 1 }
        defer { token.cancel() }

        for _ in 0..<5 {
            controller.attach(browser)
        }
        XCTAssertEqual(changes, 0, "Re-attaching the same browser must not publish")
    }

    // MARK: - Sign-in browser identity

    /// Regression: 1.4.1 set `customUserAgent = AppIdentity.userAgent`, so the
    /// sign-in browser announced itself as "TokenMon/x.y.z" with no browser
    /// tokens. OAuth providers (Google especially) refuse sign-in from a UA that
    /// does not look like a browser. This is an interactive browser, not an API
    /// client: it must keep WebKit's default Safari User-Agent.
    @MainActor
    func testSignInBrowserDoesNotOverrideTheUserAgent() {
        let browser = SignInBrowserView(
            startURL: URL(string: "about:blank")!,
            dataStore: .nonPersistent(),
            isAuthHost: { _, _ in false },
            isReturnPage: { _ in false },
            onAuthHostSeen: {},
            onReturned: { _ in }
        )
        XCTAssertTrue(
            (browser.mainWebView.customUserAgent ?? "").isEmpty,
            "Sign-in must use WebKit's default browser User-Agent"
        )

        // What the provider actually receives.
        let loaded = expectation(description: "about:blank loaded")
        let probe = UserAgentProbe { loaded.fulfill() }
        browser.mainWebView.navigationDelegate = probe
        browser.mainWebView.load(URLRequest(url: URL(string: "about:blank")!))
        wait(for: [loaded], timeout: 10)

        let reported = expectation(description: "navigator.userAgent read")
        var userAgent = ""
        browser.mainWebView.evaluateJavaScript("navigator.userAgent") { value, _ in
            userAgent = value as? String ?? ""
            reported.fulfill()
        }
        wait(for: [reported], timeout: 10)

        XCTAssertTrue(
            userAgent.contains("Mozilla/5.0"),
            "OAuth providers reject non-browser user agents, got: \(userAgent)"
        )
        XCTAssertTrue(
            userAgent.contains("AppleWebKit"),
            "Expected the default WebKit user agent, got: \(userAgent)"
        )
        XCTAssertFalse(
            userAgent.contains("TokenMon"),
            "The API-client identity must not leak into the sign-in browser"
        )
    }

    @MainActor
    func testRearmReturnDoesNotPublish() {
        let controller = SignInBrowserController()
        let browser = SignInBrowserView(
            startURL: URL(string: "about:blank")!,
            dataStore: .nonPersistent(),
            isAuthHost: { _, _ in false },
            isReturnPage: { _ in false },
            onAuthHostSeen: {},
            onReturned: { _ in }
        )
        controller.attach(browser)

        var changes = 0
        let token = controller.objectWillChange.sink { _ in changes += 1 }
        defer { token.cancel() }

        controller.rearmReturn()
        XCTAssertEqual(changes, 0)
    }
}

/// Fulfils once a probe navigation finishes.
private final class UserAgentProbe: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        onFinish()
    }
}
