@testable import TokenMon
import XCTest

/// Sleep pauses polling; wake resumes it only once the network path is
/// satisfied again, or after the fallback delay when the path never changes.
@MainActor
final class SystemWakeGateTests: XCTestCase {
    private var events: [String] = []
    private var scheduler: ManualScheduler!

    override func setUp() async throws {
        events = []
        scheduler = ManualScheduler()
    }

    private func makeGate() -> SystemWakeGate {
        let scheduler = scheduler!
        return SystemWakeGate(
            observeSystem: false,
            fallbackDelay: 30,
            sleep: { seconds in try await scheduler.sleep(seconds) },
            onSleep: { [weak self] in self?.events.append("sleep") },
            onReady: { [weak self] in self?.events.append("ready") }
        )
    }

    func testWakeWaitsForASatisfiedPath() async {
        let gate = makeGate()
        gate.systemWillSleep()
        gate.systemDidWake()
        XCTAssertEqual(events, ["sleep"])
        gate.pathChanged(satisfied: false)
        XCTAssertEqual(events, ["sleep"])
        gate.pathChanged(satisfied: true)
        XCTAssertEqual(events, ["sleep", "ready"])
        await scheduler.settle()
        XCTAssertEqual(scheduler.pendingCount, 0, "the fallback wait is cancelled")
    }

    func testPathThatCameBackDuringWakeResumesImmediately() {
        let gate = makeGate()
        gate.systemWillSleep()
        gate.pathChanged(satisfied: true)
        gate.systemDidWake()
        XCTAssertEqual(events, ["sleep", "ready"])
    }

    func testFallbackResumesWhenThePathNeverChanges() async throws {
        let gate = makeGate()
        gate.systemWillSleep()
        gate.systemDidWake()
        let delay = try await scheduler.nextSleep()
        XCTAssertEqual(delay, 30)
        scheduler.fire()
        await scheduler.settle()
        XCTAssertEqual(events, ["sleep", "ready"])
    }

    func testPathChangesOutsideAWakeDoNothing() {
        let gate = makeGate()
        gate.pathChanged(satisfied: false)
        gate.pathChanged(satisfied: true)
        XCTAssertEqual(events, [])
    }
}
