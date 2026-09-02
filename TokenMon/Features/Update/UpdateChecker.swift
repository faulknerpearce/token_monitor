import Combine
import Foundation
import os

/// Checks GitHub for a newer TokenMon release and publishes the result.
///
/// Deliberately notify-only: it downloads nothing and installs nothing, so it
/// needs no signing key, no appcast and no elevated trust. `availableRelease`
/// drives a single row in the menu that opens the release page.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var availableRelease: AvailableRelease?
    @Published private(set) var isChecking = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastCheckedAt: Date?

    /// Quiet by design — releases are rare and the API is rate-limited for
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
        }
    }

    func checkNow() async {
        guard settings.checksForUpdates, !isChecking else { return }
        guard let currentVersion else {
            // No readable bundle version — comparing would be guesswork.
            logger.warning("Skipping update check: bundle has no CFBundleShortVersionString")
            return
        }
        isChecking = true
        defer { isChecking = false }

        do {
            let data = try await fetchLatest()
            guard settings.checksForUpdates else { return }
            availableRelease = try ReleaseFeed.newerRelease(in: data, than: currentVersion)
            lastError = nil
            lastCheckedAt = Date()
            if let availableRelease {
                logger.info("Update available: \(availableRelease.version.description, privacy: .public)")
            }
        } catch {
            guard settings.checksForUpdates else { return }
            lastError = error.localizedDescription
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
            // 403 here is almost always the unauthenticated rate limit, not a
            // real failure — say so rather than showing a scary error.
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
