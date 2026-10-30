import Combine
import Foundation

/// Model-layer registry mapping each `MonitorProvider` to its live poller and
/// the session it signs in with.
///
/// App wiring (polling, menu-open refresh, sign-in completion, change
/// forwarding, usage alerts, the menu-bar image) iterates the registry, so
/// adding a provider means adding one entry.
@MainActor
struct ProviderRegistry {
    struct Entry {
        let provider: MonitorProvider
        let poller: any ProviderUsagePoller
        /// The session the provider signs in with; providers that share a
        /// session (Grokbot uses Cursor's) hold the same object.
        let auth: any ObservableObject
    }

    private let entries: [MonitorProvider: Entry]

    init(_ entries: [Entry]) {
        self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.provider, $0) })
    }

    /// Every registered provider in `MonitorProvider.allCases` order.
    var all: [(provider: MonitorProvider, poller: any ProviderUsagePoller)] {
        MonitorProvider.allCases.compactMap { provider in
            entries[provider].map { (provider, $0.poller) }
        }
    }

    /// Each distinct session once.
    var sessions: [any ObservableObject] {
        var seen = Set<ObjectIdentifier>()
        return MonitorProvider.allCases.compactMap { provider in
            guard let auth = entries[provider]?.auth, seen.insert(ObjectIdentifier(auth)).inserted else { return nil }
            return auth
        }
    }

    /// The pollers of every provider that signs in with `provider`'s session.
    func pollers(sharingSessionWith provider: MonitorProvider) -> [any ProviderUsagePoller] {
        guard let auth = entries[provider]?.auth else { return [] }
        return MonitorProvider.allCases.compactMap { other in
            guard let entry = entries[other], entry.auth === auth else { return nil }
            return entry.poller
        }
    }

    func startAll() {
        for (_, poller) in all { poller.start() }
    }
}
