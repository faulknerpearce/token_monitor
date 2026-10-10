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
    @Published var menuIsOpen = false

    private let settings: AppSettings
    private let auth: ChatGPTAuthSession
    /// Injected fetch seam (tests supply a fake); defaults to the live client.
    private let fetchUsage: (String) async throws -> ChatGPTUsageClient.Fetch
    private let logger = Logger(category: "ChatGPT")
    private var cancellables = Set<AnyCancellable>()

    private lazy var loop = PollingLoop(
        interval: { [weak self] in self?.currentInterval() },
        refresh: { [weak self] in await self?.refreshNow() }
    )

    init(
        settings: AppSettings,
        auth: ChatGPTAuthSession,
        fetchUsage: ((String) async throws -> ChatGPTUsageClient.Fetch)? = nil
    ) {
        self.settings = settings
        self.auth = auth
        self.fetchUsage = fetchUsage ?? { cookieHeader in
            try await ChatGPTUsageClient(cookieHeader: cookieHeader).fetchUsage()
        }
        auth.accountReset
            .sink { [weak self] in self?.clearSnapshot() }
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
        guard settings.needsChatGPTPolling else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let cookieHeader = auth.cookieHeader(), !cookieHeader.isEmpty else {
            auth.needsSignIn = true
            if snapshot == nil {
                lastError = "Sign in to ChatGPT to load usage."
            }
            return
        }

        let generation = auth.sessionGeneration
        do {
            let fetch = try await fetchUsage(cookieHeader)
            guard !Task.isCancelled, auth.isCurrent(generation) else { return }
            publish(fetch)
        } catch let error as ProviderError {
            // A request that began under a previous credential state must not
            // tear down the current session.
            guard auth.isCurrent(generation) else { return }
            switch error.usageError {
            case .unauthorized, .notSignedIn:
                auth.recordAuthFailure(reason: error.localizedDescription)
                reportFailure(error)
            default:
                reportFailure(error)
            }
        } catch {
            guard auth.isCurrent(generation) else { return }
            reportFailure(error)
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

    private func currentInterval() -> TimeInterval {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings)
    }
}
