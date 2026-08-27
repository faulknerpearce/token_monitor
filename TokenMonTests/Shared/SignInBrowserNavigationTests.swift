@testable import TokenMon
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
}
