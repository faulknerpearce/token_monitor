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
        func set(_ value: String, forKey key: String) throws {
            guard !failsWrites else { throw CredentialStoreError.secureStoreRefused }
            values[key] = value
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
        try? store.set("sk-or-v1-secret", forKey: "key")
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

    /// A secret in the file store is moved into the secure store and deleted from the file.
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

    /// A refused migration deletes the plaintext file anyway and leaves the
    /// provider signed out, clearing any older secret the secure store held.
    func testMigrationFailureDeletesPlaintextAndSignsOut() {
        let files = InMemoryStore()
        files.values = ["session": "sid=abc", "email": "user@example.com"]
        let secure = InMemoryStore()
        secure.values = ["session": "sid=older"]
        secure.failsWrites = true

        let store = SecretRoutingCredentialStore(secure: secure, files: files, secretKeys: ["session"])

        XCTAssertNil(files.values["session"])
        XCTAssertNil(secure.values["session"])
        XCTAssertNil(store.value(forKey: "session"))
        XCTAssertEqual(files.values["email"], "user@example.com", "labels are not credentials")
    }

    /// A secret the secure store refuses is not saved anywhere and the write throws.
    func testRefusedSecretIsNeverWrittenToFile() {
        let files = InMemoryStore()
        let secure = InMemoryStore()
        secure.failsWrites = true
        let store = SecretRoutingCredentialStore(secure: secure, files: files, secretKeys: ["key"])

        XCTAssertThrowsError(try store.set("sk-or-v1-new", forKey: "key")) { error in
            XCTAssertEqual(error as? CredentialStoreError, .secureStoreRefused)
        }
        XCTAssertTrue(files.values.isEmpty)
        XCTAssertNil(store.value(forKey: "key"))
    }

    /// Non-secret labels keep going to the file store while the Keychain refuses secrets.
    func testLabelsStillSaveWhileSecureStoreRefuses() throws {
        let files = InMemoryStore()
        let secure = InMemoryStore()
        secure.failsWrites = true
        let store = SecretRoutingCredentialStore(secure: secure, files: files, secretKeys: ["session"])

        try store.set("user@example.com", forKey: "email")

        XCTAssertEqual(files.values, ["email": "user@example.com"])
        XCTAssertEqual(store.value(forKey: "email"), "user@example.com")
    }

    /// The user-facing refusal message names the Keychain and the no-plaintext rule.
    func testSecureStoreRefusalMessage() {
        XCTAssertEqual(
            CredentialStoreError.secureStoreRefused.localizedDescription,
            "Couldn't save your sign-in securely. TokenMon never stores credentials unencrypted. "
                + "Check your login Keychain, then try again."
        )
    }

    // MARK: - No plaintext on disk (real files, fake Keychain)

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Fails when any file under `dir` contains one of `secrets`.
    private func assertNoFileContains(
        _ secrets: [String],
        in dir: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        for name in names {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            for secret in secrets where data.range(of: Data(secret.utf8)) != nil {
                XCTFail("\(name) holds secret bytes", file: file, line: line)
            }
        }
    }

    private func makeRoutingStore(
        dir: URL,
        keychain: FakeKeychain,
        prefix: String = "chatgpt_auth_"
    ) -> SecretRoutingCredentialStore {
        SecretRoutingCredentialStore(
            secure: makeStore(prefix, keychain),
            files: FileBackedCredentialStore(directory: dir, filenamePrefix: prefix),
            secretKeys: ["session"]
        )
    }

    /// Launch migration moves a legacy `.dat` secret into the Keychain and deletes the file.
    func testLaunchMigrationLeavesNoPlaintextFile() throws {
        let dir = try makeTempDirectory()
        let legacy = FileBackedStringStore(directory: dir, filenamePrefix: "chatgpt_auth_")
        XCTAssertTrue(legacy.set("sid=legacy-secret", forKey: "session"))
        XCTAssertTrue(legacy.set("user@example.com", forKey: "email"))
        let keychain = FakeKeychain()

        let store = makeRoutingStore(dir: dir, keychain: keychain)

        XCTAssertEqual(store.value(forKey: "session"), "sid=legacy-secret")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["chatgpt_auth_email.dat"])
        try assertNoFileContains(["sid=legacy-secret"], in: dir)
        XCTAssertEqual(KeychainVault(backend: keychain).value(forAccount: "chatgpt_auth_session"), "sid=legacy-secret")
    }

    /// A Keychain that refuses the migration still ends with the plaintext file
    /// deleted and the provider signed out.
    func testRefusedLaunchMigrationDeletesPlaintextFile() throws {
        let dir = try makeTempDirectory()
        let legacy = FileBackedStringStore(directory: dir, filenamePrefix: "chatgpt_auth_")
        XCTAssertTrue(legacy.set("sid=legacy-secret", forKey: "session"))
        XCTAssertTrue(legacy.set("user@example.com", forKey: "email"))
        let keychain = FakeKeychain.refusingAll()

        let store = makeRoutingStore(dir: dir, keychain: keychain)

        XCTAssertNil(store.value(forKey: "session"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["chatgpt_auth_email.dat"])
        try assertNoFileContains(["sid=legacy-secret"], in: dir)
        XCTAssertTrue(keychain.items.isEmpty)
    }

    /// No operation (save, refused save, label write, sign-out) leaves secret bytes in a file.
    func testNoOperationLeavesSecretBytesInFiles() throws {
        let dir = try makeTempDirectory()
        let store = makeRoutingStore(dir: dir, keychain: FakeKeychain())
        let secrets = ["sid=first", "sid=refused"]

        try store.set("sid=first", forKey: "session")
        try store.set("user@example.com", forKey: "email")
        try assertNoFileContains(secrets, in: dir)

        let refusing = makeRoutingStore(dir: dir, keychain: FakeKeychain.refusingAll())
        XCTAssertThrowsError(try refusing.set("sid=refused", forKey: "session"))
        try assertNoFileContains(secrets, in: dir)

        store.remove(forKey: "session")
        XCTAssertNil(store.value(forKey: "session"))
        try assertNoFileContains(secrets, in: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["chatgpt_auth_email.dat"])
    }

    /// A sign-in the Keychain refuses fails with the typed message and stays signed out.
    func testRefusedSignInSurfacesKeychainError() throws {
        let dir = try makeTempDirectory()
        let store = makeRoutingStore(dir: dir, keychain: FakeKeychain.refusingAll(), prefix: "auth_")
        let auth = ProviderAuthSession(config: makeConfig(), store: store)

        XCTAssertFalse(auth.save(cookieHeader: "sid=abc"))

        XCTAssertFalse(auth.isSignedIn)
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertEqual(auth.lastAuthError, CredentialStoreError.secureStoreRefused.description)
        XCTAssertNil(auth.cookieHeader())
        try assertNoFileContains(["sid=abc"], in: dir)
    }

    /// An OpenRouter key the Keychain refuses is not saved and the error is surfaced.
    func testRefusedOpenRouterKeySurfacesKeychainError() throws {
        let dir = try makeTempDirectory()
        let store = SecretRoutingCredentialStore(
            secure: makeStore("openrouter_auth_", FakeKeychain.refusingAll()),
            files: FileBackedCredentialStore(directory: dir, filenamePrefix: "openrouter_auth_"),
            secretKeys: ["key"]
        )
        let auth = OpenRouterAuthSession(store: store)

        XCTAssertFalse(auth.saveAPIKey("sk-or-v1-secret"))

        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(auth.apiKey())
        XCTAssertEqual(auth.lastAuthError, CredentialStoreError.secureStoreRefused.description)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    // MARK: - Keychain store (fake backend)

    private final class FakeKeychain: KeychainBackend {
        var items: [String: Data] = [:]
        var reads = 0
        var addStatus: OSStatus = errSecSuccess
        var deleteStatus: OSStatus?
        var refusedAccounts: Set<String> = []
        var corruptsWrites = false

        /// A Keychain that refuses every write, as when the login Keychain is locked or denied.
        static func refusingAll() -> FakeKeychain {
            let keychain = FakeKeychain()
            keychain.addStatus = errSecInteractionNotAllowed
            return keychain
        }

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

        XCTAssertNoThrow(try chatGPT.set("sid=abc", forKey: "session"))
        XCTAssertNoThrow(try chatGPT.set("sid=def", forKey: "session"))
        XCTAssertNoThrow(try openRouter.set("sk-or-v1-x", forKey: "key"))

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
        XCTAssertNoThrow(try makeStore("auth_", keychain).set("sso=z", forKey: "session"))
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
        XCTAssertNoThrow(try makeStore("auth_", keychain).set("sso=z", forKey: "session"))
        let stored = keychain.items[vaultKey]
        keychain.refusedAccounts = ["vault"]
        let store = makeStore("auth_", keychain)

        XCTAssertNil(store.value(forKey: "session"))
        XCTAssertThrowsError(try store.set("sso=new", forKey: "session"))
        store.remove(forKey: "session")
        XCTAssertEqual(keychain.items[vaultKey], stored)
    }

    /// A sign-out made while the vault could not be read is applied once it loads.
    func testRemovalWhileVaultUnavailableIsAppliedOnNextLoad() throws {
        let suite = "CredentialStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = FakeKeychain()
        XCTAssertNoThrow(try makeStore("auth_", keychain).set("sso=old", forKey: "session"))
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

        XCTAssertThrowsError(try store.set("sso=z", forKey: "session"))
        XCTAssertNil(store.value(forKey: "session"))
    }

    /// A write whose read-back differs is reported as failed: migration
    /// deletes the file and the provider reads as signed out.
    func testKeychainStoreVerifiesWriteByReadingBack() {
        let keychain = FakeKeychain()
        keychain.corruptsWrites = true
        let secure = makeStore("auth_", keychain)
        let files = InMemoryStore()
        files.values = ["session": "sso=z"]

        let store = SecretRoutingCredentialStore(secure: secure, files: files, secretKeys: ["session"])

        XCTAssertNil(files.values["session"])
        XCTAssertNil(store.value(forKey: "session"))
        XCTAssertThrowsError(try store.set("sso=new", forKey: "session"))
        XCTAssertTrue(files.values.isEmpty)
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
