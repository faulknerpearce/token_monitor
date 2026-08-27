import AppKit
import SwiftUI
import WebKit

/// Auth types that can capture a WebKit session for a provider sign-in sheet.
@MainActor
protocol ProviderCookieCapturing: ObservableObject {
    var lastAuthError: String? { get }
    /// Isolated WebKit store this provider signs into and captures from.
    var signInDataStore: WKWebsiteDataStore { get }
    func captureCookiesFromWebKit() async -> Bool
}

struct ProviderSignInConfig {
    var title: String
    var initialStatus: String
    var authHostStatus: String
    var capturingStatus: String
    var startURL: URL
    var isAuthHost: (String, String) -> Bool
    var isReturnPage: (URL) -> Bool
    var returnDelayNanoseconds: UInt64
    /// Optional side effect when the return page is detected (before delayed capture).
    var onReturned: ((URL) -> Void)?

    init(
        title: String,
        initialStatus: String,
        authHostStatus: String,
        capturingStatus: String,
        startURL: URL,
        isAuthHost: @escaping (String, String) -> Bool,
        isReturnPage: @escaping (URL) -> Bool,
        returnDelayNanoseconds: UInt64 = 800_000_000,
        onReturned: ((URL) -> Void)? = nil
    ) {
        self.title = title
        self.initialStatus = initialStatus
        self.authHostStatus = authHostStatus
        self.capturingStatus = capturingStatus
        self.startURL = startURL
        self.isAuthHost = isAuthHost
        self.isReturnPage = isReturnPage
        self.returnDelayNanoseconds = returnDelayNanoseconds
        self.onReturned = onReturned
    }
}

/// Shared sign-in chrome: title, nav (Back / popup), WebKit host, Capture / Done.
struct ProviderSignInSheet<Auth: ProviderCookieCapturing>: View {
    @ObservedObject var auth: Auth
    let config: ProviderSignInConfig
    var onComplete: () -> Void
    /// Runs after a successful cookie capture, before dismiss.
    var afterCapture: (() async -> Void)?

    @StateObject private var browser = SignInBrowserController()
    @State private var statusMessage: String
    @State private var isCapturing = false
    @State private var isDismissed = false
    @Environment(\.dismiss) private var dismiss

    init(
        auth: Auth,
        config: ProviderSignInConfig,
        onComplete: @escaping () -> Void,
        afterCapture: (() async -> Void)? = nil
    ) {
        self.auth = auth
        self.config = config
        self.onComplete = onComplete
        self.afterCapture = afterCapture
        _statusMessage = State(initialValue: config.initialStatus)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(config.title)
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            if let err = auth.lastAuthError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }

            SignInNavigationBar(browser: browser)
            Divider()

            ProviderSignInWebView(
                startURL: config.startURL,
                dataStore: auth.signInDataStore,
                controller: browser,
                isAuthHost: config.isAuthHost,
                isReturnPage: config.isReturnPage,
                onAuthHostSeen: {
                    statusMessage = config.authHostStatus
                },
                onReturned: { url in
                    config.onReturned?(url)
                    statusMessage = config.capturingStatus
                    Task { await captureAfterReturn() }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Button(isCapturing ? "Capturing session…" : "Capture Session") {
                    Task { _ = await capture() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCapturing)

                if isCapturing {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button("Done") {
                    onComplete()
                    dismiss()
                }
            }
            .padding()
        }
        .frame(minWidth: 880, minHeight: 640)
        .onAppear {
            NSApp.activate()
        }
        .onDisappear {
            isDismissed = true
        }
        .onChange(of: browser.popupDepth) { _, depth in
            if depth > 0 {
                statusMessage =
                    "Complete sign-in in the popup. Back or Close popup returns to the provider page."
            }
        }
    }

    /// Wait for an OAuth popup to close, then capture; retry once if cookies are late.
    private func captureAfterReturn() async {
        guard !isDismissed, !isCapturing else { return }
        for _ in 0..<40 where browser.hasPopup {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if isDismissed { return }
        }
        if config.returnDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: config.returnDelayNanoseconds)
        }
        if isDismissed { return }
        if await capture() { return }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if isDismissed { return }
        _ = await capture()
    }

    @discardableResult
    private func capture() async -> Bool {
        guard !isDismissed, !isCapturing else { return false }
        isCapturing = true
        defer { isCapturing = false }
        let ok = await auth.captureCookiesFromWebKit()
        if ok {
            if let afterCapture {
                await afterCapture()
            }
            statusMessage = "Session captured."
            onComplete()
            dismiss()
            return true
        }
        statusMessage = auth.lastAuthError
            ?? "No session cookies found yet. Finish signing in, then click Capture Session."
        return false
    }
}

/// Back / Forward / Reload / Close popup chrome for the sign-in WebKit host.
private struct SignInNavigationBar: View {
    @ObservedObject var browser: SignInBrowserController

    var body: some View {
        HStack(spacing: 8) {
            Button(action: browser.goBack) {
                Image(systemName: "chevron.backward")
            }
            .disabled(!browser.backIsEnabled)
            .help(browser.hasPopup && !browser.canGoBack ? "Back to the sign-in page" : "Back")
            .accessibilityLabel("Back")

            Button(action: browser.goForward) {
                Image(systemName: "chevron.forward")
            }
            .disabled(!browser.canGoForward)
            .help("Forward")
            .accessibilityLabel("Forward")

            Button(action: browser.reload) {
                Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(browser.isLoading ? "Stop" : "Reload")
            .accessibilityLabel(browser.isLoading ? "Stop" : "Reload")

            Text(browser.hasPopup ? "Sign-in popup" : displayURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(browser.currentURL)

            if browser.hasPopup {
                Button("Close popup", action: browser.closePopup)
                    .help("Return to the provider sign-in page")
            }

            if browser.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var displayURL: String {
        guard let url = URL(string: browser.currentURL), let host = url.host else {
            return browser.currentURL
        }
        return host + url.path
    }
}
