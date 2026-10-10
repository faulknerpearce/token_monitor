import Foundation

/// Shared helpers for building and executing cookie/bearer-authenticated requests.
///
/// Common contract: Cookie or Authorization header, JSON Accept, optional
/// Referer, 401/403 → `.unauthorized`, 429 → `.rateLimited`, other non-2xx → `.badResponse`, transport
/// errors → `.network`.
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
        if response.statusCode == 429 {
            return .rateLimited(retryAfter: retryAfter(from: response))
        }
        guard (200..<300).contains(response.statusCode) else {
            return .badResponse("HTTP \(response.statusCode)")
        }
        return nil
    }

    /// `Retry-After` as seconds from now: either delta-seconds or an HTTP date.
    /// Nil when the header is missing or unparseable.
    static func retryAfter(from response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }
        if let seconds = TimeInterval(raw) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// Executes a request with the injected session, mapping errors onto the
    /// provider's `ProviderUsageError` via `map`. Returns response body bytes.
    static func perform(
        _ request: URLRequest,
        map: @escaping (UsageError) -> any Error
    ) async throws -> Data {
        try await performWithResponse(request, map: map).data
    }

    /// As `perform`, but also returns the response so callers can persist
    /// refreshed credentials (e.g. a rolling session cookie in `Set-Cookie`).
    static func performWithResponse(
        _ request: URLRequest,
        map: @escaping (UsageError) -> any Error
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw map(.network(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            throw map(.badResponse("Non-HTTP response"))
        }
        if let usageError = mapError(for: http, data: data) {
            throw map(usageError)
        }
        return (data, http)
    }
}
