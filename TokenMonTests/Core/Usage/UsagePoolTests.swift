@testable import TokenMon
import XCTest

final class UsagePoolTests: XCTestCase {
    private func day(_ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    func testCombiningCollapsesCadences() {
        XCTAssertEqual(UsagePool.combining([]), .mixed)
        XCTAssertEqual(UsagePool.combining([.weekly]), .weekly)
        XCTAssertEqual(UsagePool.combining([.monthly, .monthly]), .monthly)
        XCTAssertEqual(UsagePool.combining([.hourly, .weekly]), .mixed)
        XCTAssertEqual(UsagePool.combining([.hourly, .weekly, .monthly]), .mixed)
    }

    func testSectionTitles() {
        XCTAssertEqual(UsagePool.weekly.sectionTitle, "Usage Pool Weekly")
        XCTAssertEqual(UsagePool.monthly.sectionTitle, "Usage Pool Monthly")
        XCTAssertEqual(UsagePool.mixed.sectionTitle, "Usage Pool Mixed")
        XCTAssertEqual(UsagePool.hourly.sectionTitle, "Usage Pool Hourly")
    }

    func testGrokIsWeekly() {
        XCTAssertEqual(WeeklyUsageSnapshot(usedPercent: 10).usagePool, .weekly)
    }

    func testGrokbotPoolsFollowPeriodLength() {
        let weekly = GrokbotSnapshot(fetchedAt: day(8, 25), usedPercent: 10, periodStart: day(8, 20), resetsAt: day(8, 27))
        XCTAssertEqual(weekly.usagePool, .weekly)

        let monthly = GrokbotSnapshot(fetchedAt: day(8, 25), usedPercent: 10, periodStart: day(8, 1), resetsAt: day(8, 31))
        XCTAssertEqual(monthly.usagePool, .monthly)

        let fortnightly = GrokbotSnapshot(fetchedAt: day(8, 25), usedPercent: 10, periodStart: day(8, 13), resetsAt: day(8, 27))
        XCTAssertEqual(fortnightly.usagePool, .mixed)
    }

    func testClaudePools() {
        let fiveHour = ClaudeUsageWindow(usedPercent: 10)
        let weekly = ClaudeUsageWindow(usedPercent: 20)
        XCTAssertEqual(ClaudeSnapshot(fetchedAt: day(8, 25), fiveHour: fiveHour, sevenDay: weekly).usagePool, .mixed)
        XCTAssertEqual(ClaudeSnapshot(fetchedAt: day(8, 25), fiveHour: fiveHour, sevenDay: nil).usagePool, .hourly)
        XCTAssertEqual(ClaudeSnapshot(fetchedAt: day(8, 25), fiveHour: nil, sevenDay: weekly).usagePool, .weekly)
    }

    func testChatGPTPools() {
        let primary = ChatGPTUsageWindow(usedPercent: 10)
        let secondary = ChatGPTUsageWindow(usedPercent: 20)
        let both = ChatGPTSnapshot(
            fetchedAt: day(8, 25),
            planName: nil,
            allowed: true,
            limitReached: false,
            primary: primary,
            secondary: secondary
        )
        XCTAssertEqual(both.usagePool, .mixed)

        let weeklyOnly = ChatGPTSnapshot(
            fetchedAt: day(8, 25),
            planName: nil,
            allowed: true,
            limitReached: false,
            primary: nil,
            secondary: secondary
        )
        XCTAssertEqual(weeklyOnly.usagePool, .weekly)
    }

    func testCursorIsMonthly() {
        let snapshot = CursorSnapshot(
            fetchedAt: day(8, 25),
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
            costStats: nil,
            accountEmail: nil
        )
        XCTAssertEqual(snapshot.usagePool, .monthly)
    }

    private func openCodeWindow(_ kind: OpenCodeWindowKind) -> OpenCodeWindowUsage {
        OpenCodeWindowUsage(kind: kind, usedUSD: 0, limitUSD: 100, resetsAt: nil, sessionCount: 0)
    }

    private func openCodeSnapshot(_ windows: [OpenCodeWindowUsage]) -> OpenCodeSnapshot {
        OpenCodeSnapshot(
            windows: windows,
            models: []
        )
    }

    func testOpenCodeMixedPools() {
        let snapshot = openCodeSnapshot([
            openCodeWindow(.rolling5h),
            openCodeWindow(.weekly),
            openCodeWindow(.monthly)
        ])
        XCTAssertEqual(snapshot.usagePool, .mixed)
        XCTAssertEqual(snapshot.usagePool.sectionTitle, "Usage Pool Mixed")
    }

    func testOpenCodeSingleWindowKeepsItsCadence() {
        XCTAssertEqual(openCodeSnapshot([openCodeWindow(.monthly)]).usagePool, .monthly)
        XCTAssertEqual(openCodeSnapshot([openCodeWindow(.weekly)]).usagePool, .weekly)
        XCTAssertEqual(openCodeSnapshot([openCodeWindow(.rolling5h)]).usagePool, .hourly)
    }
}
