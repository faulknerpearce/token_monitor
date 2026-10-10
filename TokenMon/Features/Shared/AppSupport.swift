import Foundation

/// Centralized access to the app's per-user Application Support directory
/// (created with `0700` permissions).
enum AppSupport {
    /// Current Application Support folder name.
    static let directoryName = "TokenMon"

    /// Model Monitor folder name; its contents move into `directoryName` at launch.
    static let legacyDirectoryName = "ModelMonitor"

    /// True when the process is the XCTest host.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Parent of the app's folder: the user's Application Support directory, or
    /// a per-process temporary directory under XCTest so tests stay isolated
    /// from the user's files.
    static let baseDirectory: URL = {
        let fm = FileManager.default
        if isRunningTests {
            return fm.temporaryDirectory
                .appendingPathComponent("TokenMonTests-\(UUID().uuidString)", isDirectory: true)
        }
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
    }()

    /// The app's Application Support directory (created on demand, `0700`).
    /// Defaults to `~/Library/Application Support/TokenMon` (see `baseDirectory`).
    static func directory(subdirectory: String = directoryName) -> URL {
        let fm = FileManager.default
        let base = baseDirectory
        let dir = base.appendingPathComponent(subdirectory, isDirectory: true)
        if subdirectory == directoryName {
            migrateLegacyDirectoryIfNeeded(
                from: base.appendingPathComponent(legacyDirectoryName, isDirectory: true),
                to: dir
            )
        }
        try? fm.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    /// Moves the legacy `ModelMonitor/` folder onto `TokenMon/` when the new folder is absent.
    ///
    /// No-op if the legacy folder is missing or the current folder already exists.
    static func migrateLegacyDirectoryIfNeeded(from legacy: URL, to current: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }
        guard !fm.fileExists(atPath: current.path) else { return }
        try? fm.moveItem(at: legacy, to: current)
    }
}
