@testable import TokenMon
import XCTest

/// Segment-width math for the weekly pool bar.
final class SegmentedUsageBarTests: XCTestCase {
    func testWidthsAreProportionalWhenTheyFit() {
        let widths = SegmentedUsageBar.segmentWidths(percents: [50, 25, 25], usable: 100, minWidth: 3)
        XCTAssertEqual(widths, [50, 25, 25])
    }

    /// Several tiny slices each floored at the minimum would together exceed the
    /// track; the floors are normalized down so the row still fits.
    func testFloorsAreNormalizedSoTheyDoNotOverflow() {
        let widths = SegmentedUsageBar.segmentWidths(percents: [0.1, 0.1, 0.1], usable: 5, minWidth: 3)
        XCTAssertEqual(widths.reduce(0, +), 5, accuracy: 0.0001)
    }

    func testZeroUsableKeepsFloors() {
        let widths = SegmentedUsageBar.segmentWidths(percents: [50, 50], usable: 0, minWidth: 3)
        XCTAssertEqual(widths, [3, 3])
    }
}
