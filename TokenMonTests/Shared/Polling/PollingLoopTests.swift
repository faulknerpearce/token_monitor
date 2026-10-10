@testable import TokenMon
import XCTest

/// PollingLoop scheduling, driven by a manual clock and sleeper so no test
/// waits on real time: first refresh, full-interval sleeps, parking on a nil
/// interval, wake/refreshNow re-arming, backoff, Retry-After, jitter, and
/// cancellation on stop and deinit.
@MainActor
final class PollingLoopTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var refreshCount = 0
    private var interval: TimeInterval? = 300
    private var outcomes: [PollOutcome] = []
    private var jitter = 0.0

    override func setUp() async throws {
        scheduler = ManualScheduler()
        refreshCount = 0
        interval = 300
        outcomes = []
        jitter = 0
    }

    private func makeLoop() -> PollingLoop {
        let scheduler = scheduler!
        return PollingLoop(
            interval: { [weak self] in self?.interval },
            now: { scheduler.now },
            sleep: { seconds in try await scheduler.sleep(seconds) },
            jitter: { [weak self] in self?.jitter ?? 0 },
            refresh: { [weak self] in self?.nextOutcome() ?? .skipped }
        )
    }

    private func nextOutcome() -> PollOutcome {
        refreshCount += 1
        return outcomes.isEmpty ? .success : outcomes.removeFirst()
    }

    func testRefreshesImmediatelyThenSleepsTheFullInterval() async throws {
        let loop = makeLoop()
        loop.start()
        let sleep = try await scheduler.nextSleep()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(sleep, 300, accuracy: 0.001)
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.fire()
        let next = try await scheduler.nextSleep()
        XCTAssertEqual(refreshCount, 2)
        XCTAssertEqual(next, 300, accuracy: 0.001)
        loop.stop()
    }

    func testNilIntervalParksWithoutATimerUntilWoken() async throws {
        interval = nil
        let loop = makeLoop()
        loop.start()
        await scheduler.settle()
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(scheduler.pendingCount, 0)

        interval = 60
        loop.wake()
        let sleep = try await scheduler.nextSleep()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(sleep, 60, accuracy: 0.001)

        interval = nil
        loop.wake()
        await scheduler.settle()
        XCTAssertEqual(scheduler.pendingCount, 0, "parking cancels the pending wait")
        loop.stop()
    }

    func testWakeWithShorterIntervalRefreshesWhenOverdue() async throws {
        let loop = makeLoop()
        loop.start()
        _ = try await scheduler.nextSleep()
        scheduler.now.addTimeInterval(100)

        interval = 60
        loop.wake()
        let sleep = try await scheduler.nextSleep()
        XCTAssertEqual(refreshCount, 2, "100s since the last refresh is past the 60s interval")
        XCTAssertEqual(sleep, 60, accuracy: 0.001)
        XCTAssertEqual(scheduler.pendingCount, 1, "the old wait was cancelled")
        loop.stop()
    }

    func testWakeRearmsTheRemainingWaitWhenNotYetDue() async throws {
        let loop = makeLoop()
        loop.start()
        _ = try await scheduler.nextSleep()
        scheduler.now.addTimeInterval(20)

        interval = 60
        loop.wake()
        let sleep = try await scheduler.nextSleep()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(sleep, 40, accuracy: 0.001)
        loop.stop()
    }

    func testRefreshNowRestartsTheWaitFromThatRefresh() async throws {
        let loop = makeLoop()
        loop.start()
        _ = try await scheduler.nextSleep()
        scheduler.now.addTimeInterval(250)

        await loop.refreshNow()
        let sleep = try await scheduler.nextSleep()
        XCTAssertEqual(refreshCount, 2)
        XCTAssertEqual(sleep, 300, accuracy: 0.001, "no early follow-up refresh after a manual one")
        XCTAssertEqual(scheduler.pendingCount, 1)
        loop.stop()
    }

    func testFailuresBackOffExponentiallyAndSuccessResets() async throws {
        interval = 10
        outcomes = [.failure(retryAfter: nil), .failure(retryAfter: nil), .success]
        let loop = makeLoop()
        loop.start()
        let first = try await scheduler.nextSleep()
        XCTAssertEqual(first, 30, accuracy: 0.001)
        scheduler.fire()
        let second = try await scheduler.nextSleep()
        XCTAssertEqual(second, 60, accuracy: 0.001)
        scheduler.fire()
        let third = try await scheduler.nextSleep()
        XCTAssertEqual(third, 10, accuracy: 0.001)
        loop.stop()
    }

    func testRetryAfterIsHonoured() async throws {
        interval = 10
        outcomes = [.failure(retryAfter: 500)]
        let loop = makeLoop()
        loop.start()
        let sleep = try await scheduler.nextSleep()
        XCTAssertEqual(sleep, 500, accuracy: 0.001)
        loop.stop()
    }

    func testSkippedRefreshKeepsTheInterval() async throws {
        interval = 10
        outcomes = [.skipped]
        let loop = makeLoop()
        loop.start()
        let sleep = try await scheduler.nextSleep()
        XCTAssertEqual(sleep, 10, accuracy: 0.001)
        loop.stop()
    }

    func testJitterStretchesTheWaitAndIsClampedToTenPercent() async throws {
        jitter = 0.1
        let loop = makeLoop()
        loop.start()
        let up = try await scheduler.nextSleep()
        XCTAssertEqual(up, 330, accuracy: 0.001)

        jitter = -0.5
        scheduler.fire()
        let down = try await scheduler.nextSleep()
        XCTAssertEqual(down, 270, accuracy: 0.001)
        loop.stop()
    }

    func testStopCancelsThePendingWait() async throws {
        let loop = makeLoop()
        loop.start()
        _ = try await scheduler.nextSleep()
        loop.stop()
        await scheduler.settle()
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(scheduler.cancelledCount, 1)
        XCTAssertEqual(refreshCount, 1)
    }

    func testPauseCancelsTheWaitAndResumeRefreshesWhenOverdue() async throws {
        let loop = makeLoop()
        loop.start()
        _ = try await scheduler.nextSleep()
        loop.pause()
        await scheduler.settle()
        XCTAssertEqual(scheduler.pendingCount, 0)

        scheduler.now.addTimeInterval(1000)
        loop.resume()
        _ = try await scheduler.nextSleep()
        XCTAssertEqual(refreshCount, 2)
        loop.stop()
    }

    func testDeinitCancelsTheWait() async throws {
        var loop: PollingLoop? = makeLoop()
        weak var weakLoop = loop
        loop?.start()
        _ = try await scheduler.nextSleep()
        loop = nil
        XCTAssertNil(weakLoop, "a sleeping loop must not retain itself")
        await scheduler.settle()
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testOutcomeClassifiesCancellationAndRateLimits() {
        XCTAssertEqual(PollOutcome(error: CancellationError()), .skipped)
        XCTAssertEqual(
            PollOutcome(error: ProviderError(.rateLimited(retryAfter: 42), context: .claude)),
            .failure(retryAfter: 42)
        )
        XCTAssertEqual(
            PollOutcome(error: ProviderError(.network("offline"), context: .claude)),
            .failure(retryAfter: nil)
        )
    }
}

/// Manual clock plus a sleeper whose waits complete only when `fire()` is called.
@MainActor
final class ManualScheduler {
    var now = Date(timeIntervalSince1970: 1_000_000)
    private(set) var cancelledCount = 0
    private var pending: [(id: Int, seconds: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextID = 0

    var pendingCount: Int { pending.count }

    func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.append((id, seconds, continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    /// Advances the clock by the oldest pending wait and completes it.
    func fire() {
        guard !pending.isEmpty else { return }
        let entry = pending.removeFirst()
        now.addTimeInterval(entry.seconds)
        entry.continuation.resume()
    }

    /// Duration of the newest pending wait, once queued work has settled and
    /// the loop has asked for one.
    func nextSleep(file: StaticString = #filePath, line: UInt = #line) async throws -> TimeInterval {
        await settle()
        for _ in 0..<1000 {
            if let last = pending.last { return last.seconds }
            await Task.yield()
        }
        XCTFail("loop never slept", file: file, line: line)
        throw CancellationError()
    }

    /// Lets queued main-actor work (task starts, cancellation hops) run.
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    private func cancel(_ id: Int) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let entry = pending.remove(at: index)
        cancelledCount += 1
        entry.continuation.resume(throwing: CancellationError())
    }
}
