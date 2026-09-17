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

    /// The cookies the usage token exchange actually sends. Narrowing the
    /// persisted jar to these keeps unrelated analytics and SSO cookies out of
    /// `chatgpt_auth_session.dat`; when none is present the capture falls back to
    /// the full domain jar so sign-in still works.
    static let essentialCookieNames: Set<String> = [
        "__secure-next-auth.session-token",
        "__host-next-auth.csrf-token"
    ]

    static func chatgptPolicy() -> WebKitCookieCapture.Policy {
        WebKitCookieCapture.Policy(
            isDomain: { domain in Domain.matches(domain, hosts: chatgptHosts) },
            isPreferredSessionCookie: {
                $0.name == "__Secure-next-auth.session-token"
                    || $0.name == "__Host-next-auth.csrf-token"
            },
            looksLikeAuthCookie: { cookie in
                let name = cookie.name.lowercased()
                if name.contains("next-auth.session-token") { return true }
                let hints = ["session", "token", "auth"]
                return hints.contains { name.contains($0) }
            },
            includeAllDomainCookiesWhenSessionFound: true,
            essentialCookieNames: Self.essentialCookieNames,
            maxAttempts: 4,
            failureMessage: "No ChatGPT session cookie found. Finish signing in to chatgpt.com, then click Capture Session."
        )
    }

    init() {
        super.init(
            config: ProviderAuthConfig(
                storeFilenamePrefix: "chatgpt_auth_",
                logCategory: "ChatGPTAuth",
                usesBearerToken: false,
                extraStoreKeys: [],
                signOutHosts: Self.chatgptHosts,
                capturePolicy: Self.chatgptPolicy(),
                isDomain: { domain in Domain.matches(domain, hosts: Self.chatgptHosts) }
            )
        )
    }
}
