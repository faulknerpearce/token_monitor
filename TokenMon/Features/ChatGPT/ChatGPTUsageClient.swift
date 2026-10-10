import Foundation

/// Fetches Codex/ChatGPT rate-limit usage.
///
/// Two-step flow: the captured session cookie exchanges for a short-lived web
/// access token at `/api/auth/session`, which authorizes the internal
/// `/backend-api/wham/usage` endpoint.
struct ChatGPTUsageClient: Sendable {
    static let baseURL = URL(staticString: "https://chatgpt.com")

    /// One usage refresh: the parsed payload plus any `Set-Cookie` the server
    /// returned. NextAuth renews the session cookie on `/api/auth/session`, so
    /// the poller folds these back into the stored header before the rolling
    /// cookie can hard-expire.
    struct Fetch: Sendable {
        var response: ChatGPTUsageResponse
        var fetchedAt: Date
        var setCookieHeaders: [String]
    }

    /// Network seam: `/api/auth/session` and `wham/usage`, each returning the
    /// body and any `Set-Cookie` values.
    struct Transport: Sendable {
        var session: @Sendable (_ cookieHeader: String) async throws -> (Data, [String])
        var usage: @Sendable (_ cookieHeader: String, _ accessToken: String, _ accountID: String?) async throws -> (Data, [String])
    }

    private let cookieHeader: String
    private let transport: Transport
    private let tokenCache: ChatGPTAccessTokenCache?
    private let tokenCacheKey: String

    /// `tokenCache` keeps the exchanged access token between calls (nil
    /// exchanges the cookie on every call). `tokenCacheKey` identifies the
    /// signed-in session; it stays the same while the session cookie is
    /// renewed, so a renewed cookie still reuses the cached token.
    init(
        cookieHeader: String,
        tokenCache: ChatGPTAccessTokenCache? = nil,
        tokenCacheKey: String = "",
        transport: Transport = .live
    ) {
        self.cookieHeader = cookieHeader
        self.tokenCache = tokenCache
        self.tokenCacheKey = tokenCacheKey
        self.transport = transport
    }

    /// Fetches `wham/usage` with a cached access token when one is valid,
    /// otherwise exchanges the session cookie for a fresh token first.
    ///
    /// A cached token rejected with 401/403 is dropped and the call retried once
    /// with a freshly exchanged token.
    func fetchUsage(now: Date = Date()) async throws -> Fetch {
        if let cached = tokenCache?.token(forKey: tokenCacheKey, now: now) {
            do {
                return try await usage(accessToken: cached, sessionCookies: [], now: now)
            } catch let error as ProviderError where error.usageError == .unauthorized {
                tokenCache?.clear()
            }
        }
        let session = try await fetchSession()
        tokenCache?.store(
            session.accessToken,
            forKey: tokenCacheKey,
            validUntil: ChatGPTAccessTokenCache.validUntil(accessToken: session.accessToken, now: now)
        )
        return try await usage(accessToken: session.accessToken, sessionCookies: session.setCookieHeaders, now: now)
    }

    private func usage(accessToken: String, sessionCookies: [String], now: Date) async throws -> Fetch {
        let accountID = ChatGPTAccountID.fromAccessToken(accessToken)
        let (data, usageCookies) = try await transport.usage(cookieHeader, accessToken, accountID)
        return try Fetch(
            response: ChatGPTUsageResponse.parse(data),
            fetchedAt: now,
            setCookieHeaders: sessionCookies + usageCookies
        )
    }

    /// Parses the `/api/auth/session` payload for the bearer access token.
    ///
    /// A non-JSON body (an HTML edge challenge or the sign-in page) maps to a
    /// transient error, which keeps the stored credential: such a body also
    /// appears while the session is still valid.
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
        let (data, cookies) = try await transport.session(cookieHeader)
        return try (Self.parseSessionToken(data), cookies)
    }
}

extension ChatGPTUsageClient.Transport {
    /// Cookie-authenticated requests against chatgpt.com.
    static let live = Self(
        session: { cookieHeader in
            let result = try await ProviderHTTP.getWithResponse(
                "api/auth/session",
                baseURL: ChatGPTUsageClient.baseURL,
                context: .chatGPT,
                cookieHeader: cookieHeader,
                referer: "https://chatgpt.com/"
            )
            return (result.data, ProviderHTTP.setCookieHeaders(from: result.response))
        },
        usage: { cookieHeader, accessToken, accountID in
            let result = try await ProviderHTTP.getWithResponse(
                "/backend-api/wham/usage",
                baseURL: ChatGPTUsageClient.baseURL,
                context: .chatGPT,
                cookieHeader: cookieHeader,
                bearerToken: accessToken,
                referer: "https://chatgpt.com/",
                headers: accountID.map { ["ChatGPT-Account-Id": $0] } ?? [:]
            )
            return (result.data, ProviderHTTP.setCookieHeaders(from: result.response))
        }
    )
}

/// In-memory cache of the web access token exchanged for a session cookie.
///
/// The token is reused until shortly before its JWT `exp`, and for at most
/// ``sessionRenewInterval``: the `/api/auth/session` exchange also renews the
/// rolling session cookie, so it runs regularly.
final class ChatGPTAccessTokenCache: @unchecked Sendable {
    /// Longest a token is reused before the session endpoint is called again.
    static let sessionRenewInterval: TimeInterval = 30 * 60
    /// Margin before the token's own expiry at which reuse stops.
    static let expiryMargin: TimeInterval = 5 * 60
    /// Reuse period for a token whose expiry cannot be read.
    static let unknownExpiryLifetime: TimeInterval = 5 * 60

    private let lock = NSLock()
    private var entry: (key: String, token: String, validUntil: Date)?

    /// The cached token for `key` while it is still valid at `now`.
    func token(forKey key: String, now: Date) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.key == key, now < entry.validUntil else { return nil }
        return entry.token
    }

    func store(_ token: String, forKey key: String, validUntil: Date) {
        lock.lock()
        defer { lock.unlock() }
        entry = (key, token, validUntil)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
    }

    /// Reuse deadline for `accessToken` fetched at `now`.
    static func validUntil(accessToken: String, now: Date) -> Date {
        let renewBy = now.addingTimeInterval(sessionRenewInterval)
        guard let expiry = ChatGPTAccountID.expiry(fromAccessToken: accessToken) else {
            return now.addingTimeInterval(unknownExpiryLifetime)
        }
        return min(renewBy, expiry.addingTimeInterval(-expiryMargin))
    }
}
