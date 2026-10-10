@testable import TokenMon
import XCTest

/// What an expired session keeps and what an explicit sign-out or account
/// change clears. Uses in-memory credential stores, temp-dir activity stores,
/// and injected fetch seams; no network, Keychain, or WebKit is touched.
@MainActor
final class AuthInvalidationTests: XCTestCase {
    private var dir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "AuthInvalidation-\(UUID().uuidString)"
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
        DailyQuotaDeltaStore(store: FileBackedStringStore(directory: dir, filenamePrefix: "daily_"), storageKey: key)
    }

    private func hourlyStore(_ key: String) -> HourlyDeltaActivityStore {
        HourlyDeltaActivityStore(store: FileBackedStringStore(directory: dir, filenamePrefix: "hourly_"), storageKey: key)
    }

    private func claudeResponse(weekly: Double) -> ClaudeUsageResponse {
        ClaudeUsageResponse(
            fiveHour: ClaudeUsageWindow(usedPercent: 10, resetsAt: nil),
            sevenDay: ClaudeUsageWindow(usedPercent: weekly, resetsAt: Date().addingTimeInterval(3 * 86400))
        )
    }

    /// Feeds a fixed sequence of outcomes to a fetch seam.
    private final class Script<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [Result<Value, Error>]

        init(_ outcomes: [Result<Value, Error>]) {
            self.outcomes = outcomes
        }

        func next() throws -> Value {
            lock.lock()
            defer { lock.unlock() }
            return try (outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]).get()
        }
    }

    private func makeClaude() -> (ClaudeUsagePoller, ClaudeAuthSession, DailyQuotaDeltaStore, Script<(ClaudeUsageResponse, Date)>) {
        let auth = ClaudeAuthSession(store: InMemoryCredentialStore())
        auth.save(cookieHeader: "sessionKey=live")
        let daily = dailyStore("claude")
        let now = Date()
        let script = Script<(ClaudeUsageResponse, Date)>([
            .success((claudeResponse(weekly: 10), now.addingTimeInterval(-60))),
            .success((claudeResponse(weekly: 20), now)),
            .failure(ProviderError.unauthorized(.claude))
        ])
        let poller = ClaudeUsagePoller(
            settings: settings(.claude),
            auth: auth,
            hourly: hourlyStore("claude"),
            daily: daily,
            fetchUsage: { _ in try script.next() }
        )
        return (poller, auth, daily, script)
    }

    /// An expired Claude session asks for sign-in but keeps the snapshot and
    /// the persisted daily history.
    func testClaudeInvalidationKeepsHistory() async {
        let (poller, auth, daily, _) = makeClaude()
        await poller.refreshNow()
        await poller.refreshNow()
        XCTAssertFalse(daily.spentByDay.isEmpty)

        for _ in 1...ProviderAuthSession.authFailureThreshold {
            await poller.refreshNow()
        }

        XCTAssertTrue(auth.needsSignIn)
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNotNil(poller.snapshot)
        XCTAssertFalse(daily.spentByDay.isEmpty)
    }

    /// A failed refresh after a successful one reports its error alongside the
    /// kept snapshot, so the panel marks the data as stale.
    func testClaudeFailureAfterDataReportsError() async {
        let (poller, _, _, _) = makeClaude()
        await poller.refreshNow()
        await poller.refreshNow()
        XCTAssertNil(poller.lastError)

        await poller.refreshNow()

        XCTAssertNotNil(poller.snapshot)
        XCTAssertNotNil(poller.lastError)
    }

    func testClaudeSignOutClearsHistory() async {
        let (poller, auth, daily, _) = makeClaude()
        await poller.refreshNow()
        await poller.refreshNow()
        XCTAssertFalse(daily.spentByDay.isEmpty)

        auth.signOut()

        XCTAssertNil(poller.snapshot)
        XCTAssertTrue(daily.spentByDay.isEmpty)
    }

    // MARK: - Grokbot on the shared Cursor session

    /// A Bot-only 403 never counts against the shared Cursor session.
    func testGrokbotForbiddenDoesNotInvalidateCursorSession() async {
        let auth = CursorAuthSession(store: InMemoryCredentialStore())
        auth.save(cookieHeader: "WorkosCursorSessionToken=live")
        let message = ProviderErrorContext.grokbot.forbiddenMessage ?? ""
        let poller = GrokbotUsagePoller(
            settings: settings(.grokbot),
            auth: auth,
            hourly: hourlyStore("grokbot"),
            daily: dailyStore("grokbot"),
            fetchSnapshot: { _, _ in throw ProviderError.custom(message: message, usage: .badResponse(message)) }
        )

        for _ in 1...(ProviderAuthSession.authFailureThreshold + 1) {
            await poller.refreshNow()
        }

        XCTAssertTrue(auth.isSignedIn)
        XCTAssertFalse(auth.needsSignIn)
        XCTAssertEqual(auth.consecutiveAuthFailures, 0)
        XCTAssertEqual(poller.lastError, message)
    }

    /// Once the shared session has expired, Grokbot keeps its stored history.
    func testGrokbotKeepsHistoryWhileSignedOut() async {
        let auth = CursorAuthSession(store: InMemoryCredentialStore())
        auth.save(cookieHeader: "WorkosCursorSessionToken=live")
        let daily = dailyStore("grokbot")
        daily.record(windowUsedPercent: 5, at: Date().addingTimeInterval(-3600), window: QuotaWindow(start: nil, resetsAt: nil))
        daily.record(windowUsedPercent: 9, at: Date(), window: QuotaWindow(start: nil, resetsAt: nil))
        let before = daily.spentByDay
        let poller = GrokbotUsagePoller(
            settings: settings(.grokbot),
            auth: auth,
            hourly: hourlyStore("grokbot"),
            daily: daily,
            fetchSnapshot: { _, _ in throw ProviderError.unauthorized(.grokbot) }
        )

        for _ in 1...(ProviderAuthSession.authFailureThreshold + 1) {
            await poller.refreshNow()
        }

        XCTAssertFalse(auth.isSignedIn)
        XCTAssertEqual(daily.spentByDay, before)
    }

    // MARK: - Grok

    func testGrokInvalidationKeepsHourlyDeltasButSignOutClearsThem() async {
        let auth = AuthSessionService(directory: nil, store: InMemoryCredentialStore())
        auth.save(cookieHeader: "sso=live")
        let hourly = hourlyStore("grok")
        hourly.record(usedPercent: 10, at: Date().addingTimeInterval(-120))
        hourly.record(usedPercent: 12, at: Date())
        let recorded = hourly.hourWeights
        XCTAssertFalse(recorded.allSatisfy { $0 == 0 })
        let poller = UsagePoller(
            auth: auth,
            history: HistoryStore(inMemory: true),
            settings: settings(.grok),
            notifier: ThresholdNotifier(defaults: defaults, deliver: { _, _ in }),
            grokHourly: hourly,
            fetchUsage: { _, _ in throw ProviderError.unauthorized(.grok) }
        )

        for _ in 1...ProviderAuthSession.authFailureThreshold {
            await poller.refreshNow()
        }
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertEqual(hourly.hourWeights, recorded)

        auth.signOut()
        XCTAssertTrue(hourly.hourWeights.allSatisfy { $0 == 0 })
    }
}
