import Foundation

/// Fetches Codex/ChatGPT rate-limit usage.
///
/// Two-step flow: the captured session cookie exchanges for a short-lived web
/// access token at `/api/auth/session`, which authorizes the internal
/// `/backend-api/wham/usage` endpoint.
struct ChatGPTUsageClient: Sendable {
    static let baseURL = URL(string: "https://chatgpt.com")!

    /// One usage refresh: the parsed payload plus any `Set-Cookie` the server
    /// returned. NextAuth renews the session cookie on `/api/auth/session`, so
    /// the poller folds these back into the stored header before the rolling
    /// cookie can hard-expire.
    struct Fetch: Sendable {
        var response: ChatGPTUsageResponse
        var fetchedAt: Date
        var setCookieHeaders: [String]
    }

    private let cookieHeader: String

    init(cookieHeader: String) {
        self.cookieHeader = cookieHeader
    }

    func fetchUsage(now: Date = Date()) async throws -> Fetch {
        let session = try await fetchSession()
        let accountID = ChatGPTAccountID.fromAccessToken(session.accessToken)
        let usage = try await whamUsage(accessToken: session.accessToken, accountID: accountID)
        let response = try ChatGPTUsageResponse.parse(usage.data)
        return Fetch(
            response: response,
            fetchedAt: now,
            setCookieHeaders: session.setCookieHeaders + usage.setCookieHeaders
        )
    }

    /// Parses the `/api/auth/session` payload for the bearer access token.
    ///
    /// A non-JSON body (an HTML edge challenge or the sign-in page) is not proof
    /// that the stored session is dead, so it stays transient: mapping it to
    /// `.unauthorized` would delete the credential the user just captured.
    static func parseSessionToken(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let message = ProviderHTTP.looksLikeHTML(data)
                ? "Sign-in page returned instead of a session token"
                : "Malformed session payload"
            throw ProviderError.badResponse(.chatGPT, message)
        }
        guard let token = JSON.string(root["accessToken"]), !token.isEmpty else {
            throw ProviderError.unauthorized(.chatGPT)
        }
        return token
    }

    private func fetchSession() async throws -> (accessToken: String, setCookieHeaders: [String]) {
        let result = try await ProviderHTTP.getWithResponse(
            "api/auth/session",
            baseURL: Self.baseURL,
            context: .chatGPT,
            cookieHeader: cookieHeader,
            referer: "https://chatgpt.com/"
        )
        return (
            try Self.parseSessionToken(result.data),
            ProviderHTTP.setCookieHeaders(from: result.response)
        )
    }

    private func whamUsage(
        accessToken: String,
        accountID: String?
    ) async throws -> (data: Data, setCookieHeaders: [String]) {
        let result = try await ProviderHTTP.getWithResponse(
            "/backend-api/wham/usage",
            baseURL: Self.baseURL,
            context: .chatGPT,
            cookieHeader: cookieHeader,
            bearerToken: accessToken,
            referer: "https://chatgpt.com/",
            headers: accountID.map { ["ChatGPT-Account-Id": $0] } ?? [:]
        )
        return (result.data, ProviderHTTP.setCookieHeaders(from: result.response))
    }
}
