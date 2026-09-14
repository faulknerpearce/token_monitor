import Foundation

/// Centralized access to the app's per-user Application Support directory.
///
/// Several subsystems (auth cookie store, history store) each re-implemented
/// creating `Application Support/<app>` with `0700` permissions. Hoisting that
/// here keeps the directory location and hardening consistent in one place.
enum AppSupport {
    /// Current Application Support folder name.
    static let directoryName = "TokenMon"

    /// Pre-rename folder used by Model Monitor. Migrated once into `directoryName`.
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
    /// No-op if the legacy folder is missing or the current folder already exists,
    /// so a partial new install is never overwritten.
    static func migrateLegacyDirectoryIfNeeded(from legacy: URL, to current: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }
        guard !fm.fileExists(atPath: current.path) else { return }
        try? fm.moveItem(at: legacy, to: current)
    }
}
