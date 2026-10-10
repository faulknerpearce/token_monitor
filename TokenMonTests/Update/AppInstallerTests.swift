import CryptoKit
@testable import TokenMon
import XCTest

/// Serves `body` for every request and counts requests.
private final class ArchiveStubURLProtocol: URLProtocol {
    static var body = Data()
    static var requestCount = 0

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": String(Self.body.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Exercises the download → verify → swap path against ad-hoc signed fixture
/// apps in a temporary folder. Nothing touches /Applications or the network.
final class AppInstallerTests: XCTestCase {
    private static let bundleID = "com.modelmonitor.app"
    private static let releaseURL = URL(
        string: "https://github.com/faulknerpearce/token_monitor/releases/download/v2.0.0/TokenMon-2.0.0.zip"
    )!

    private var root: URL!
    private var destination: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppInstallerTests-\(UUID().uuidString)", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        destination = try makeApp(in: applications, version: "1.5.0", signed: false)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArchiveStubURLProtocol.self]
        session = URLSession(configuration: configuration)
        ArchiveStubURLProtocol.body = Data()
        ArchiveStubURLProtocol.requestCount = 0
    }

    override func tearDownWithError() throws {
        if let root {
            _ = try? Self.run("/bin/chmod", ["-R", "u+w", root.path])
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Install path

    func testInstallsVerifiedUpdateInPlace() async throws {
        let sha = try serve(makeApp(in: fixtureFolder(), version: "2.0.0"))
        let installed = try await install(sha256: sha)

        XCTAssertEqual(installed.standardizedFileURL.path, destination.standardizedFileURL.path)
        XCTAssertEqual(try bundleVersion(of: destination), "2.0.0")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["TokenMon.app"], "the staged copy is swapped in, not left beside it")
    }

    func testChecksumMismatchIsRefused() async throws {
        try serve(makeApp(in: fixtureFolder(), version: "2.0.0"))
        await assertInstallFails(sha256: String(repeating: "0", count: 64)) {
            guard case .verification = $0 else { return XCTFail("expected verification failure, got \($0)") }
        }
    }

    func testWrongBundleIdentifierIsRefused() async throws {
        let sha = try serve(makeApp(in: fixtureFolder(), version: "2.0.0", bundleID: "com.example.other"))
        await assertInstallFails(sha256: sha) {
            guard case .verification = $0 else { return XCTFail("expected verification failure, got \($0)") }
        }
    }

    func testDowngradeIsRefused() async throws {
        let sha = try serve(makeApp(in: fixtureFolder(), version: "1.4.0"))
        await assertInstallFails(sha256: sha) {
            XCTAssertEqual($0, .verification("The download is not newer than this version."))
        }
    }

    func testSameVersionIsRefused() async throws {
        let sha = try serve(makeApp(in: fixtureFolder(), version: "1.5.0"))
        await assertInstallFails(sha256: sha) {
            XCTAssertEqual($0, .verification("The download is not newer than this version."))
        }
    }

    func testUnsignedAppIsRefused() async throws {
        let sha = try serve(makeApp(in: fixtureFolder(), version: "2.0.0", signed: false))
        await assertInstallFails(sha256: sha) {
            guard case .verification = $0 else { return XCTFail("expected verification failure, got \($0)") }
        }
    }

    func testAppModifiedAfterSigningIsRefused() async throws {
        let app = try makeApp(in: fixtureFolder(), version: "2.0.0")
        try Data("tampered".utf8).write(to: app.appendingPathComponent("Contents/Resources/data.txt"))
        let sha = try serve(app)
        await assertInstallFails(sha256: sha) {
            XCTAssertEqual($0, .verification("The code signature is not valid for TokenMon."))
        }
    }

    func testSymbolicLinkInArchiveIsRefused() async throws {
        let app = try makeApp(in: fixtureFolder(), version: "2.0.0")
        try FileManager.default.createSymbolicLink(
            at: app.appendingPathComponent("Contents/Resources/link"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        let sha = try serve(app)
        await assertInstallFails(sha256: sha) {
            XCTAssertEqual($0, .archive("The release zip contains a symbolic link."))
        }
    }

    func testAppNestedBelowTopLevelIsRefused() async throws {
        let folder = fixtureFolder()
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try makeApp(in: nested, version: "2.0.0")
        let sha = try serve(folder)
        await assertInstallFails(sha256: sha) {
            XCTAssertEqual($0, .archive("The release zip does not contain TokenMon.app at its top level."))
        }
    }

    func testDownloadOutsideThisRepositoryIsRefused() async throws {
        let sha = try serve(makeApp(in: fixtureFolder(), version: "2.0.0"))
        let elsewhere = URL(string: "https://github.com/someone/else/releases/download/v2.0.0/TokenMon-2.0.0.zip")!
        await assertInstallFails(sha256: sha, from: elsewhere) {
            guard case .download = $0 else { return XCTFail("expected download failure, got \($0)") }
        }
        XCTAssertEqual(ArchiveStubURLProtocol.requestCount, 0)
    }

    func testReadOnlyInstallFolderIsRefused() async throws {
        let sha = try serve(makeApp(in: fixtureFolder(), version: "2.0.0"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destination.deletingLastPathComponent().path)
        await assertInstallFails(sha256: sha) { XCTAssertEqual($0, .notWritable) }
        XCTAssertEqual(ArchiveStubURLProtocol.requestCount, 0)
    }

    // MARK: - Pieces

    func testDownloadStopsAtSizeLimit() async throws {
        ArchiveStubURLProtocol.body = Data(repeating: 7, count: 200 * 1024)
        let file = root.appendingPathComponent("big.zip")
        do {
            _ = try await AppInstaller.download(Self.releaseURL, to: file, session: session, limit: 100 * 1024)
            XCTFail("expected the size limit to stop the download")
        } catch let failure as AppInstaller.Failure {
            XCTAssertEqual(failure, .download("The release file is unexpectedly large."))
        }
    }

    func testDownloadReturnsSHA256OfBody() async throws {
        ArchiveStubURLProtocol.body = Data((0..<100_000).map { UInt8($0 % 251) })
        let file = root.appendingPathComponent("body.zip")
        let digest = try await AppInstaller.download(Self.releaseURL, to: file, session: session)
        XCTAssertEqual(digest, Self.sha256(ArchiveStubURLProtocol.body))
        XCTAssertEqual(try Data(contentsOf: file), ArchiveStubURLProtocol.body)
    }

    func testCanReplaceRunningAppChecksTheGivenBundle() throws {
        XCTAssertTrue(AppInstaller.canReplaceRunningApp(bundleURL: destination))
        let translocated = URL(fileURLWithPath: "/private/var/folders/xy/AppTranslocation/ABCD/d/TokenMon.app")
        XCTAssertFalse(AppInstaller.canReplaceRunningApp(bundleURL: translocated))
        XCTAssertFalse(AppInstaller.canReplaceRunningApp(bundleURL: root.appendingPathComponent("TokenMon")))

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destination.path)
        XCTAssertFalse(AppInstaller.canReplaceRunningApp(bundleURL: destination))
    }

    func testDeclaredUncompressedBytesParsesZipinfoSummary() {
        XCTAssertEqual(
            AppInstaller.declaredUncompressedBytes(in: "12 files, 3456 bytes uncompressed, 1200 bytes compressed:  65.3%\n"),
            3456
        )
        XCTAssertNil(AppInstaller.declaredUncompressedBytes(in: "Empty zipfile."))
    }

    // MARK: - Helpers

    private func install(sha256: String, from url: URL = AppInstallerTests.releaseURL) async throws -> URL {
        try await AppInstaller.installUpdate(
            from: url,
            expecting: AppInstaller.Expectation(
                sha256: sha256,
                bundleIdentifier: Self.bundleID,
                currentVersion: AppVersion("1.5.0")!,
                teamIdentifier: nil
            ),
            replacing: destination,
            session: session
        )
    }

    private func assertInstallFails(
        sha256: String,
        from url: URL = AppInstallerTests.releaseURL,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: (AppInstaller.Failure) -> Void
    ) async {
        do {
            _ = try await install(sha256: sha256, from: url)
            XCTFail("expected the install to fail", file: file, line: line)
        } catch let failure as AppInstaller.Failure {
            check(failure)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
        XCTAssertEqual(try? bundleVersion(of: destination), "1.5.0", "the installed app is untouched", file: file, line: line)
        let siblings = try? FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["TokenMon.app"], "no staged copy is left behind", file: file, line: line)
    }

    private func fixtureFolder() -> URL {
        let folder = root.appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Builds `TokenMon.app` in `folder` around a copy of `/usr/bin/true`,
    /// ad-hoc signed unless `signed` is false.
    private func makeApp(
        in folder: URL,
        version: String,
        bundleID: String = AppInstallerTests.bundleID,
        signed: Bool = true
    ) throws -> URL {
        let app = folder.appendingPathComponent("TokenMon.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("TokenMon"))
        try Data("fixture".utf8).write(to: resources.appendingPathComponent("data.txt"))
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "TokenMon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1"
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        if signed {
            let status = try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
            XCTAssertEqual(status, 0, "codesign")
        }
        return app
    }

    /// Zips `item` and serves it: an `.app` as the release does, a folder as
    /// its contents. Returns the zip's SHA-256.
    @discardableResult
    private func serve(_ item: URL) throws -> String {
        let zip = root.appendingPathComponent("served-\(UUID().uuidString).zip")
        let arguments = item.pathExtension == "app"
            ? ["-c", "-k", "--keepParent", item.path, zip.path]
            : ["-c", "-k", item.path, zip.path]
        XCTAssertEqual(try Self.run("/usr/bin/ditto", arguments), 0, "ditto")
        ArchiveStubURLProtocol.body = try Data(contentsOf: zip)
        return Self.sha256(ArchiveStubURLProtocol.body)
    }

    private func bundleVersion(of app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return info?["CFBundleShortVersionString"] as? String
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
