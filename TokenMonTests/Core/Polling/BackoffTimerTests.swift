@testable import TokenMon
import XCTest

@MainActor
final class BackoffTimerTests: XCTestCase {
    func testStartsAtZero() {
        var timer = BackoffTimer(initial: 30, maximum: 600)
        XCTAssertEqual(timer.current, 0)
    }

    func testDoublesGeometrically() {
        var timer = BackoffTimer(initial: 30, maximum: 600)
        timer.recordFailure()
        XCTAssertEqual(timer.current, 30)
        timer.recordFailure()
        XCTAssertEqual(timer.current, 60)
        timer.recordFailure()
        XCTAssertEqual(timer.current, 120)
    }

    func testCapsAtMaximum() {
        var timer = BackoffTimer(initial: 30, maximum: 600)
        for _ in 0..<10 { timer.recordFailure() }
        XCTAssertEqual(timer.current, 600)
        // Additional failures stay capped.
        timer.recordFailure()
        XCTAssertEqual(timer.current, 600)
    }

    func testResetOnSuccess() {
        var timer = BackoffTimer(initial: 15, maximum: 300)
        timer.recordFailure()
        timer.recordFailure()
        XCTAssertEqual(timer.current, 30)
        timer.reset()
        XCTAssertEqual(timer.current, 0)
    }
}
