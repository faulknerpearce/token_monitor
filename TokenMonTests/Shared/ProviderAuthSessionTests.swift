@testable import TokenMon
import XCTest

@MainActor
final class ProviderAuthSessionTests: XCTestCase {
    private func makeConfig(filenamePrefix: String = "auth_") -> ProviderAuthConfig {
        ProviderAuthConfig(
            storeFilenamePrefix: filenamePrefix,
            logCategory: "TestAuth",
            usesBearerToken: false,
            extraStoreKeys: [],
            signOutHosts: ["example.com"],
            capturePolicy: WebKitCookieCapture.Policy(
                isDomain: { _ in false },
                looksLikeAuthCookie: { _ in false },
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
}
