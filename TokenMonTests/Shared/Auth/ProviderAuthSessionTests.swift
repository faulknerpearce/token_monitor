import Combine
@testable import TokenMon
import XCTest

@MainActor
final class ProviderAuthSessionTests: XCTestCase {
    private func makeConfig(
        filenamePrefix: String = "auth_",
        essential: Set<String> = [],
        essentialPrefixes: Set<String> = [],
        accountIdentityCookie: String? = nil
    ) -> ProviderAuthConfig {
        ProviderAuthConfig(
            storeFilenamePrefix: filenamePrefix,
            logCategory: "TestAuth",
            extraStoreKeys: [],
            signOutHosts: ["example.com"],
            capturePolicy: WebKitCookieCapture.Policy(
                isDomain: { _ in false },
                looksLikeAuthCookie: { _ in false },
                essentialCookieNames: essential,
                essentialCookiePrefixes: essentialPrefixes,
                failureMessage: "no cookie"
            ),
            isDomain: { _ in false },
            accountIdentityCookie: accountIdentityCookie
        )
    }

    func testStartsWithSignedOutState() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let auth = ProviderAuthSession(
            config: makeConfig(),
            directory: dir
        )
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertNil(auth.accountEmail)
    }

    func testSaveAndLoadAccountEmailPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let auth = ProviderAuthSession(config: makeConfig(), directory: dir)
        auth.saveAccountEmail("user@example.com")
        XCTAssertEqual(auth.accountEmail, "user@example.com")

        // A fresh instance reading the same directory observes the persisted email.
        let reloaded = ProviderAuthSession(config: makeConfig(), directory: dir)
        reloaded.refreshFromDisk()
        XCTAssertEqual(reloaded.accountEmail, "user@example.com")
    }

    func testMarkSessionInvalidClearsState() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let auth = ProviderAuthSession(config: makeConfig(), directory: dir)
        auth.saveAccountEmail("user@example.com")
        auth.markSessionInvalid(reason: "401")
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertEqual(auth.lastAuthError, "401")
        // Disk key is removed and the in-memory email is cleared with it, so no
        // PII stays readable while signed out.
        XCTAssertNil(auth.accountEmail)
    }

    /// A refresh captures `sessionGeneration` before its await; a sign-out or
    /// account switch makes that capture stale so it cannot publish.
    func testGenerationInvalidatesInFlightRefresh() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let auth = ProviderAuthSession(config: makeConfig(), directory: dir)
        auth.save(cookieHeader: "session=abc")
        let generation = auth.sessionGeneration
        XCTAssertTrue(auth.isCurrent(generation))

        auth.signOut()
        XCTAssertFalse(auth.isCurrent(generation))

        // A successful re-auth mints a new generation; the old capture stays stale.
        auth.save(cookieHeader: "session=def")
        XCTAssertTrue(auth.isCurrent(auth.sessionGeneration))
        XCTAssertFalse(auth.isCurrent(generation))
    }

    /// `isCurrent` is false while the session needs sign-in even if the
    /// generation has not moved (e.g. a pre-fetch guard).
    func testIsCurrentRequiresUsableSession() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let auth = ProviderAuthSession(config: makeConfig(), directory: dir)
        auth.save(cookieHeader: "session=abc")
        auth.needsSignIn = true
        XCTAssertFalse(auth.isCurrent(auth.sessionGeneration))
    }

    /// A stored jar holding cookies outside the allowlist is narrowed on load, so
    /// only the essential cookies stay in the file store.
    func testLoadNarrowsStoredCookieJarToAllowlist() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let auth = ProviderAuthSession(config: makeConfig(essential: ["sso", "sso-rw"]), directory: dir)
        auth.save(cookieHeader: "auth_token=x; ct0=y; sso=z; sso-rw=w; twid=t")

        XCTAssertEqual(auth.cookieHeader(), "sso=z; sso-rw=w")
        // The narrowed header is persisted, not only returned.
        XCTAssertEqual(auth.loadCookieHeader(), "sso=z; sso-rw=w")
    }

    /// A jar without any essential cookie is left untouched.
    func testLoadKeepsJarWhenEssentialsAbsent() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let auth = ProviderAuthSession(config: makeConfig(essential: ["sso"]), directory: dir)
        auth.save(cookieHeader: "auth_token=x; ct0=y")

        XCTAssertEqual(auth.cookieHeader(), "auth_token=x; ct0=y")
    }

    /// A prefixed essential family is kept whole: NextAuth chunks a large session
    /// JWT into `…session-token.0`, `.1`, …, and every chunk is kept while the
    /// CSRF and analytics cookies are dropped.
    func testLoadKeepsChunkedEssentialFamily() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let auth = ProviderAuthSession(
            config: makeConfig(essentialPrefixes: ["__secure-next-auth.session-token"]),
            directory: dir
        )
        auth.save(
            cookieHeader: "__Host-next-auth.csrf-token=c; __Secure-next-auth.session-token.0=a; "
                + "__Secure-next-auth.session-token.1=b; _ga=g"
        )

        XCTAssertEqual(
            auth.cookieHeader(),
            "__Secure-next-auth.session-token.0=a; __Secure-next-auth.session-token.1=b"
        )
    }

    /// A jar with only a non-essential cookie (the CSRF cookie that shares
    /// ChatGPT's sign-in page) is not narrowed to nothing.
    func testLoadLeavesJarWhenOnlyNonEssentialPresent() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let auth = ProviderAuthSession(
            config: makeConfig(essentialPrefixes: ["__secure-next-auth.session-token"]),
            directory: dir
        )
        auth.save(cookieHeader: "__Host-next-auth.csrf-token=c; _ga=g")

        XCTAssertEqual(auth.cookieHeader(), "__Host-next-auth.csrf-token=c; _ga=g")
    }

    // MARK: - Rejection streak

    func testSessionSurvivesRejectionsBelowThreshold() {
        let auth = ProviderAuthSession(config: makeConfig(), store: InMemoryCredentialStore())
        auth.save(cookieHeader: "session=abc")

        for _ in 1..<ProviderAuthSession.authFailureThreshold {
            XCTAssertFalse(auth.recordAuthFailure(reason: "401"))
        }
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(auth.cookieHeader(), "session=abc")

        XCTAssertTrue(auth.recordAuthFailure(reason: "401"))
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertNil(auth.cookieHeader())
    }

    /// A success between rejections restarts the streak.
    func testAuthSuccessResetsRejectionStreak() {
        let auth = ProviderAuthSession(config: makeConfig(), store: InMemoryCredentialStore())
        auth.save(cookieHeader: "session=abc")

        for _ in 1..<ProviderAuthSession.authFailureThreshold {
            auth.recordAuthFailure(reason: "401")
        }
        auth.recordAuthSuccess()
        XCTAssertFalse(auth.recordAuthFailure(reason: "401"))
        XCTAssertTrue(auth.isSignedIn)
    }

    // MARK: - Account reset

    private final class ResetCounter {
        var count = 0
    }

    private func observeResets(_ auth: ProviderAuthSession) -> (ResetCounter, AnyCancellable) {
        let counter = ResetCounter()
        let token = auth.accountReset.sink { counter.count += 1 }
        return (counter, token)
    }

    /// Invalidation keeps history: it does not fire `accountReset`.
    func testInvalidationDoesNotResetAccountData() {
        let auth = ProviderAuthSession(config: makeConfig(), store: InMemoryCredentialStore())
        auth.save(cookieHeader: "session=abc")
        let (resets, token) = observeResets(auth)
        defer { token.cancel() }

        auth.markSessionInvalid(reason: "401")

        XCTAssertEqual(resets.count, 0)
    }

    func testSignOutResetsAccountData() {
        let auth = ProviderAuthSession(config: makeConfig(), store: InMemoryCredentialStore())
        auth.save(cookieHeader: "session=abc")
        let (resets, token) = observeResets(auth)
        defer { token.cancel() }

        auth.signOut()

        XCTAssertEqual(resets.count, 1)
    }

    /// Re-signing in after an expiry as the same account keeps the history; a
    /// different account resets it.
    func testEmailIdentifiedAccountChangeResetsAccountData() {
        let auth = ProviderAuthSession(config: makeConfig(), store: InMemoryCredentialStore())
        auth.save(cookieHeader: "session=a")
        auth.saveAccountEmail("one@example.com")
        let (resets, token) = observeResets(auth)
        defer { token.cancel() }

        auth.markSessionInvalid(reason: "401")
        auth.save(cookieHeader: "session=a2")
        auth.saveAccountEmail("one@example.com")
        XCTAssertEqual(resets.count, 0)

        auth.markSessionInvalid(reason: "401")
        auth.save(cookieHeader: "session=b")
        auth.saveAccountEmail("two@example.com")
        XCTAssertEqual(resets.count, 1)
    }

    private func capture(_ cookies: [(String, String)], email: String?) -> WebKitCookieCapture.CaptureResult {
        let httpCookies = cookies.compactMap { name, value in
            HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: name, .value: value])
        }
        return WebKitCookieCapture.CaptureResult(
            cookies: httpCookies,
            cookieHeader: cookies.map { "\($0.0)=\($0.1)" }.joined(separator: "; "),
            email: email
        )
    }

    /// Claude identifies the account by its org cookie: a capture for another
    /// org resets the stored history.
    func testCookieIdentifiedAccountChangeResetsAccountData() {
        let auth = ProviderAuthSession(
            config: makeConfig(accountIdentityCookie: "lastactiveorg"),
            store: InMemoryCredentialStore()
        )
        auth.adopt(capture([("sessionKey", "k1"), ("lastActiveOrg", "org-1")], email: nil))
        let (resets, token) = observeResets(auth)
        defer { token.cancel() }

        auth.markSessionInvalid(reason: "401")
        auth.adopt(capture([("sessionKey", "k2"), ("lastActiveOrg", "org-1")], email: nil))
        XCTAssertEqual(resets.count, 0)

        auth.adopt(capture([("sessionKey", "k3"), ("lastActiveOrg", "org-2")], email: nil))
        XCTAssertEqual(resets.count, 1)
    }

    /// A new capture always replaces the shown email, even with none.
    func testCaptureReplacesPreviousAccountEmail() {
        let store = InMemoryCredentialStore()
        let auth = ProviderAuthSession(config: makeConfig(), store: store)
        auth.adopt(capture([("session", "a")], email: "old@example.com"))
        XCTAssertEqual(auth.accountEmail, "old@example.com")

        auth.adopt(capture([("session", "b")], email: "new@example.com"))
        XCTAssertEqual(auth.accountEmail, "new@example.com")

        auth.adopt(capture([("session", "c")], email: nil))
        XCTAssertNil(auth.accountEmail)
        XCTAssertNil(store.value(forKey: "email"))
    }

    // MARK: - Refreshed Set-Cookie

    private func chatGPTSession(_ header: String) -> (ProviderAuthSession, InMemoryCredentialStore) {
        let store = InMemoryCredentialStore()
        let auth = ProviderAuthSession(
            config: makeConfig(essentialPrefixes: ["__secure-next-auth.session-token"]),
            store: store
        )
        auth.save(cookieHeader: header)
        return (auth, store)
    }

    /// Foundation folds repeated `Set-Cookie` headers into one comma-joined
    /// value; every cookie in it is applied, including `Expires` dates that
    /// themselves contain a comma.
    func testRefreshedCookiesParseCommaFoldedHeader() {
        let (auth, _) = chatGPTSession(
            "__Secure-next-auth.session-token.0=old0; __Secure-next-auth.session-token.1=old1"
        )
        let folded = "__Secure-next-auth.session-token.0=new0; Path=/; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Secure; HttpOnly, "
            + "__Secure-next-auth.session-token.1=new1; Path=/; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Secure; HttpOnly, "
            + "_ga=tracker; Path=/"
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/api/auth/session")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Set-Cookie": folded]
        )
        let headers = response.map { ProviderHTTP.setCookieHeaders(from: $0) } ?? []

        auth.applyRefreshedCookies(headers)

        XCTAssertEqual(
            auth.cookieHeader(),
            "__Secure-next-auth.session-token.0=new0; __Secure-next-auth.session-token.1=new1"
        )
    }

    /// A deletion cookie (`Max-Age=0`) removes the stored cookie.
    func testRefreshedDeletionCookieRemovesChunk() {
        let (auth, _) = chatGPTSession(
            "__Secure-next-auth.session-token.0=a; __Secure-next-auth.session-token.1=b"
        )
        auth.applyRefreshedCookies([
            "__Secure-next-auth.session-token.0=whole; Path=/; Secure, "
                + "__Secure-next-auth.session-token.1=; Path=/; Max-Age=0"
        ])

        XCTAssertEqual(auth.cookieHeader(), "__Secure-next-auth.session-token.0=whole")
    }

    /// A renewed unchunked token replaces every stored chunk,
    /// so an old `.1` is never paired with a new token.
    func testRenewedUnchunkedTokenReplacesStoredChunks() {
        let (auth, _) = chatGPTSession(
            "__Secure-next-auth.session-token.0=a; __Secure-next-auth.session-token.1=b"
        )
        auth.applyRefreshedCookies(["__Secure-next-auth.session-token=whole; Path=/; Secure; HttpOnly"])

        XCTAssertEqual(auth.cookieHeader(), "__Secure-next-auth.session-token=whole")
    }

    /// A cookie expiring in the past is a deletion too.
    func testRefreshedPastExpiryRemovesCookie() {
        let (auth, _) = chatGPTSession("__Secure-next-auth.session-token=a")
        auth.applyRefreshedCookies(["__Secure-next-auth.session-token=a; Expires=Thu, 01 Jan 1970 00:00:00 GMT"])

        XCTAssertEqual(auth.cookieHeader(), "")
    }
}
