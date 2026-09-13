@testable import TokenMon
import XCTest

/// Exercises the `CredentialStore` seam the auth sessions depend on, including
/// the file-backed backend and injection through `ProviderAuthSession`.
@MainActor
final class CredentialStoreTests: XCTestCase {
    private final class InMemoryStore: CredentialStore {
        var values: [String: String] = [:]
        func value(forKey key: String) -> String? { values[key] }
        func set(_ value: String, forKey key: String) { values[key] = value }
        func remove(forKey key: String) { values.removeValue(forKey: key) }
    }

    private func makeConfig() -> ProviderAuthConfig {
        ProviderAuthConfig(
            storeFilenamePrefix: "auth_",
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

    func testInjectedStoreBacksSession() {
        let store = InMemoryStore()
        let auth = ProviderAuthSession(config: makeConfig(), store: store)

        auth.save(cookieHeader: "sid=abc")
        XCTAssertEqual(store.values["session"], "sid=abc")
        XCTAssertTrue(auth.isSignedIn)

        // A fresh session over the same store sees the persisted cookie.
        let reloaded = ProviderAuthSession(config: makeConfig(), store: store)
        XCTAssertEqual(reloaded.loadCookieHeader(), "sid=abc")
        XCTAssertTrue(reloaded.isSignedIn)
    }

    func testSignOutRemovesCredentialThroughStore() {
        let store = InMemoryStore()
        let auth = ProviderAuthSession(config: makeConfig(), store: store)
        auth.save(cookieHeader: "sid=abc")
        auth.saveAccountEmail("user@example.com")

        auth.signOut()

        XCTAssertNil(store.values["session"])
        XCTAssertNil(store.values["email"])
        XCTAssertFalse(auth.isSignedIn)
    }

    func testFileBackedCredentialStoreDelegates() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileBackedCredentialStore(directory: dir, filenamePrefix: "openrouter_auth_")
        XCTAssertNil(store.value(forKey: "key"))
        store.set("sk-or-v1-secret", forKey: "key")
        XCTAssertEqual(store.value(forKey: "key"), "sk-or-v1-secret")
        store.remove(forKey: "key")
        XCTAssertNil(store.value(forKey: "key"))
    }

    func testFilePermissionsAreUserOnly() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileBackedStringStore(directory: dir, filenamePrefix: "auth_")
        store.set("secret", forKey: "session")

        let url = dir.appendingPathComponent("auth_session.dat")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o600)
    }
}
