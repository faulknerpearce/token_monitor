import Foundation
import os
import Security

/// Persistence for provider credentials (session cookies, bearer tokens, API keys).
protocol CredentialStore {
    func value(forKey key: String) -> String?
    /// Persists `value`; returns `false` when the write did not stick.
    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool
    func remove(forKey key: String)
}

/// Application Support files with mode `0600`.
struct FileBackedCredentialStore: CredentialStore {
    private let backing: FileBackedStringStore

    init(filenamePrefix: String, subdirectory: String = AppSupport.directoryName) {
        backing = FileBackedStringStore(subdirectory: subdirectory, filenamePrefix: filenamePrefix)
    }

    init(directory: URL, filenamePrefix: String) {
        backing = FileBackedStringStore(directory: directory, filenamePrefix: filenamePrefix)
    }

    func value(forKey key: String) -> String? {
        backing.value(forKey: key)
    }

    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        backing.set(value, forKey: key)
    }

    func remove(forKey key: String) {
        backing.remove(forKey: key)
    }
}

/// Credentials held in process memory only. The XCTest host uses it, so a
/// test run never reads, migrates, or writes the user's real credentials.
final class InMemoryCredentialStore: CredentialStore {
    private var values: [String: String] = [:]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func value(forKey key: String) -> String? {
        values[key]
    }

    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        values[key] = value
        return true
    }

    func remove(forKey key: String) {
        values.removeValue(forKey: key)
    }
}

// MARK: - Keychain

/// The `SecItem` calls `KeychainCredentialStore` makes, behind a seam so tests
/// run against an in-memory fake instead of the user's Keychain.
protocol KeychainBackend {
    func read(service: String, account: String) -> (status: OSStatus, data: Data?)
    func add(service: String, account: String, data: Data) -> OSStatus
    func update(service: String, account: String, data: Data) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

/// Generic-password items in the login Keychain.
///
/// Items are `kSecClassGenericPassword`, readable after first unlock and never
/// synced or migrated to another device. The data-protection keychain is not
/// used: it requires a `keychain-access-groups` / application-identifier
/// entitlement backed by a team ID, which an ad-hoc-signed build cannot carry
/// (`SecItemAdd` fails with `errSecMissingEntitlement`).
struct SecItemKeychainBackend: KeychainBackend {
    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrLabel as String] = "TokenMon (\(account))"
        return SecItemAdd(query as CFDictionary, nil)
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        let attributes = [kSecValueData as String: data] as CFDictionary
        return SecItemUpdate(baseQuery(service: service, account: account) as CFDictionary, attributes)
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }
}

/// Every provider secret in a single Keychain item, stored as a JSON object
/// keyed by account (`<prefix><key>`, e.g. `chatgpt_auth_session`).
///
/// An ad-hoc-signed build is identified by its code hash, so the Keychain asks
/// each new build for access to every item it reads. One item means one prompt
/// per build instead of one per provider.
///
/// Secrets saved as separate items (one per account, same service) are copied
/// in the first time their account is read, and the separate item is deleted
/// when the Keychain allows it. Each account is checked once; the checked list
/// is stored in the item, so a signed-out account is not restored from an old
/// separate item.
///
/// The item is loaded on first use and cached. When the read fails for any
/// reason other than "not found" (for example the user denied access), the
/// vault reports every account as missing and refuses writes for the rest of
/// the process, so it never overwrites secrets it could not read.
final class KeychainVault {
    static let shared = KeychainVault()

    /// Keychain service of the vault item and of the separate items it replaces.
    static let service = "com.modelmonitor.app.credentials"
    /// Account of the vault item.
    static let vaultAccount = "vault"

    private struct Payload: Codable, Equatable {
        var entries: [String: String] = [:]
        var checkedSeparateItems: Set<String> = []
    }

    private enum State {
        case unloaded
        case loaded(Payload)
        case unavailable
    }

    private let backend: any KeychainBackend
    private let service: String
    private let lock = NSLock()
    private var state = State.unloaded
    private let logger = Logger(category: "Keychain")

    init(service: String = KeychainVault.service, backend: any KeychainBackend = SecItemKeychainBackend()) {
        self.service = service
        self.backend = backend
    }

    func value(forAccount account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard case let .loaded(payload) = loadedState() else { return nil }
        if let value = payload.entries[account] { return value }
        guard !payload.checkedSeparateItems.contains(account) else { return nil }
        return adoptSeparateItem(account: account, into: payload)
    }

    /// Stores `value` and verifies it by reading the item back.
    @discardableResult
    func set(_ value: String, forAccount account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case var .loaded(payload) = loadedState() else { return false }
        payload.entries[account] = value
        payload.checkedSeparateItems.insert(account)
        return write(payload)
    }

    func remove(forAccount account: String) {
        lock.lock()
        defer { lock.unlock() }
        guard case var .loaded(payload) = loadedState() else { return }
        let hadEntry = payload.entries.removeValue(forKey: account) != nil
        let newlyChecked = payload.checkedSeparateItems.insert(account).inserted
        deleteSeparateItem(account: account)
        guard hadEntry || newlyChecked else { return }
        write(payload)
    }

    // MARK: - Private (call with `lock` held)

    private func loadedState() -> State {
        if case .unloaded = state {
            state = readVault()
        }
        return state
    }

    private func readVault() -> State {
        let (status, data) = backend.read(service: service, account: Self.vaultAccount)
        switch status {
        case errSecSuccess:
            guard let data, let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
                logger.error("Keychain vault is unreadable; credentials stay unavailable")
                return .unavailable
            }
            return .loaded(payload)
        case errSecItemNotFound:
            return .loaded(Payload())
        default:
            logger.error("Keychain vault read failed: \(status, privacy: .public)")
            return .unavailable
        }
    }

    /// Copies a separately stored secret into the vault and returns it.
    private func adoptSeparateItem(account: String, into payload: Payload) -> String? {
        var payload = payload
        let (status, data) = backend.read(service: service, account: account)
        let value: String?
        switch status {
        case errSecSuccess:
            value = data.flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound:
            value = nil
        default:
            // Denied or failed: the account reads as signed out and is not asked for again.
            logger.error("Keychain read failed for \(account, privacy: .public): \(status, privacy: .public)")
            value = nil
        }
        if let value {
            payload.entries[account] = value
        }
        payload.checkedSeparateItems.insert(account)
        if write(payload), value != nil {
            deleteSeparateItem(account: account)
            logger.info("Moved \(account, privacy: .public) into the Keychain vault")
        }
        return value
    }

    private func deleteSeparateItem(account: String) {
        let status = backend.delete(service: service, account: account)
        if status != errSecSuccess, status != errSecItemNotFound {
            logger.info("Separate Keychain item \(account, privacy: .public) left in place: \(status, privacy: .public)")
        }
    }

    /// Writes the vault, reads it back, and updates the cache only when the
    /// read-back matches.
    @discardableResult
    private func write(_ payload: Payload) -> Bool {
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        var status = backend.update(service: service, account: Self.vaultAccount, data: data)
        if status == errSecItemNotFound {
            status = backend.add(service: service, account: Self.vaultAccount, data: data)
        }
        guard status == errSecSuccess else {
            logger.error("Keychain vault write failed: \(status, privacy: .public)")
            return false
        }
        let (readStatus, readBack) = backend.read(service: service, account: Self.vaultAccount)
        guard readStatus == errSecSuccess,
              let readBack,
              (try? JSONDecoder().decode(Payload.self, from: readBack)) == payload else {
            logger.error("Keychain vault read-back mismatch")
            return false
        }
        state = .loaded(payload)
        return true
    }
}

/// One provider's view of the `KeychainVault`: key `k` is account `accountPrefix + k`.
final class KeychainCredentialStore: CredentialStore {
    private let vault: KeychainVault
    private let accountPrefix: String

    /// - Parameter accountPrefix: Per-provider prefix, matching the provider's
    ///   Application Support file prefix (e.g. `chatgpt_auth_`).
    init(accountPrefix: String, vault: KeychainVault = .shared) {
        self.accountPrefix = accountPrefix
        self.vault = vault
    }

    func value(forKey key: String) -> String? {
        vault.value(forAccount: accountPrefix + key)
    }

    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        vault.set(value, forAccount: accountPrefix + key)
    }

    func remove(forKey key: String) {
        vault.remove(forAccount: accountPrefix + key)
    }
}

// MARK: - Routing + migration

/// Sends secret keys to a secure store and everything else to a file store,
/// moving any secret still held in a legacy file into the secure store.
///
/// Migration copies the file value into the secure store, which verifies it by
/// reading it back, and only then deletes the file. When the secure write
/// fails the file is kept and keeps serving reads and writes, so a Keychain
/// problem never signs the user out.
final class SecretRoutingCredentialStore: CredentialStore {
    private let secure: any CredentialStore
    private let files: any CredentialStore
    private let secretKeys: Set<String>
    private let logger = Logger(category: "Keychain")

    init(secure: any CredentialStore, files: any CredentialStore, secretKeys: Set<String>) {
        self.secure = secure
        self.files = files
        self.secretKeys = secretKeys
        for key in secretKeys.sorted() {
            migrateIfNeeded(key: key)
        }
    }

    func value(forKey key: String) -> String? {
        guard secretKeys.contains(key) else { return files.value(forKey: key) }
        if let legacy = files.value(forKey: key) {
            // Migration failed earlier; the file stays authoritative.
            return legacy
        }
        return secure.value(forKey: key)
    }

    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        guard secretKeys.contains(key) else { return files.set(value, forKey: key) }
        if secure.set(value, forKey: key) {
            files.remove(forKey: key)
            return true
        }
        logger.error("Keeping \(key, privacy: .public) in the file store; Keychain write failed")
        return files.set(value, forKey: key)
    }

    func remove(forKey key: String) {
        if secretKeys.contains(key) {
            secure.remove(forKey: key)
        }
        files.remove(forKey: key)
    }

    private func migrateIfNeeded(key: String) {
        guard let legacy = files.value(forKey: key) else { return }
        guard secure.set(legacy, forKey: key), secure.value(forKey: key) == legacy else {
            logger.error("Keychain migration failed for \(key, privacy: .public); keeping the file")
            return
        }
        files.remove(forKey: key)
        logger.info("Moved \(key, privacy: .public) into the Keychain")
    }
}

extension SecretRoutingCredentialStore {
    /// Production store for a provider: `secretKeys` in the Keychain, other
    /// keys (account email, workspace id) in `<prefix><key>.dat` files.
    static func live(filenamePrefix: String, secretKeys: Set<String>) -> SecretRoutingCredentialStore {
        SecretRoutingCredentialStore(
            secure: KeychainCredentialStore(accountPrefix: filenamePrefix),
            files: FileBackedCredentialStore(filenamePrefix: filenamePrefix),
            secretKeys: secretKeys
        )
    }
}
