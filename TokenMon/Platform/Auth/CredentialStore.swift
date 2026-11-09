import Foundation
import os
import Security

/// Persistence for provider credentials (session cookies, bearer tokens, API keys).
protocol CredentialStore {
    func value(forKey key: String) -> String?
    /// Persists `value`.
    ///
    /// - Throws: `CredentialStoreError` when the write did not stick; nothing
    ///   is stored in that case.
    func set(_ value: String, forKey key: String) throws
    func remove(forKey key: String)
}

/// Why a `CredentialStore` refused a write.
///
/// TokenMon never stores a credential unencrypted, so a secret the login
/// Keychain refuses is not saved anywhere: the sign-in fails with this error
/// instead of falling back to a file.
enum CredentialStoreError: Error, LocalizedError, CustomStringConvertible, Equatable {
    /// The login Keychain did not accept the secret, or did not read it back intact.
    case secureStoreRefused
    /// A non-secret label (email, account identity, workspace id) could not be written to its file.
    case fileWriteFailed

    /// User-visible explanation, shown by the sign-in flow.
    var description: String {
        switch self {
        case .secureStoreRefused:
            return "Couldn't save your sign-in securely. TokenMon never stores credentials unencrypted. "
                + "Check your login Keychain, then try again."
        case .fileWriteFailed:
            return "Couldn't save your account details. Check that ~/Library/Application Support/TokenMon "
                + "is writable, then try again."
        }
    }

    var errorDescription: String? {
        description
    }
}

/// Application Support files with mode `0600`.
///
/// - Warning: Plain files, not encrypted. Production code uses this only for
///   labels that cannot authenticate (email, account identity, workspace id);
///   secrets go through `SecretRoutingCredentialStore` to the Keychain.
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

    func set(_ value: String, forKey key: String) throws {
        guard backing.set(value, forKey: key) else { throw CredentialStoreError.fileWriteFailed }
    }

    func remove(forKey key: String) {
        backing.remove(forKey: key)
    }
}

/// Credentials held in process memory only. The XCTest host uses it, so a
/// test run stays isolated from the user's real credentials.
final class InMemoryCredentialStore: CredentialStore {
    private var values: [String: String] = [:]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func value(forKey key: String) -> String? {
        values[key]
    }

    func set(_ value: String, forKey key: String) {
        values[key] = value
    }

    func remove(forKey key: String) {
        values.removeValue(forKey: key)
    }
}

// MARK: - Keychain

/// The `SecItem` calls `KeychainCredentialStore` makes, behind a seam so tests
/// run against an in-memory fake.
protocol KeychainBackend {
    func read(service: String, account: String) -> (status: OSStatus, data: Data?)
    func add(service: String, account: String, data: Data) -> OSStatus
    func update(service: String, account: String, data: Data) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

/// Generic-password items in the login Keychain.
///
/// Items are `kSecClassGenericPassword`, readable after first unlock and kept
/// on this device only. They live in the file-based login Keychain because the
/// data-protection keychain requires a `keychain-access-groups` /
/// application-identifier entitlement backed by a team ID, which an
/// ad-hoc-signed build cannot carry (`SecItemAdd` fails with
/// `errSecMissingEntitlement`).
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
/// per build, shared by every provider.
///
/// Secrets saved as separate items (one per account, same service) are copied
/// in the first time their account is read, and the separate item is deleted
/// when the Keychain allows it. Each account is checked once; the checked list
/// is stored in the item, so a signed-out account stays signed out even when an
/// old separate item remains.
///
/// The item is loaded on first use and cached. When the read fails for any
/// reason other than "not found" (for example the user denied access), the
/// vault reports every account as missing and refuses writes for the rest of
/// the process, so secrets it could not read stay intact. A removal made
/// meanwhile (sign-out, session invalidation) is recorded in `pendingRemovals`
/// and applied the next time the item loads, so the removed secret stays
/// removed.
final class KeychainVault {
    static let shared = KeychainVault(pendingRemovals: .standard)

    /// Defaults key listing accounts removed while the vault was unavailable.
    static let pendingRemovalsKey = "keychainVaultPendingRemovals"

    /// Keychain service of the vault item and of any separate per-account items it adopts.
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
    private let pendingRemovals: UserDefaults?
    private let lock = NSLock()
    private var state = State.unloaded
    private var memoryPendingRemovals: [String] = []
    private let logger = Logger(category: "Keychain")

    /// - Parameter pendingRemovals: Where removals made while the vault is
    ///   unavailable are kept until it loads; nil keeps them in memory only.
    init(
        service: String = KeychainVault.service,
        backend: any KeychainBackend = SecItemKeychainBackend(),
        pendingRemovals: UserDefaults? = nil
    ) {
        self.service = service
        self.backend = backend
        self.pendingRemovals = pendingRemovals
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
        guard case var .loaded(payload) = loadedState() else {
            recordPendingRemoval(account)
            return
        }
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
            applyPendingRemovals()
        }
        return state
    }

    private func storedPendingRemovals() -> [String] {
        guard let pendingRemovals else { return memoryPendingRemovals }
        return pendingRemovals.stringArray(forKey: Self.pendingRemovalsKey) ?? []
    }

    private func storePendingRemovals(_ accounts: [String]) {
        guard let pendingRemovals else {
            memoryPendingRemovals = accounts
            return
        }
        if accounts.isEmpty {
            pendingRemovals.removeObject(forKey: Self.pendingRemovalsKey)
        } else {
            pendingRemovals.set(accounts, forKey: Self.pendingRemovalsKey)
        }
    }

    private func recordPendingRemoval(_ account: String) {
        var accounts = storedPendingRemovals()
        guard !accounts.contains(account) else { return }
        accounts.append(account)
        storePendingRemovals(accounts)
    }

    /// Removes accounts recorded while the vault was unavailable; the record is
    /// cleared once the vault holds none of them.
    private func applyPendingRemovals() {
        let accounts = storedPendingRemovals()
        guard !accounts.isEmpty, case var .loaded(payload) = state else { return }
        var changed = false
        for account in accounts {
            changed = payload.entries.removeValue(forKey: account) != nil || changed
            changed = payload.checkedSeparateItems.insert(account).inserted || changed
            deleteSeparateItem(account: account)
        }
        if !changed || write(payload) {
            storePendingRemovals([])
        }
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
            // Denied or failed: the account reads as signed out and is marked checked.
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

    /// - Throws: `CredentialStoreError.secureStoreRefused` when the vault
    ///   could not be written or did not read back intact.
    func set(_ value: String, forKey key: String) throws {
        guard vault.set(value, forAccount: accountPrefix + key) else {
            throw CredentialStoreError.secureStoreRefused
        }
    }

    func remove(forKey key: String) {
        vault.remove(forAccount: accountPrefix + key)
    }
}

// MARK: - Routing + migration

/// Sends secret keys to a secure store and everything else to a file store.
///
/// A secret is never written to the file store. When the secure store refuses
/// it, `set` throws `CredentialStoreError.secureStoreRefused` and nothing is
/// saved, so the sign-in fails instead of leaving a plaintext copy on disk.
///
/// At init, a secret still held in a legacy `.dat` file (written by an older
/// build) is moved into the secure store, verified by reading it back, and the
/// file is deleted. When the move fails the file is deleted anyway and the
/// secret is removed from the secure store too, so the provider is signed out
/// and the user signs in again. Secret values are never logged.
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
            migrateLegacyFile(key: key)
        }
    }

    func value(forKey key: String) -> String? {
        secretKeys.contains(key) ? secure.value(forKey: key) : files.value(forKey: key)
    }

    /// - Throws: `CredentialStoreError.secureStoreRefused` when `key` is a
    ///   secret and the secure store refused it; `CredentialStoreError` from
    ///   the file store for a non-secret key.
    func set(_ value: String, forKey key: String) throws {
        guard secretKeys.contains(key) else {
            try files.set(value, forKey: key)
            return
        }
        do {
            try secure.set(value, forKey: key)
        } catch {
            logger.error("Keychain refused \(key, privacy: .public); not saved, never written to a file")
            throw CredentialStoreError.secureStoreRefused
        }
    }

    func remove(forKey key: String) {
        if secretKeys.contains(key) {
            secure.remove(forKey: key)
        }
        files.remove(forKey: key)
    }

    /// Moves a secret left in a `.dat` file by an older build into the secure
    /// store. The file is deleted whatever the outcome; when the secure store
    /// refuses the secret, the key is cleared there as well so the provider
    /// reads as signed out rather than holding an older session.
    private func migrateLegacyFile(key: String) {
        guard let legacy = files.value(forKey: key) else { return }
        let moved: Bool
        do {
            try secure.set(legacy, forKey: key)
            moved = secure.value(forKey: key) == legacy
        } catch {
            moved = false
        }
        files.remove(forKey: key)
        if moved {
            logger.info("Moved \(key, privacy: .public) from a file into the Keychain")
        } else {
            secure.remove(forKey: key)
            logger.error("Keychain refused \(key, privacy: .public); deleted the plaintext file, sign-in required")
        }
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
