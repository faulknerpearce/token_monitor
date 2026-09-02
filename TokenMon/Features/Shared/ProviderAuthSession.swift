import Combine
import Foundation
import os
import WebKit

/// Per-provider configuration for the shared `ProviderAuthSession`.
struct ProviderAuthConfig {
    /// File-bucket prefix isolating each provider's cookie/email store.
    var storeFilenamePrefix: String
    /// Log category (subsystem: `com.modelmonitor.app`).
    var logCategory: String
    /// Whether the session begins signed-out (vs. signed-in-until-proven-wrong).
    var startsSignedOut: Bool
    /// Whether this provider also persists a bearer token (Grok only).
    var usesBearerToken: Bool
    /// Extra store keys to clear on sign-out / invalid (e.g. `workspace`).
    var extraStoreKeys: [String]
    /// HTTP hosts whose `HTTPCookieStorage` cookies are cleared on sign-out.
    var signOutHosts: [String]
    /// WebKit capture policy (domains, preferred cookie, auth heuristics).
    var capturePolicy: WebKitCookieCapture.Policy
    /// Matches a cookie domain to this provider (also used on sign-out via WKWebsiteDataStore).
    var isDomain: (String) -> Bool
}

/// Shared cookie/email/bearer session backing every provider's auth.
///
/// Provider subclasses configure a `ProviderAuthConfig` (capture policy, sign-out
/// hosts, extra persisted keys) and inherit the disk refresh, sign-in state
/// machine, cookie capture, and sign-out behavior. This removes the near-duplicate
/// session classes for Grok, OpenCode, and Cursor (and future providers like
/// OpenRouter).
@MainActor
class ProviderAuthSession: ObservableObject, ProviderCookieCapturing {
    let config: ProviderAuthConfig

    @Published private(set) var isSignedIn = false
    @Published private(set) var accountEmail: String?
    @Published var needsSignIn = true
    @Published private(set) var lastAuthError: String?

    /// WebKit store isolated to this provider. Sign-in and capture only ever see
    /// this provider's cookies; other providers (and legacy default-jar cookies)
    /// are invisible to it.
    let signInDataStore = WKWebsiteDataStore.nonPersistent()

    private let store: any CredentialStore
    private let logger: Logger

    init(config: ProviderAuthConfig, directory: URL? = nil, store: (any CredentialStore)? = nil) {
        self.config = config
        self.logger = Logger(category: config.logCategory)
        if let store {
            self.store = store
        } else if let directory {
            self.store = FileBackedCredentialStore(directory: directory, filenamePrefix: config.storeFilenamePrefix)
        } else {
            self.store = FileBackedCredentialStore(filenamePrefix: config.storeFilenamePrefix)
        }
        self.needsSignIn = config.startsSignedOut
        refreshFromDisk()
    }

    func refreshFromDisk() {
        let cookies = loadCookieHeader()
        let hasTokenOrCookie = !(cookies?.isEmpty ?? true)
            || (config.usesBearerToken && loadBearerToken() != nil)
        isSignedIn = hasTokenOrCookie
        accountEmail = loadEmail()
        needsSignIn = !isSignedIn
    }

    /// Marks the session invalid (e.g. server returned 401/403) and clears both
    /// disk state and browser cookies, so "Sign in again" cannot auto-capture
    /// the same expired session.
    func markSessionInvalid(reason: String? = nil) {
        needsSignIn = true
        if let reason { lastAuthError = reason }
        clearBrowserState()
        isSignedIn = false
        logger.info("\(self.config.logCategory, privacy: .public) session marked invalid")
    }

    func cookieHeader() -> String? {
        loadCookieHeader()
    }

    /// Persisted cookie header (Grok poller reads it directly).
    func loadCookieHeader() -> String? {
        readStore(key: "session")
    }

    func saveAccountEmail(_ email: String) {
        writeStore(key: "email", value: email)
        accountEmail = email
    }

    func save(cookieHeader: String) {
        writeStore(key: "session", value: cookieHeader)
        isSignedIn = true
        needsSignIn = false
    }

    func loadBearerToken() -> String? {
        readStore(key: "token")
    }

    func captureCookiesFromWebKit() async -> Bool {
        guard let result = await WebKitCookieCapture.capture(policy: config.capturePolicy, dataStore: signInDataStore) else {
            lastAuthError = config.capturePolicy.failureMessage
            logger.warning("No auth cookies found after sign-in")
            return false
        }

        save(cookieHeader: result.cookieHeader)
        for cookie in result.cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        if let email = result.email {
            saveAccountEmail(email)
        }

        isSignedIn = true
        needsSignIn = false
        lastAuthError = nil
        logger.info("Captured \(result.cookies.count, privacy: .public) session cookies")
        return true
    }

    func signOut() {
        clearBrowserState()
        isSignedIn = false
        accountEmail = nil
        needsSignIn = true
        lastAuthError = nil
        logger.info("\(self.config.logCategory, privacy: .public) signed out")
    }

    /// Clears persisted session keys and browser cookies (the provider's isolated
    /// WebKit store, matching domains in the legacy default jar, and
    /// `HTTPCookieStorage`). Shared by explicit sign-out and 401/403 invalidation.
    func clearBrowserState() {
        removeStore(key: "session")
        removeStore(key: "email")
        if config.usesBearerToken { removeStore(key: "token") }
        for key in config.extraStoreKeys { removeStore(key: key) }
        WebKitCookieCapture.clearHTTPCookieStorage(hosts: config.signOutHosts)
        let dataStore = signInDataStore
        let isDomain = config.isDomain
        Task {
            await WKWebsiteDataStoreBridge.shared.clearAllCookies(in: dataStore)
            // Legacy cookies from before per-provider stores lived in the default jar.
            await WKWebsiteDataStoreBridge.shared.clearCookies(matching: isDomain, in: .default())
        }
    }

    // MARK: - Store (protected for subclasses)

    func writeStore(key: String, value: String) {
        store.set(value, forKey: key)
    }

    func readStore(key: String) -> String? {
        store.value(forKey: key)
    }

    func removeStore(key: String) {
        store.remove(forKey: key)
    }

    private func loadEmail() -> String? {
        readStore(key: "email")
    }
}
