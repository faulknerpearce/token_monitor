import Foundation

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
    /// An HTML sign-in page (served after an expired-session redirect: WorkOS,
    /// Clerk) maps to `.unauthorized`. Any other HTML, such as a bot-protection
    /// interstitial or an error page, and any malformed body stay transient, so
    /// the poller keeps the last-good snapshot and the session keeps its standing.
    static func jsonObject(
        _ data: Data,
        context: ProviderErrorContext
    ) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if looksLikeHTML(data) {
                if looksLikeLoginPage(data) {
                    throw ProviderError.unauthorized(context)
                }
                throw ProviderError.badResponse(context, "Unexpected HTML response")
            }
            throw ProviderError.badResponse(context, "Malformed response body")
        }
        return object
    }

    /// True when `data` looks like an HTML document; a malformed or truncated
    /// JSON payload reads false.
    static func looksLikeHTML(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(512), encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
    }

    /// Markers of a Cloudflare challenge / interstitial page.
    private static let challengeMarkers = [
        "cf-chl", "challenge-platform", "cf_chl_opt", "just a moment...",
        "attention required! | cloudflare", "cf-browser-verification"
    ]

    /// Markers of a provider sign-in page.
    private static let loginMarkers = [
        "type=\"password\"", "type='password'", "sign in", "sign-in", "signin",
        "log in", "log-in", "login", "authkit", "workos"
    ]

    /// Lowercased start of an HTML body, enough to hold the title and the
    /// first form. Decoded as Latin-1, which accepts any bytes (a UTF-8
    /// sequence cut at the limit included) and keeps the ASCII markers intact.
    private static func htmlPrefix(_ data: Data) -> String {
        (String(bytes: data.prefix(65_536), encoding: .isoLatin1) ?? "").lowercased()
    }

    /// True when an HTML body is a provider sign-in page.
    static func looksLikeLoginPage(_ data: Data) -> Bool {
        guard looksLikeHTML(data) else { return false }
        let html = htmlPrefix(data)
        if challengeMarkers.contains(where: html.contains) { return false }
        return loginMarkers.contains(where: html.contains)
    }

    /// True when `response` is a bot-protection challenge (Cloudflare), which
    /// says nothing about the credentials: any response carrying a
    /// `cf-mitigated` header, or a 403 whose body is HTML. A real credential
    /// rejection on these APIs is a 401, or a 403 with a JSON body.
    static func isBotChallenge(_ response: HTTPURLResponse, data: Data) -> Bool {
        if response.value(forHTTPHeaderField: "cf-mitigated") != nil { return true }
        return response.statusCode == 403 && looksLikeHTML(data)
    }

    /// User-facing message for a bot-protection challenge.
    static func botChallengeMessage(status: Int) -> String {
        "Request blocked by a bot-protection check (HTTP \(status)). Retrying."
    }

    /// Provider payloads can signal an expired session in the body with an
    /// `error` string (`not_authenticated` / `unauthorized`).
    static func isUnauthorizedMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("not_authenticated") || lowered.contains("unauthor")
    }

    /// Resolves `path` against `baseURL`, treating the base as a directory.
    ///
    /// A relative `path` (`"key"`) lands under the base's last segment, so
    /// `https://openrouter.ai/api/v1` + `"key"` is `…/api/v1/key` whether or not
    /// the base ends in `/`. A root-relative `path` (`"/api/…"`) replaces the
    /// base path, and an absolute URL string is used as-is.
    static func resolve(_ path: String, baseURL: URL) -> URL? {
        var base = baseURL.absoluteString
        if !base.hasSuffix("/") {
            base += "/"
        }
        guard let directory = URL(string: base) else { return nil }
        return URL(string: path, relativeTo: directory)?.absoluteURL
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
        guard let resolved = resolve(path, baseURL: baseURL) else {
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
        let forbidden = context.forbiddenMessage.map { ProviderError.custom(message: $0, usage: .badResponse($0)) }
        return try await AuthenticatedRequest.performWithResponse(request, forbidden: forbidden) { usageError in
            ProviderError(usageError, context: context)
        }
    }
}
