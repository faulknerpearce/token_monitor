@testable import TokenMon
import XCTest

/// Pointer and placement math for the daily bars' floating hover label.
final class DailyBudgetHoverTests: XCTestCase {
    func testColumnIndexMapsThePointerToABar() {
        XCTAssertEqual(DailyBudgetHover.columnIndex(x: 0, columnWidth: 40, columns: 7), 0)
        XCTAssertEqual(DailyBudgetHover.columnIndex(x: 119.9, columnWidth: 40, columns: 7), 2)
        XCTAssertEqual(DailyBudgetHover.columnIndex(x: 279, columnWidth: 40, columns: 7), 6)
        XCTAssertNil(DailyBudgetHover.columnIndex(x: 280, columnWidth: 40, columns: 7))
        XCTAssertNil(DailyBudgetHover.columnIndex(x: -1, columnWidth: 40, columns: 7))
        XCTAssertNil(DailyBudgetHover.columnIndex(x: 10, columnWidth: 0, columns: 0))
    }

    /// The label floats left of the pointer, flips right when there is no
    /// room on the left, and stays inside the chart when neither side fits.
    func testLabelFloatsBesideThePointer() {
        let size = CGSize(width: 100, height: 60)
        let gap = HoverLabelPlacement.pointerGap
        XCTAssertEqual(
            HoverLabelPlacement.labelOrigin(pointer: CGPoint(x: 200, y: 50), labelSize: size, containerWidth: 300),
            CGPoint(x: 200 - gap - 100, y: 20)
        )
        XCTAssertEqual(
            HoverLabelPlacement.labelOrigin(pointer: CGPoint(x: 40, y: 50), labelSize: size, containerWidth: 300),
            CGPoint(x: 40 + gap, y: 20)
        )
        XCTAssertEqual(
            HoverLabelPlacement.labelOrigin(pointer: CGPoint(x: 100, y: 50), labelSize: CGSize(width: 250, height: 60), containerWidth: 300),
            CGPoint(x: 0, y: 20)
        )
    }

    func testUsageLineDescribesTheDay() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(
            DailyBudgetHover.usageLine(DailyBudgetDay(date: date, spentUSD: 31, budgetUSD: 100.0 / 7), allowanceNoun: "weekly"),
            "31.0% of weekly · 217% of daily allowance"
        )
        XCTAssertEqual(
            DailyBudgetHover.usageLine(DailyBudgetDay(date: date, spentUSD: 0, budgetUSD: 100.0 / 7), allowanceNoun: "weekly"),
            "0% of the 14.3% daily allowance"
        )
    }
}
