import AppKit
import Foundation
import Network

/// Pauses polling across system sleep and resumes it once the network is back.
///
/// On wake the interfaces are usually still down, so refreshing straight away
/// fails every provider at once. The gate waits for `NWPathMonitor` to report a
/// satisfied path after the wake (or for `fallbackDelay` when the path stays
/// unchanged) before calling `onReady`.
@MainActor
final class SystemWakeGate {
    /// Suspends for the given number of seconds; throws when cancelled.
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let onSleep: @MainActor () -> Void
    private let onReady: @MainActor () -> Void
    private let fallbackDelay: TimeInterval
    private let sleep: Sleeper
    private var monitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var fallbackTask: Task<Void, Never>?

    /// Latest path status reported by the monitor.
    private(set) var isNetworkSatisfied = true
    /// True between a wake and the moment polling resumes.
    private(set) var isAwaitingNetwork = false
    /// Set by a path update that arrives after the last sleep.
    private var pathUpdatedSinceSleep = false

    /// - Parameters:
    ///   - observeSystem: Subscribe to workspace sleep/wake and start the path
    ///     monitor. Tests pass false and drive the handlers directly.
    init(
        observeSystem: Bool = true,
        fallbackDelay: TimeInterval = 30,
        sleep: @escaping Sleeper = { seconds in
            try await Task.sleep(nanoseconds: UInt64(min(max(0, seconds), 86_400) * 1_000_000_000))
        },
        onSleep: @escaping @MainActor () -> Void,
        onReady: @escaping @MainActor () -> Void
    ) {
        self.fallbackDelay = fallbackDelay
        self.sleep = sleep
        self.onSleep = onSleep
        self.onReady = onReady
        guard observeSystem else { return }
        observeWorkspace()
        startPathMonitor()
    }

    deinit {
        monitor?.cancel()
        fallbackTask?.cancel()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func systemWillSleep() {
        isAwaitingNetwork = false
        pathUpdatedSinceSleep = false
        fallbackTask?.cancel()
        fallbackTask = nil
        onSleep()
    }

    func systemDidWake() {
        isAwaitingNetwork = true
        if pathUpdatedSinceSleep, isNetworkSatisfied {
            finishWake()
            return
        }
        let sleep = sleep
        let delay = fallbackDelay
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            self?.finishWake()
        }
    }

    func pathChanged(satisfied: Bool) {
        isNetworkSatisfied = satisfied
        pathUpdatedSinceSleep = true
        if satisfied, isAwaitingNetwork {
            finishWake()
        }
    }

    private func finishWake() {
        guard isAwaitingNetwork else { return }
        isAwaitingNetwork = false
        fallbackTask?.cancel()
        fallbackTask = nil
        onReady()
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        })
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "TokenMon.NetworkPath", qos: .utility))
        self.monitor = monitor
    }
}
