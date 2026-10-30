import Combine
import Foundation

/// Uniform surface every provider poller implements.
///
/// Exposes the shared lifecycle (start/stop, manual refresh, the polling
/// loop) and the headline figures the menu bar and the usage alert read, so
/// app wiring iterates over providers; each poller's full snapshot stays on
/// its concrete type.
@MainActor
protocol ProviderUsagePoller: ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    var menuIsOpen: Bool { get set }
    var lastRefreshedAt: Date? { get }
    var lastError: String? { get }
    /// Headline used percentage (the menu-bar figure and the alert input);
    /// nil without data.
    var headlineUsedPercent: Double? { get }
    /// When the headline pool resets, when the provider reports it.
    var headlineResetsAt: Date? { get }
    /// Signed-in account the usage alert is scoped to.
    var alertAccount: String? { get }
    /// The poller's timer; `wake()` it after an input to its interval changes.
    var pollingLoop: PollingLoop { get }
    func start()
    func stop()
    /// Fetches now (when the provider is enabled) and restarts the poll wait.
    func refreshNow() async
    /// Drops the displayed snapshot. Stored history is kept.
    func clearSnapshot()
}
