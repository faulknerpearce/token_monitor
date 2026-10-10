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

/// Credentials stored as one Keychain item per key under a stable service name.
///
/// Values are cached in memory after the first read, so polling does not hit
/// the Keychain (or re-trigger an access prompt) every tick. A read the user
/// refuses is remembered as missing for the rest of the process.
final class KeychainCredentialStore: CredentialStore {
    /// Shared Keychain service for every provider's items.
    static let service = "com.modelmonitor.app.credentials"

    private let backend: any KeychainBackend
    private let service: String
    private let accountPrefix: String
    private let lock = NSLock()
    private var cache: [String: String?] = [:]
    private let logger = Logger(category: "Keychain")

    /// - Parameters:
    ///   - accountPrefix: Per-provider prefix; the item account is `prefix + key`
    ///     (e.g. `chatgpt_auth_session`), matching the legacy file name.
    init(
        accountPrefix: String,
        service: String = KeychainCredentialStore.service,
        backend: any KeychainBackend = SecItemKeychainBackend()
    ) {
        self.accountPrefix = accountPrefix
        self.service = service
        self.backend = backend
    }

    func value(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let value = readItem(forKey: key)
        cache[key] = value
        return value
    }

    /// Writes the item and reads it back; the value is cached only when the
    /// read-back matches.
    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let account = accountPrefix + key
        let data = Data(value.utf8)
        var status = backend.update(service: service, account: account, data: data)
        if status == errSecItemNotFound {
            status = backend.add(service: service, account: account, data: data)
        }
        guard status == errSecSuccess else {
            logger.error("Keychain write failed for \(account, privacy: .public): \(status, privacy: .public)")
            cache[key] = nil
            return false
        }
        guard readItem(forKey: key) == value else {
            logger.error("Keychain read-back mismatch for \(account, privacy: .public)")
            cache[key] = nil
            return false
        }
        cache[key] = .some(value)
        return true
    }

    func remove(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        let account = accountPrefix + key
        let status = backend.delete(service: service, account: account)
        if status != errSecSuccess, status != errSecItemNotFound {
            logger.error("Keychain delete failed for \(account, privacy: .public): \(status, privacy: .public)")
        }
        cache[key] = .some(nil)
    }

    private func readItem(forKey key: String) -> String? {
        let account = accountPrefix + key
        let (status, data) = backend.read(service: service, account: account)
        switch status {
        case errSecSuccess:
            return data.flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound:
            return nil
        default:
            logger.error("Keychain read failed for \(account, privacy: .public): \(status, privacy: .public)")
            return nil
        }
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
