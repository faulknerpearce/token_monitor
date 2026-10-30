import Combine
import Foundation
import Observation
import os

/// Polls ChatGPT usage for the captured session cookie.
@MainActor
@Observable
final class ChatGPTUsagePoller: ProviderUsagePoller {
    private(set) var snapshot: ChatGPTSnapshot?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var lastRefreshedAt: Date?
    var menuIsOpen = false {
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
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    @ObservationIgnored private(set) lazy var pollingLoop = PollingLoop(
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
        auth.signedOut
            .merge(with: auth.accountReset)
            .sink { [weak self] in self?.clearSnapshot() }
            .store(in: &cancellables)
    }

    var headlineUsedPercent: Double? { snapshot?.headlineUsedPercent }
    var headlineResetsAt: Date? { snapshot?.resetsAt }
    var alertAccount: String? { auth.accountEmail }

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
        guard settings.isProviderEnabled(.chatgpt), !isRefreshing else { return .skipped }
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
        return await ProviderRefresh.run(
            auth: auth,
            logger: logger,
            label: "ChatGPT",
            fetch: { try await fetchUsage(cookieHeader, generation) },
            publish: { fetch in
                publish(fetch)
                return .success
            },
            onRejected: { tokenCache.clear() },
            reportError: { lastError = $0 }
        )
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
        let headline = response.primary?.usedPercent ?? response.secondary?.usedPercent ?? 0
        logger.info("ChatGPT refresh: \(Int(headline.rounded()))% used")
    }

    private func pollInterval() -> TimeInterval? {
        settings.pollInterval(for: .chatgpt, menuIsOpen: menuIsOpen)
    }
}
