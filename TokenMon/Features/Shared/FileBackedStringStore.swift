import Foundation

/// Atomic, per-user key/value files under Application Support.
/// Files are written atomically with 0600 permissions; the directory is 0700.
struct FileBackedStringStore {
    let directory: URL
    private let filenamePrefix: String

    init(subdirectory: String = AppSupport.directoryName, filenamePrefix: String = "auth_") {
        self.directory = AppSupport.directory(subdirectory: subdirectory)
        self.filenamePrefix = filenamePrefix
    }

    /// Test-only convenience backed by an explicit directory.
    init(directory: URL, filenamePrefix: String = "auth_") {
        self.directory = directory
        self.filenamePrefix = filenamePrefix
    }

    func value(forKey key: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL(forKey: key)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, forKey key: String) {
        let url = fileURL(forKey: key)
        let data = Data(value.utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        } else {
            // Create user-only from the start; the directory is already 0700, so
            // there is no window where a umask-default file holds a credential.
            FileManager.default.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    func remove(forKey key: String) {
        try? FileManager.default.removeItem(at: fileURL(forKey: key))
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent("\(filenamePrefix)\(key).dat")
    }
}
