import Foundation

/// Session for chatgpt.com (`__Secure-next-auth.session-token` cookie).
///
/// The usage endpoint requires an OAuth bearer token; the poller exchanges the
/// captured session cookie for a short-lived access token via `/api/auth/session`.
@MainActor
final class ChatGPTAuthSession: ProviderAuthSession {
    private static let chatgptHosts = [
        "chatgpt.com",
        "www.chatgpt.com",
        "auth.openai.com",
        "auth0.openai.com",
        "api.openai.com"
    ]

    /// NextAuth's ChatGPT session cookie family. A large session JWT is chunked
    /// into `__Secure-next-auth.session-token.0`, `.1`, …, so the whole family is
    /// the session credential.
    static let sessionTokenPrefix = "__secure-next-auth.session-token"

    /// The cookies the usage token exchange sends: the session family only.
    /// The CSRF cookie is present on the sign-in page before sign-in, so it is
    /// excluded from the credential.
    static let essentialCookiePrefixes: Set<String> = [sessionTokenPrefix]

    static func chatgptPolicy() -> WebKitCookieCapture.Policy {
        WebKitCookieCapture.Policy(
            isDomain: { domain in Domain.matches(domain, hosts: chatgptHosts) },
            isPreferredSessionCookie: { cookie in
                let name = cookie.name.lowercased()
                return name == Self.sessionTokenPrefix || name.hasPrefix(Self.sessionTokenPrefix + ".")
            },
            looksLikeAuthCookie: { cookie in
                // Only a session token counts, so capture succeeds once the real
                // session cookie exists; analytics and CSRF cookies alone would
                // sign the user out on the first poll.
                let name = cookie.name.lowercased()
                if name.contains("csrf") { return false }
                return name.contains("session-token") || name.contains("session_token")
            },
            includeAllDomainCookiesWhenSessionFound: true,
            essentialCookiePrefixes: Self.essentialCookiePrefixes,
            maxAttempts: 4,
            failureMessage: "No ChatGPT session cookie found. Finish signing in to chatgpt.com, then click Capture Session."
        )
    }

    static func chatgptConfig() -> ProviderAuthConfig {
        ProviderAuthConfig(
            storeFilenamePrefix: "chatgpt_auth_",
            logCategory: "ChatGPTAuth",
            extraStoreKeys: [],
            signOutHosts: chatgptHosts,
            capturePolicy: chatgptPolicy(),
            isDomain: { domain in Domain.matches(domain, hosts: chatgptHosts) }
        )
    }

    /// Live store by default; tests isolate it to `directory` or pass `store`.
    init(directory: URL? = nil, store: (any CredentialStore)? = nil) {
        super.init(config: Self.chatgptConfig(), directory: directory, store: store)
    }
}
