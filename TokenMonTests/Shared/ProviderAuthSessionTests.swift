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
}
