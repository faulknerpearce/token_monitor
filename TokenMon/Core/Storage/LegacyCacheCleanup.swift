import Foundation
import os

/// One-time removal of the on-disk HTTP cache and shared cookie jar of
/// `URLSession.shared`. The cache can hold authenticated JSON
/// responses and the jar provider session cookies; provider requests go
/// through `ProviderURLSession`, which keeps neither.
///
/// Each step runs once, recorded by its own defaults flag:
///
/// - **Cache**: clears `URLCache.shared` and deletes only the `URLCache` files in
///   `<Caches>/<bundle id>/` — `Cache.db`, its `-shm`/`-wal` journals, and
///   `fsCachedData/`.
/// - **Cookie jar**: clears `HTTPCookieStorage.shared` and deletes only
///   `<bundle id>.binarycookies` (and its `_tmp_*.dat` write leftovers) in
///   `~/Library/Cookies/` and `~/Library/HTTPStorages/`. The update check, the
///   only other `URLSession.shared` user, needs no cookies.
enum LegacyCacheCleanup {
    static let completedKey = "legacyURLCacheRemoved"
    static let cookieJarRemovedKey = "legacyCookieJarRemoved"

    /// File and folder names `URLCache` writes in the bundle's cache folder.
    static let cacheItemNames = ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"]

    /// Folders under `~/Library` where `HTTPCookieStorage` keeps an app's jar.
    static let cookieJarFolders = ["Cookies", "HTTPStorages"]

    private static let logger = Logger(category: "Cache")

    /// Runs each cleanup step that `defaults` does not record as done.
    ///
    /// - Returns: True when at least one step ran.
    @discardableResult
    static func runOnce(
        defaults: UserDefaults = .standard,
        cachesDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
        libraryDirectory: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        urlCache: URLCache? = .shared,
        cookieStorage: HTTPCookieStorage? = .shared
    ) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        var ran = false
        if !defaults.bool(forKey: completedKey) {
            urlCache?.removeAllCachedResponses()
            if let cachesDirectory {
                let folder = cachesDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)
                remove(cacheItemNames.map { folder.appendingPathComponent($0) })
            }
            defaults.set(true, forKey: completedKey)
            ran = true
        }
        if !defaults.bool(forKey: cookieJarRemovedKey) {
            cookieStorage?.removeCookies(since: .distantPast)
            if let libraryDirectory {
                remove(cookieJarFiles(in: libraryDirectory, bundleIdentifier: bundleIdentifier))
            }
            defaults.set(true, forKey: cookieJarRemovedKey)
            ran = true
        }
        return ran
    }

    /// The jar file and its leftover write files for `bundleIdentifier`.
    private static func cookieJarFiles(in library: URL, bundleIdentifier: String) -> [URL] {
        let jarName = "\(bundleIdentifier).binarycookies"
        let fileManager = FileManager.default
        return cookieJarFolders.flatMap { folderName -> [URL] in
            let folder = library.appendingPathComponent(folderName, isDirectory: true)
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            return names
                .filter { $0 == jarName || ($0.hasPrefix(jarName + "_tmp_") && $0.hasSuffix(".dat")) }
                .map { folder.appendingPathComponent($0) }
        }
    }

    private static func remove(_ items: [URL]) {
        let fileManager = FileManager.default
        for item in items where fileManager.fileExists(atPath: item.path) {
            do {
                try fileManager.removeItem(at: item)
            } catch {
                logger.error("Could not remove \(item.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
