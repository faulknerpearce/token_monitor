@testable import TokenMon
import XCTest

/// `ProviderDayHourlyUsage.build` must degrade gracefully on short/long input
/// arrays rather than trapping on a precondition.
final class ProviderHourlyUsageTests: XCTestCase {
    func testShortArraysArePaddedToTwentyFourHours() {
        let usage = ProviderDayHourlyUsage.build(
            dayStart: Date(),
            grokHourWeights: [5.0],
            openCodeGoHourWeights: [],
            openCodeZenHourWeights: [1.0, 2.0]
        )
        XCTAssertEqual(usage.hours.count, 24)
        XCTAssertEqual(usage.hours[0].grokSharePercent, 5.0 / 6.0 * 100, accuracy: 0.001)
        XCTAssertEqual(usage.hours[0].activity, 6, accuracy: 0.001)
        XCTAssertEqual(usage.hours[1].activity, 2, accuracy: 0.001)
        XCTAssertEqual(usage.hours[23].activity, 0, accuracy: 0.001)
    }

    func testLongArraysAreTruncatedToTwentyFourHours() {
        let usage = ProviderDayHourlyUsage.build(
            dayStart: Date(),
            grokHourWeights: Array(repeating: 1.0, count: 30),
            openCodeGoHourWeights: [],
            openCodeZenHourWeights: []
        )
        XCTAssertEqual(usage.hours.count, 24)
        XCTAssertEqual(usage.hours[23].activity, 1, accuracy: 0.001)
    }
}
