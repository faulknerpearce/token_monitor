import Foundation

/// What the sign-in Back button should do for the active web view.
///
/// OAuth providers open a popup with little or no history. Back must then
/// dismiss the popup instead of doing nothing, which is how users got stuck.
enum SignInBackAction: String, Codable, CaseIterable, Hashable, Sendable {
    case goBack
    case closePopup
    case none

    /// Human-readable, user-visible name.
    var displayName: String {
        switch self {
        case .goBack: return "Back"
        case .closePopup: return "Close popup"
        case .none: return "None"
        }
    }
}

/// Pure Back-button policy for the sign-in browser (main page + OAuth popups).
enum SignInPopupStack {
    /// Resolve Back given the active web view's history and how many popups are open.
    ///
    /// - Parameters:
    ///   - canGoBack: Whether the frontmost web view has history.
    ///   - popupDepth: Number of open OAuth/popup web views (0 = main page only).
    /// - Returns: Navigate back, dismiss the popup, or do nothing.
    static func backAction(canGoBack: Bool, popupDepth: Int) -> SignInBackAction {
        if canGoBack { return .goBack }
        if popupDepth > 0 { return .closePopup }
        return .none
    }
}

/// Auth-host then return-page detector for automatic cookie capture.
///
/// Capture must not fire on the first load of the provider's start URL. The
/// user has to visit an auth host (Google, GitHub, xAI, …) first; only then
/// is a later return-page navigation treated as "signed in".
struct SignInReturnGate {
    var isAuthHost: (String, String) -> Bool
    var isReturnPage: (URL) -> Bool
    private(set) var didSeeAuth = false

    enum Event: String, Codable, CaseIterable, Hashable, Sendable {
        case none
        case authHost
        case returnPage

        var displayName: String {
            switch self {
            case .none: return "None"
            case .authHost: return "Auth host"
            case .returnPage: return "Return page"
            }
        }
    }

    /// Record a finished navigation and report whether capture should run.
    ///
    /// - Parameter url: The URL that just finished loading.
    /// - Returns: `.authHost` on the first auth-host hit, `.returnPage` once
    ///   the user has been to an auth host and is back on the provider page.
    mutating func note(url: URL) -> Event {
        let host = url.host?.lowercased() ?? ""
        var event: Event = .none
        if !didSeeAuth, isAuthHost(host, url.path) {
            didSeeAuth = true
            event = .authHost
        }
        if didSeeAuth, isReturnPage(url) {
            return .returnPage
        }
        return event
    }

    /// True when the user already passed through an auth host and `url` is the provider return page.
    func matchesReturnPage(_ url: URL) -> Bool {
        didSeeAuth && isReturnPage(url)
    }
}
