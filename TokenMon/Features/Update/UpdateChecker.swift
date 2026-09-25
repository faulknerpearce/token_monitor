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

    init(
        settings: AppSettings,
        currentVersion: AppVersion? = AppVersion.current(),
        session: URLSession = .shared
    ) {
        self.settings = settings
        self.currentVersion = currentVersion
        self.session = session
    }

    func start() {
        guard settings.checksForUpdates else { return }
        loop.start()
    }

    func stop() {
        loop.stop()
    }

    /// Re-reads the setting: turning checks off clears any pending banner so the
    /// row disappears immediately rather than at the next poll.
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

    /// Installs the published zip, or opens the release page when there is no zip.
    func performPrimaryAction() async {
        if availableRelease != nil {
            await installAvailableUpdate()
        } else {
            await checkManually()
        }
    }

    /// Installs the pending zip, or opens the release page when there is none.
    func installAvailableUpdate() async {
        guard let release = availableRelease, !isInstalling else { return }
        guard let archiveURL = release.archiveURL else {
            statusMessage = "No installer was published — opening the release page."
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        guard AppInstaller.canReplaceRunningApp() else {
            statusMessage = AppInstaller.isRunningTranslocated
                ? "Move TokenMon into Applications, then update."
                : AppInstaller.Failure.notWritable.localizedDescription
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let app = try await AppInstaller.downloadApp(from: archiveURL, session: downloadSession)
            try AppInstaller.replaceAndRelaunch(newApp: app)
        } catch {
            statusMessage = error.localizedDescription
            logger.error("Update install failed: \(error.localizedDescription, privacy: .public)")
            NSWorkspace.shared.open(release.pageURL)
        }
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
            // 403 is usually the unauthenticated rate limit, not a real
            // failure.
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
