import Observation
@testable import TokenMon
import XCTest

/// The observation loop calls its handler with the latest values after a
/// change, coalesces bursts, and stops when cancelled.
@MainActor
final class ObservationLoopTests: XCTestCase {
    @Observable
    final class Counter {
        var value = 0
        var unrelated = 0
    }

    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    func testHandlesTheFirstReadingAndEachChange() async {
        let counter = Counter()
        var seen: [Int] = []
        let loop = ObservationLoop(track: { counter.value }, handle: { seen.append($0) })
        XCTAssertEqual(seen, [0])

        counter.value = 1
        await settle()
        XCTAssertEqual(seen, [0, 1])

        counter.unrelated = 5
        await settle()
        XCTAssertEqual(seen, [0, 1], "a value the tracker did not read is not a dependency")
        loop.cancel()
    }

    func testBurstIsHandledOnceWithTheLatestValue() async {
        let counter = Counter()
        var seen: [Int] = []
        let loop = ObservationLoop(
            coalescing: .milliseconds(30),
            initial: false,
            track: { counter.value },
            handle: { seen.append($0) }
        )
        counter.value = 1
        counter.value = 2
        counter.value = 3
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(seen, [3])
        loop.cancel()
    }

    func testCancelStopsHandling() async {
        let counter = Counter()
        var seen: [Int] = []
        let loop = ObservationLoop(initial: false, track: { counter.value }, handle: { seen.append($0) })
        loop.cancel()
        counter.value = 1
        await settle()
        XCTAssertTrue(seen.isEmpty)
    }
}
