import Foundation

/// Common usage-fetch failure cases shared across providers.
///
/// Provider clients map their provider-specific errors onto these cases via
/// `ProviderUsageError.usageError`.
enum UsageError: LocalizedError, Equatable {
    case notSignedIn
    case unauthorized
    case network(String)
    case badResponse(String)
    /// HTTP 429. `retryAfter` is the server's `Retry-After` delay in seconds, when sent.
    case rateLimited(retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to load usage."
        case .unauthorized:
            return "Session expired. Sign in again."
        case let .network(message):
            return "Network error: \(message)"
        case let .badResponse(message):
            return "Response error: \(message)"
        case .rateLimited:
            return "Rate limited. Retrying later."
        }
    }
}

extension UsageError {
    /// Server-requested wait before the next attempt, when this is a rate limit.
    var retryAfter: TimeInterval? {
        guard case let .rateLimited(retryAfter) = self else { return nil }
        return retryAfter
    }
}

/// Anything that can be reduced to the shared `UsageError` cases.
protocol ProviderUsageError: Error {
    var usageError: UsageError { get }
}
