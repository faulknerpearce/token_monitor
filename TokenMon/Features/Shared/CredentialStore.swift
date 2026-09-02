import Foundation

/// Persistence for provider credentials (session cookies, bearer tokens, API keys).
///
/// Auth sessions depend on this protocol so a Keychain-backed store can replace
/// the file backend in release builds without touching provider logic.
protocol CredentialStore {
    func value(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
    func remove(forKey key: String)
}

/// Application Support files with mode `0600` — the current production backend.
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

    func set(_ value: String, forKey key: String) {
        backing.set(value, forKey: key)
    }

    func remove(forKey key: String) {
        backing.remove(forKey: key)
    }
}
