import Foundation
import os

/// One-time removal of the on-disk HTTP cache written when provider requests
/// went through `URLSession.shared`, which can hold authenticated JSON
/// responses.
///
/// Only the `URLCache` files inside `<Caches>/<bundle id>/` are deleted:
/// `Cache.db`, its `-shm`/`-wal` journals, and `fsCachedData/`. A defaults
/// flag records completion, so later launches do nothing.
enum LegacyCacheCleanup {
    static let completedKey = "legacyURLCacheRemoved"

    /// File and folder names `URLCache` writes in the bundle's cache folder.
    static let cacheItemNames = ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"]

    private static let logger = Logger(category: "Cache")

    /// Clears `urlCache` and deletes the legacy cache files under
    /// `cachesDirectory/bundleIdentifier` unless `defaults` records a previous
    /// run. Returns true when the cleanup ran.
    @discardableResult
    static func runOnce(
        defaults: UserDefaults = .standard,
        cachesDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        urlCache: URLCache? = .shared
    ) -> Bool {
        guard !defaults.bool(forKey: completedKey) else { return false }
        urlCache?.removeAllCachedResponses()
        if let cachesDirectory, let bundleIdentifier, !bundleIdentifier.isEmpty {
            let folder = cachesDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)
            removeCacheItems(in: folder)
        }
        defaults.set(true, forKey: completedKey)
        return true
    }

    private static func removeCacheItems(in folder: URL) {
        let fileManager = FileManager.default
        for name in cacheItemNames {
            let item = folder.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: item.path) else { continue }
            do {
                try fileManager.removeItem(at: item)
            } catch {
                logger.error("Could not remove cached \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
