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
        try await getWithResponse(
            path,
            baseURL: baseURL,
            context: context,
            cookieHeader: cookieHeader,
            bearerToken: bearerToken,
            referer: referer,
            headers: headers
        ).data
    }

    /// As `get`, but also returns the response so callers can read `Set-Cookie`
    /// and persist a refreshed session cookie.
    static func getWithResponse(
        _ path: String,
        baseURL: URL,
        context: ProviderErrorContext,
        cookieHeader: String? = nil,
        bearerToken: String? = nil,
        referer: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> (data: Data, response: HTTPURLResponse) {
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

    /// Every `Set-Cookie` value on `response`, in header order.
    static func setCookieHeaders(from response: HTTPURLResponse) -> [String] {
        response.allHeaderFields
            .filter { ($0.key as? String)?.lowercased() == "set-cookie" }
            .compactMap { $0.value as? String }
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
        ).data
    }

    /// Decodes a 2xx body as a JSON object.
    ///
    /// An HTML body is a provider's sign-in page served after an expired-session
    /// redirect (WorkOS, Clerk), so it maps to `.unauthorized`. Any other
    /// malformed body stays transient, so the poller keeps the last-good
    /// snapshot instead of signing the user out on a truncated response.
    static func jsonObject(
        _ data: Data,
        context: ProviderErrorContext
    ) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if looksLikeHTML(data) {
                throw ProviderError.unauthorized(context)
            }
            throw ProviderError.badResponse(context, "Malformed response body")
        }
        return object
    }

    /// True when `data` looks like an HTML document (a sign-in page), as opposed
    /// to a malformed or truncated JSON payload.
    static func looksLikeHTML(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(512), encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
    }

    /// Provider payloads signal an expired session with an `error` string
    /// (`not_authenticated` / `unauthorized`) rather than a 401/403 status.
    static func isUnauthorizedMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("not_authenticated") || lowered.contains("unauthor")
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
    ) async throws -> (data: Data, response: HTTPURLResponse) {
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
        return try await AuthenticatedRequest.performWithResponse(request) { usageError in
            ProviderError(usageError, context: context)
        }
    }
}
