@testable import TokenMon
import XCTest

@MainActor
final class ProviderAuthSessionTests: XCTestCase {
    private func makeConfig(
        filenamePrefix: String = "auth_",
        essential: Set<String> = [],
        essentialPrefixes: Set<String> = []
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
            isDomain: { _ in false }
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
        // Disk key is removed, so the in-memory email must be cleared too —
        // otherwise stale PII remains readable while signed out.
        XCTAssertNil(auth.accountEmail)
    }

    /// A refresh captures `sessionGeneration` before its await; a sign-out or
    /// account switch must make that capture stale so it cannot publish.
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

    /// A jar written before the allowlist existed is narrowed on load, so an
    /// unrelated SSO session cannot survive in the file store.
    func testLoadNarrowsLegacyCookieJarToAllowlist() {
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
    /// JWT into `…session-token.0`, `.1`, and an exact-name match would drop the
    /// session while keeping an unrelated cookie that shares the allowlist.
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
}
