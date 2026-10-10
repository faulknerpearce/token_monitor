import Combine
import Foundation
import os

/// Polls ChatGPT usage, retrying once before invalidating the session.
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
    private let fetchUsage: (String) async throws -> ChatGPTUsageClient.Fetch
    /// Wait before the one retry that precedes tearing the stored session down.
    private let unauthorizedRetryDelayNanoseconds: UInt64
    private let logger = Logger(category: "ChatGPT")
    private var cancellables = Set<AnyCancellable>()

    private(set) lazy var pollingLoop = PollingLoop(
        interval: { [weak self] in self?.pollInterval() },
        refresh: { [weak self] in await self?.performRefresh() ?? .skipped }
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
            let fetch = try await fetchUsage(cookieHeader)
            guard !Task.isCancelled, auth.isCurrent(generation) else { return .skipped }
            publish(fetch)
            return .success
        } catch is CancellationError {
            return .skipped
        } catch let error as ProviderError {
            // A request that began under a previous credential state must not
            // tear down the current session.
            guard auth.isCurrent(generation) else { return .skipped }
            switch error.usageError {
            case .unauthorized, .notSignedIn:
                return await invalidateUnlessRetrySucceeds(error, generation: generation, cookieHeader: cookieHeader)
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

    /// One retry before invalidating. A 401 here can be a transient token-exchange
    /// hiccup, and `markSessionInvalid` deletes the stored cookie, so invalidating
    /// on the first failure forces a full manual sign-in for a blip.
    private func invalidateUnlessRetrySucceeds(
        _ error: ProviderError,
        generation: Int,
        cookieHeader: String
    ) async -> PollOutcome {
        if unauthorizedRetryDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: unauthorizedRetryDelayNanoseconds)
        }
        guard !Task.isCancelled, auth.isCurrent(generation) else { return .skipped }
        if let fetch = try? await fetchUsage(cookieHeader), auth.isCurrent(generation) {
            publish(fetch)
            return .success
        }
        guard auth.isCurrent(generation) else { return .skipped }
        auth.markSessionInvalid(reason: error.localizedDescription)
        reportFailure(error)
        return PollOutcome(error: error)
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

    private func pollInterval() -> TimeInterval? {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings, needed: settings.needsChatGPTPolling)
    }
}
