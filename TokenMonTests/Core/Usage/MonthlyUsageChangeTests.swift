@testable import TokenMon
import XCTest

/// Month-over-month change of a model's spend or tokens, and its wording.
final class MonthlyUsageChangeTests: XCTestCase {
    // MARK: - Classification

    func testIncreaseCarriesTheAmountAndPercent() throws {
        guard case let .increase(amount, percent) = MonthlyUsageChange.between(previous: 100, current: 118, unit: .usd) else {
            return XCTFail("expected an increase")
        }
        XCTAssertEqual(amount, 18, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(percent), 18, accuracy: 0.0001)
    }

    func testDecreaseCarriesPositiveAmountAndPercent() throws {
        guard case let .decrease(amount, percent) = MonthlyUsageChange.between(previous: 200, current: 150, unit: .usd) else {
            return XCTFail("expected a decrease")
        }
        XCTAssertEqual(amount, 50, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(percent), 25, accuracy: 0.0001)
    }

    func testNoUsageLastMonthIsNew() {
        XCTAssertEqual(MonthlyUsageChange.between(previous: nil, current: 3.91, unit: .usd), .new)
        XCTAssertEqual(MonthlyUsageChange.between(previous: nil, current: 0, unit: .usd), .new)
    }

    /// Differences that round away in the unit (under half a cent, under
    /// half a token) count as no change.
    func testDifferenceBelowTheResolutionIsUnchanged() {
        XCTAssertEqual(MonthlyUsageChange.between(previous: 12.40, current: 12.404, unit: .usd), .unchanged)
        XCTAssertEqual(MonthlyUsageChange.between(previous: 0, current: 0, unit: .usd), .unchanged)
        XCTAssertEqual(MonthlyUsageChange.between(previous: 1_000, current: 1_000, unit: .tokens), .unchanged)
        XCTAssertNotEqual(MonthlyUsageChange.between(previous: 12.40, current: 12.41, unit: .usd), .unchanged)
    }

    /// Last month's usage was priced at $0.00 (a few cheap tokens): there is
    /// no percent to give, only the amount.
    func testZeroSpendLastMonthHasNoPercent() {
        guard case let .increase(amount, percent) = MonthlyUsageChange.between(previous: 0.001, current: 3.91, unit: .usd) else {
            return XCTFail("expected an increase")
        }
        XCTAssertEqual(amount, 3.909, accuracy: 0.0001)
        XCTAssertNil(percent)
        XCTAssertEqual(
            MonthlyUsageChange.between(previous: 0, current: 3.91, unit: .usd),
            .increase(amount: 3.91, percent: nil)
        )
    }

    func testUnitResolutionAndRawValues() {
        XCTAssertEqual(MonthlyUsageChange.Unit.usd.resolution, 0.005, accuracy: 1e-9)
        XCTAssertEqual(MonthlyUsageChange.Unit.tokens.resolution, 0.5, accuracy: 1e-9)
        for unit in MonthlyUsageChange.Unit.allCases {
            XCTAssertEqual(MonthlyUsageChange.Unit(rawValue: unit.rawValue), unit)
        }
        XCTAssertNil(MonthlyUsageChange.Unit(rawValue: "euros"))
    }

    // MARK: - Wording

    func testIncreaseLine() {
        let change = MonthlyUsageChange.between(previous: 1_500.05, current: 1_712.45, unit: .usd)
        XCTAssertEqual(change.summary(versus: "October", unit: .usd), "↑ 14% · +$212.40 vs October")
    }

    func testDecreaseLineUsesAMinusSign() {
        let change = MonthlyUsageChange.between(previous: 880, current: 749.51, unit: .usd)
        XCTAssertEqual(change.summary(versus: "October", unit: .usd), "↓ 15% · \u{2212}$130.49 vs October")
    }

    func testIncreaseFromZeroSpendGivesOnlyTheAmount() {
        let change = MonthlyUsageChange.between(previous: 0, current: 3.91, unit: .usd)
        XCTAssertEqual(change.summary(versus: "October", unit: .usd), "↑ $3.91 vs October")
    }

    func testDropToZeroSpendIsAFullDecrease() {
        let change = MonthlyUsageChange.between(previous: 2.50, current: 0, unit: .usd)
        XCTAssertEqual(change.summary(versus: "October", unit: .usd), "↓ 100% · \u{2212}$2.50 vs October")
    }

    func testNewAndUnchangedLines() {
        XCTAssertEqual(MonthlyUsageChange.new.summary(versus: "October", unit: .usd), "New this month")
        XCTAssertEqual(MonthlyUsageChange.unchanged.summary(versus: "October", unit: .usd), "Same as October")
    }

    func testTokenLines() {
        let change = MonthlyUsageChange.between(previous: 1_000_000, current: 1_200_000, unit: .tokens)
        XCTAssertEqual(change.summary(versus: "October", unit: .tokens), "↑ 20% · +200K tokens vs October")
        let drop = MonthlyUsageChange.between(previous: 4_000_000, current: 1_000_000, unit: .tokens)
        XCTAssertEqual(drop.summary(versus: "October", unit: .tokens), "↓ 75% · \u{2212}3.0M tokens vs October")
    }

    // MARK: - Percent rounding

    func testPercentRoundsHalfAwayFromZero() {
        XCTAssertEqual(MonthlyUsageChange.percentText(14.5), "15%")
        XCTAssertEqual(MonthlyUsageChange.percentText(14.49), "14%")
        XCTAssertEqual(MonthlyUsageChange.percentText(-25), "25%")
        XCTAssertEqual(MonthlyUsageChange.percentText(1_250), "1250%")
    }

    /// A real but tiny change never reads as 0%, and a drop to nearly
    /// nothing never reads as a full 100%.
    func testPercentDoesNotOverstateTheExtremes() {
        XCTAssertEqual(MonthlyUsageChange.percentText(0.3), "<1%")
        XCTAssertEqual(MonthlyUsageChange.percentText(0.5), "1%")
        XCTAssertEqual(MonthlyUsageChange.percentText(99.7), ">99%")
        XCTAssertEqual(MonthlyUsageChange.percentText(100), "100%")
        XCTAssertEqual(MonthlyUsageChange.percentText(100.2), "100%")
    }
}
