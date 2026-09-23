import AppKit
import Foundation

/// Downloads a release zip and swaps it in for the running app.
enum AppInstaller {
    static let maximumArchiveBytes = 80 * 1024 * 1024

    enum Failure: LocalizedError {
        case download(String)
        case archive(String)
        case notWritable

        var errorDescription: String? {
            switch self {
            case let .download(message): return "Could not download the update: \(message)"
            case let .archive(message): return "Could not read the update: \(message)"
            case .notWritable: return "TokenMon cannot replace itself from this folder."
            }
        }
    }

    /// App Translocation runs a downloaded app from a read-only copy. Replacing
    /// that copy would not update the file the user actually opens.
    static var isRunningTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }

    static func canReplaceRunningApp(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        guard bundleURL.pathExtension == "app", !isRunningTranslocated else { return false }
        let parent = bundleURL.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: parent.path)
    }

    /// Downloads `archiveURL`, unzips it, and returns the `TokenMon.app` inside.
    static func downloadApp(from archiveURL: URL, session: URLSession = .shared) async throws -> URL {
        guard ReleaseFeed.isTrustedDownload(archiveURL) else {
            throw Failure.download("The release file is not hosted on GitHub.")
        }
        let (data, response) = try await download(archiveURL, session: session)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.download("The release file was not available.")
        }
        guard data.count <= maximumArchiveBytes else {
            throw Failure.download("The release file is unexpectedly large.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmon-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let zip = root.appendingPathComponent("TokenMon.zip")
        try data.write(to: zip, options: .atomic)

        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, unpacked.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw Failure.archive("The release zip could not be opened.")
        }
        guard let app = bundledApp(in: unpacked) else {
            throw Failure.archive("The release zip does not contain TokenMon.app.")
        }
        return app
    }

    /// Replaces `destination` with `newApp` after this process exits, then reopens it.
    static func replaceAndRelaunch(newApp: URL, destination: URL = Bundle.main.bundleURL) throws {
        guard canReplaceRunningApp(bundleURL: destination) else { throw Failure.notWritable }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        set -euo pipefail
        while kill -0 \(pid) 2>/dev/null; do
          sleep 0.2
        done
        rm -rf \(shellQuote(destination.path))
        ditto \(shellQuote(newApp.path)) \(shellQuote(destination.path))
        xattr -dr com.apple.quarantine \(shellQuote(destination.path)) || true
        open \(shellQuote(destination.path))
        """
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmon-update-\(pid).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }

    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func download(_ url: URL, session: URLSession) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        do {
            return try await session.data(for: request)
        } catch {
            throw Failure.download(error.localizedDescription)
        }
    }

    private static func bundledApp(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "TokenMon.app", url.path.hasPrefix(directory.path) {
                return url
            }
        }
        return nil
    }
}

/// Refuses a redirect that leaves GitHub's release hosts.
final class TrustedReleaseRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, ReleaseFeed.isTrustedDownload(url) else { return nil }
        return request
    }
}
