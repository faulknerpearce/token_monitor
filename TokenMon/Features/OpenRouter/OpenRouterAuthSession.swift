import Combine
import Foundation
import os

/// Stores the user's OpenRouter API key.
///
/// OpenRouter authenticates with a plain bearer key (`sk-or-…`), so this
/// session persists only the key, in the Keychain.
@MainActor
final class OpenRouterAuthSession: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published var needsSignIn = true
    @Published private(set) var lastAuthError: String?

    /// Fires on explicit sign-out; see `ProviderAuthSession.accountReset`.
    let accountReset = PassthroughSubject<Void, Never>()

    /// Rejections of the live key since its last successful request; see
    /// `ProviderAuthSession.authFailureThreshold`.
    private(set) var consecutiveAuthFailures = 0

    /// Monotonic counter identifying the current key state; see
    /// `ProviderAuthSession.sessionGeneration`.
    private(set) var sessionGeneration = 0

    private let store: any CredentialStore
    private let logger = Logger(category: "OpenRouter")

    init(directory: URL? = nil, store: (any CredentialStore)? = nil) {
        if let store {
            self.store = store
        } else if let directory {
            self.store = FileBackedCredentialStore(directory: directory, filenamePrefix: "openrouter_auth_")
        } else {
            self.store = SecretRoutingCredentialStore.live(filenamePrefix: "openrouter_auth_", secretKeys: ["key"])
        }
        refreshFromDisk()
    }

    func refreshFromDisk() {
        isSignedIn = apiKey() != nil
        needsSignIn = !isSignedIn
        consecutiveAuthFailures = 0
        sessionGeneration += 1
    }

    /// Counts a rejection of the live key and marks it invalid once
    /// `ProviderAuthSession.authFailureThreshold` rejections arrive in a row.
    ///
    /// - Returns: `true` when this rejection invalidated the key.
    @discardableResult
    func recordAuthFailure(reason: String) -> Bool {
        consecutiveAuthFailures += 1
        guard consecutiveAuthFailures >= ProviderAuthSession.authFailureThreshold else { return false }
        markSessionInvalid(reason: reason)
        return true
    }

    /// Resets the rejection count after the key authenticated.
    func recordAuthSuccess() {
        consecutiveAuthFailures = 0
    }

    func apiKey() -> String? {
        guard let key = readStore(key: "key"), !key.isEmpty else { return nil }
        return key
    }

    /// True when `generation` still describes the live, usable key.
    func isCurrent(_ generation: Int) -> Bool {
        generation == sessionGeneration && isSignedIn && !needsSignIn
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
        consecutiveAuthFailures = 0
        isSignedIn = true
        needsSignIn = false
        sessionGeneration += 1
        logger.info("OpenRouter API key saved")
        return true
    }

    func markSessionInvalid(reason: String? = nil) {
        needsSignIn = true
        if let reason { lastAuthError = reason }
        isSignedIn = false
        consecutiveAuthFailures = 0
        sessionGeneration += 1
        logger.info("OpenRouter session marked invalid")
    }

    func signOut() {
        removeStore(key: "key")
        isSignedIn = false
        needsSignIn = true
        lastAuthError = nil
        consecutiveAuthFailures = 0
        sessionGeneration += 1
        logger.info("OpenRouter signed out")
        accountReset.send()
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
