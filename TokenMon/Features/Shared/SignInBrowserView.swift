import AppKit
import Combine
import WebKit

/// Observable chrome for the provider sign-in browser.
///
/// The SwiftUI sign-in window owns this object and drives Back / Forward /
/// Reload / Close popup. The AppKit `SignInBrowserView` publishes live
/// `WKWebView` state into it.
@MainActor
final class SignInBrowserController: ObservableObject {
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentURL = ""
    @Published private(set) var popupDepth = 0

    /// True while an OAuth `window.open` popup is covering the provider page.
    var hasPopup: Bool { popupDepth > 0 }

    /// Back is enabled when the frontmost page has history, or a popup can be dismissed.
    var backIsEnabled: Bool { canGoBack || hasPopup }

    fileprivate weak var browser: SignInBrowserView?

    func attach(_ browser: SignInBrowserView) {
        self.browser = browser
        browser.controller = self
        browser.publishChrome()
    }

    func goBack() { browser?.goBackOrClosePopup() }
    func goForward() { browser?.goForward() }
    func reload() { browser?.reloadOrStop() }
    func closePopup() { browser?.closeTopPopup() }

    fileprivate func apply(
        canGoBack: Bool,
        canGoForward: Bool,
        isLoading: Bool,
        currentURL: String,
        popupDepth: Int
    ) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.currentURL = currentURL
        self.popupDepth = popupDepth
    }
}

/// AppKit host for provider sign-in: one main `WKWebView` plus a stack of OAuth popups.
///
/// Google / GitHub / Apple sign-in uses `window.open`. Returning `nil` from
/// `createWebViewWith` and loading that URL in the parent view destroys the
/// original page and breaks `window.opener`. Each popup is a real child
/// `WKWebView` created with the configuration WebKit supplies (required so
/// cookies stay in the provider's isolated store). Back with no history
/// dismisses the top popup.
@MainActor
final class SignInBrowserView: NSView, WKNavigationDelegate, WKUIDelegate {
    var isAuthHost: (String, String) -> Bool {
        didSet { returnGate.isAuthHost = isAuthHost }
    }

    var isReturnPage: (URL) -> Bool {
        didSet { returnGate.isReturnPage = isReturnPage }
    }

    var onAuthHostSeen: () -> Void
    var onReturned: (URL) -> Void
    weak var controller: SignInBrowserController?

    private let mainWebView: WKWebView
    private var popups: [WKWebView] = []
    private var observations: [NSKeyValueObservation] = []
    private var returnGate: SignInReturnGate

    init(
        startURL: URL,
        dataStore: WKWebsiteDataStore,
        isAuthHost: @escaping (String, String) -> Bool,
        isReturnPage: @escaping (URL) -> Bool,
        onAuthHostSeen: @escaping () -> Void,
        onReturned: @escaping (URL) -> Void
    ) {
        self.isAuthHost = isAuthHost
        self.isReturnPage = isReturnPage
        self.onAuthHostSeen = onAuthHostSeen
        self.onReturned = onReturned
        self.returnGate = SignInReturnGate(isAuthHost: isAuthHost, isReturnPage: isReturnPage)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = AppIdentity.userAgent
        self.mainWebView = webView

        super.init(frame: .zero)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        observe(webView)
        webView.load(URLRequest(url: startURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        mainWebView.frame = bounds
        for popup in popups {
            popup.frame = bounds
        }
    }

    private var activeWebView: WKWebView {
        popups.last ?? mainWebView
    }

    func goBackOrClosePopup() {
        switch SignInPopupStack.backAction(canGoBack: activeWebView.canGoBack, popupDepth: popups.count) {
        case .goBack:
            activeWebView.goBack()
        case .closePopup:
            closeTopPopup()
        case .none:
            break
        }
    }

    func goForward() {
        guard activeWebView.canGoForward else { return }
        activeWebView.goForward()
    }

    func reloadOrStop() {
        if activeWebView.isLoading {
            activeWebView.stopLoading()
        } else {
            activeWebView.reload()
        }
    }

    func closeTopPopup() {
        guard let popup = popups.last else { return }
        dismiss(popup)
        if let url = mainWebView.url, returnGate.matchesReturnPage(url) {
            onReturned(url)
        }
    }

    func publishChrome() {
        let web = activeWebView
        controller?.apply(
            canGoBack: web.canGoBack,
            canGoForward: web.canGoForward,
            isLoading: web.isLoading,
            currentURL: web.url?.absoluteString ?? "",
            popupDepth: popups.count
        )
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        publishChrome()
        guard let url = webView.url else { return }
        handleFinished(url, isPopup: webView !== mainWebView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError _: Error) {
        publishChrome()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError _: Error
    ) {
        publishChrome()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        publishChrome()
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for _: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        let popup = WKWebView(frame: bounds, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.allowsBackForwardNavigationGestures = true
        popup.customUserAgent = mainWebView.customUserAgent
        popup.autoresizingMask = [.width, .height]
        popups.append(popup)
        addSubview(popup)
        observe(popup)
        publishChrome()
        window?.makeFirstResponder(popup)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard popups.contains(where: { $0 === webView }) else { return }
        dismiss(webView)
        if let url = mainWebView.url, returnGate.matchesReturnPage(url) {
            onReturned(url)
        }
    }

    // MARK: - Private

    private func handleFinished(_ url: URL, isPopup: Bool) {
        switch returnGate.note(url: url) {
        case .authHost:
            onAuthHostSeen()
        case .returnPage:
            // Wait until the OAuth popup is gone so cookies are committed and
            // window.opener can finish. Manual Capture Session still works.
            guard !isPopup, popups.isEmpty else { return }
            onReturned(url)
        case .none:
            break
        }
    }

    private func dismiss(_ popup: WKWebView) {
        popup.stopLoading()
        popup.navigationDelegate = nil
        popup.uiDelegate = nil
        popup.removeFromSuperview()
        popups.removeAll { $0 === popup }
        observe(activeWebView)
        publishChrome()
        window?.makeFirstResponder(activeWebView)
    }

    private func observe(_ webView: WKWebView) {
        observations.removeAll()
        let kick: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.publishChrome() }
        }
        observations = [
            webView.observe(\.canGoBack, options: [.new]) { _, _ in kick() },
            webView.observe(\.canGoForward, options: [.new]) { _, _ in kick() },
            webView.observe(\.isLoading, options: [.new]) { _, _ in kick() },
            webView.observe(\.url, options: [.new]) { _, _ in kick() }
        ]
    }
}
