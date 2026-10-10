import Combine
import Foundation

/// Uniform lifecycle surface every provider poller implements.
///
/// Exposes only the shared lifecycle — start/stop, manual refresh and the
/// polling loop (wake, pause/resume) — so app wiring can iterate over
/// providers; concrete snapshots live on `AppModel`.
@MainActor
protocol ProviderUsagePoller: ObservableObject {
    var menuIsOpen: Bool { get set }
    var lastRefreshedAt: Date? { get }
    var lastError: String? { get }
    /// The poller's timer; `wake()` it after an input to its interval changes.
    var pollingLoop: PollingLoop { get }
    func start()
    func stop()
    /// Fetches now (when the provider is enabled) and restarts the poll wait.
    func refreshNow() async
    func clearSnapshot()
}
