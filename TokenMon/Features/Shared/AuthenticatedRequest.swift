import Foundation

/// The `URLSession` every provider API request goes through.
///
/// Ephemeral, with no cookie jar and no response cache: requests carry the
/// stored credential in an explicit `Cookie` / `Authorization` header, a
/// provider's `Set-Cookie` never lands in a shared jar that outlives sign-out,
/// and authenticated JSON is never written to a disk cache.
enum ProviderURLSession {
    static let shared = URLSession(configuration: configuration)

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

/// Shared helpers for building and executing cookie/bearer-authenticated requests.
///
/// Common contract: Cookie or Authorization header, JSON Accept, the app
/// User-Agent, optional Referer, a bot-protection challenge → `.badResponse`,
/// 401/403 → `.unauthorized`, other non-2xx → `.badResponse`, transport errors
/// → `.network`.
enum AuthenticatedRequest {
    /// Applies the standard auth/content headers to a request.
    static func applyHeaders(
        to request: inout URLRequest,
        cookieHeader: String?,
        bearerToken: String?,
        referer: String?
    ) {
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
    }

    /// Maps an HTTP response to a shared `UsageError`, or `nil` on success.
    ///
    /// The response body is not included in the user-facing message, since it can
    /// echo credentials or internal identifiers.
    static func mapError(for response: HTTPURLResponse, data _: Data) -> UsageError? {
        if response.statusCode == 401 || response.statusCode == 403 {
            return .unauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            return .badResponse("HTTP \(response.statusCode)")
        }
        return nil
    }

    /// Maps a response to a `UsageError`, or `nil` on success. A bot-protection
    /// challenge (see `ProviderHTTP.isBotChallenge`) is transient whatever its
    /// status, so it never counts against the session.
    static func responseError(for response: HTTPURLResponse, data: Data) -> UsageError? {
        if ProviderHTTP.isBotChallenge(response, data: data) {
            return .badResponse(ProviderHTTP.botChallengeMessage(status: response.statusCode))
        }
        return mapError(for: response, data: data)
    }

    /// Executes a request on `session`, mapping errors onto the provider's
    /// `ProviderUsageError` via `map`. Returns response body bytes.
    static func perform(
        _ request: URLRequest,
        session: URLSession = ProviderURLSession.shared,
        map: @escaping (UsageError) -> any Error
    ) async throws -> Data {
        try await performWithResponse(request, session: session, map: map).data
    }

    /// As `perform`, but also returns the response so callers can persist
    /// refreshed credentials (e.g. a rolling session cookie in `Set-Cookie`).
    ///
    /// - Parameter forbidden: Thrown for a non-challenge 403 instead of the
    ///   mapped `.unauthorized`, for endpoints whose 403 refuses a feature
    ///   rather than the session.
    static func performWithResponse(
        _ request: URLRequest,
        session: URLSession = ProviderURLSession.shared,
        forbidden: (any Error)? = nil,
        map: @escaping (UsageError) -> any Error
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw map(.network(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            throw map(.badResponse("Non-HTTP response"))
        }
        if let forbidden, http.statusCode == 403, !ProviderHTTP.isBotChallenge(http, data: data) {
            throw forbidden
        }
        if let usageError = responseError(for: http, data: data) {
            throw map(usageError)
        }
        return (data, http)
    }
}
