import Foundation
import Observation

/// Re-runs a handler whenever an observable value it depends on changes.
///
/// `track` runs inside `withObservationTracking`, so every `@Observable`
/// property it reads becomes a dependency; its result goes to `handle`,
/// which runs outside tracking. After a change the loop waits `coalescing`,
/// reads the current values with `track` again and calls `handle` once, so a
/// burst of changes produces one call with the latest values.
@MainActor
final class ObservationLoop {
    private let coalescing: Duration
    private var run: (@MainActor () -> Void)?
    private var isScheduled = false

    /// - Parameters:
    ///   - coalescing: Wait after a change before re-reading.
    ///   - initial: Calls `handle` with the first reading too.
    init<Value>(
        coalescing: Duration = .zero,
        initial: Bool = true,
        track: @escaping @MainActor () -> Value,
        handle: @escaping @MainActor (Value) -> Void
    ) {
        self.coalescing = coalescing
        var skipNext = !initial
        run = { [weak self] in
            let value = withObservationTracking(track) { [weak self] in
                Task { @MainActor in self?.changed() }
            }
            if skipNext {
                skipNext = false
            } else {
                handle(value)
            }
        }
        run?()
    }

    /// Stops observing; `handle` is not called again.
    func cancel() {
        run = nil
    }

    private func changed() {
        guard run != nil, !isScheduled else { return }
        isScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            if coalescing > .zero {
                try? await Task.sleep(for: coalescing)
            }
            isScheduled = false
            run?()
        }
    }
}
