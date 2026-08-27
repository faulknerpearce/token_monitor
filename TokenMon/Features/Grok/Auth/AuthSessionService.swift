import Foundation

/// Persists grok.com session cookies and optional bearer token under Application Support.
/// Keychain is intentionally avoided — ad-hoc/debug builds spam "wants to access keychain" dialogs in a loop.
@MainActor
final class AuthSessionService: ProviderAuthSession {
    private static let grokHosts = ["grok.com", "x.ai", "x.com", "twitter.com"]

    /// Cookie names that indicate a real authenticated session (not anonymous browsing).
    private static let authCookieHints: Set<String> = [
        "sso", "session", "auth", "token", "jwt", "sid", "user", "account",
        "x-session", "xai", "oidc", "refresh", "access"
    ]

    init() {
        super.init(
            config: ProviderAuthConfig(
                storeFilenamePrefix: "auth_",
                logCategory: "Auth",
                startsSignedOut: false,
                usesBearerToken: true,
                extraStoreKeys: [],
                signOutHosts: Self.grokHosts,
                capturePolicy: Self.grokPolicy(),
                isDomain: { domain in Domain.matches(domain, hosts: Self.grokHosts) }
            )
        )
    }

    private static func grokPolicy() -> WebKitCookieCapture.Policy {
        WebKitCookieCapture.Policy(
            isDomain: { domain in Domain.matches(domain, hosts: grokHosts) },
            looksLikeAuthCookie: { cookie in
                let name = cookie.name.lowercased()
                guard Self.authCookieHints.contains(where: { name.contains($0) }) else { return false }
                return cookie.isSecure || cookie.isHTTPOnly
            },
            includeAllDomainCookiesWhenSessionFound: true,
            maxAttempts: 4,
            failureMessage: "No session cookies found. Finish signing in, then click Capture Session."
        )
    }

    nonisolated static func isGrokDomain(_ domain: String) -> Bool {
        Domain.matches(domain, hosts: grokHosts)
    }
}
