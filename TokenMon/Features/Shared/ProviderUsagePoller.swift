import Combine
import Foundation

/// Uniform lifecycle surface every provider poller implements.
///
/// Exposes only the shared lifecycle — start/stop and manual refresh — so app
/// wiring can iterate over providers; concrete snapshots live on `AppModel`.
@MainActor
protocol ProviderUsagePoller: ObservableObject {
    var menuIsOpen: Bool { get set }
    func start()
    func stop()
    func refreshNow() async
    func clearSnapshot()
}
