@testable import TokenMon
import XCTest

@MainActor
final class ClaudeUsagePollerTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar = gregorian
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// August 2026: Aug 27 is a Thursday — the reset instant from the live
    /// payload shape, not a fixed Saturday.
    func testBuildDailyBudgetDaysAnchorsFirstBarToPeriodStart() {
        let days = ClaudeUsagePoller.buildDailyBudgetDays(
            spentByDay: [:],
            resetsAt: date(2026, 8, 27, hour: 11),
            now: date(2026, 8, 25, hour: 15),
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertTrue(calendar.isDate(days[0].date, inSameDayAs: date(2026, 8, 20)))
        XCTAssertTrue(calendar.isDate(days[6].date, inSameDayAs: date(2026, 8, 26)))
        // The weekly pool's budget is split evenly across its 7 days.
        XCTAssertEqual(days[0].budgetUSD, 100.0 / 7, accuracy: 1e-9)
    }

    /// No provider reset observed → no bars at all. A rolling 7-day window is
    /// never substituted for the real weekly period.
    func testBuildDailyBudgetDaysEmptyWithoutResetTime() {
        let days = ClaudeUsagePoller.buildDailyBudgetDays(
            spentByDay: [:],
            resetsAt: nil,
            now: date(2026, 8, 25),
            calendar: calendar
        )
        XCTAssertTrue(days.isEmpty)
    }

    // MARK: - Provider-initiated early resets

    private func makeStore() -> (DailyQuotaDeltaStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backing = FileBackedStringStore(directory: dir, filenamePrefix: "activity_")
        return (DailyQuotaDeltaStore(store: backing, storageKey: "claude_daily_usage"), dir)
    }

    private func local(_ dayOffset: Int, hour: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date()))!
        return cal.date(byAdding: .hour, value: hour, to: day)!
    }

    private func poll(_ store: DailyQuotaDeltaStore, used: Double, at fetched: Date, resetOffset: Int) -> [DailyBudgetDay] {
        let resetsAt = local(resetOffset, hour: 8)
        store.record(windowUsedPercent: used, at: fetched, window: QuotaWindow(start: nil, resetsAt: resetsAt))
        return ClaudeUsagePoller.buildDailyBudgetDays(
            spentByDay: store.spentByDay,
            resetsAt: resetsAt,
            windowStart: store.windowStart,
            interruptedWindowStart: store.interruptedWindowStart,
            now: fetched
        )
    }

    /// Claude sends only `seven_day.resets_at`. A drop plus a reset instant that
    /// jumps while the old one is still ahead is an early reset: prior days stay
    /// as dimmed history and the 7 live bars open on the new window's start.
    func testEarlyResetKeepsPriorDaysAndRestartsTheWeeklyWindow() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = poll(store, used: 20, at: local(-2, hour: 9), resetOffset: 5)
        _ = poll(store, used: 45, at: local(-1, hour: 9), resetOffset: 5)

        let days = poll(store, used: 2, at: local(0, hour: 9), resetOffset: 7)

        let window = days.filter { !$0.isPriorWindow }
        let prior = days.filter(\.isPriorWindow)
        XCTAssertEqual(window.count, 7)
        XCTAssertTrue(Calendar.current.isDate(window[0].date, inSameDayAs: local(0, hour: 8)))
        XCTAssertEqual(window[0].spentUSD, 2, accuracy: 0.001)
        XCTAssertEqual(prior.last?.spentUSD ?? 0, 25, accuracy: 0.001)
        XCTAssertEqual(DailyBudget.weeklyPacePeriodStart(days: days), Calendar.current.startOfDay(for: local(0, hour: 8)))
    }

    /// Without any reset movement a bigger-than-noise drop is still just the
    /// store's drop-as-reset credit; no prior-window bars appear.
    func testSameResetInstantDropLeavesBarsUnchanged() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = poll(store, used: 60, at: local(-1, hour: 9), resetOffset: 5)
        let days = poll(store, used: 10, at: local(0, hour: 9), resetOffset: 5)
        XCTAssertEqual(days.count, 7)
        XCTAssertFalse(days.contains(where: \.isPriorWindow))
    }

    /// The same chevron-left shift the Grok chart uses: one weekly period back,
    /// with that period's recorded spend on the matching bar.
    func testBuildDailyBudgetDaysWeekOffsetShowsPriorPeriod() {
        let days = ClaudeUsagePoller.buildDailyBudgetDays(
            spentByDay: [calendar.startOfDay(for: date(2026, 8, 14)): 6],
            resetsAt: date(2026, 8, 27, hour: 11),
            weekOffset: -1,
            now: date(2026, 8, 25, hour: 15),
            calendar: calendar
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertTrue(calendar.isDate(days[0].date, inSameDayAs: date(2026, 8, 13)))
        XCTAssertEqual(days[1].spentUSD, 6, accuracy: 0.001)
        XCTAssertFalse(days.contains(where: \.isPriorWindow))
    }

    // MARK: - Weekly reset fallback

    func testProjectWeeklyResetCarriesPastInstantForwardByWholeWeeks() {
        let reset = date(2026, 9, 13, hour: 8)
        let projected = ClaudeUsagePoller.projectWeeklyReset(reset, now: date(2026, 10, 10, hour: 9))
        XCTAssertEqual(projected, date(2026, 10, 11, hour: 8))
        let future = date(2026, 10, 12, hour: 8)
        XCTAssertEqual(ClaudeUsagePoller.projectWeeklyReset(future, now: date(2026, 10, 10)), future)
        XCTAssertNil(ClaudeUsagePoller.projectWeeklyReset(nil, now: date(2026, 10, 10)))
    }

    /// `seven_day: null` with the weekly pool in `limits` records the daily
    /// store and publishes seven bars.
    func testRefreshBuildsBarsFromWeeklyLimitWhenSevenDayIsNull() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data("""
        {"five_hour": {"utilization": 14}, "seven_day": null,
         "limits": [{"group": "weekly", "percent": 3, "resets_at": "2099-01-04T08:00:00+00:00",
                     "scope": {"model": {"display_name": "Fable"}}}]}
        """.utf8)
        let poller = try makePoller(daily: store, dir: dir) { _ in
            try (ClaudeUsageResponse.parse(payload), Date())
        }
        await poller.refreshNow()
        XCTAssertEqual(poller.dailyBudgetDays?.count, 7)
        XCTAssertEqual(store.lastUsedPercent ?? -1, 3, accuracy: 0.001)
        XCTAssertNotNil(store.windowResetsAt)
    }

    /// A weekly pool without `resets_at` reuses the reset the store persisted on
    /// an earlier run, carried forward to the current week.
    func testRefreshWithoutResetTimeReusesPersistedReset() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let earlier = Date().addingTimeInterval(-10 * 86_400)
        store.record(windowUsedPercent: 5, at: earlier, window: QuotaWindow(start: nil, resetsAt: earlier.addingTimeInterval(86_400)))
        let poller = try makePoller(daily: store, dir: dir) { _ in
            (ClaudeUsageResponse(fiveHour: nil, sevenDay: ClaudeUsageWindow(usedPercent: 9, resetsAt: nil)), Date())
        }
        await poller.refreshNow()
        XCTAssertEqual(poller.dailyBudgetDays?.count, 7)
        let reset = try XCTUnwrap(poller.weeklyResetsAt())
        XCTAssertGreaterThan(reset, Date())
        XCTAssertLessThanOrEqual(reset.timeIntervalSinceNow, 7 * 86_400)
    }

    /// Each refresh publishes the Claude Code usage loaded from local logs,
    /// and a poller with an injected fetch reads no local logs by default.
    func testRefreshLoadsClaudeCodeUsage() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let response = ClaudeUsageResponse(fiveHour: ClaudeUsageWindow(usedPercent: 1, resetsAt: nil), sevenDay: nil)
        let summary = Self.codeSummary
        let poller = try makePoller(
            daily: store,
            dir: dir,
            loadCodeUsage: { _ in ClaudeCodeUsageScan(summary: summary) },
            fetch: { _ in (response, Date()) }
        )
        await poller.refreshNow()
        XCTAssertNotNil(poller.snapshot)
        XCTAssertEqual(poller.codeUsage, summary)

        let hermetic = try makePoller(daily: store, dir: dir) { _ in (response, Date()) }
        await hermetic.refreshNow()
        XCTAssertNotNil(hermetic.snapshot)
        XCTAssertNil(hermetic.codeUsage)
    }

    /// Claude Code usage comes from this Mac's logs, so it loads without a
    /// claude.ai session and when the claude.ai fetch fails.
    func testClaudeCodeUsageLoadsWithoutSessionAndOnFetchFailure() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let summary = Self.codeSummary
        let failing = try makePoller(
            daily: store,
            dir: dir,
            loadCodeUsage: { _ in ClaudeCodeUsageScan(summary: summary) },
            fetch: { _ in throw URLError(.notConnectedToInternet) }
        )
        await failing.refreshNow()
        XCTAssertNil(failing.snapshot)
        XCTAssertEqual(failing.codeUsage, summary)

        let (signedOutStore, signedOutDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: signedOutDir) }
        let signedOut = try makePoller(
            daily: signedOutStore,
            dir: signedOutDir,
            signedIn: false,
            loadCodeUsage: { _ in ClaudeCodeUsageScan(summary: summary) },
            fetch: { _ in XCTFail("no fetch without a session"); throw CancellationError() }
        )
        await signedOut.refreshNow()
        XCTAssertNil(signedOut.snapshot)
        XCTAssertEqual(signedOut.codeUsage, summary)
    }

    /// Sign-out drops the claude.ai snapshot but keeps the local Claude Code usage.
    func testSignOutKeepsClaudeCodeUsage() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let response = ClaudeUsageResponse(fiveHour: ClaudeUsageWindow(usedPercent: 1, resetsAt: nil), sevenDay: nil)
        let summary = Self.codeSummary
        let poller = try makePoller(
            daily: store,
            dir: dir,
            loadCodeUsage: { _ in ClaudeCodeUsageScan(summary: summary) },
            fetch: { _ in (response, Date()) }
        )
        await poller.refreshNow()
        poller.clearSnapshot()
        XCTAssertNil(poller.snapshot)
        XCTAssertEqual(poller.codeUsage, summary)
    }

    /// Each daily bar carries the Claude Code tokens of its local day, summed
    /// over models and valued at API rates; days without logs carry none.
    func testAttachTokensAddsEachLocalDaysTokens() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        let monday = try XCTUnwrap(DayKey.startOfDay(for: "2026-11-02", calendar: calendar))
        let tuesday = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: monday))
        let days = [
            DailyBudgetDay(date: monday, spentUSD: 5, budgetUSD: 100.0 / 7),
            DailyBudgetDay(date: tuesday, spentUSD: 0, budgetUSD: 100.0 / 7)
        ]
        let byDay: ClaudeDailyTokens = ["2026-11-02": [
            "claude-opus-5-5": ClaudeModelTokens(inputTokens: 10, outputTokens: 20, cacheReadTokens: 1_000_000, cacheWrite5mTokens: 30, cacheWrite1hTokens: 40),
            "claude-sonnet-5-5": ClaudeModelTokens(inputTokens: 5, outputTokens: 5),
            "mystery-model": ClaudeModelTokens(outputTokens: 1)
        ]]

        let attached = ClaudeUsagePoller.attachTokens(byDay, to: days, calendar: calendar)
        let tokens = try XCTUnwrap(attached[0].tokens)
        XCTAssertEqual(tokens.inputTokens, 15)
        XCTAssertEqual(tokens.outputTokens, 26)
        XCTAssertEqual(tokens.cacheReadTokens, 1_000_000)
        XCTAssertEqual(tokens.cacheWriteTokens, 70)
        XCTAssertEqual(tokens.totalTokens, 1_000_111)
        XCTAssertEqual(tokens.models.map(\.name).first, ClaudeModelName.display("claude-opus-5-5"))
        XCTAssertEqual(tokens.models.count, 3)
        XCTAssertGreaterThan(tokens.costUSD ?? 0, 0)
        XCTAssertTrue(tokens.hasUnpriced)
        XCTAssertNil(attached[1].tokens)
        XCTAssertEqual(attached[0].spentUSD, 5)
    }

    private static let codeSummary = ClaudeCodeUsageSummary(
        month: ClaudeUsageTotals(tokens: 10, costUSD: 1),
        allTime: ClaudeUsageTotals(tokens: 20, costUSD: 2),
        monthModels: []
    )

    private func makePoller(
        daily: DailyQuotaDeltaStore,
        dir: URL,
        signedIn: Bool = true,
        loadCodeUsage: ((Date) async -> ClaudeCodeUsageScan?)? = nil,
        fetch: @escaping (String) async throws -> (ClaudeUsageResponse, Date)
    ) throws -> ClaudeUsagePoller {
        let suite = "ClaudePoller-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.selectedProvider = .claude
        let auth = ClaudeAuthSession(directory: dir)
        if signedIn {
            auth.save(cookieHeader: "sessionKey=test; lastActiveOrg=org")
        }
        let hourly = HourlyDeltaActivityStore(
            store: FileBackedStringStore(directory: dir, filenamePrefix: "hourly_"),
            storageKey: "claude_hourly"
        )
        return ClaudeUsagePoller(
            settings: settings,
            auth: auth,
            hourly: hourly,
            daily: daily,
            fetchUsage: fetch,
            loadCodeUsage: loadCodeUsage
        )
    }
}
