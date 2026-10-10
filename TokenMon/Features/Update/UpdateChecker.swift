import AppKit
import Combine
import Foundation
import os

/// Checks GitHub for a newer TokenMon release and can install its zip in place.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var availableRelease: AvailableRelease?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    /// Result of a manual check ("You're up to date.") or the last failure.
    @Published private(set) var statusMessage: String?
    /// Last check failure, kept for tests. `statusMessage` is what the UI shows.
    private(set) var lastError: String?

    var actionTitle: String {
        if isInstalling { return "Installing update…" }
        if isChecking { return "Checking for updates…" }
        if let availableRelease {
            return "Update to \(availableRelease.version.description)…"
        }
        return "Check for Updates"
    }

    var canAct: Bool { !isChecking && !isInstalling }

    /// Poll interval: releases are rare and the API is rate-limited for
    /// unauthenticated callers.
    static let checkInterval: TimeInterval = 6 * 60 * 60

    private let settings: AppSettings
    private let currentVersion: AppVersion?
    private let session: URLSession
    private let logger = Logger(category: "Update")

    private lazy var loop = PollingLoop(
        interval: { [weak self] in self?.currentInterval() },
        refresh: { [weak self] in await self?.checkNow() }
    )

    private let bundleIdentifier: String?
    private let installedAppURL: URL
    private let openURL: (URL) -> Void

    /// - Parameters:
    ///   - installedAppURL: The app bundle an update replaces.
    ///   - openURL: Opens release pages and installer downloads.
    init(
        settings: AppSettings,
        currentVersion: AppVersion? = AppVersion.current(),
        session: URLSession = .shared,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        installedAppURL: URL = Bundle.main.bundleURL,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.settings = settings
        self.currentVersion = currentVersion
        self.session = session
        self.bundleIdentifier = bundleIdentifier
        self.installedAppURL = installedAppURL
        self.openURL = openURL
    }

    func start() {
        guard settings.checksForUpdates else { return }
        loop.start()
    }

    func stop() {
        loop.stop()
    }

    /// Re-reads the setting: turning checks off clears any pending banner so the
    /// row disappears immediately.
    func settingChanged() {
        if settings.checksForUpdates {
            loop.start()
        } else {
            loop.stop()
            availableRelease = nil
            lastError = nil
            statusMessage = nil
        }
    }

    /// Background poll. Skipped when automatic checks are off.
    func checkNow() async {
        await performCheck(userInitiated: false)
    }

    /// Menu or Settings button. Runs even when automatic checks are off.
    func checkManually() async {
        await performCheck(userInitiated: true)
    }

    /// Installs the available update, or checks for one when none is pending.
    func performPrimaryAction() async {
        if availableRelease != nil {
            await installAvailableUpdate()
        } else {
            await checkManually()
        }
    }

    /// Installs the pending zip after verifying it. Falls back to the
    /// installer package when this copy cannot replace itself, and to the
    /// release page when the zip is missing, unverifiable, or fails to install.
    func installAvailableUpdate() async {
        guard let release = availableRelease, !isInstalling else { return }
        guard let archive = release.archive else {
            openReleasePage(release, message: "No installer was published — opening the release page.")
            return
        }
        guard AppInstaller.canReplaceRunningApp(bundleURL: installedAppURL) else {
            offerManualInstall(release)
            return
        }
        guard let sha256 = archive.sha256 else {
            openReleasePage(release, message: "The release has no checksum to verify — opening the release page.")
            return
        }
        guard let currentVersion, let bundleIdentifier else {
            openReleasePage(release, message: "This build has no version or bundle identifier to check against — opening the release page.")
            return
        }
        isInstalling = true
        defer { isInstalling = false }
        let expectation = AppInstaller.Expectation(
            sha256: sha256,
            bundleIdentifier: bundleIdentifier,
            currentVersion: currentVersion,
            teamIdentifier: AppInstaller.runningTeamIdentifier()
        )
        do {
            let app = try await AppInstaller.installUpdate(
                from: archive.url,
                expecting: expectation,
                replacing: installedAppURL,
                session: downloadSession
            )
            do {
                try AppInstaller.relaunch(app)
            } catch {
                statusMessage = "TokenMon \(release.version.description) is installed. Quit and reopen TokenMon to finish."
            }
        } catch {
            logger.error("Update install failed: \(error.localizedDescription, privacy: .public)")
            openReleasePage(release, message: error.localizedDescription)
        }
    }

    /// This copy cannot replace itself: translocated copies are asked to move
    /// into Applications; otherwise the installer package is downloaded when
    /// the release has one.
    private func offerManualInstall(_ release: AvailableRelease) {
        if AppInstaller.isTranslocated(installedAppURL) {
            openReleasePage(release, message: "Move TokenMon into Applications, then update.")
        } else if let package = release.installerPackage {
            statusMessage = "TokenMon cannot replace itself here. Downloading the installer package — open it to update."
            openURL(package.url)
        } else {
            openReleasePage(release, message: AppInstaller.Failure.notWritable.localizedDescription)
        }
    }

    private func openReleasePage(_ release: AvailableRelease, message: String) {
        statusMessage = message
        openURL(release.pageURL)
    }

    private lazy var downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        return URLSession(configuration: configuration, delegate: TrustedReleaseRedirect(), delegateQueue: nil)
    }()

    private func performCheck(userInitiated: Bool) async {
        guard userInitiated || settings.checksForUpdates, !isChecking else { return }
        guard let currentVersion else {
            logger.warning("Skipping update check: bundle has no CFBundleShortVersionString")
            if userInitiated {
                statusMessage = "This build has no version number to compare."
            }
            return
        }
        isChecking = true
        if userInitiated { statusMessage = nil }
        defer { isChecking = false }

        do {
            let data = try await fetchLatest()
            guard userInitiated || settings.checksForUpdates else { return }
            availableRelease = try ReleaseFeed.newerRelease(in: data, than: currentVersion)
            lastError = nil
            if let availableRelease {
                statusMessage = nil
                logger.info("Update available: \(availableRelease.version.description, privacy: .public)")
            } else if userInitiated {
                statusMessage = "You're up to date."
            }
        } catch {
            guard userInitiated || settings.checksForUpdates else { return }
            lastError = error.localizedDescription
            if userInitiated { statusMessage = error.localizedDescription }
            logger.warning("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetchLatest() async throws -> Data {
        var request = URLRequest(url: ReleaseFeed.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateCheckError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.badResponse("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // 403 is usually the unauthenticated rate limit, reported as a
            // retry-later message.
            let detail = http.statusCode == 403
                ? "GitHub rate limit reached; will retry later"
                : "HTTP \(http.statusCode)"
            throw UpdateCheckError.badResponse(detail)
        }
        return data
    }

    private func currentInterval() -> TimeInterval? {
        settings.checksForUpdates ? Self.checkInterval : nil
    }
}
