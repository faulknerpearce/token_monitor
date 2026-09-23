import Combine
import Foundation
import os

@MainActor
final class OpenCodeUsagePoller: ObservableObject, ProviderUsagePoller {
    @Published private(set) var snapshot: OpenCodeSnapshot?
    @Published private(set) var dayHourlyUsage: OpenCodeDayHourlyUsage?
    @Published private(set) var dailyBudgetDays: [DailyBudgetDay]?
    /// Full monthly-period start matching `dailyBudgetDays` (for pace captions).
    @Published private(set) var dailyBudgetPeriodStart: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var dataSourceLabel: String?
    @Published var menuIsOpen = false

    private let settings: AppSettings
    private let auth: OpenCodeAuthSession
    /// Injected console/local fetch seams (tests supply fakes); default to live.
    private let fetchConsole: (String, String?) async throws -> (OpenCodeSnapshot, String)
    private let fetchLocal: () async throws -> (OpenCodeSnapshot, OpenCodeDayHourlyUsage?)
    private let logger = Logger(category: "OpenCode")
    private var cancellables = Set<AnyCancellable>()

    private lazy var loop = PollingLoop(
        interval: { [weak self] in self?.currentInterval() },
        refresh: { [weak self] in await self?.refreshNow() }
    )

    init(
        settings: AppSettings,
        auth: OpenCodeAuthSession,
        fetchConsole: ((String, String?) async throws -> (OpenCodeSnapshot, String))? = nil,
        fetchLocal: (() async throws -> (OpenCodeSnapshot, OpenCodeDayHourlyUsage?))? = nil
    ) {
        self.settings = settings
        self.auth = auth
        self.fetchConsole = fetchConsole ?? { cookieHeader, knownOrgID in
            try await OpenCodeConsoleClient(cookieHeader: cookieHeader)
                .fetchGoUsageSnapshot(knownOrgID: knownOrgID)
        }
        self.fetchLocal = fetchLocal ?? {
            try await Task.detached(priority: .userInitiated) {
                (
                    try OpenCodeLocalStats.fetchSnapshot(),
                    try? OpenCodeLocalStats.fetchDayHourlyUsage()
                )
            }.value
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
        dayHourlyUsage = nil
        dailyBudgetDays = nil
        dailyBudgetPeriodStart = nil
        lastError = nil
        dataSourceLabel = nil
        lastRefreshedAt = nil
    }

    func refreshNow() async {
        guard settings.needsOpenCodePolling else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Prefer official console Go usage (matches opencode.ai bars).
        let generation = auth.sessionGeneration
        let cookieHeader = auth.cookieHeader()
        if let cookieHeader, !cookieHeader.isEmpty {
            do {
                let (consoleSnap, orgID) = try await fetchConsole(cookieHeader, auth.workspaceID)
                let localBundle = try? await fetchLocal()
                var snap = consoleSnap
                if let local = localBundle?.0 {
                    snap = Self.mergeLocalModels(into: snap, local: local)
                }
                guard !Task.isCancelled, auth.isCurrent(generation) else { return }
                // Persist the workspace id only for the live session, and only
                // when it changed, so a late success cannot rewrite the previous
                // account's id after sign-out cleared it.
                if auth.workspaceID != orgID {
                    auth.saveWorkspaceID(orgID)
                }
                snapshot = snap
                if let hourly = localBundle?.1 { dayHourlyUsage = hourly }
                let budget = await Self.buildDailyBudgetDays(for: snap)
                dailyBudgetDays = budget?.days
                dailyBudgetPeriodStart = budget?.periodStart
                lastError = nil
                lastRefreshedAt = Date()
                dataSourceLabel = "OpenCode console"
                auth.needsSignIn = false
                let pct = snap.primaryUsedPercent
                logger.info(
                    "OpenCode console refresh: monthly \(pct, format: .fixed(precision: 1))%"
                )
                return
            } catch let error as ProviderError {
                // A request that began under a previous credential state must
                // not tear down the current session.
                guard auth.isCurrent(generation) else { return }
                switch error.usageError {
                case .unauthorized, .notSignedIn:
                    auth.markSessionInvalid(reason: error.localizedDescription)
                default:
                    break
                }
                logger.error("OpenCode console fetch failed: \(error.localizedDescription, privacy: .public)")
            } catch {
                logger.error("OpenCode console fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Local estimate fallback (labeled).
        do {
            let (snap, hourly) = try await fetchLocal()
            // Do not republish after a sign-out / account switch cleared the
            // snapshot while this poll was in flight (generation moved). A poll
            // that *started* signed-out keeps working: its generation is stable.
            guard !Task.isCancelled, auth.sessionGeneration == generation else { return }
            snapshot = snap
            if let hourly { dayHourlyUsage = hourly }
            let budget = await Self.buildDailyBudgetDays(for: snap)
            dailyBudgetDays = budget?.days
            dailyBudgetPeriodStart = budget?.periodStart
            dataSourceLabel = "Local estimate"
            if cookieHeader == nil || cookieHeader?.isEmpty == true {
                lastError = "Showing local estimate. Sign in to OpenCode for official Go usage."
            } else if auth.needsSignIn {
                lastError = "Console session expired — showing local estimate. Sign in again for official numbers."
            } else {
                lastError = "Console fetch failed — showing local estimate."
            }
            lastRefreshedAt = Date()
            logger.info(
                "OpenCode local refresh: monthly \(snap.primaryUsedPercent, format: .fixed(precision: 1))%"
            )
        } catch {
            if snapshot == nil {
                lastError = error.localizedDescription
            }
            logger.error("OpenCode local refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentInterval() -> TimeInterval {
        PollInterval.seconds(menuIsOpen: menuIsOpen, settings: settings)
    }

    private static func buildDailyBudgetDays(
        for snapshot: OpenCodeSnapshot
    ) async -> (days: [DailyBudgetDay], periodStart: Date)? {
        let monthly = snapshot.windows.first { $0.kind == .monthly }
        let monthlyLimit = monthly?.limitUSD ?? OpenCodeWindowKind.monthly.defaultLimitUSD
        guard monthlyLimit > 0 else { return nil }
        // Anchor the bars to the consumed monthly usage; prefer console
        // resetsAt when local subscription bounds are unavailable.
        let usedPercent = snapshot.monthlyUsedPercent
        let resetsAt = monthly?.resetsAt
        return await Task.detached(priority: .utility) {
            OpenCodeLocalStats.monthDailyBudgetDays(
                limitUSD: monthlyLimit,
                usedPercent: usedPercent,
                periodResetsAt: resetsAt
            )
        }.value
    }

    /// Keep console limit windows; attach local model/token breakdown when present.
    private static func mergeLocalModels(into server: OpenCodeSnapshot, local: OpenCodeSnapshot) -> OpenCodeSnapshot {
        var merged = server
        if !local.models.isEmpty {
            merged.models = local.models
            merged.modelsWindowLabel = local.modelsWindowLabel
            merged.inputTokens = local.inputTokens
            merged.outputTokens = local.outputTokens
            merged.cacheReadTokens = local.cacheReadTokens
            merged.cacheWriteTokens = local.cacheWriteTokens
            merged.totalSessions = local.totalSessions
        }
        if local.monthlyTokens > 0 || local.monthlyEstimatedUSD > 0 {
            merged.monthlyTokens = local.monthlyTokens
            merged.monthlyEstimatedUSD = local.monthlyEstimatedUSD
            merged.monthlyInputTokens = local.monthlyInputTokens
            merged.monthlyOutputTokens = local.monthlyOutputTokens
        }
        return merged
    }
}
