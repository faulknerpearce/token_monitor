import Foundation

/// User-facing wording for a provider's usage errors.
struct ProviderErrorContext: Sendable, Equatable {
    var displayName: String
    var notSignedInMessage: String
    var unauthorizedMessage: String
    /// Message for a 403 that refuses one feature while the session stays valid.
    /// When set, a non-challenge 403 maps to a transient error with this
    /// message in place of `.unauthorized`.
    var forbiddenMessage: String?

    static let claude = ProviderErrorContext(
        displayName: "Claude",
        notSignedInMessage: "Sign in to Claude to load usage.",
        unauthorizedMessage: "Claude session expired. Sign in again."
    )

    static let chatGPT = ProviderErrorContext(
        displayName: "ChatGPT",
        notSignedInMessage: "Sign in to ChatGPT to load usage.",
        unauthorizedMessage: "ChatGPT session expired. Sign in again."
    )

    static let cursor = ProviderErrorContext(
        displayName: "Cursor",
        notSignedInMessage: "Sign in to Cursor to load usage.",
        unauthorizedMessage: "Cursor session expired. Sign in again."
    )

    static let grok = ProviderErrorContext(
        displayName: "Grok",
        notSignedInMessage: "Sign in to grok.com to load usage.",
        unauthorizedMessage: "Session expired. Please sign in again."
    )

    /// Grokbot borrows the Cursor session; a 403 from the Bot endpoint means
    /// this account lacks Bot access while the Cursor session stays valid.
    static let grokbot = ProviderErrorContext(
        displayName: "Grokbot",
        notSignedInMessage: "Sign in to Cursor to load your Grokbot allowance.",
        unauthorizedMessage: "Cursor session expired. Sign in again.",
        forbiddenMessage: "Grok Bot is not available on this Cursor account."
    )

    static let openCode = ProviderErrorContext(
        displayName: "OpenCode console",
        notSignedInMessage: "Sign in to the OpenCode console to load official Go usage.",
        unauthorizedMessage: "OpenCode console session expired. Sign in again."
    )

    static let openRouter = ProviderErrorContext(
        displayName: "OpenRouter",
        notSignedInMessage: "Add an OpenRouter API key to load usage.",
        unauthorizedMessage: "OpenRouter rejected the API key. Check or replace it."
    )
}

/// A usage-fetch failure tagged with the provider's user-facing wording.
enum ProviderError: LocalizedError, ProviderUsageError, Equatable {
    case notSignedIn(ProviderErrorContext)
    case unauthorized(ProviderErrorContext)
    case badResponse(ProviderErrorContext, String)
    case network(ProviderErrorContext, String)
    /// Provider-specific failure with a prebuilt message and its shared mapping.
    case custom(message: String, usage: UsageError)

    init(_ usageError: UsageError, context: ProviderErrorContext) {
        switch usageError {
        case .notSignedIn: self = .notSignedIn(context)
        case .unauthorized: self = .unauthorized(context)
        case let .network(message): self = .network(context, message)
        case let .badResponse(message): self = .badResponse(context, message)
        case .rateLimited:
            self = .custom(message: "\(context.displayName) is rate limiting requests. Retrying later.", usage: usageError)
        }
    }

    var usageError: UsageError {
        switch self {
        case .notSignedIn: return .notSignedIn
        case .unauthorized: return .unauthorized
        case let .badResponse(_, message): return .badResponse(message)
        case let .network(_, message): return .network(message)
        case let .custom(_, usage): return usage
        }
    }

    var errorDescription: String? {
        switch self {
        case let .notSignedIn(context): return context.notSignedInMessage
        case let .unauthorized(context): return context.unauthorizedMessage
        case let .badResponse(context, message): return "\(context.displayName) response error: \(message)"
        case let .network(context, message): return "\(context.displayName) network error: \(message)"
        case let .custom(message, _): return message
        }
    }
}
