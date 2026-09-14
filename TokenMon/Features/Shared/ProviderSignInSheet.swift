import AppKit
import SwiftUI
import WebKit

/// Auth types that can capture a WebKit session for a provider sign-in sheet.
@MainActor
protocol ProviderCookieCapturing: ObservableObject {
    var lastAuthError: String? { get }
    var accountEmail: String? { get }
    /// Isolated WebKit store this provider signs into and captures from.
    var signInDataStore: WKWebsiteDataStore { get }
    func captureCookiesFromWebKit() async -> Bool
}

/// Per-provider configuration for the shared sign-in sheet.
struct ProviderSignInConfig {
    var title: String
    var subtitle: String
    var startURL: URL
    var isAuthHost: (String, String) -> Bool
    var isReturnPage: (URL) -> Bool
    var returnDelayNanoseconds: UInt64
    /// Runs when the return page is detected, before the delayed capture.
    var onReturned: ((URL) -> Void)?

    init(
        title: String,
        subtitle: String,
        startURL: URL,
        isAuthHost: @escaping (String, String) -> Bool,
        isReturnPage: @escaping (URL) -> Bool,
        returnDelayNanoseconds: UInt64 = 800_000_000,
        onReturned: ((URL) -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.startURL = startURL
        self.isAuthHost = isAuthHost
        self.isReturnPage = isReturnPage
        self.returnDelayNanoseconds = returnDelayNanoseconds
        self.onReturned = onReturned
    }
}

/// Guided sign-in: the user signs in on the provider's own page and the sheet
/// finishes on its own, showing a brief confirmation before it closes.
struct ProviderSignInSheet<Auth: ProviderCookieCapturing>: View {
    @ObservedObject var auth: Auth
    let config: ProviderSignInConfig
    var onComplete: () -> Void
    /// Runs after a successful cookie capture, before dismissal.
    var afterCapture: (() async -> Void)?

    @StateObject private var browser = SignInBrowserController()
    @State private var phase: Phase = .signingIn
    @State private var didHintTimeout = false
    @State private var isDismissed = false
    @Environment(\.dismiss) private var dismiss

    /// How long the window waits before nudging the user to finish manually.
    private let timeoutHintNanoseconds: UInt64 = 25_000_000_000
    /// How long the "signed in" confirmation stays up before the window closes.
    private let confirmationNanoseconds: UInt64 = 1_100_000_000

    private enum Phase: Equatable {
        case signingIn
        case finishing
        case signedIn(email: String?)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            SignInNavigationBar(browser: browser)
            Divider()

            ProviderSignInWebView(
                startURL: config.startURL,
                dataStore: auth.signInDataStore,
                controller: browser,
                isAuthHost: config.isAuthHost,
                isReturnPage: config.isReturnPage,
                onAuthHostSeen: {},
                onReturned: { url in
                    config.onReturned?(url)
                    Task { await captureAfterReturn() }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(minWidth: 880, minHeight: 640)
        .onAppear { NSApp.activate() }
        .onDisappear { isDismissed = true }
        .task {
            try? await Task.sleep(nanoseconds: timeoutHintNanoseconds)
            if !Task.isCancelled { didHintTimeout = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if case .signedIn = phase {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(config.title)
                    .font(.title2.weight(.semibold))
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private var statusText: String {
        switch phase {
        case .signingIn:
            if browser.hasPopup {
                return "Complete sign-in in the popup above."
            }
            if didHintTimeout {
                return "Signed in? Choose Finish Sign-In to complete."
            }
            return config.subtitle
        case .finishing:
            return "Finishing sign-in…"
        case let .signedIn(email):
            return email.map { "Signed in as \($0)" } ?? "Signed in"
        case let .failed(message):
            return message
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if case .finishing = phase {
                ProgressView().controlSize(.small)
            }

            Spacer()

            Button(primaryTitle) {
                Task { await finish() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy || isSignedIn)
        }
        .padding()
    }

    private var primaryTitle: String {
        switch phase {
        case .signingIn: return "Finish Sign-In"
        case .finishing: return "Finishing…"
        case .failed: return "Try Again"
        case .signedIn: return "Signed In"
        }
    }

    private var isBusy: Bool {
        if case .finishing = phase { return true }
        return false
    }

    private var isSignedIn: Bool {
        if case .signedIn = phase { return true }
        return false
    }

    // MARK: - Flow

    /// Manual finish: capture now and close, or surface a retry.
    private func finish() async {
        guard !isDismissed, !isBusy, !isSignedIn else { return }
        phase = .finishing
        if await capture() {
            await confirmAndDismiss()
        } else {
            phase = .failed(failureMessage)
            browser.rearmReturn()
        }
    }

    /// Automatic capture after the user returns to the provider page.
    private func captureAfterReturn() async {
        guard !isDismissed, !isBusy, !isSignedIn else { return }
        for _ in 0..<40 where browser.hasPopup {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if isDismissed { return }
        }
        if config.returnDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: config.returnDelayNanoseconds)
        }
        // The user may have finished manually while we waited.
        guard !isDismissed, !isBusy, !isSignedIn else { return }

        phase = .finishing
        if await capture() {
            await confirmAndDismiss()
            return
        }
        // Cookies may be late; retry once before asking the user.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard !isDismissed, !isSignedIn else { return }
        if await capture() {
            await confirmAndDismiss()
        } else {
            phase = .failed(failureMessage)
            browser.rearmReturn()
        }
    }

    private func capture() async -> Bool {
        let ok = await auth.captureCookiesFromWebKit()
        if ok, let afterCapture {
            await afterCapture()
        }
        return ok
    }

    private func confirmAndDismiss() async {
        guard !isSignedIn else { return }
        phase = .signedIn(email: auth.accountEmail)
        onComplete()
        try? await Task.sleep(nanoseconds: confirmationNanoseconds)
        if !isDismissed { dismiss() }
    }

    private var failureMessage: String {
        auth.lastAuthError
            ?? "Couldn't find a signed-in session yet. Finish signing in, then try again."
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
