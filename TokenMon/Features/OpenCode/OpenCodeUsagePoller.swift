import Combine
import Foundation
import os

@MainActor
final class OpenCodeUsagePoller: ObservableObject, ProviderUsagePoller {
    @Published private(set) var snapshot: OpenCodeSnapshot?
    @Published private(set) var dayHourlyUsage: OpenCodeDayHourlyUsage?
    @Published private(set) var dailyBudgetDays: [DailyBudgetDay]?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var dataSourceLabel: String?
    @Published var menuIsOpen = false

    private let settings: AppSettings
    private let auth: OpenCodeAuthSession
    private let logger = Logger(category: "OpenCode")

    private lazy var loop = PollingLoop(
        interval: { [weak self] in self?.currentInterval() },
        refresh: { [weak self] in await self?.refreshNow() }
    )

    init(settings: AppSettings, auth: OpenCodeAuthSession) {
        self.settings = settings
        self.auth = auth
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
        guard settings.needsOpenCodePolling else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Prefer official console Go usage (matches opencode.ai bars).
        let cookieHeader = auth.cookieHeader()
        if let cookieHeader, !cookieHeader.isEmpty {
            do {
                let client = OpenCodeConsoleClient(cookieHeader: cookieHeader)
                let (consoleSnap, workspaceID) = try await client.fetchGoUsageSnapshot(
                    knownWorkspaceID: auth.workspaceID
                )
                auth.saveWorkspaceID(workspaceID)

                let localBundle = try? await Task.detached(priority: .userInitiated) {
                    (
                        try OpenCodeLocalStats.fetchSnapshot(),
                        try? OpenCodeLocalStats.fetchDayHourlyUsage()
                    )
                }.value
                var snap = consoleSnap
                if let local = localBundle?.0 {
                    snap = Self.mergeLocalModels(into: snap, local: local)
                }
                guard !Task.isCancelled, auth.isSignedIn, !auth.needsSignIn else { return }
                snapshot = snap
                if let hourly = localBundle?.1 { dayHourlyUsage = hourly }
                dailyBudgetDays = await Self.buildDailyBudgetDays(for: snap)
                lastError = nil
                lastRefreshedAt = Date()
                dataSourceLabel = "OpenCode console"
                auth.needsSignIn = false
                let pct = snap.primaryUsedPercent
                logger.info(
                    "OpenCode console refresh: monthly \(pct, format: .fixed(precision: 1))%"
                )
                return
            } catch let error as OpenCodeConsoleError {
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
            let (snap, hourly) = try await Task.detached(priority: .userInitiated) {
                let snap = try OpenCodeLocalStats.fetchSnapshot()
                let hourly = try? OpenCodeLocalStats.fetchDayHourlyUsage()
                return (snap, hourly)
            }.value
            guard !Task.isCancelled else { return }
            snapshot = snap
            if let hourly { dayHourlyUsage = hourly }
            dailyBudgetDays = await Self.buildDailyBudgetDays(for: snap)
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

    private static func buildDailyBudgetDays(for snapshot: OpenCodeSnapshot) async -> [DailyBudgetDay]? {
        let monthlyLimit = snapshot.windows.first { $0.kind == .monthly }?.limitUSD
            ?? OpenCodeWindowKind.monthly.defaultLimitUSD
        guard monthlyLimit > 0 else { return nil }
        // Anchor the bars to the Monthly bar the user sees so the daily chart
        // reconciles with the consumed monthly usage.
        let usedPercent = snapshot.monthlyUsedPercent
        return await Task.detached(priority: .utility) {
            (try? OpenCodeLocalStats.monthDailyBudgetDays(limitUSD: monthlyLimit, usedPercent: usedPercent))
                ?? DailyBudget.buildCalendarMonthDays(
                    containing: Date(),
                    limitUSD: monthlyLimit,
                    spentByDay: [:]
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
