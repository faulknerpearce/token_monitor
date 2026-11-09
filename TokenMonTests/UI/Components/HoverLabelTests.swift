@testable import TokenMon
import XCTest

/// Shared hover-label placement and the rows every hover label builds from.
final class HoverLabelTests: XCTestCase {
    // MARK: - Placement

    func testLabelStaysCenteredOnThePointerWithoutABottomLimit() {
        let origin = HoverLabelPlacement.labelOrigin(
            pointer: CGPoint(x: 200, y: 90),
            labelSize: CGSize(width: 100, height: 60),
            containerWidth: 300
        )
        XCTAssertEqual(origin.y, 60)
    }

    /// Near the bottom of its container the label is raised so it ends at
    /// the bottom edge instead of hanging below it.
    func testLabelIsRaisedAboveTheBottomEdge() {
        let size = CGSize(width: 100, height: 60)
        XCTAssertEqual(
            HoverLabelPlacement.labelOrigin(pointer: CGPoint(x: 200, y: 90), labelSize: size, containerWidth: 300, maxY: 100),
            CGPoint(x: 200 - HoverLabelPlacement.pointerGap - 100, y: 40)
        )
        // Far enough from the edge, the limit changes nothing.
        XCTAssertEqual(
            HoverLabelPlacement.labelOrigin(pointer: CGPoint(x: 200, y: 30), labelSize: size, containerWidth: 300, maxY: 100).y,
            0
        )
    }

    /// A label taller than its container may rise above the container's top.
    func testTallLabelRisesAboveTheContainer() {
        let origin = HoverLabelPlacement.labelOrigin(
            pointer: CGPoint(x: 200, y: 20),
            labelSize: CGSize(width: 100, height: 160),
            containerWidth: 300,
            maxY: 80
        )
        XCTAssertEqual(origin.y, -80)
    }

    func testNearestRowContainsThePointer() {
        let rows = [
            CGRect(x: 0, y: 0, width: 300, height: 30),
            CGRect(x: 0, y: 40, width: 300, height: 30),
            CGRect(x: 0, y: 80, width: 300, height: 30)
        ]
        XCTAssertEqual(HoverLabelPlacement.nearestRowIndex(y: 10, rowFrames: rows), 0)
        XCTAssertEqual(HoverLabelPlacement.nearestRowIndex(y: 55, rowFrames: rows), 1)
        XCTAssertEqual(HoverLabelPlacement.nearestRowIndex(y: 110, rowFrames: rows), 2)
    }

    /// The gap between two rows, and the space above or below them, still
    /// pick a row, so the label does not flicker off between rows.
    func testNearestRowCoversTheGapsBetweenRows() {
        let rows = [
            CGRect(x: 0, y: 20, width: 300, height: 30),
            CGRect(x: 0, y: 60, width: 300, height: 30)
        ]
        XCTAssertEqual(HoverLabelPlacement.nearestRowIndex(y: 52, rowFrames: rows), 0)
        XCTAssertEqual(HoverLabelPlacement.nearestRowIndex(y: 58, rowFrames: rows), 1)
        XCTAssertEqual(HoverLabelPlacement.nearestRowIndex(y: 0, rowFrames: rows), 0)
        XCTAssertEqual(HoverLabelPlacement.nearestRowIndex(y: 200, rowFrames: rows), 1)
    }

    func testNearestRowIsNilWithoutRows() {
        XCTAssertNil(HoverLabelPlacement.nearestRowIndex(y: 10, rowFrames: []))
    }

    // MARK: - Rows

    func testBreakdownListsInputOutputAndBothCacheCounts() {
        XCTAssertEqual(
            HoverLabelRow.breakdown(input: 1_200, output: 3_400_000, cacheRead: 999, cacheWrite: 0),
            [
                HoverLabelRow(label: "Input", value: "1K"),
                HoverLabelRow(label: "Output", value: "3.4M"),
                HoverLabelRow(label: "Cache read", value: "999"),
                HoverLabelRow(label: "Cache write", value: "0")
            ]
        )
    }

    // MARK: - Daily label value

    func testDailyValueTextMarksUnpricedUsage() {
        var tokens = DailyTokenUsage()
        tokens.add(model: "Opus 5.5", output: 10, costUSD: 12.4)
        XCTAssertEqual(DailyBudgetHoverLabel.valueText(tokens), "≈ $12.40")
        tokens.add(model: "Mystery", output: 10, costUSD: nil)
        XCTAssertEqual(DailyBudgetHoverLabel.valueText(tokens), "≈ $12.40+")
    }

    func testDailyValueTextIsHiddenWithoutSpend() {
        var tokens = DailyTokenUsage()
        tokens.add(model: "Mystery", output: 10, costUSD: nil)
        XCTAssertNil(DailyBudgetHoverLabel.valueText(tokens))
        XCTAssertNil(DailyBudgetHoverLabel.valueText(DailyTokenUsage()))
    }
}
