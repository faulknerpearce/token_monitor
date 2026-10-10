import Foundation

/// Shared menu-open vs idle poll interval from settings.
@MainActor
enum PollInterval {
    static func seconds(menuIsOpen: Bool, settings: AppSettings) -> TimeInterval {
        TimeInterval(menuIsOpen ? settings.activePollSeconds : settings.idlePollSeconds)
    }

    /// The poll interval while `needed`, or nil so the loop parks until woken.
    static func seconds(menuIsOpen: Bool, settings: AppSettings, needed: Bool) -> TimeInterval? {
        needed ? seconds(menuIsOpen: menuIsOpen, settings: settings) : nil
    }
}

/// What one refresh achieved, so the loop can back off after failures.
enum PollOutcome: Equatable, Sendable {
    /// Fresh data arrived; any backoff is cleared.
    case success
    /// The fetch failed. `retryAfter` is the server's requested wait, when known.
    case failure(retryAfter: TimeInterval?)
    /// Nothing was fetched (not needed, signed out, already refreshing).
    case skipped

    /// Classifies a thrown fetch error. Task cancellation is `.skipped`, not a failure.
    init(error: Error) {
        if error is CancellationError {
            self = .skipped
        } else {
            self = .failure(retryAfter: (error as? ProviderUsageError)?.usageError.retryAfter)
        }
    }
}

/// Main-actor refresh loop.
///
/// Refreshes as soon as it starts, then sleeps the full remaining interval
/// between refreshes. `interval()` returning nil parks the loop (no timer at
/// all) until `wake()` re-evaluates it. Callers `wake()` the loop when an input
/// to `interval()` changes (menu opened, settings edited), which cancels the
/// pending wait and re-arms it from the last refresh time, refreshing at once
/// when that is already overdue.
///
/// After a failed refresh the wait grows exponentially (`BackoffTimer`), and a
/// server `Retry-After` is honoured. Every wait carries ±10% jitter so loops
/// started together drift apart.
@MainActor
final class PollingLoop {
    /// Suspends for the given number of seconds; throws when cancelled.
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let interval: @MainActor () -> TimeInterval?
    private let refresh: @MainActor () async -> PollOutcome
    private let now: @MainActor () -> Date
    private let sleep: Sleeper
    private let jitter: @MainActor () -> Double

    private var waitTask: Task<Void, Never>?
    private var isStarted = false
    private var isPaused = false
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    private var backoff: BackoffTimer
    private var retryAfterUntil: Date?
    private var jitterFactor: Double = 1

    /// - Parameters:
    ///   - interval: Seconds between refreshes, or nil when no polling is needed.
    ///   - backoff: Growth of the wait after consecutive failures.
    ///   - now: Clock (tests inject a manual one).
    ///   - sleep: Suspension used for the wait (tests inject a manual one).
    ///   - jitter: Fraction added to each wait, drawn from -0.1...0.1 by default.
    ///   - refresh: One poll; reports its outcome for backoff.
    init(
        interval: @escaping @MainActor () -> TimeInterval?,
        backoff: BackoffTimer = BackoffTimer(initial: 30, maximum: 600),
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping Sleeper = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        jitter: @escaping @MainActor () -> Double = { Double.random(in: -0.1...0.1) },
        refresh: @escaping @MainActor () async -> PollOutcome
    ) {
        self.interval = interval
        self.backoff = backoff
        self.now = now
        self.sleep = sleep
        self.jitter = jitter
        self.refresh = refresh
    }

    /// A loop whose refreshes report no outcome, so it never backs off.
    convenience init(
        interval: @escaping @MainActor () -> TimeInterval?,
        refresh: @escaping @MainActor () async -> Void
    ) {
        self.init(interval: interval) {
            await refresh()
            return .success
        }
    }

    deinit {
        waitTask?.cancel()
    }

    /// Starts polling: refreshes now when `interval()` is non-nil, else parks.
    func start() {
        isStarted = true
        lastRefreshAt = nil
        schedule()
    }

    func stop() {
        isStarted = false
        cancelWait()
    }

    /// Suspends the timer (system sleep) without forgetting the last refresh.
    func pause() {
        isPaused = true
        cancelWait()
    }

    /// Resumes after `pause()`, refreshing at once when a refresh is overdue.
    func resume() {
        isPaused = false
        schedule()
    }

    /// Re-evaluates `interval()` and re-arms the wait from the last refresh.
    /// No-op while a refresh is in flight (the next wait is computed after it).
    func wake() {
        guard !isRefreshing else { return }
        schedule()
    }

    /// Refreshes immediately and restarts the wait from this refresh, so a
    /// manual refresh is never followed by an early scheduled one. No-op while
    /// a refresh is already in flight.
    func refreshNow() async {
        guard !isRefreshing else { return }
        cancelWait()
        await runRefresh()
    }

    /// As `refreshNow()`, but only when the last refresh is older than `age`
    /// seconds (or there has been none).
    func refreshNow(ifOlderThan age: TimeInterval) async {
        if let lastRefreshAt, now().timeIntervalSince(lastRefreshAt) < age { return }
        await refreshNow()
    }

    /// Seconds until the next refresh is due, or nil when parked.
    func delayUntilDue() -> TimeInterval? {
        guard let base = interval(), base > 0 else { return nil }
        guard let lastRefreshAt else { return 0 }
        var wait = base
        if backoff.current > 0 {
            wait = max(wait, backoff.current)
        }
        var due = lastRefreshAt.addingTimeInterval(wait * jitterFactor)
        if let retryAfterUntil, retryAfterUntil > due {
            due = retryAfterUntil
        }
        return max(0, due.timeIntervalSince(now()))
    }

    private func schedule() {
        cancelWait()
        guard isStarted, !isPaused, let delay = delayUntilDue() else { return }
        let sleep = sleep
        waitTask = Task { [weak self] in
            if delay > 0 {
                do { try await sleep(delay) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.runRefresh()
        }
    }

    private func cancelWait() {
        waitTask?.cancel()
        waitTask = nil
    }

    private func runRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let outcome = await refresh()
        isRefreshing = false
        record(outcome)
        schedule()
    }

    private func record(_ outcome: PollOutcome) {
        let finishedAt = now()
        lastRefreshAt = finishedAt
        jitterFactor = 1 + min(0.1, max(-0.1, jitter()))
        switch outcome {
        case .success:
            backoff.reset()
            retryAfterUntil = nil
        case let .failure(retryAfter):
            backoff.recordFailure()
            retryAfterUntil = retryAfter.map { finishedAt.addingTimeInterval($0) }
        case .skipped:
            break
        }
    }
}
