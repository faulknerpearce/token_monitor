@testable import TokenMon
import XCTest

/// One-time removal of the URLCache files and shared cookie jar, run against
/// temporary caches and library folders, a throwaway defaults suite, and
/// private cache and cookie stores.
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
    private var library: URL { root.appendingPathComponent("Library", isDirectory: true) }

    @discardableResult
    private func runCleanup(urlCache: URLCache? = nil, cookieStorage: HTTPCookieStorage? = nil) -> Bool {
        LegacyCacheCleanup.runOnce(
            defaults: defaults,
            cachesDirectory: root,
            libraryDirectory: library,
            bundleIdentifier: bundleID,
            urlCache: urlCache,
            cookieStorage: cookieStorage
        )
    }

    private func write(_ name: String, in folderName: String) throws -> URL {
        let folder = library.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data("jar".utf8).write(to: file)
        return file
    }

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

        let ran = runCleanup()

        XCTAssertTrue(ran)
        for item in items {
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.path), item.lastPathComponent)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(defaults.bool(forKey: LegacyCacheCleanup.completedKey))
    }

    func testRunsOnlyOnce() throws {
        XCTAssertTrue(runCleanup())
        let items = try makeLegacyCache()
        XCTAssertFalse(runCleanup())
        for item in items {
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.path), item.lastPathComponent)
        }
    }

    func testMissingCacheFolderStillCompletes() {
        XCTAssertTrue(runCleanup())
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

        runCleanup(urlCache: cache)

        XCTAssertNil(cache.cachedResponse(for: request))
    }

    func testRemovesOnlyThisAppsCookieJarFiles() throws {
        let jars = [
            try write("\(bundleID).binarycookies", in: "Cookies"),
            try write("\(bundleID).binarycookies", in: "HTTPStorages"),
            try write("\(bundleID).binarycookies_tmp_123.dat", in: "HTTPStorages")
        ]
        let kept = [
            try write("com.example.other.binarycookies", in: "HTTPStorages"),
            try write("\(bundleID).binarycookies.bak", in: "Cookies"),
            try write("httpstorages.sqlite", in: "HTTPStorages/\(bundleID)")
        ]

        XCTAssertTrue(runCleanup())

        for jar in jars {
            XCTAssertFalse(FileManager.default.fileExists(atPath: jar.path), jar.lastPathComponent)
        }
        for file in kept {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
        }
        XCTAssertTrue(defaults.bool(forKey: LegacyCacheCleanup.cookieJarRemovedKey))
    }

    /// The cookie step runs on its own flag, so it still runs once after the
    /// cache step has already been recorded, and never again after that.
    func testCookieJarStepRunsOnceOnItsOwnFlag() throws {
        defaults.set(true, forKey: LegacyCacheCleanup.completedKey)
        let jar = try write("\(bundleID).binarycookies", in: "Cookies")

        XCTAssertTrue(runCleanup())
        XCTAssertFalse(FileManager.default.fileExists(atPath: jar.path))

        let again = try write("\(bundleID).binarycookies", in: "Cookies")
        XCTAssertFalse(runCleanup())
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.path))
    }

    func testClearsTheGivenCookieStorage() {
        let storage = RecordingCookieStorage()

        runCleanup(cookieStorage: storage)

        XCTAssertEqual(storage.removedSince, .distantPast)
    }
}

/// Cookie jar fake that records the clear.
private final class RecordingCookieStorage: HTTPCookieStorage {
    var removedSince: Date?

    override func removeCookies(since date: Date) {
        removedSince = date
    }
}
