import SwiftUI
import WebKit

/// Shared WebKit sign-in host: starts at the provider's auth URL, hosts OAuth
/// popups as overlay tabs with Back, and fires when the return page loads.
struct ProviderSignInWebView: NSViewRepresentable {
    var startURL: URL
    /// Isolated store for this provider's sign-in (cookies never leak across providers).
    var dataStore: WKWebsiteDataStore
    var controller: SignInBrowserController
    var isAuthHost: (String, String) -> Bool
    var isReturnPage: (URL) -> Bool
    var onAuthHostSeen: () -> Void
    var onReturned: (URL) -> Void

    func makeNSView(context _: Context) -> SignInBrowserView {
        let view = SignInBrowserView(
            startURL: startURL,
            dataStore: dataStore,
            isAuthHost: isAuthHost,
            isReturnPage: isReturnPage,
            onAuthHostSeen: onAuthHostSeen,
            onReturned: onReturned
        )
        controller.attach(view)
        return view
    }

    func updateNSView(_ nsView: SignInBrowserView, context _: Context) {
        nsView.isAuthHost = isAuthHost
        nsView.isReturnPage = isReturnPage
        nsView.onAuthHostSeen = onAuthHostSeen
        nsView.onReturned = onReturned
    }
}
