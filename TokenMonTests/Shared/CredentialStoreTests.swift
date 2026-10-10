@testable import TokenMon
import XCTest

/// Exercises the `CredentialStore` seam the auth sessions depend on, including
/// the file-backed backend and injection through `ProviderAuthSession`.
@MainActor
final class CredentialStoreTests: XCTestCase {
    private final class InMemoryStore: CredentialStore {
        var values: [String: String] = [:]
        var failsWrites = false
        func value(forKey key: String) -> String? { values[key] }
        func set(_ value: String, forKey key: String) -> Bool {
            guard !failsWrites else { return false }
            values[key] = value
            return true
        }

        func remove(forKey key: String) { values.removeValue(forKey: key) }
    }

    private func makeConfig() -> ProviderAuthConfig {
        ProviderAuthConfig(
            storeFilenamePrefix: "auth_",
            logCategory: "TestAuth",
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

    // MARK: - Secret routing and migration

    /// A legacy secret file is moved into the secure store and deleted.
    func testMigrationMovesSecretFileIntoSecureStore() {
        let files = InMemoryStore()
        files.values = ["session": "sid=abc", "email": "user@example.com"]
        let secure = InMemoryStore()

        let store = SecretRoutingCredentialStore(secure: secure, files: files, secretKeys: ["session"])

        XCTAssertEqual(secure.values["session"], "sid=abc")
        XCTAssertNil(files.values["session"])
        XCTAssertEqual(store.value(forKey: "session"), "sid=abc")
        // Non-secret keys stay file-backed.
        XCTAssertEqual(files.values["email"], "user@example.com")
        XCTAssertNil(secure.values["email"])
    }

    /// A failed secure write keeps the file, which keeps serving the session.
    func testMigrationFailureKeepsFileAndKeepsWorking() {
        let files = InMemoryStore()
        files.values = ["session": "sid=abc"]
        let secure = InMemoryStore()
        secure.failsWrites = true

        let store = SecretRoutingCredentialStore(secure: secure, files: files, secretKeys: ["session"])

        XCTAssertEqual(files.values["session"], "sid=abc")
        XCTAssertEqual(store.value(forKey: "session"), "sid=abc")
        XCTAssertTrue(store.set("sid=new", forKey: "session"))
        XCTAssertEqual(store.value(forKey: "session"), "sid=new")
        XCTAssertEqual(files.values["session"], "sid=new")
    }

    /// A secret written after a failed migration leaves no stale file behind
    /// once the secure store accepts writes again.
    func testSecureWriteRemovesLeftoverFile() {
        let files = InMemoryStore()
        files.values = ["key": "sk-or-v1-old"]
        let secure = InMemoryStore()
        secure.failsWrites = true
        let store = SecretRoutingCredentialStore(secure: secure, files: files, secretKeys: ["key"])

        secure.failsWrites = false
        XCTAssertTrue(store.set("sk-or-v1-new", forKey: "key"))

        XCTAssertNil(files.values["key"])
        XCTAssertEqual(store.value(forKey: "key"), "sk-or-v1-new")
        store.remove(forKey: "key")
        XCTAssertNil(store.value(forKey: "key"))
        XCTAssertNil(secure.values["key"])
    }

    // MARK: - Keychain store (fake backend)

    private final class FakeKeychain: KeychainBackend {
        var items: [String: Data] = [:]
        var reads = 0
        var addStatus: OSStatus = errSecSuccess
        var readStatus: OSStatus?
        var corruptsWrites = false

        func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
            reads += 1
            if let readStatus { return (readStatus, nil) }
            guard let data = items["\(service)/\(account)"] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }

        func add(service: String, account: String, data: Data) -> OSStatus {
            guard addStatus == errSecSuccess else { return addStatus }
            items["\(service)/\(account)"] = corruptsWrites ? Data("garbage".utf8) : data
            return errSecSuccess
        }

        func update(service: String, account: String, data: Data) -> OSStatus {
            guard items["\(service)/\(account)"] != nil else { return errSecItemNotFound }
            items["\(service)/\(account)"] = corruptsWrites ? Data("garbage".utf8) : data
            return errSecSuccess
        }

        func delete(service: String, account: String) -> OSStatus {
            items.removeValue(forKey: "\(service)/\(account)") == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    func testKeychainStoreUsesOneItemPerKeyUnderStableService() {
        let keychain = FakeKeychain()
        let store = KeychainCredentialStore(accountPrefix: "chatgpt_auth_", backend: keychain)

        XCTAssertTrue(store.set("sid=abc", forKey: "session"))
        XCTAssertTrue(store.set("sid=def", forKey: "session"))

        XCTAssertEqual(
            Set(keychain.items.keys),
            ["com.modelmonitor.app.credentials/chatgpt_auth_session"]
        )
        XCTAssertEqual(store.value(forKey: "session"), "sid=def")
        store.remove(forKey: "session")
        XCTAssertNil(store.value(forKey: "session"))
        XCTAssertTrue(keychain.items.isEmpty)
    }

    /// Reads are cached, so polling does not query the Keychain every tick.
    func testKeychainStoreCachesReads() {
        let keychain = FakeKeychain()
        keychain.items["com.modelmonitor.app.credentials/auth_session"] = Data("sso=z".utf8)
        let store = KeychainCredentialStore(accountPrefix: "auth_", backend: keychain)

        XCTAssertEqual(store.value(forKey: "session"), "sso=z")
        XCTAssertEqual(store.value(forKey: "session"), "sso=z")
        XCTAssertEqual(keychain.reads, 1)
    }

    /// A refused read (e.g. the user denied access) is not retried every poll.
    func testKeychainStoreRemembersRefusedRead() {
        let keychain = FakeKeychain()
        keychain.readStatus = errSecAuthFailed
        let store = KeychainCredentialStore(accountPrefix: "auth_", backend: keychain)

        XCTAssertNil(store.value(forKey: "session"))
        XCTAssertNil(store.value(forKey: "session"))
        XCTAssertEqual(keychain.reads, 1)
    }

    func testKeychainStoreReportsFailedWrite() {
        let keychain = FakeKeychain()
        keychain.addStatus = errSecInteractionNotAllowed
        let store = KeychainCredentialStore(accountPrefix: "auth_", backend: keychain)

        XCTAssertFalse(store.set("sso=z", forKey: "session"))
        XCTAssertNil(store.value(forKey: "session"))
    }

    /// A write whose read-back differs is reported as failed, so migration keeps the file.
    func testKeychainStoreVerifiesWriteByReadingBack() {
        let keychain = FakeKeychain()
        keychain.corruptsWrites = true
        let secure = KeychainCredentialStore(accountPrefix: "auth_", backend: keychain)
        let files = InMemoryStore()
        files.values = ["session": "sso=z"]

        let store = SecretRoutingCredentialStore(secure: secure, files: files, secretKeys: ["session"])

        XCTAssertEqual(files.values["session"], "sso=z")
        XCTAssertEqual(store.value(forKey: "session"), "sso=z")
    }

    // MARK: - File store writes

    func testFileStoreFirstWriteIsAtomicAndLeavesNoStagingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileBackedStringStore(directory: dir, filenamePrefix: "activity_")

        XCTAssertTrue(store.set("one", forKey: "k"))
        XCTAssertTrue(store.set("two", forKey: "k"))

        XCTAssertEqual(store.value(forKey: "k"), "two")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["activity_k.dat"])
    }

    func testFileStoreReportsFailedWrite() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("absent", isDirectory: true)
        let store = FileBackedStringStore(directory: missing, filenamePrefix: "auth_")

        XCTAssertFalse(store.set("secret", forKey: "session"))
        XCTAssertNil(store.value(forKey: "session"))
    }
}
