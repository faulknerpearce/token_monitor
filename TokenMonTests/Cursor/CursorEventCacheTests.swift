@testable import TokenMon
import XCTest

/// Event paging cadence, failure fallback, and the sign-in host check.
@MainActor
final class CursorEventCacheTests: XCTestCase {
    private var dir: URL!
    private var suiteName: String!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "CursorEventCache-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Events window

    func testEventsWindowStartIsCycleStartWithinCap() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let cycleStart = now.addingTimeInterval(-10 * 86400)
        XCTAssertEqual(CursorUsageClient.eventsWindowStart(cycleStart: cycleStart, now: now, calendar: calendar), cycleStart)
    }

    func testEventsWindowStartCapsAtThirtyOneDays() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let cap = calendar.date(byAdding: .day, value: -31, to: calendar.startOfDay(for: now))!
        let ancient = now.addingTimeInterval(-90 * 86400)
        XCTAssertEqual(CursorUsageClient.eventsWindowStart(cycleStart: ancient, now: now, calendar: calendar), cap)
        XCTAssertEqual(CursorUsageClient.eventsWindowStart(cycleStart: nil, now: now, calendar: calendar), cap)
    }

    // MARK: - Client cache

    func testEventsArePagedOnceWithinRefreshInterval() async throws {
        let counter = CallCounter()
        let cache = CursorEventCache()
        let client = makeClient(cache: cache, counter: counter) { _ in CursorFixtures.eventsPage(cents: 250) }
        let now = CursorFixtures.middayToday()
        let (first, _, _) = try await client.fetchSnapshot(now: now)
        let (second, _, _) = try await client.fetchSnapshot(now: now.addingTimeInterval(60))
        let pages = await counter.eventPages
        let summaries = await counter.summaries
        XCTAssertEqual(pages, 1)
        XCTAssertEqual(summaries, 2)
        XCTAssertEqual(first.costStats?.meteredCycleUSD ?? -1, 2.5, accuracy: 0.001)
        XCTAssertEqual(second.costStats, first.costStats)

        _ = try await client.fetchSnapshot(now: now.addingTimeInterval(CursorUsageClient.eventsRefreshInterval + 1))
        let refreshed = await counter.eventPages
        XCTAssertEqual(refreshed, 2)
    }

    func testEventsFailureReusesCachedAggregates() async throws {
        let counter = CallCounter()
        let cache = CursorEventCache()
        let now = CursorFixtures.middayToday()
        let good = makeClient(cache: cache, counter: counter) { _ in CursorFixtures.eventsPage(cents: 400) }
        _ = try await good.fetchSnapshot(now: now)
        let failing = makeClient(cache: cache, counter: counter) { _ in throw ProviderError.network(.cursor, "offline") }
        let (snap, hourly, _) = try await failing.fetchSnapshot(now: now.addingTimeInterval(CursorUsageClient.eventsRefreshInterval + 1))
        XCTAssertEqual(snap.costStats?.meteredCycleUSD ?? -1, 4, accuracy: 0.001)
        XCTAssertFalse(hourly.isEmpty)
    }

    func testEventsFailureWithoutCacheLeavesCostStatsNil() async throws {
        let client = makeClient(cache: CursorEventCache(), counter: CallCounter()) { _ in
            throw ProviderError.network(.cursor, "offline")
        }
        let (snap, hourly, weights) = try await client.fetchSnapshot(now: CursorFixtures.middayToday())
        XCTAssertNil(snap.costStats)
        XCTAssertTrue(hourly.isEmpty)
        XCTAssertTrue(weights.isEmpty)
    }

    func testCacheIsScopedToSession() {
        let cache = CursorEventCache()
        let aggregates = CursorEventAggregates(
            fetchedAt: Date(),
            windowStart: Date(),
            costStats: CursorCostStats(meteredCycleUSD: 1, cycleTokens: 1),
            hourly: .empty(dayStart: Date()),
            estimatedWeightByDay: [:]
        )
        cache.store(aggregates, forKey: "a")
        XCTAssertNotNil(cache.value(forKey: "a"))
        XCTAssertNil(cache.value(forKey: "b"))
        cache.clear()
        XCTAssertNil(cache.value(forKey: "a"))
    }

    // MARK: - Poller

    func testPollerKeepsPreviousEventFiguresWhenEventsAreUnavailable() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = AppSettings(defaults: defaults)
        settings.selectedProvider = .cursor
        let auth = CursorAuthSession(directory: dir)
        auth.save(cookieHeader: "WorkosCursorSessionToken=test")
        let daily = DailyQuotaDeltaStore(
            store: FileBackedStringStore(directory: dir, filenamePrefix: "activity_"),
            storageKey: "cursor_daily_usage"
        )
        let now = Date()
        let stats = CursorCostStats(meteredCycleUSD: 7, cycleTokens: 70)
        var hourWeights = Array(repeating: 0.0, count: 24)
        hourWeights[3] = 5
        let hourly = CursorDayHourlyUsage(dayStart: Calendar.current.startOfDay(for: now), hourWeights: hourWeights, quotaHourWeights: hourWeights)
        let responses = ResponseQueue([
            (Self.snapshot(now: now, stats: stats), hourly),
            (Self.snapshot(now: now, stats: nil), .empty(dayStart: hourly.dayStart))
        ])
        let poller = CursorUsagePoller(settings: settings, auth: auth, daily: daily) { _ in
            let (snap, hourly) = await responses.next()
            return (snap, hourly, [:])
        }
        await poller.refreshNow()
        await poller.refreshNow()
        XCTAssertEqual(poller.snapshot?.costStats, stats)
        XCTAssertEqual(poller.dayHourlyUsage, hourly)
    }

    // MARK: - Sign-in

    func testAuthPageMatchesIdentityHostsExactlyOrBySuffix() {
        XCTAssertTrue(CursorSignInView.isAuthPage(host: "github.com", path: "/session"))
        XCTAssertTrue(CursorSignInView.isAuthPage(host: "authenticator.cursor.sh", path: "/"))
        XCTAssertTrue(CursorSignInView.isAuthPage(host: "accounts.google.com", path: "/o/oauth2"))
        XCTAssertTrue(CursorSignInView.isAuthPage(host: "cursor.com", path: "/login"))
        XCTAssertFalse(CursorSignInView.isAuthPage(host: "github.com.evil.example", path: "/"))
        XCTAssertFalse(CursorSignInView.isAuthPage(host: "notgithub.com", path: "/"))
        XCTAssertFalse(CursorSignInView.isAuthPage(host: "cursor.com", path: "/dashboard"))
    }

    // MARK: - Helpers

    private func makeClient(
        cache: CursorEventCache,
        counter: CallCounter,
        eventsPage: @escaping @Sendable (Int) async throws -> Data
    ) -> CursorUsageClient {
        let transport = CursorUsageClient.Transport(
            get: { path in
                if path.hasSuffix("usage-summary") {
                    await counter.noteSummary()
                    return CursorFixtures.summary()
                }
                return Data(#"{"email":"a@b.c"}"#.utf8)
            },
            eventsPage: { _, _, page, _ in
                await counter.noteEventPage()
                return try await eventsPage(page)
            }
        )
        return CursorUsageClient(transport: transport, cacheKey: "session", eventCache: cache)
    }

    private static func snapshot(now: Date, stats: CursorCostStats?) -> CursorSnapshot {
        CursorSnapshot(
            fetchedAt: now,
            usedPercent: 10,
            pools: [],
            billingCycleStart: nil,
            billingCycleEnd: nil,
            membershipType: nil,
            planUsedUSD: nil,
            planLimitUSD: nil,
            onDemandEnabled: false,
            onDemandUsedUSD: nil,
            onDemandLimitUSD: nil,
            costStats: stats,
            accountEmail: nil
        )
    }
}

private actor CallCounter {
    private(set) var summaries = 0
    private(set) var eventPages = 0

    func noteSummary() {
        summaries += 1
    }

    func noteEventPage() {
        eventPages += 1
    }
}

private actor ResponseQueue {
    private var items: [(CursorSnapshot, CursorDayHourlyUsage)]

    init(_ items: [(CursorSnapshot, CursorDayHourlyUsage)]) {
        self.items = items
    }

    func next() -> (CursorSnapshot, CursorDayHourlyUsage) {
        items.removeFirst()
    }
}

private enum CursorFixtures {
    static func middayToday() -> Date {
        Calendar.current.date(byAdding: .hour, value: 12, to: Calendar.current.startOfDay(for: Date()))!
    }

    static func summary() -> Data {
        let start = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5 * 86400))
        let end = ISO8601DateFormatter().string(from: Date().addingTimeInterval(25 * 86400))
        return Data("""
        {"billingCycleStart": "\(start)", "billingCycleEnd": "\(end)",
         "individualUsage": {"plan": {"used": 100, "limit": 2000, "totalPercentUsed": 5}}}
        """.utf8)
    }

    static func eventsPage(cents: Int) -> Data {
        let stamp = Int64(middayToday().addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        return Data("""
        {"totalUsageEventsCount": 1, "usageEventsDisplay": [
          {"timestamp": "\(stamp)", "model": "default", "chargedCents": \(cents),
           "tokenUsage": {"inputTokens": 10, "outputTokens": 5}}
        ]}
        """.utf8)
    }
}
