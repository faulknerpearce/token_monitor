import Foundation
import os

/// The session surface a provider refresh needs: the credential generation
/// and the rejection streak.
@MainActor
protocol PollingAuthSession: AnyObject {
    var sessionGeneration: Int { get }
    /// True when `generation` still describes the live, usable session.
    func isCurrent(_ generation: Int) -> Bool
    @discardableResult
    func recordAuthFailure(reason: String) -> Bool
    func recordAuthSuccess()
}

extension ProviderAuthSession: PollingAuthSession {}
extension OpenRouterAuthSession: PollingAuthSession {}

/// The fetch, stale-session and error steps every provider poller shares.
@MainActor
enum ProviderRefresh {
    /// Runs `fetch` under the session generation current at the call.
    ///
    /// A result is passed to `publish` only while that generation is still
    /// live, so a response that finishes after a sign-out or account switch is
    /// dropped. A failure is reported only for the live generation: a
    /// rejected session (`unauthorized` / `notSignedIn`) runs `onRejected`,
    /// then counts toward the session's rejection streak; every failure goes to
    /// `reportError` and the log. Cancellation is `.skipped`.
    ///
    /// - Parameters:
    ///   - label: Provider name used in log lines.
    ///   - publish: Stores the fetched value; returns the poll outcome.
    /// - Returns: The outcome for `PollingLoop` backoff.
    static func run<Value>(
        auth: some PollingAuthSession,
        logger: Logger,
        label: String,
        fetch: () async throws -> Value,
        publish: (Value) -> PollOutcome,
        onRejected: () -> Void = {},
        reportError: (String) -> Void
    ) async -> PollOutcome {
        let generation = auth.sessionGeneration
        do {
            let value = try await fetch()
            guard !Task.isCancelled, auth.isCurrent(generation) else { return .skipped }
            auth.recordAuthSuccess()
            return publish(value)
        } catch is CancellationError {
            return .skipped
        } catch {
            guard auth.isCurrent(generation) else { return .skipped }
            if let providerError = error as? ProviderError {
                switch providerError.usageError {
                case .unauthorized, .notSignedIn:
                    onRejected()
                    auth.recordAuthFailure(reason: providerError.localizedDescription)
                default:
                    break
                }
            }
            reportError(error.localizedDescription)
            logger.error("\(label, privacy: .public) refresh failed: \(error.localizedDescription, privacy: .public)")
            return PollOutcome(error: error)
        }
    }
}
