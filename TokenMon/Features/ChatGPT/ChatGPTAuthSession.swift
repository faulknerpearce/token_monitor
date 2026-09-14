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

    private static func chatgptPolicy() -> WebKitCookieCapture.Policy {
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

    nonisolated static func isChatGPTDomain(_ domain: String) -> Bool {
        Domain.matches(domain, hosts: chatgptHosts)
    }
}
