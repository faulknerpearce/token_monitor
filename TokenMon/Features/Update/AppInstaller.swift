import AppKit
import CryptoKit
import Foundation
import Security

/// Downloads a release zip, verifies it, and swaps it in for the running app.
///
/// The zip must match the SHA-256 GitHub reports for the release asset. The
/// app inside must carry a valid code signature for this bundle identifier (and
/// this Team ID when the running copy has one) and a version newer than the
/// running one. The verified copy is staged next to the installed app and
/// swapped in with a single replace, so a failure leaves the installed app
/// untouched and still running.
///
/// Quarantine attributes are left as they are. The download is written by this
/// process, whose files carry no quarantine flag, so the swapped-in app opens
/// without a Gatekeeper prompt; a quarantined ad-hoc build is refused because
/// Gatekeeper would block its relaunch.
enum AppInstaller {
    static let maximumArchiveBytes: Int64 = 80 * 1024 * 1024
    static let maximumExtractedBytes: Int64 = 256 * 1024 * 1024
    static let appBundleName = "TokenMon.app"

    /// Download, archive, verification, and writability failures from
    /// installing an update.
    enum Failure: LocalizedError, Equatable {
        case download(String)
        case archive(String)
        case verification(String)
        case install(String)
        case notWritable

        var errorDescription: String? {
            switch self {
            case let .download(message): return "Could not download the update: \(message)"
            case let .archive(message): return "Could not read the update: \(message)"
            case let .verification(message): return "The update failed verification: \(message)"
            case let .install(message): return "Could not install the update: \(message)"
            case .notWritable: return "TokenMon cannot replace itself from this folder."
            }
        }
    }

    /// What a downloaded app must match before it replaces the installed copy.
    struct Expectation: Sendable {
        /// Lowercase hex SHA-256 of the release zip.
        var sha256: String
        var bundleIdentifier: String
        /// The new app's version must be strictly greater.
        var currentVersion: AppVersion
        /// Team ID the new app must be signed with; `nil` for ad-hoc builds.
        var teamIdentifier: String?
    }

    /// App Translocation runs a downloaded app from a read-only copy. Replacing
    /// that copy leaves the file the user actually opens unchanged.
    static var isRunningTranslocated: Bool {
        isTranslocated(Bundle.main.bundleURL)
    }

    static func isTranslocated(_ bundleURL: URL) -> Bool {
        bundleURL.path.contains("/AppTranslocation/")
    }

    /// True when `bundleURL` is a writable `.app`, in a writable folder,
    /// outside App Translocation.
    static func canReplaceRunningApp(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        guard bundleURL.pathExtension == "app", !isTranslocated(bundleURL) else { return false }
        let fileManager = FileManager.default
        return fileManager.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
            && fileManager.isWritableFile(atPath: bundleURL.path)
    }

    /// Team ID of the running app's signature, or `nil` for ad-hoc and
    /// unsigned builds.
    static func runningTeamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return nil }
        return signingTeam(of: staticCode)
    }

    /// Downloads `archiveURL`, verifies it against `expectation`, and replaces
    /// `destination` with the app inside.
    ///
    /// - Returns: The installed app, at `destination`.
    /// - Throws: `Failure`, or a file-system error from preparing the download.
    ///   `destination` is unchanged when this throws.
    static func installUpdate(
        from archiveURL: URL,
        expecting expectation: Expectation,
        replacing destination: URL,
        session: URLSession
    ) async throws -> URL {
        guard ReleaseFeed.isRepositoryReleaseDownload(archiveURL) else {
            throw Failure.download("The release file is not one of this project's GitHub releases.")
        }
        guard canReplaceRunningApp(bundleURL: destination) else { throw Failure.notWritable }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmon-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let zip = work.appendingPathComponent("TokenMon.zip")
        let digest = try await download(archiveURL, to: zip, session: session)
        guard digest == expectation.sha256.lowercased() else {
            throw Failure.verification("The download does not match the release checksum.")
        }
        let app = try await extractApp(from: zip, into: work.appendingPathComponent("unpacked", isDirectory: true))
        return try stageAndSwap(app, into: destination, expecting: expectation)
    }

    /// Opens `app` once this process has exited, then quits.
    @MainActor
    static func relaunch(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$2""#,
            "tokenmon-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            app.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }

    // MARK: - Download

    /// Streams `url` to `file`, enforcing the size cap while receiving.
    ///
    /// - Returns: Lowercase hex SHA-256 of the received bytes.
    static func download(
        _ url: URL,
        to file: URL,
        session: URLSession,
        limit: Int64 = maximumArchiveBytes
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: TrustedReleaseRedirect())
        } catch {
            throw Failure.download(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.download("The release file was not available.")
        }
        if let finalURL = http.url, !ReleaseFeed.isTrustedDownload(finalURL) {
            throw Failure.download("The release file is not hosted on GitHub.")
        }
        guard response.expectedContentLength <= limit else {
            throw Failure.download("The release file is unexpectedly large.")
        }

        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw Failure.download("The download could not be saved.")
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        func flush() throws {
            received += Int64(buffer.count)
            guard received <= limit else {
                throw Failure.download("The release file is unexpectedly large.")
            }
            hasher.update(data: buffer)
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 { try flush() }
            }
            try flush()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.download(error.localizedDescription)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Archive

    /// Unzips `zip` into `directory` and returns the top-level `TokenMon.app`.
    ///
    /// Rejects archives whose declared or extracted size exceeds
    /// `maximumExtractedBytes` and archives that contain symbolic links.
    static func extractApp(from zip: URL, into directory: URL) async throws -> URL {
        let listing = try await run("/usr/bin/zipinfo", ["-t", zip.path])
        guard listing.status == 0, let declared = declaredUncompressedBytes(in: listing.output) else {
            throw Failure.archive("The release zip could not be opened.")
        }
        guard declared <= maximumExtractedBytes else {
            throw Failure.archive("The release zip is unexpectedly large.")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unzip = try await run("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path])
        guard unzip.status == 0 else {
            throw Failure.archive("The release zip could not be opened.")
        }
        try checkExtractedTree(directory)

        let app = directory.appendingPathComponent(appBundleName, isDirectory: true)
        let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw Failure.archive("The release zip does not contain TokenMon.app at its top level.")
        }
        return app
    }

    /// Total from `zipinfo -t` (`N files, X bytes uncompressed, …`).
    static func declaredUncompressedBytes(in summary: String) -> Int64? {
        let words = summary.split(whereSeparator: \.isWhitespace)
        guard let index = words.firstIndex(of: "uncompressed,"), index >= 2, words[index - 1] == "bytes" else {
            return nil
        }
        return Int64(words[index - 2])
    }

    /// Fails on any symbolic link and on more than `maximumExtractedBytes`.
    static func checkExtractedTree(_ directory: URL) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            throw Failure.archive("The release zip could not be read.")
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw Failure.archive("The release zip contains a symbolic link.")
            }
            total += Int64(values.fileSize ?? 0)
            if total > maximumExtractedBytes {
                throw Failure.archive("The release zip is unexpectedly large.")
            }
        }
    }

    // MARK: - Verify and swap

    /// Copies `app` next to `destination`, verifies the copy, and swaps it in.
    static func stageAndSwap(_ app: URL, into destination: URL, expecting expectation: Expectation) throws -> URL {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".TokenMon-update-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            try FileManager.default.copyItem(at: app, to: staged)
        } catch {
            throw Failure.install(error.localizedDescription)
        }

        try verify(staged, against: expectation)
        do {
            return try FileManager.default.replaceItemAt(destination, withItemAt: staged) ?? destination
        } catch {
            throw Failure.install(error.localizedDescription)
        }
    }

    /// Checks the code signature, bundle identifier, version, and quarantine
    /// state of `app`.
    static func verify(_ app: URL, against expectation: Expectation) throws {
        let signingTeam = try verifySignature(
            of: app,
            identifier: expectation.bundleIdentifier,
            teamIdentifier: expectation.teamIdentifier
        )

        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == expectation.bundleIdentifier else {
            throw Failure.verification("The download is not TokenMon.")
        }
        guard let version = (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
              version > expectation.currentVersion
        else {
            throw Failure.verification("The download is not newer than this version.")
        }
        if signingTeam == nil, isQuarantined(app) {
            throw Failure.verification("macOS would block this unnotarized download from opening.")
        }
    }

    /// Validates the signature of `app` against a requirement on its signing
    /// identifier and, when given, its Team ID.
    ///
    /// - Returns: The Team ID the app is signed with, if any.
    @discardableResult
    static func verifySignature(of app: URL, identifier: String, teamIdentifier: String?) throws -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw Failure.verification("The download is not a signed app.")
        }
        var requirementText = "identifier \"\(identifier)\""
        if let teamIdentifier {
            requirementText += " and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess else {
            throw Failure.verification("The signing requirement could not be built.")
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures)
            | UInt32(kSecCSStrictValidate)
            | UInt32(kSecCSCheckNestedCode))
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw Failure.verification("The code signature is not valid for TokenMon.")
        }
        return signingTeam(of: staticCode)
    }

    static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    private static func signingTeam(of staticCode: SecStaticCode) -> String? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - Processes

    /// Runs `executable` and suspends, leaving the thread free, until it exits.
    static func run(_ executable: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (finished.terminationStatus, String(bytes: data, encoding: .utf8) ?? ""))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: Failure.archive(error.localizedDescription))
            }
        }
    }
}

/// Refuses a redirect that leaves this repository's release downloads and
/// GitHub's release-asset hosts.
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
