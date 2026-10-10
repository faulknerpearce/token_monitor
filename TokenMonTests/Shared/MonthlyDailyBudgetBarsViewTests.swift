import SwiftUI
@testable import TokenMon
import XCTest

/// The monthly chart hands its reset instant to the shared bars, so the final
/// day of a cycle paces against the time left until the reset.
final class MonthlyDailyBudgetBarsViewTests: XCTestCase {
    func testResetsAtReachesTheSharedBars() {
        let reset = Date(timeIntervalSinceReferenceDate: 813_698_722)
        let start = Date(timeIntervalSinceReferenceDate: 811_144_800)
        let view = MonthlyDailyBudgetBarsView(
            days: [],
            accent: .blue,
            periodUsedPercent: 40,
            periodStart: start,
            resetsAt: reset
        )
        XCTAssertEqual(view.bars.resetsAt, reset)
        XCTAssertEqual(view.bars.allowancePeriod, .monthly)
    }
}
