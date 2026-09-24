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
/// hosts, extra persisted keys) and inherit disk refresh, sign-in state machine,
/// cookie capture, and sign-out behavior.
@MainActor
class ProviderAuthSession: ObservableObject, ProviderCookieCapturing {
    let config: ProviderAuthConfig

    @Published private(set) var isSignedIn = false
    @Published private(set) var accountEmail: String?
    @Published var needsSignIn = true
    @Published private(set) var lastAuthError: String?

    /// Monotonic counter identifying the current credential state. A poller
    /// captures it before a fetch and checks it after the await via
    /// `isCurrent(_:)`, so a refresh that completes after a sign-out or account
    /// switch cannot publish data for the previous account.
    private(set) var sessionGeneration = 0

    /// WebKit store isolated to this provider; sign-in and capture only see this
    /// provider's cookies.
    let signInDataStore = WKWebsiteDataStore.nonPersistent()

    private let store: any CredentialStore
    private let logger: Logger
    /// In-flight browser-cookie purge from a prior sign-out / invalidation.
    /// Capture awaits it so a quick re-auth cannot race the late clear.
    private var clearTask: Task<Void, Never>?

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
        // `refreshFromDisk()` derives `needsSignIn` from the stored credentials.
        refreshFromDisk()
    }

    func refreshFromDisk() {
        let cookies = loadCookieHeader()
        isSignedIn = !(cookies?.isEmpty ?? true)
        accountEmail = loadEmail()
        needsSignIn = !isSignedIn
        sessionGeneration += 1
    }

    /// Marks the session invalid (e.g. server returned 401/403) and clears both
    /// disk state and browser cookies, so "Sign in again" cannot auto-capture
    /// the same expired session.
    func markSessionInvalid(reason: String? = nil) {
        needsSignIn = true
        if let reason { lastAuthError = reason }
        clearBrowserState()
        isSignedIn = false
        accountEmail = nil
        logger.info("\(self.config.logCategory, privacy: .public) session marked invalid")
    }

    /// True when `generation` still describes the live, usable session.
    func isCurrent(_ generation: Int) -> Bool {
        generation == sessionGeneration && isSignedIn && !needsSignIn
    }

    func cookieHeader() -> String? {
        loadCookieHeader()
    }

    /// Persisted cookie header, narrowed to the provider's essential cookies.
    func loadCookieHeader() -> String? {
        guard let stored = readStore(key: "session") else { return nil }
        let pruned = Self.pruneCookieHeader(stored, policy: config.capturePolicy)
        if pruned != stored {
            // A jar captured before the allowlist existed can still carry SSO
            // cookies from another account (e.g. an X session in the Grok jar).
            writeStore(key: "session", value: pruned)
        }
        return pruned
    }

    /// Narrows a stored `Cookie:` header to the provider's essential cookies,
    /// mirroring `WebKitCookieCapture.select`: only narrow when one of them is
    /// present, so a provider without an allowlist keeps its stored jar. Prefixed
    /// families (NextAuth's chunked session cookie) are matched as a whole.
    static func pruneCookieHeader(
        _ header: String,
        policy: WebKitCookieCapture.Policy
    ) -> String {
        guard policy.hasEssentialCookieAllowlist else { return header }
        let pairs = header
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        func name(of pair: String) -> String? {
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            return String(pair[..<separator])
        }
        guard pairs.contains(where: { name(of: $0).map(policy.isEssential) ?? false }) else {
            return header
        }
        let kept = pairs.filter { name(of: $0).map(policy.isEssential) ?? false }
        return kept.joined(separator: "; ")
    }

    /// Folds refreshed `Set-Cookie` values for this provider's essential cookies
    /// into the stored header. A rolling session cookie (NextAuth renews
    /// `__Secure-next-auth.session-token` on every `/api/auth/session` call) is
    /// otherwise only ever polled and never renewed, so it hard-expires while the
    /// user is still signed in. Writes the store directly: it must not bump
    /// `sessionGeneration`, or a poll in flight would invalidate its own session.
    func applyRefreshedCookies(_ setCookieHeaders: [String]) {
        guard !setCookieHeaders.isEmpty, let stored = readStore(key: "session") else { return }
        var order: [String] = []
        var values: [String: String] = [:]
        for pair in Self.cookiePairs(stored) {
            order.append(pair.name)
            values[pair.name.lowercased()] = pair.value
        }
        var changed = false
        for raw in setCookieHeaders {
            guard let pair = Self.parseSetCookie(raw), config.capturePolicy.isEssential(pair.name) else {
                continue
            }
            let key = pair.name.lowercased()
            if values[key] != pair.value {
                if values[key] == nil { order.append(pair.name) }
                values[key] = pair.value
                changed = true
            }
        }
        guard changed else { return }
        let header = order.compactMap { name -> String? in
            values[name.lowercased()].map { "\(name)=\($0)" }
        }.joined(separator: "; ")
        writeStore(key: "session", value: header)
    }

    /// Splits a `Cookie:` header into ordered name/value pairs.
    private static func cookiePairs(_ header: String) -> [(name: String, value: String)] {
        header.split(separator: ";").compactMap { pair in
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") else { return nil }
            return (String(trimmed[..<separator]), String(trimmed[trimmed.index(after: separator)...]))
        }
    }

    /// Extracts the name/value from a `Set-Cookie` header, ignoring attributes.
    private static func parseSetCookie(_ raw: String) -> (name: String, value: String)? {
        let first = raw.split(separator: ";").first.map(String.init) ?? raw
        return cookiePairs(first).first
    }

    func saveAccountEmail(_ email: String) {
        writeStore(key: "email", value: email)
        accountEmail = email
    }

    func save(cookieHeader: String) {
        writeStore(key: "session", value: cookieHeader)
        isSignedIn = true
        needsSignIn = false
        sessionGeneration += 1
    }

    func captureCookiesFromWebKit() async -> Bool {
        // Finish any pending sign-out purge first so it cannot delete cookies
        // being captured from a fresh sign-in.
        _ = await clearTask?.value
        guard let result = await WebKitCookieCapture.capture(policy: config.capturePolicy, dataStore: signInDataStore) else {
            lastAuthError = config.capturePolicy.failureMessage
            logger.warning("No auth cookies found after sign-in")
            return false
        }

        save(cookieHeader: result.cookieHeader)
        // Only the file store keeps these; copying into `HTTPCookieStorage.shared`
        // would leave the session in a shared jar that outlives the 0600 file and
        // lets unrelated requests auto-attach it. Request paths send the captured
        // Cookie header explicitly.
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
    /// WebKit store, matching domains in the default jar, and
    /// `HTTPCookieStorage`). Shared by explicit sign-out and 401/403 invalidation.
    func clearBrowserState() {
        sessionGeneration += 1
        removeStore(key: "session")
        removeStore(key: "email")
        for key in config.extraStoreKeys { removeStore(key: key) }
        WebKitCookieCapture.clearHTTPCookieStorage(hosts: config.signOutHosts)
        let dataStore = signInDataStore
        let isDomain = config.isDomain
        clearTask?.cancel()
        clearTask = Task {
            await WKWebsiteDataStoreBridge.shared.clearAllCookies(in: dataStore)
            // Clear matching cookies from the shared default cookie jar.
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
