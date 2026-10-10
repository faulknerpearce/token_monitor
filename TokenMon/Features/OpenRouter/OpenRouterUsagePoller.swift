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
    @Published var menuIsOpen = false {
        didSet { if menuIsOpen != oldValue { pollingLoop.wake() } }
    }

    private let settings: AppSettings
    private let auth: OpenRouterAuthSession
    /// Injected fetch seam (tests supply a fake); defaults to the live client.
    private let fetchSnapshot: (String) async throws -> OpenRouterSnapshot
    private let logger = Logger(category: "OpenRouter")
    private var cancellables = Set<AnyCancellable>()

    private(set) lazy var pollingLoop = PollingLoop(
        interval: { [weak self] in self?.pollInterval() },
        refresh: { [weak self] in await self?.performRefresh() ?? .skipped }
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
        auth.accountReset
            .sink { [weak self] in self?.clearSnapshot() }
            .store(in: &cancellables)
    }

    func start() {
        pollingLoop.start()
    }

    func stop() {
        pollingLoop.stop()
    }

    func clearSnapshot() {
        snapshot = nil
        lastError = nil
        lastRefreshedAt = nil
    }

    /// Fetches now when the provider is enabled and restarts the poll wait from here.
    func refreshNow() async {
        await pollingLoop.refreshNow()
    }

    private func performRefresh() async -> PollOutcome {
        guard settings.isProviderEnabled(.openrouter) else { return .skipped }
        guard !isRefreshing else { return .skipped }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let apiKey = auth.apiKey(), !apiKey.isEmpty else {
            auth.needsSignIn = true
            if snapshot == nil {
                lastError = "Add an OpenRouter API key to load usage."
            }
            return .skipped
        }

        // A rejected key stops the poller until the user saves a new one.
        guard auth.isSignedIn, !auth.needsSignIn else { return .skipped }

        let generation = auth.sessionGeneration
        do {
            let snap = try await fetchSnapshot(apiKey)
            guard !Task.isCancelled, auth.isCurrent(generation) else { return .skipped }
            snapshot = snap
            lastError = nil
            lastRefreshedAt = Date()
            auth.needsSignIn = false
            auth.recordAuthSuccess()
            if let percent = snap.usedPercent {
                logger.info("OpenRouter refresh: \(Int(percent.rounded()))% of credits used (\(Format.usd(snap.remainingUSD ?? 0), privacy: .public) left)")
            } else {
                logger.info("OpenRouter refresh: \(Format.usd(snap.usedUSD), privacy: .public) spent (no credit limit)")
            }
            return .success
        } catch is CancellationError {
            return .skipped
        } catch let error as ProviderError {
            // Only a request made under the current credential state tears down
            // the session; a stale one is skipped.
            guard auth.isCurrent(generation) else { return .skipped }
            switch error.usageError {
            case .unauthorized, .notSignedIn:
                auth.recordAuthFailure(reason: error.localizedDescription)
            default:
                break
            }
            lastError = error.localizedDescription
            logger.error("OpenRouter refresh failed: \(error.localizedDescription, privacy: .public)")
            return PollOutcome(error: error)
        } catch {
            guard auth.isCurrent(generation) else { return .skipped }
            lastError = error.localizedDescription
            logger.error("OpenRouter refresh failed: \(error.localizedDescription, privacy: .public)")
            return PollOutcome(error: error)
        }
    }

    private func pollInterval() -> TimeInterval? {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings, needed: settings.needsOpenRouterPolling)
    }
}
