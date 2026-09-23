@testable import TokenMon
import XCTest

/// Poller ↔ session-generation contract.
///
/// Every poller captures `auth.sessionGeneration` before its fetch and must:
///  - drop a result that lands after a sign-out / account switch (success path);
///  - NOT tear down the current session when a request that began under a
///    previous credential state returns 401/403 (error path);
///  - DO invalidate the session when the live session itself is rejected.
///
/// These use the injected fetch seams; no network or WebKit is touched.
@MainActor
final class PollerSessionGuardTests: XCTestCase {
    private var dir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "PollerGuard-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func settings(_ provider: MonitorProvider) -> AppSettings {
        let settings = AppSettings(defaults: defaults)
        settings.selectedProvider = provider
        return settings
    }

    private func dailyStore(_ key: String) -> DailyQuotaDeltaStore {
        DailyQuotaDeltaStore(
            store: FileBackedStringStore(directory: dir, filenamePrefix: "daily_"),
            storageKey: key
        )
    }

    private func hourlyStore(_ key: String) -> HourlyDeltaActivityStore {
        HourlyDeltaActivityStore(
            store: FileBackedStringStore(directory: dir, filenamePrefix: "hourly_"),
            storageKey: key
        )
    }

    // MARK: - Fakes

    private func cursorSnapshot() -> CursorSnapshot {
        CursorSnapshot(
            fetchedAt: Date(),
            usedPercent: 42,
            pools: [],
            billingCycleStart: nil,
            billingCycleEnd: nil,
            membershipType: nil,
            planUsedUSD: nil,
            planLimitUSD: nil,
            onDemandEnabled: false,
            onDemandUsedUSD: nil,
            onDemandLimitUSD: nil,
            costStats: nil,
            accountEmail: nil
        )
    }

    private func cursorHourly() -> CursorDayHourlyUsage {
        CursorDayHourlyUsage(dayStart: Date(), hourWeights: [], quotaHourWeights: [])
    }

    private func claudeResponse() -> ClaudeUsageResponse {
        ClaudeUsageResponse(fiveHour: ClaudeUsageWindow(usedPercent: 10, resetsAt: nil), sevenDay: nil)
    }

    private func chatGPTResponse() -> ChatGPTUsageResponse {
        ChatGPTUsageResponse(
            planName: "Plus",
            allowed: true,
            limitReached: false,
            primary: ChatGPTUsageWindow(usedPercent: 10, resetsAt: nil, windowSeconds: nil),
            secondary: nil
        )
    }

    private func openRouterSnapshot() -> OpenRouterSnapshot {
        OpenRouterSnapshot(
            fetchedAt: Date(),
            keyLabel: nil,
            isManagementKey: false,
            isFreeTier: false,
            accountCreditsUSD: nil,
            accountUsedUSD: nil,
            keyUsageUSD: 0,
            keyUsageDailyUSD: 0,
            keyUsageWeeklyUSD: 0,
            keyUsageMonthlyUSD: 0,
            keyLimitUSD: nil,
            keyLimitRemainingUSD: nil,
            budgetSource: nil,
            budgetUSD: nil,
            usedUSD: 0,
            remainingUSD: nil
        )
    }

    private func openCodeSnapshot() -> OpenCodeSnapshot {
        OpenCodeSnapshot(
            windows: [],
            models: []
        )
    }

    // MARK: - Cursor

    func testCursorStaleSuccessIsDropped() async {
        let auth = CursorAuthSession(directory: dir)
        auth.save(cookieHeader: "WorkosCursorSessionToken=old")
        let poller = CursorUsagePoller(
            settings: settings(.cursor),
            auth: auth,
            daily: dailyStore("cursor"),
            fetchSnapshot: { _ in
                auth.signOut()
                auth.save(cookieHeader: "WorkosCursorSessionToken=new")
                return (self.cursorSnapshot(), self.cursorHourly(), [:])
            }
        )
        await poller.refreshNow()
        XCTAssertNil(poller.snapshot)
        XCTAssertTrue(auth.isSignedIn)
    }

    func testCursorStaleUnauthorizedDoesNotInvalidateNewSession() async {
        let auth = CursorAuthSession(directory: dir)
        auth.save(cookieHeader: "WorkosCursorSessionToken=old")
        let poller = CursorUsagePoller(
            settings: settings(.cursor),
            auth: auth,
            daily: dailyStore("cursor"),
            fetchSnapshot: { _ in
                auth.signOut()
                auth.save(cookieHeader: "WorkosCursorSessionToken=new")
                throw ProviderError.unauthorized(.cursor)
            }
        )
        await poller.refreshNow()
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertFalse(auth.needsSignIn)
    }

    func testCursorCurrentUnauthorizedInvalidatesSession() async {
        let auth = CursorAuthSession(directory: dir)
        auth.save(cookieHeader: "WorkosCursorSessionToken=live")
        let poller = CursorUsagePoller(
            settings: settings(.cursor),
            auth: auth,
            daily: dailyStore("cursor"),
            fetchSnapshot: { _ in throw ProviderError.unauthorized(.cursor) }
        )
        await poller.refreshNow()
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertFalse(auth.isSignedIn)
    }

    // MARK: - Claude

    func testClaudeStaleUnauthorizedDoesNotInvalidateNewSession() async {
        let auth = ClaudeAuthSession(directory: dir)
        auth.save(cookieHeader: "sessionKey=old")
        let poller = ClaudeUsagePoller(
            settings: settings(.claude),
            auth: auth,
            hourly: hourlyStore("claude"),
            daily: dailyStore("claude"),
            fetchUsage: { _ in
                auth.signOut()
                auth.save(cookieHeader: "sessionKey=new")
                throw ProviderError.unauthorized(.claude)
            }
        )
        await poller.refreshNow()
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertFalse(auth.needsSignIn)
    }

    func testClaudeCurrentUnauthorizedInvalidatesSession() async {
        let auth = ClaudeAuthSession(directory: dir)
        auth.save(cookieHeader: "sessionKey=live")
        let poller = ClaudeUsagePoller(
            settings: settings(.claude),
            auth: auth,
            hourly: hourlyStore("claude"),
            daily: dailyStore("claude"),
            fetchUsage: { _ in throw ProviderError.unauthorized(.claude) }
        )
        await poller.refreshNow()
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertFalse(auth.isSignedIn)
    }

    // MARK: - ChatGPT

    func testChatGPTStaleUnauthorizedDoesNotInvalidateNewSession() async {
        let auth = ChatGPTAuthSession(directory: dir)
        auth.save(cookieHeader: "__Secure-next-auth.session-token=old")
        let poller = ChatGPTUsagePoller(
            settings: settings(.chatgpt),
            auth: auth,
            fetchUsage: { _ in
                auth.signOut()
                auth.save(cookieHeader: "__Secure-next-auth.session-token=new")
                throw ProviderError.unauthorized(.chatGPT)
            }
        )
        await poller.refreshNow()
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertFalse(auth.needsSignIn)
    }

    func testChatGPTCurrentUnauthorizedInvalidatesSession() async {
        let auth = ChatGPTAuthSession(directory: dir)
        auth.save(cookieHeader: "__Secure-next-auth.session-token=live")
        let poller = ChatGPTUsagePoller(
            settings: settings(.chatgpt),
            auth: auth,
            fetchUsage: { _ in throw ProviderError.unauthorized(.chatGPT) }
        )
        await poller.refreshNow()
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertFalse(auth.isSignedIn)
    }

    // MARK: - OpenRouter

    func testOpenRouterStaleUnauthorizedDoesNotInvalidateNewKey() async {
        let auth = OpenRouterAuthSession(directory: dir)
        auth.saveAPIKey("sk-or-v1-old")
        let poller = OpenRouterUsagePoller(
            settings: settings(.openrouter),
            auth: auth,
            fetchSnapshot: { _ in
                auth.signOut()
                auth.saveAPIKey("sk-or-v1-new")
                throw ProviderError.unauthorized(.openRouter)
            }
        )
        await poller.refreshNow()
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertFalse(auth.needsSignIn)
    }

    func testOpenRouterCurrentUnauthorizedInvalidatesKey() async {
        let auth = OpenRouterAuthSession(directory: dir)
        auth.saveAPIKey("sk-or-v1-live")
        let poller = OpenRouterUsagePoller(
            settings: settings(.openrouter),
            auth: auth,
            fetchSnapshot: { _ in throw ProviderError.unauthorized(.openRouter) }
        )
        await poller.refreshNow()
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertFalse(auth.isSignedIn)
    }

    // MARK: - Grokbot (shared Cursor session)

    func testGrokbotStaleUnauthorizedDoesNotInvalidateNewSession() async {
        let auth = CursorAuthSession(directory: dir)
        auth.save(cookieHeader: "WorkosCursorSessionToken=old")
        let poller = GrokbotUsagePoller(
            settings: settings(.grokbot),
            auth: auth,
            hourly: hourlyStore("grokbot"),
            daily: dailyStore("grokbot"),
            fetchSnapshot: { _, _ in
                auth.signOut()
                auth.save(cookieHeader: "WorkosCursorSessionToken=new")
                throw ProviderError.unauthorized(.grokbot)
            }
        )
        await poller.refreshNow()
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertFalse(auth.needsSignIn)
    }

    func testGrokbotCurrentUnauthorizedInvalidatesSession() async {
        let auth = CursorAuthSession(directory: dir)
        auth.save(cookieHeader: "WorkosCursorSessionToken=live")
        let poller = GrokbotUsagePoller(
            settings: settings(.grokbot),
            auth: auth,
            hourly: hourlyStore("grokbot"),
            daily: dailyStore("grokbot"),
            fetchSnapshot: { _, _ in throw ProviderError.unauthorized(.grokbot) }
        )
        await poller.refreshNow()
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertFalse(auth.isSignedIn)
    }

    // MARK: - OpenCode

    func testOpenCodeStaleSuccessIsDropped() async {
        let auth = OpenCodeAuthSession(directory: dir)
        auth.save(cookieHeader: "auth=old")
        let poller = OpenCodeUsagePoller(
            settings: settings(.opencode),
            auth: auth,
            fetchConsole: { _, _ in
                auth.signOut()
                auth.save(cookieHeader: "auth=new")
                return (self.openCodeSnapshot(), "wrk_new")
            },
            fetchLocal: { (self.openCodeSnapshot(), nil) }
        )
        await poller.refreshNow()
        XCTAssertNil(poller.snapshot)
        XCTAssertTrue(auth.isSignedIn)
    }

    /// A late success must not rewrite the workspace id after sign-out cleared it.
    func testOpenCodeLateSuccessDoesNotRestoreWorkspaceID() async {
        let auth = OpenCodeAuthSession(directory: dir)
        auth.save(cookieHeader: "auth=old")
        auth.saveWorkspaceID("wrk_old")
        let poller = OpenCodeUsagePoller(
            settings: settings(.opencode),
            auth: auth,
            fetchConsole: { _, _ in
                auth.signOut()
                auth.save(cookieHeader: "auth=new")
                return (self.openCodeSnapshot(), "wrk_old")
            },
            fetchLocal: { (self.openCodeSnapshot(), nil) }
        )
        await poller.refreshNow()
        XCTAssertNotEqual(auth.workspaceID, "wrk_old")
    }

    func testOpenCodeStaleUnauthorizedDoesNotInvalidateNewSession() async {
        let auth = OpenCodeAuthSession(directory: dir)
        auth.save(cookieHeader: "auth=old")
        let poller = OpenCodeUsagePoller(
            settings: settings(.opencode),
            auth: auth,
            fetchConsole: { _, _ in
                auth.signOut()
                auth.save(cookieHeader: "auth=new")
                throw ProviderError.unauthorized(.openCode)
            },
            fetchLocal: { (self.openCodeSnapshot(), nil) }
        )
        await poller.refreshNow()
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertFalse(auth.needsSignIn)
    }

    func testOpenCodeCurrentUnauthorizedInvalidatesSession() async {
        let auth = OpenCodeAuthSession(directory: dir)
        auth.save(cookieHeader: "auth=live")
        let poller = OpenCodeUsagePoller(
            settings: settings(.opencode),
            auth: auth,
            fetchConsole: { _, _ in throw ProviderError.unauthorized(.openCode) },
            fetchLocal: { (self.openCodeSnapshot(), nil) }
        )
        await poller.refreshNow()
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertFalse(auth.isSignedIn)
    }

    /// A poll that *started* signed out still publishes the local estimate.
    func testOpenCodeLocalEstimatePublishesWhenStartedSignedOut() async {
        let auth = OpenCodeAuthSession(directory: dir)
        XCTAssertFalse(auth.isSignedIn)
        let poller = OpenCodeUsagePoller(
            settings: settings(.opencode),
            auth: auth,
            fetchConsole: { _, _ in throw ProviderError.unauthorized(.openCode) },
            fetchLocal: { (self.openCodeSnapshot(), nil) }
        )
        await poller.refreshNow()
        XCTAssertNotNil(poller.snapshot)
        XCTAssertEqual(poller.dataSourceLabel, "Local estimate")
    }

    /// A sign-out while a local estimate poll is in flight must not republish.
    func testOpenCodeLocalEstimateSuppressedAfterMidPollSignOut() async {
        let auth = OpenCodeAuthSession(directory: dir)
        let poller = OpenCodeUsagePoller(
            settings: settings(.opencode),
            auth: auth,
            fetchConsole: { _, _ in throw ProviderError.unauthorized(.openCode) },
            fetchLocal: {
                auth.save(cookieHeader: "auth=late")
                auth.signOut()
                return (self.openCodeSnapshot(), nil)
            }
        )
        await poller.refreshNow()
        XCTAssertNil(poller.snapshot)
    }
}
