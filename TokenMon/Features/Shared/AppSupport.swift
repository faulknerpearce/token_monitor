import Foundation

/// Centralized access to the app's per-user Application Support directory
/// (created with `0700` permissions).
enum AppSupport {
    /// Current Application Support folder name.
    static let directoryName = "TokenMon"

    /// Legacy Model Monitor folder name, migrated into `directoryName`.
    static let legacyDirectoryName = "ModelMonitor"

    /// The app's Application Support directory (created on demand, `0700`).
    /// Defaults to `~/Library/Application Support/TokenMon`.
    static func directory(subdirectory: String = directoryName) -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
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
