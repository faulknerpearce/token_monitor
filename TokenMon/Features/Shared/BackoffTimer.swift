import Foundation

/// Exponential backoff for poller retries.
///
/// Starts at 0 (no backoff). Each `recordFailure()` doubles the delay from
/// `initial` up to `maximum`; `reset()` clears it after a success.
@MainActor
struct BackoffTimer {
    private let initial: TimeInterval
    private let maximum: TimeInterval
    private(set) var current: TimeInterval = 0

    init(initial: TimeInterval, maximum: TimeInterval) {
        self.initial = initial
        self.maximum = maximum
    }

    /// Doubles the delay (starting from `initial`), capped at `maximum`.
    mutating func recordFailure() {
        if current == 0 {
            current = initial
        } else {
            current = min(current * 2, maximum)
        }
    }

    /// Clears backoff after a successful refresh.
    mutating func reset() {
        current = 0
    }
}
