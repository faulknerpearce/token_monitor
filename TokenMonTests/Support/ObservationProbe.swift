import Foundation
import Observation

/// Records whether a value read by `read` changed since the last check.
@MainActor
final class ObservationProbe {
    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    private let read: () -> Void
    private var flag = Flag()

    init(_ read: @escaping () -> Void) {
        self.read = read
        arm()
    }

    /// True when an observed value changed since the last call; observes again.
    func changed() -> Bool {
        let fired = flag.fired
        arm()
        return fired
    }

    private func arm() {
        let flag = Flag()
        self.flag = flag
        withObservationTracking(read) { flag.fired = true }
    }
}
