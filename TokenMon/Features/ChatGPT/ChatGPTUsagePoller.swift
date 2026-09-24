import Combine
import Foundation
import os

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
    /// Wait before the one retry that precedes tearing the stored session down.
    private let unauthorizedRetryDelayNanoseconds: UInt64
    private let logger = Logger(category: "ChatGPT")
    private var cancellables = Set<AnyCancellable>()

    private lazy var loop = PollingLoop(
        interval: { [weak self] in self?.currentInterval() },
        refresh: { [weak self] in await self?.refreshNow() }
    )

    init(
        settings: AppSettings,
        auth: ChatGPTAuthSession,
        unauthorizedRetryDelayNanoseconds: UInt64 = 1_500_000_000,
        fetchUsage: ((String) async throws -> ChatGPTUsageClient.Fetch)? = nil
    ) {
        self.settings = settings
        self.auth = auth
        self.fetchUsage = fetchUsage ?? { cookieHeader in
            try await ChatGPTUsageClient(cookieHeader: cookieHeader).fetchUsage()
        }
        self.unauthorizedRetryDelayNanoseconds = unauthorizedRetryDelayNanoseconds
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
                await invalidateUnlessRetrySucceeds(error, generation: generation, cookieHeader: cookieHeader)
            default:
                reportFailure(error)
            }
        } catch {
            guard auth.isCurrent(generation) else { return }
            reportFailure(error)
        }
    }

    /// One retry before invalidating. A 401 here can be a transient token-exchange
    /// hiccup, and `markSessionInvalid` deletes the stored cookie, so invalidating
    /// on the first failure forces a full manual sign-in for a blip.
    private func invalidateUnlessRetrySucceeds(
        _ error: ProviderError,
        generation: Int,
        cookieHeader: String
    ) async {
        if unauthorizedRetryDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: unauthorizedRetryDelayNanoseconds)
        }
        guard !Task.isCancelled, auth.isCurrent(generation) else { return }
        if let fetch = try? await fetchUsage(cookieHeader), auth.isCurrent(generation) {
            publish(fetch)
            return
        }
        guard auth.isCurrent(generation) else { return }
        auth.markSessionInvalid(reason: error.localizedDescription)
        reportFailure(error)
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
