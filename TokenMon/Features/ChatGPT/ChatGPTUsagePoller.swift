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
    private let logger = Logger(category: "ChatGPT")
    private var cancellables = Set<AnyCancellable>()

    private lazy var loop = PollingLoop(
        interval: { [weak self] in self?.currentInterval() },
        refresh: { [weak self] in await self?.refreshNow() }
    )

    init(settings: AppSettings, auth: ChatGPTAuthSession) {
        self.settings = settings
        self.auth = auth
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

        let client = ChatGPTUsageClient(cookieHeader: cookieHeader)
        do {
            let (response, fetchedAt) = try await client.fetchUsage()
            guard !Task.isCancelled else { return }
            snapshot = ChatGPTSnapshot(
                fetchedAt: fetchedAt,
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
        } catch let error as ProviderError {
            let usageError = error.usageError
            switch usageError {
            case .unauthorized, .notSignedIn:
                auth.markSessionInvalid(reason: error.localizedDescription)
            default:
                break
            }
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            logger.error("ChatGPT refresh failed: \(error.localizedDescription, privacy: .public)")
        } catch {
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            logger.error("ChatGPT refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentInterval() -> TimeInterval {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings)
    }
}
