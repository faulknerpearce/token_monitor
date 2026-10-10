import Combine
import Foundation
import os
import WebKit

/// Per-provider configuration for the shared `ProviderAuthSession`.
struct ProviderAuthConfig {
    /// Prefix isolating each provider's stored keys: the `<prefix><key>.dat`
    /// file name and the `<prefix><key>` Keychain account.
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
    /// Lowercased name of a captured cookie whose value identifies the account
    /// (Claude's `lastActiveOrg`). `nil` identifies the account by its email.
    var accountIdentityCookie: String?
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

    /// Fires when locally stored usage history stops belonging to the session:
    /// an explicit sign-out, or a capture for a different account. Those are its
    /// only triggers, so history survives invalidation after rejected requests
    /// and a re-login to the same account.
    let accountReset = PassthroughSubject<Void, Never>()

    /// Consecutive rejections of the live session required before it is
    /// invalidated. One rejection can be a token-exchange hiccup or an edge
    /// challenge, and invalidation deletes the stored credential.
    static let authFailureThreshold = 3

    /// Rejections of the live session since its last successful request.
    private(set) var consecutiveAuthFailures = 0

    /// Monotonic counter identifying the current credential state. A poller
    /// captures it before a fetch and checks it after the await via
    /// `isCurrent(_:)`, so a refresh that completes after a sign-out or account
    /// switch publishes nothing for the previous account.
    private(set) var sessionGeneration = 0

    /// WebKit store isolated to this provider; sign-in and capture only see this
    /// provider's cookies.
    let signInDataStore = WKWebsiteDataStore.nonPersistent()

    private let store: any CredentialStore
    private let logger: Logger
    /// In-flight browser-cookie purge from a prior sign-out / invalidation.
    /// Capture awaits it so the clear finishes before a quick re-auth captures.
    private var clearTask: Task<Void, Never>?

    /// Store keys holding a credential; they live in the Keychain. The others
    /// (account email and identity, workspace id) identify the account but
    /// cannot authenticate, so they stay in Application Support files.
    static let secretStoreKeys: Set<String> = ["session"]

    init(config: ProviderAuthConfig, directory: URL? = nil, store: (any CredentialStore)? = nil) {
        self.config = config
        self.logger = Logger(category: config.logCategory)
        if let store {
            self.store = store
        } else if let directory {
            self.store = FileBackedCredentialStore(directory: directory, filenamePrefix: config.storeFilenamePrefix)
        } else {
            self.store = SecretRoutingCredentialStore.live(
                filenamePrefix: config.storeFilenamePrefix,
                secretKeys: Self.secretStoreKeys
            )
        }
        // `refreshFromDisk()` derives `needsSignIn` from the stored credentials.
        refreshFromDisk()
    }

    /// Reloads persisted credentials into sign-in state and advances `sessionGeneration`.
    func refreshFromDisk() {
        let cookies = loadCookieHeader()
        isSignedIn = !(cookies?.isEmpty ?? true)
        accountEmail = loadEmail()
        needsSignIn = !isSignedIn
        consecutiveAuthFailures = 0
        sessionGeneration += 1
    }

    /// Counts a rejection of the live session and invalidates it once
    /// `authFailureThreshold` rejections arrive in a row.
    ///
    /// - Returns: `true` when this rejection invalidated the session.
    @discardableResult
    func recordAuthFailure(reason: String) -> Bool {
        consecutiveAuthFailures += 1
        guard consecutiveAuthFailures >= Self.authFailureThreshold else {
            let count = consecutiveAuthFailures
            let threshold = Self.authFailureThreshold
            logger.info("\(self.config.logCategory, privacy: .public) auth rejection \(count, privacy: .public) of \(threshold, privacy: .public)")
            return false
        }
        markSessionInvalid(reason: reason)
        return true
    }

    /// Resets the rejection count after the live session authenticated.
    func recordAuthSuccess() {
        consecutiveAuthFailures = 0
    }

    /// Marks the session invalid (e.g. repeated 401s) and clears both disk
    /// credentials and browser cookies, so "Sign in again" starts from a clean
    /// session. Usage history is kept: `accountReset` stays
    /// silent, and the stored account identity survives for the next capture.
    func markSessionInvalid(reason: String? = nil) {
        needsSignIn = true
        if let reason { lastAuthError = reason }
        clearBrowserState()
        isSignedIn = false
        accountEmail = nil
        consecutiveAuthFailures = 0
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
            // A stored jar can carry SSO cookies from another account (e.g. an X
            // session in the Grok jar).
            writeStore(key: "session", value: pruned)
        }
        return pruned
    }

    /// Narrows a stored `Cookie:` header to the provider's essential cookies.
    /// Narrows only when one of them is present; a stored jar without any
    /// essential cookie is sent as-is for the server to accept or reject. Prefixed
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
    /// into the stored header, keeping a rolling session cookie (NextAuth renews
    /// `__Secure-next-auth.session-token` on every `/api/auth/session` call)
    /// valid while the user is signed in. Writes the store directly and leaves
    /// `sessionGeneration` unchanged, so a poll in flight keeps its own session.
    ///
    /// Each value may hold several cookies folded into one comma-joined header,
    /// as `HTTPURLResponse` reports them; Foundation's parser splits them and
    /// reads `Expires` dates. A cookie with an empty value or an expiry at or
    /// before `now` (`Max-Age=0`) deletes the stored cookie. A renewed member of
    /// a chunked family (`…session-token.0`, `.1`) replaces every stored member
    /// of that family, so the chunks always come from the same token.
    func applyRefreshedCookies(_ setCookieHeaders: [String], now: Date = Date()) {
        guard !setCookieHeaders.isEmpty,
              let stored = readStore(key: "session"),
              let host = config.signOutHosts.first,
              let url = URL(string: "https://\(host)/") else { return }
        let policy = config.capturePolicy
        var latest: [String: HTTPCookie] = [:]
        var order: [String] = []
        for raw in setCookieHeaders {
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: url)
                where policy.isEssential(cookie.name) {
                let key = cookie.name.lowercased()
                if latest[key] == nil { order.append(key) }
                latest[key] = cookie
            }
        }
        guard !order.isEmpty else { return }
        let refreshed = order.compactMap { latest[$0] }
        let isLive: (HTTPCookie) -> Bool = { cookie in
            !cookie.value.isEmpty && (cookie.expiresDate.map { $0 > now } ?? true)
        }
        let renewedFamilies = Set(refreshed.filter(isLive).compactMap { policy.essentialFamily(of: $0.name) })
        var pairs = Self.cookiePairs(stored).filter { pair in
            let key = pair.name.lowercased()
            if latest[key] != nil { return true }
            guard let family = policy.essentialFamily(of: pair.name) else { return true }
            return !renewedFamilies.contains(family)
        }
        for cookie in refreshed {
            let key = cookie.name.lowercased()
            let index = pairs.firstIndex { $0.name.lowercased() == key }
            switch (index, isLive(cookie)) {
            case let (index?, true): pairs[index].value = cookie.value
            case (nil, true): pairs.append((cookie.name, cookie.value))
            case let (index?, false): pairs.remove(at: index)
            case (nil, false): break
            }
        }
        let header = pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        guard header != stored else { return }
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

    /// Persists the account email. For providers identified by email, an email
    /// that differs from the previous account's fires `accountReset`.
    func saveAccountEmail(_ email: String) {
        writeStore(key: "email", value: email)
        accountEmail = email
        if config.accountIdentityCookie == nil {
            noteAccountIdentity(email)
        }
    }

    /// Records `identity` as the signed-in account, firing `accountReset` when
    /// it differs from the account the stored history belongs to.
    private func noteAccountIdentity(_ identity: String) {
        let previous = readStore(key: "account")
        guard previous != identity else { return }
        writeStore(key: "account", value: identity)
        if previous != nil {
            logger.info("\(self.config.logCategory, privacy: .public) account changed")
            accountReset.send()
        }
    }

    /// The identity of the account a capture signed in to, when known.
    private func accountIdentity(of result: WebKitCookieCapture.CaptureResult) -> String? {
        guard let cookieName = config.accountIdentityCookie else { return result.email }
        let value = result.cookies.first { $0.name.lowercased() == cookieName }?.value
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    func save(cookieHeader: String) {
        writeStore(key: "session", value: cookieHeader)
        isSignedIn = true
        needsSignIn = false
        consecutiveAuthFailures = 0
        sessionGeneration += 1
    }

    /// Captures the isolated store's session cookies; returns false and records `lastAuthError` when none qualify.
    func captureCookiesFromWebKit() async -> Bool {
        // Finish any pending sign-out purge first so it completes before cookies
        // from a fresh sign-in are captured.
        _ = await clearTask?.value
        guard let result = await WebKitCookieCapture.capture(policy: config.capturePolicy, dataStore: signInDataStore) else {
            lastAuthError = config.capturePolicy.failureMessage
            logger.warning("No auth cookies found after sign-in")
            return false
        }
        adopt(result)
        return true
    }

    /// Stores a capture as the live session and records its account.
    func adopt(_ result: WebKitCookieCapture.CaptureResult) {
        save(cookieHeader: result.cookieHeader)
        // Only the credential store keeps these, so the session stays out of
        // `HTTPCookieStorage.shared`, a shared jar that outlives sign-out and
        // auto-attaches cookies to unrelated requests. Request paths send the
        // captured Cookie header explicitly.
        //
        // The email shown is the captured account's: a capture without one
        // drops the previous account's email until a poll supplies it.
        if let identity = accountIdentity(of: result) {
            noteAccountIdentity(identity)
        }
        if let email = result.email {
            writeStore(key: "email", value: email)
            accountEmail = email
        } else {
            removeStore(key: "email")
            accountEmail = nil
        }

        isSignedIn = true
        needsSignIn = false
        lastAuthError = nil
        logger.info("Captured \(result.cookies.count, privacy: .public) session cookies")
    }

    /// Explicit sign-out: clears credentials, the account identity, and fires
    /// `accountReset` so pollers drop that account's stored history.
    func signOut() {
        clearBrowserState()
        removeStore(key: "account")
        isSignedIn = false
        accountEmail = nil
        needsSignIn = true
        lastAuthError = nil
        consecutiveAuthFailures = 0
        logger.info("\(self.config.logCategory, privacy: .public) signed out")
        accountReset.send()
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
