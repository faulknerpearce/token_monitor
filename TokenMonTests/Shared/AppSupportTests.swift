@testable import TokenMon
import XCTest

final class AppSupportTests: XCTestCase {
    func testDirectoryIsCreatedAsDirectory() throws {
        let dir = AppSupport.directory(subdirectory: "TokenMon-Tests-\(UUID().uuidString)")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testDefaultUsesExpectedSubdirectory() {
        let dir = AppSupport.directory()
        XCTAssertTrue(dir.path.contains("Application Support"))
        XCTAssertEqual(dir.lastPathComponent, AppSupport.directoryName)
    }

    func testMigratesLegacyDirectoryWhenCurrentIsAbsent() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent("tokenmon-migrate-\(UUID().uuidString)", isDirectory: true)
        let legacy = parent.appendingPathComponent(AppSupport.legacyDirectoryName, isDirectory: true)
        let current = parent.appendingPathComponent(AppSupport.directoryName, isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("session".utf8).write(to: legacy.appendingPathComponent("auth_session.dat"))

        AppSupport.migrateLegacyDirectoryIfNeeded(from: legacy, to: current)

        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent("auth_session.dat").path))
        try? fm.removeItem(at: parent)
    }

    func testDoesNotOverwriteExistingCurrentDirectory() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent("tokenmon-no-clobber-\(UUID().uuidString)", isDirectory: true)
        let legacy = parent.appendingPathComponent(AppSupport.legacyDirectoryName, isDirectory: true)
        let current = parent.appendingPathComponent(AppSupport.directoryName, isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: legacy.appendingPathComponent("legacy.dat"))
        try Data("new".utf8).write(to: current.appendingPathComponent("current.dat"))

        AppSupport.migrateLegacyDirectoryIfNeeded(from: legacy, to: current)

        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("legacy.dat").path))
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent("current.dat").path))
        XCTAssertFalse(fm.fileExists(atPath: current.appendingPathComponent("legacy.dat").path))
        try? fm.removeItem(at: parent)
    }

    /// The OpenCode database path resolves to the account's home directory,
    /// from any thread.
    func testRealHomeDirectoryIsTheUserHome() async {
        let expected = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let fromDetached = await Task.detached { OpenCodeLocalStats.realHomeDirectory.standardizedFileURL.path }.value
        XCTAssertEqual(fromDetached, expected)
    }
}
