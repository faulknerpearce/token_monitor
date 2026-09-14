import Foundation

/// User-facing wording for a provider's usage errors.
struct ProviderErrorContext: Sendable, Equatable {
    var displayName: String
    var notSignedInMessage: String
    var unauthorizedMessage: String

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

    static let grokbot = ProviderErrorContext(
        displayName: "Grokbot",
        notSignedInMessage: "Sign in to Cursor to load your Grokbot allowance.",
        unauthorizedMessage: "Cursor session expired. Sign in again."
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

/// Shared HTTP plumbing for cookie/bearer-authenticated provider requests.
enum ProviderHTTP {
    static func get(
        _ path: String,
        baseURL: URL,
        context: ProviderErrorContext,
        cookieHeader: String? = nil,
        bearerToken: String? = nil,
        referer: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        try await send(
            path,
            baseURL: baseURL,
            method: "GET",
            context: context,
            cookieHeader: cookieHeader,
            bearerToken: bearerToken,
            referer: referer,
            headers: headers
        )
    }

    static func post(
        _ path: String,
        baseURL: URL,
        context: ProviderErrorContext,
        json: [String: Any],
        cookieHeader: String? = nil,
        bearerToken: String? = nil,
        referer: String? = nil,
        origin: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        try await send(
            path,
            baseURL: baseURL,
            method: "POST",
            context: context,
            cookieHeader: cookieHeader,
            bearerToken: bearerToken,
            referer: referer,
            origin: origin,
            headers: headers,
            json: json
        )
    }

    private static func send(
        _ path: String,
        baseURL: URL,
        method: String,
        context: ProviderErrorContext,
        cookieHeader: String?,
        bearerToken: String?,
        referer: String?,
        origin: String? = nil,
        headers: [String: String] = [:],
        json: [String: Any]? = nil
    ) async throws -> Data {
        guard let resolved = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw ProviderError.badResponse(context, "Invalid path \(path)")
        }
        var request = URLRequest(url: resolved)
        request.httpMethod = method
        AuthenticatedRequest.applyHeaders(
            to: &request,
            cookieHeader: cookieHeader,
            bearerToken: bearerToken,
            referer: referer
        )
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await AuthenticatedRequest.perform(request) { usageError in
            ProviderError(usageError, context: context)
        }
    }
}
