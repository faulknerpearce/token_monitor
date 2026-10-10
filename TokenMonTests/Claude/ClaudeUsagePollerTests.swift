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

    private func makePoller(
        daily: DailyQuotaDeltaStore,
        dir: URL,
        fetch: @escaping (String) async throws -> (ClaudeUsageResponse, Date)
    ) throws -> ClaudeUsagePoller {
        let suite = "ClaudePoller-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.selectedProvider = .claude
        let auth = ClaudeAuthSession(directory: dir)
        auth.save(cookieHeader: "sessionKey=test; lastActiveOrg=org")
        let hourly = HourlyDeltaActivityStore(
            store: FileBackedStringStore(directory: dir, filenamePrefix: "hourly_"),
            storageKey: "claude_hourly"
        )
        return ClaudeUsagePoller(settings: settings, auth: auth, hourly: hourly, daily: daily, fetchUsage: fetch)
    }
}
