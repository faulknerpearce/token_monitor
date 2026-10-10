import Foundation
import os

/// Atomic, per-user key/value files under Application Support.
/// Files are written atomically with 0600 permissions; the directory is 0700.
struct FileBackedStringStore {
    let directory: URL
    private let filenamePrefix: String
    private static let logger = Logger(category: "FileStore")

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
        let url = fileURL(forKey: key)
        do {
            return String(data: try Data(contentsOf: url), encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            Self.logger.error("Read failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Writes `value` to a temporary file and renames it into place, so a
    /// reader never sees a partial file. The staging file lives in the `0700`
    /// directory and is created `0600`; the rename keeps that mode. Returns
    /// `false` (and logs) when either step fails.
    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        let url = fileURL(forKey: key)
        let fm = FileManager.default
        let staging = directory.appendingPathComponent(".\(filenamePrefix)\(key).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: staging.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]) else {
            Self.logger.error("Write failed for \(url.lastPathComponent, privacy: .public): could not create staging file")
            return false
        }
        guard rename(staging.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: staging)
            Self.logger.error("Write failed for \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
            return false
        }
        return true
    }

    func remove(forKey key: String) {
        let url = fileURL(forKey: key)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            Self.logger.error("Remove failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent("\(filenamePrefix)\(key).dat")
    }
}
