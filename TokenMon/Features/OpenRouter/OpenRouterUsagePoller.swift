import Combine
import Foundation
import os

/// Polls OpenRouter usage for the saved API key.
@MainActor
final class OpenRouterUsagePoller: ObservableObject, ProviderUsagePoller {
    @Published private(set) var snapshot: OpenRouterSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?
    @Published var menuIsOpen = false

    private let settings: AppSettings
    private let auth: OpenRouterAuthSession
    /// Injected fetch seam (tests supply a fake); defaults to the live client.
    private let fetchSnapshot: (String) async throws -> OpenRouterSnapshot
    private let logger = Logger(category: "OpenRouter")
    private var cancellables = Set<AnyCancellable>()

    private lazy var loop = PollingLoop(
        interval: { [weak self] in self?.currentInterval() },
        refresh: { [weak self] in await self?.refreshNow() }
    )

    init(
        settings: AppSettings,
        auth: OpenRouterAuthSession,
        fetchSnapshot: ((String) async throws -> OpenRouterSnapshot)? = nil
    ) {
        self.settings = settings
        self.auth = auth
        self.fetchSnapshot = fetchSnapshot ?? { apiKey in
            try await OpenRouterUsageClient(apiKey: apiKey).fetchSnapshot()
        }
        auth.$isSignedIn
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] signedIn in
                if !signedIn { self?.clearSnapshot() }
            }
            .store(in: &cancellables)
    }

    func start() {
        loop.start()
    }

    func stop() {
        loop.stop()
    }

    func clearSnapshot() {
        snapshot = nil
        lastError = nil
        lastRefreshedAt = nil
    }

    func refreshNow() async {
        guard settings.needsOpenRouterPolling else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let apiKey = auth.apiKey(), !apiKey.isEmpty else {
            auth.needsSignIn = true
            if snapshot == nil {
                lastError = "Add an OpenRouter API key to load usage."
            }
            return
        }

        // A rejected key must stop the poller until the user saves a new one,
        // instead of re-sending the same bearer token every interval.
        guard auth.isSignedIn, !auth.needsSignIn else { return }

        let generation = auth.sessionGeneration
        do {
            let snap = try await fetchSnapshot(apiKey)
            guard !Task.isCancelled, auth.isCurrent(generation) else { return }
            snapshot = snap
            lastError = nil
            lastRefreshedAt = Date()
            auth.needsSignIn = false
            if let percent = snap.usedPercent {
                logger.info("OpenRouter refresh: \(Int(percent.rounded()))% of credits used (\(Format.usd(snap.remainingUSD ?? 0), privacy: .public) left)")
            } else {
                logger.info("OpenRouter refresh: \(Format.usd(snap.usedUSD), privacy: .public) spent (no credit limit)")
            }
        } catch let error as ProviderError {
            // A request that began under a previous credential state must not
            // tear down the current session.
            guard auth.isCurrent(generation) else { return }
            switch error.usageError {
            case .unauthorized, .notSignedIn:
                auth.markSessionInvalid(reason: error.localizedDescription)
            default:
                break
            }
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            logger.error("OpenRouter refresh failed: \(error.localizedDescription, privacy: .public)")
        } catch {
            guard auth.isCurrent(generation) else { return }
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            logger.error("OpenRouter refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentInterval() -> TimeInterval {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings)
    }
}
