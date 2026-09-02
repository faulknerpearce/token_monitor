import Combine
import Foundation
import os

/// Stores the user's OpenRouter API key.
///
/// OpenRouter authenticates with a plain bearer key (`sk-or-…`) rather than a
/// browser session, so this session skips the WebKit cookie machinery other
/// providers need and persists only the key in the same 0600 file store.
@MainActor
final class OpenRouterAuthSession: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published var needsSignIn = true
    @Published private(set) var lastAuthError: String?

    private let store: any CredentialStore
    private let logger = Logger(category: "OpenRouter")

    init(directory: URL? = nil, store: (any CredentialStore)? = nil) {
        if let store {
            self.store = store
        } else if let directory {
            self.store = FileBackedCredentialStore(directory: directory, filenamePrefix: "openrouter_auth_")
        } else {
            self.store = FileBackedCredentialStore(filenamePrefix: "openrouter_auth_")
        }
        refreshFromDisk()
    }

    func refreshFromDisk() {
        isSignedIn = apiKey() != nil
        needsSignIn = !isSignedIn
    }

    func apiKey() -> String? {
        guard let key = readStore(key: "key"), !key.isEmpty else { return nil }
        return key
    }

    /// Persists a trimmed API key. Returns `false` (without saving) when the
    /// value does not look like an OpenRouter key.
    @discardableResult
    func saveAPIKey(_ rawKey: String) -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            lastAuthError = "Enter an OpenRouter API key."
            return false
        }
        guard Self.looksLikeAPIKey(key) else {
            lastAuthError = "That doesn't look like an OpenRouter key (expected sk-or-…)."
            return false
        }
        writeStore(key: "key", value: key)
        lastAuthError = nil
        isSignedIn = true
        needsSignIn = false
        logger.info("OpenRouter API key saved")
        return true
    }

    func markSessionInvalid(reason: String? = nil) {
        needsSignIn = true
        if let reason { lastAuthError = reason }
        isSignedIn = false
        logger.info("OpenRouter session marked invalid")
    }

    func signOut() {
        removeStore(key: "key")
        isSignedIn = false
        needsSignIn = true
        lastAuthError = nil
        logger.info("OpenRouter signed out")
    }

    static func looksLikeAPIKey(_ key: String) -> Bool {
        key.hasPrefix("sk-or-v1-") || key.hasPrefix("sk-or-")
    }

    // MARK: - Store

    private func writeStore(key storageKey: String, value: String) {
        store.set(value, forKey: storageKey)
    }

    private func readStore(key storageKey: String) -> String? {
        store.value(forKey: storageKey)
    }

    private func removeStore(key storageKey: String) {
        store.remove(forKey: storageKey)
    }
}
