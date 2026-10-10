@testable import TokenMon
import XCTest

/// One-time removal of the legacy URLCache files, run against a temporary
/// caches folder and a throwaway defaults suite.
final class LegacyCacheCleanupTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let bundleID = "com.example.tokenmon-tests"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyCacheCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "LegacyCacheCleanupTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var folder: URL { root.appendingPathComponent(bundleID, isDirectory: true) }

    private func makeLegacyCache() throws -> [URL] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var items: [URL] = []
        for name in ["Cache.db", "Cache.db-shm", "Cache.db-wal"] {
            let file = folder.appendingPathComponent(name)
            try Data("cached".utf8).write(to: file)
            items.append(file)
        }
        let blobs = folder.appendingPathComponent("fsCachedData", isDirectory: true)
        try fileManager.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data("{\"token\":1}".utf8).write(to: blobs.appendingPathComponent("ABC"))
        items.append(blobs)
        return items
    }

    func testRemovesOnlyCacheFilesAndRecordsCompletion() throws {
        let items = try makeLegacyCache()
        let keep = folder.appendingPathComponent("other.dat")
        try Data("keep".utf8).write(to: keep)
        let sibling = root.appendingPathComponent("com.example.other/Cache.db")
        try FileManager.default.createDirectory(
            at: sibling.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: sibling)

        let ran = LegacyCacheCleanup.runOnce(
            defaults: defaults,
            cachesDirectory: root,
            bundleIdentifier: bundleID,
            urlCache: nil
        )

        XCTAssertTrue(ran)
        for item in items {
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.path), item.lastPathComponent)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(defaults.bool(forKey: LegacyCacheCleanup.completedKey))
    }

    func testRunsOnlyOnce() throws {
        XCTAssertTrue(LegacyCacheCleanup.runOnce(
            defaults: defaults,
            cachesDirectory: root,
            bundleIdentifier: bundleID,
            urlCache: nil
        ))
        let items = try makeLegacyCache()
        XCTAssertFalse(LegacyCacheCleanup.runOnce(
            defaults: defaults,
            cachesDirectory: root,
            bundleIdentifier: bundleID,
            urlCache: nil
        ))
        for item in items {
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.path), item.lastPathComponent)
        }
    }

    func testMissingCacheFolderStillCompletes() {
        XCTAssertTrue(LegacyCacheCleanup.runOnce(
            defaults: defaults,
            cachesDirectory: root,
            bundleIdentifier: bundleID,
            urlCache: nil
        ))
        XCTAssertTrue(defaults.bool(forKey: LegacyCacheCleanup.completedKey))
    }

    func testClearsTheGivenURLCache() throws {
        let cache = URLCache(memoryCapacity: 1 << 16, diskCapacity: 0, directory: nil)
        let url = try XCTUnwrap(URL(string: "https://example.com/usage"))
        let request = URLRequest(url: url)
        let response = try XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        )
        cache.storeCachedResponse(CachedURLResponse(response: response, data: Data("{}".utf8)), for: request)
        XCTAssertNotNil(cache.cachedResponse(for: request))

        LegacyCacheCleanup.runOnce(
            defaults: defaults,
            cachesDirectory: root,
            bundleIdentifier: bundleID,
            urlCache: cache
        )

        XCTAssertNil(cache.cachedResponse(for: request))
    }
}
