import Foundation

/// Shared helpers for building and executing cookie/bearer-authenticated requests.
///
/// Common contract: Cookie or Authorization header, JSON Accept, optional
/// Referer, 401/403 → `.unauthorized`, other non-2xx → `.badResponse`, transport
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
        guard (200..<300).contains(response.statusCode) else {
            return .badResponse("HTTP \(response.statusCode)")
        }
        return nil
    }

    /// Executes a request with the injected session, mapping errors onto the
    /// provider's `ProviderUsageError` via `map`. Returns response body bytes.
    static func perform(
        _ request: URLRequest,
        map: @escaping (UsageError) -> any Error
    ) async throws -> Data {
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
        return data
    }
}
