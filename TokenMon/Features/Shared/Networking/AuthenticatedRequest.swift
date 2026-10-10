import Foundation

/// The `URLSession` every provider API request goes through.
///
/// Ephemeral, with cookie storage and the URL cache disabled: requests carry the
/// stored credential in an explicit `Cookie` / `Authorization` header, a
/// provider's `Set-Cookie` stays out of any shared jar that outlives sign-out,
/// and authenticated JSON stays in memory.
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
/// 401/403 → `.unauthorized`, 429 → `.rateLimited`, other non-2xx →
/// `.badResponse`, transport errors → `.network`.
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
    /// The user-facing message omits the response body, since it can echo
    /// credentials or internal identifiers.
    static func mapError(for response: HTTPURLResponse, data _: Data) -> UsageError? {
        if response.statusCode == 401 || response.statusCode == 403 {
            return .unauthorized
        }
        if response.statusCode == 429 {
            return .rateLimited(retryAfter: retryAfter(from: response))
        }
        guard (200..<300).contains(response.statusCode) else {
            return .badResponse("HTTP \(response.statusCode)")
        }
        return nil
    }

    /// Maps a response to a `UsageError`, or `nil` on success. A bot-protection
    /// challenge (see `ProviderHTTP.isBotChallenge`) is transient whatever its
    /// status, so it leaves the session's auth-failure count unchanged.
    static func responseError(for response: HTTPURLResponse, data: Data) -> UsageError? {
        if ProviderHTTP.isBotChallenge(response, data: data) {
            return .badResponse(ProviderHTTP.botChallengeMessage(status: response.statusCode))
        }
        return mapError(for: response, data: data)
    }

    /// Longest `Retry-After` honoured; a longer request waits this long.
    static let maxRetryAfter: TimeInterval = 60 * 60

    /// `Retry-After` as seconds from now, clamped to `0...maxRetryAfter`:
    /// either delta-seconds or an HTTP date. Nil when the header is missing or
    /// unparseable.
    static func retryAfter(from response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }
        if let seconds = TimeInterval(raw) {
            guard !seconds.isNaN else { return nil }
            return min(max(0, seconds), maxRetryAfter)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return min(max(0, date.timeIntervalSince(now)), maxRetryAfter)
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
    /// - Parameter forbidden: Thrown in place of the mapped `.unauthorized` for a
    ///   non-challenge 403, for endpoints whose 403 refuses one feature while the
    ///   session stays valid.
    /// `session.data(for:)`, with a cancelled request (system sleep, loop
    /// restart) thrown as `CancellationError` so pollers skip it.
    static func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    static func performWithResponse(
        _ request: URLRequest,
        session: URLSession = ProviderURLSession.shared,
        forbidden: (any Error)? = nil,
        map: @escaping (UsageError) -> any Error
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.data(for: request, session: session)
        } catch is CancellationError {
            throw CancellationError()
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
