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
        var deleteStatus: OSStatus?
        var refusedAccounts: Set<String> = []
        var corruptsWrites = false

        func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
            reads += 1
            if refusedAccounts.contains(account) { return (errSecAuthFailed, nil) }
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
            if let deleteStatus { return deleteStatus }
            return items.removeValue(forKey: "\(service)/\(account)") == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    private let vaultKey = "com.modelmonitor.app.credentials/vault"

    private func makeStore(_ prefix: String, _ keychain: FakeKeychain) -> KeychainCredentialStore {
        KeychainCredentialStore(accountPrefix: prefix, vault: KeychainVault(backend: keychain))
    }

    /// Every provider's secret lives in the one vault item.
    func testProvidersShareOneVaultItem() {
        let keychain = FakeKeychain()
        let vault = KeychainVault(backend: keychain)
        let chatGPT = KeychainCredentialStore(accountPrefix: "chatgpt_auth_", vault: vault)
        let openRouter = KeychainCredentialStore(accountPrefix: "openrouter_auth_", vault: vault)

        XCTAssertTrue(chatGPT.set("sid=abc", forKey: "session"))
        XCTAssertTrue(chatGPT.set("sid=def", forKey: "session"))
        XCTAssertTrue(openRouter.set("sk-or-v1-x", forKey: "key"))

        XCTAssertEqual(Set(keychain.items.keys), [vaultKey])
        XCTAssertEqual(chatGPT.value(forKey: "session"), "sid=def")
        XCTAssertEqual(openRouter.value(forKey: "key"), "sk-or-v1-x")

        // A fresh vault over the same Keychain sees both secrets.
        let reloaded = KeychainVault(backend: keychain)
        XCTAssertEqual(reloaded.value(forAccount: "chatgpt_auth_session"), "sid=def")
        chatGPT.remove(forKey: "session")
        XCTAssertNil(chatGPT.value(forKey: "session"))
        XCTAssertNil(KeychainVault(backend: keychain).value(forAccount: "chatgpt_auth_session"))
        XCTAssertEqual(openRouter.value(forKey: "key"), "sk-or-v1-x")
    }

    /// The vault is read once; later lookups come from memory.
    func testVaultCachesReads() {
        let keychain = FakeKeychain()
        XCTAssertTrue(makeStore("auth_", keychain).set("sso=z", forKey: "session"))
        let store = makeStore("auth_", keychain)
        keychain.reads = 0

        XCTAssertEqual(store.value(forKey: "session"), "sso=z")
        XCTAssertEqual(store.value(forKey: "session"), "sso=z")
        XCTAssertEqual(keychain.reads, 1)
    }

    /// A separately stored secret is copied into the vault and the separate item deleted.
    func testSeparateItemMovesIntoVault() {
        let keychain = FakeKeychain()
        keychain.items["com.modelmonitor.app.credentials/opencode_auth_session"] = Data("auth=1".utf8)
        let store = makeStore("opencode_auth_", keychain)

        XCTAssertEqual(store.value(forKey: "session"), "auth=1")

        XCTAssertEqual(Set(keychain.items.keys), [vaultKey])
        XCTAssertEqual(KeychainVault(backend: keychain).value(forAccount: "opencode_auth_session"), "auth=1")
    }

    /// A separate item the Keychain will not delete is not restored after sign-out.
    func testSignedOutAccountIsNotRestoredFromSeparateItem() {
        let keychain = FakeKeychain()
        keychain.items["com.modelmonitor.app.credentials/opencode_auth_session"] = Data("auth=1".utf8)
        keychain.deleteStatus = errSecInvalidOwnerEdit
        let store = makeStore("opencode_auth_", keychain)
        XCTAssertEqual(store.value(forKey: "session"), "auth=1")

        store.remove(forKey: "session")

        XCTAssertNil(store.value(forKey: "session"))
        XCTAssertNil(makeStore("opencode_auth_", keychain).value(forKey: "session"))
    }

    /// A refused separate item reads as signed out and is not asked for again.
    func testRefusedSeparateItemIsNotRetried() {
        let keychain = FakeKeychain()
        keychain.items["com.modelmonitor.app.credentials/auth_session"] = Data("sso=z".utf8)
        keychain.refusedAccounts = ["auth_session"]
        let store = makeStore("auth_", keychain)

        XCTAssertNil(store.value(forKey: "session"))
        let reads = keychain.reads
        XCTAssertNil(store.value(forKey: "session"))
        XCTAssertNil(makeStore("auth_", keychain).value(forKey: "session"))
        XCTAssertEqual(keychain.reads, reads + 1, "only the fresh vault's own read")
    }

    /// A refused vault read reports secrets as missing and never overwrites the item.
    func testRefusedVaultIsNeverOverwritten() {
        let keychain = FakeKeychain()
        XCTAssertTrue(makeStore("auth_", keychain).set("sso=z", forKey: "session"))
        let stored = keychain.items[vaultKey]
        keychain.refusedAccounts = ["vault"]
        let store = makeStore("auth_", keychain)

        XCTAssertNil(store.value(forKey: "session"))
        XCTAssertFalse(store.set("sso=new", forKey: "session"))
        store.remove(forKey: "session")
        XCTAssertEqual(keychain.items[vaultKey], stored)
    }

    /// A sign-out made while the vault could not be read is applied once it loads.
    func testRemovalWhileVaultUnavailableIsAppliedOnNextLoad() throws {
        let suite = "CredentialStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = FakeKeychain()
        XCTAssertTrue(makeStore("auth_", keychain).set("sso=old", forKey: "session"))
        keychain.refusedAccounts = ["vault"]
        let refused = KeychainCredentialStore(
            accountPrefix: "auth_",
            vault: KeychainVault(backend: keychain, pendingRemovals: defaults)
        )

        refused.remove(forKey: "session")
        XCTAssertEqual(defaults.stringArray(forKey: KeychainVault.pendingRemovalsKey), ["auth_session"])

        keychain.refusedAccounts = []
        let next = KeychainVault(backend: keychain, pendingRemovals: defaults)
        XCTAssertNil(next.value(forAccount: "auth_session"))
        XCTAssertNil(KeychainVault(backend: keychain).value(forAccount: "auth_session"))
        XCTAssertNil(defaults.stringArray(forKey: KeychainVault.pendingRemovalsKey))
    }

    func testKeychainStoreReportsFailedWrite() {
        let keychain = FakeKeychain()
        keychain.addStatus = errSecInteractionNotAllowed
        let store = makeStore("auth_", keychain)

        XCTAssertFalse(store.set("sso=z", forKey: "session"))
        XCTAssertNil(store.value(forKey: "session"))
    }

    /// A write whose read-back differs is reported as failed, so migration keeps the file.
    func testKeychainStoreVerifiesWriteByReadingBack() {
        let keychain = FakeKeychain()
        keychain.corruptsWrites = true
        let secure = makeStore("auth_", keychain)
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
