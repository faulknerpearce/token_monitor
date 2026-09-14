import Foundation

/// Fetches Codex/ChatGPT rate-limit usage.
///
/// Two-step flow: the captured session cookie exchanges for a short-lived web
/// access token at `/api/auth/session`, which authorizes the internal
/// `/backend-api/wham/usage` endpoint.
struct ChatGPTUsageClient: Sendable {
    static let baseURL = URL(string: "https://chatgpt.com")!

    private let cookieHeader: String

    init(cookieHeader: String) {
        self.cookieHeader = cookieHeader
    }

    func fetchUsage(now: Date = Date()) async throws -> (ChatGPTUsageResponse, Date) {
        let accessToken = try await fetchAccessToken()
        let accountID = ChatGPTAccountID.fromAccessToken(accessToken)
        let data = try await whamUsage(accessToken: accessToken, accountID: accountID)
        let response = try ChatGPTUsageResponse.parse(data)
        return (response, now)
    }

    /// Parses the `/api/auth/session` payload for the bearer access token.
    static func parseSessionToken(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = JSON.string(root["accessToken"]), !token.isEmpty
        else {
            throw ProviderError.unauthorized(.chatGPT)
        }
        return token
    }

    private func fetchAccessToken() async throws -> String {
        let data = try await ProviderHTTP.get(
            "api/auth/session",
            baseURL: Self.baseURL,
            context: .chatGPT,
            cookieHeader: cookieHeader,
            referer: "https://chatgpt.com/"
        )
        return try Self.parseSessionToken(data)
    }

    private func whamUsage(accessToken: String, accountID: String?) async throws -> Data {
        try await ProviderHTTP.get(
            "/backend-api/wham/usage",
            baseURL: Self.baseURL,
            context: .chatGPT,
            cookieHeader: cookieHeader,
            bearerToken: accessToken,
            referer: "https://chatgpt.com/",
            headers: accountID.map { ["ChatGPT-Account-Id": $0] } ?? [:]
        )
    }
}
