import Combine
import Foundation
import os

/// Polls ChatGPT usage for the captured session cookie.
@MainActor
final class ChatGPTUsagePoller: ObservableObject, ProviderUsagePoller {
    @Published private(set) var snapshot: ChatGPTSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?
    @Published var menuIsOpen = false {
        didSet { if menuIsOpen != oldValue { pollingLoop.wake() } }
    }

    private let settings: AppSettings
    private let auth: ChatGPTAuthSession
    /// Injected fetch seam (tests supply a fake); defaults to the live client.
    /// Takes the cookie header and the session generation.
    private let fetchUsage: (String, Int) async throws -> ChatGPTUsageClient.Fetch
    /// Access token reused across polls by the live client.
    private let tokenCache: ChatGPTAccessTokenCache
    private let logger = Logger(category: "ChatGPT")
    private var cancellables = Set<AnyCancellable>()

    private(set) lazy var pollingLoop = PollingLoop(
        interval: { [weak self] in self?.pollInterval() },
        refresh: { [weak self] in await self?.performRefresh() ?? .skipped }
    )

    init(
        settings: AppSettings,
        auth: ChatGPTAuthSession,
        fetchUsage: ((String, Int) async throws -> ChatGPTUsageClient.Fetch)? = nil
    ) {
        self.settings = settings
        self.auth = auth
        let tokenCache = ChatGPTAccessTokenCache()
        self.tokenCache = tokenCache
        self.fetchUsage = fetchUsage ?? { cookieHeader, generation in
            try await ChatGPTUsageClient(
                cookieHeader: cookieHeader,
                tokenCache: tokenCache,
                tokenCacheKey: String(generation)
            ).fetchUsage()
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
        tokenCache.clear()
        snapshot = nil
        lastError = nil
        lastRefreshedAt = nil
    }

    /// Fetches now when the provider is enabled and restarts the poll wait from here.
    func refreshNow() async {
        await pollingLoop.refreshNow()
    }

    private func performRefresh() async -> PollOutcome {
        guard settings.isProviderEnabled(.chatgpt) else { return .skipped }
        guard !isRefreshing else { return .skipped }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let cookieHeader = auth.cookieHeader(), !cookieHeader.isEmpty else {
            auth.needsSignIn = true
            if snapshot == nil {
                lastError = "Sign in to ChatGPT to load usage."
            }
            return .skipped
        }

        let generation = auth.sessionGeneration
        do {
            let fetch = try await fetchUsage(cookieHeader, generation)
            guard !Task.isCancelled, auth.isCurrent(generation) else { return .skipped }
            publish(fetch)
            return .success
        } catch is CancellationError {
            return .skipped
        } catch let error as ProviderError {
            // Only a request made under the current credential state tears down
            // the session; a stale one is skipped.
            guard auth.isCurrent(generation) else { return .skipped }
            switch error.usageError {
            case .unauthorized, .notSignedIn:
                tokenCache.clear()
                auth.recordAuthFailure(reason: error.localizedDescription)
                reportFailure(error)
                return PollOutcome(error: error)
            default:
                reportFailure(error)
                return PollOutcome(error: error)
            }
        } catch {
            guard auth.isCurrent(generation) else { return .skipped }
            reportFailure(error)
            return PollOutcome(error: error)
        }
    }

    private func publish(_ fetch: ChatGPTUsageClient.Fetch) {
        // Fold a renewed session cookie back into the store before it hard-expires.
        auth.applyRefreshedCookies(fetch.setCookieHeaders)
        let response = fetch.response
        snapshot = ChatGPTSnapshot(
            fetchedAt: fetch.fetchedAt,
            planName: response.planName,
            allowed: response.allowed,
            limitReached: response.limitReached,
            primary: response.primary,
            secondary: response.secondary
        )
        lastError = nil
        lastRefreshedAt = Date()
        auth.needsSignIn = false
        auth.recordAuthSuccess()
        let headline = response.primary?.usedPercent ?? response.secondary?.usedPercent ?? 0
        logger.info("ChatGPT refresh: \(Int(headline.rounded()))% used")
    }

    private func reportFailure(_ error: Error) {
        if snapshot == nil {
            lastError = error.localizedDescription
        }
        logger.error("ChatGPT refresh failed: \(error.localizedDescription, privacy: .public)")
    }

    private func pollInterval() -> TimeInterval? {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings, needed: settings.needsChatGPTPolling)
    }
}
