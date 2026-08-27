import Combine
import Foundation
import os

@MainActor
final class CursorUsagePoller: ObservableObject, ProviderUsagePoller {
    @Published private(set) var snapshot: CursorSnapshot?
    @Published private(set) var dayHourlyUsage: CursorDayHourlyUsage?
    @Published private(set) var dailyBudgetDays: [DailyBudgetDay]?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var dataSourceLabel: String?
    @Published var menuIsOpen = false

    private let settings: AppSettings
    private let auth: CursorAuthSession
    private let logger = Logger(category: "Cursor")
    private var cancellables = Set<AnyCancellable>()

    /// Reuse the last refreshed result when a rapid consecutive poll lands within
    /// this window, avoiding redundant full-cycle event paging on every poll step.
    private let eventCacheTTL: TimeInterval = 4

    private lazy var loop = PollingLoop(
        interval: { [weak self] in self?.currentInterval() },
        refresh: { [weak self] in await self?.refreshNow() }
    )

    init(settings: AppSettings, auth: CursorAuthSession) {
        self.settings = settings
        self.auth = auth
        // Grokbot signs out this same session; drop the Cursor snapshot as soon
        // as the cookies are gone rather than waiting for the next poll.
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
        dayHourlyUsage = nil
        dailyBudgetDays = nil
        lastError = nil
        dataSourceLabel = nil
    }

    func refreshNow() async {
        guard settings.needsCursorPolling else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let cookieHeader = auth.cookieHeader(), !cookieHeader.isEmpty else {
            auth.needsSignIn = true
            if snapshot == nil {
                lastError = "Sign in to Cursor to load usage."
            }
            return
        }

        // Rapid consecutive polls (e.g. while the menu is open) can reuse the
        // last result instead of re-paginating the full event history.
        if let lastRefreshedAt,
           snapshot != nil,
           Date().timeIntervalSince(lastRefreshedAt) < eventCacheTTL {
            auth.needsSignIn = false
            return
        }

        let client = CursorUsageClient(cookieHeader: cookieHeader)
        do {
            let (snap, hourly, budgetDays) = try await client.fetchSnapshot()
            guard !Task.isCancelled, auth.isSignedIn, !auth.needsSignIn else { return }
            snapshot = snap
            dayHourlyUsage = hourly
            dailyBudgetDays = budgetDays
            if let email = snap.accountEmail {
                auth.saveAccountEmail(email)
            }
            lastError = nil
            lastRefreshedAt = Date()
            dataSourceLabel = "Cursor dashboard"
            auth.needsSignIn = false
            logger.info(
                "Cursor refresh: total \(snap.usedPercent, format: .fixed(precision: 1))% used (\(Int((100 - snap.usedPercent).rounded()))% left)"
            )
        } catch let cursorError as CursorUsageError {
            let usageError = cursorError.usageError
            switch usageError {
            case .unauthorized, .notSignedIn:
                auth.markSessionInvalid(reason: cursorError.localizedDescription)
            default:
                break
            }
            if snapshot == nil {
                lastError = cursorError.localizedDescription
            }
            logger.error("Cursor refresh failed: \(cursorError.localizedDescription, privacy: .public)")
        } catch {
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            logger.error("Cursor refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentInterval() -> TimeInterval {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings)
    }
}
