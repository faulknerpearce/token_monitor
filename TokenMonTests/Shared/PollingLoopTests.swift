@testable import TokenMon
import XCTest

/// PollingLoop lifecycle: first refresh, nil-interval exit, stop cancellation,
/// and interval shrink taking effect mid-sleep.
@MainActor
final class PollingLoopTests: XCTestCase {
    func testRefreshesImmediatelyOnStart() async {
        let expectation = expectation(description: "first refresh")
        expectation.assertForOverFulfill = true
        let loop = PollingLoop(
            interval: { nil },
            refresh: { expectation.fulfill() }
        )
        loop.start()
        await fulfillment(of: [expectation], timeout: 2)
        loop.stop()
    }

    func testNilIntervalExitsAfterFirstRefresh() async {
        let counter = Counter()
        let loop = PollingLoop(
            interval: { nil },
            refresh: { counter.increment() }
        )
        loop.start()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(counter.value, 1, "nil interval must end the loop after the first refresh")
        loop.stop()
    }

    func testStopCancelsPendingRefreshes() async {
        let counter = Counter()
        let loop = PollingLoop(
            interval: { 0.05 },
            refresh: { counter.increment() }
        )
        loop.start()
        try? await Task.sleep(nanoseconds: 300_000_000)
        loop.stop()
        let afterStop = counter.value
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counter.value, afterStop, "no further refreshes after stop()")
        XCTAssertGreaterThan(afterStop, 0)
    }

    func testIntervalShrinkIsHonoredQuickly() async {
        // Simulates menu opening during a long idle sleep: the effective delay
        // between two refreshes must approach the short interval, not wait out
        // the full idle one.
        let state = LoopState(initialInterval: 5)
        let loop = PollingLoop(
            interval: { state.interval },
            refresh: { state.incrementRefreshCount() }
        )
        loop.start()
        // First refresh happens immediately; then shrink the interval to 0.2s.
        try? await Task.sleep(nanoseconds: 150_000_000)
        state.interval = 0.2
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertGreaterThanOrEqual(
            state.refreshCount,
            3,
            "second refresh should fire ~0.2s after shrinking, not after 5s"
        )
        loop.stop()
    }
}

/// Plain lock-guarded helpers: PollingLoop closures run on the main actor, but
/// tests read the values from async test methods.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}

private final class LoopState: @unchecked Sendable {
    private let lock = NSLock()
    private var _interval: TimeInterval
    private var _refreshCount = 0
    init(initialInterval: TimeInterval) { _interval = initialInterval }
    var interval: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _interval }
        set { lock.lock(); defer { lock.unlock() }; _interval = newValue }
    }
    var refreshCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _refreshCount
    }
    func incrementRefreshCount() {
        lock.lock(); defer { lock.unlock() }
        _refreshCount += 1
    }
}
