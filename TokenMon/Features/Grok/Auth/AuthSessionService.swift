import Foundation

/// Session for grok.com (`sso` / `sso-rw` cookies).
///
/// Sign-in may pass through x.com / twitter.com (see `SignInView.authHosts`),
/// but those hosts are not part of the session: their cookies are never
/// captured or stored.
@MainActor
final class AuthSessionService: ProviderAuthSession {
    private static let grokHosts = ["grok.com", "x.ai"]

    /// Cookie names that indicate a real authenticated session (not anonymous browsing).
    private static let authCookieHints: Set<String> = [
        "sso", "session", "auth", "token", "jwt", "sid", "user", "account",
        "x-session", "xai", "oidc", "refresh", "access"
    ]

    /// The grok.com/xAI session cookies the usage requests send. Capture stores
    /// only these, and waits until one of them is present.
    static let essentialCookieNames: Set<String> = ["sso", "sso-rw"]

    convenience init() {
        self.init(directory: nil)
    }

    /// Test seam: isolates the session's file store to `directory`, or uses `store`.
    init(directory: URL?, store: (any CredentialStore)? = nil) {
        super.init(
            config: ProviderAuthConfig(
                storeFilenamePrefix: "auth_",
                logCategory: "Auth",
                extraStoreKeys: [],
                signOutHosts: Self.grokHosts,
                capturePolicy: Self.grokPolicy(),
                isDomain: { domain in Self.isGrokDomain(domain) }
            ),
            directory: directory,
            store: store
        )
    }

    /// Cookie-capture policy for the grok.com/xAI sign-in flow.
    static func grokPolicy() -> WebKitCookieCapture.Policy {
        WebKitCookieCapture.Policy(
            isDomain: { domain in Self.isGrokDomain(domain) },
            isPreferredSessionCookie: { cookie in
                Self.essentialCookieNames.contains(cookie.name.lowercased())
            },
            looksLikeAuthCookie: { cookie in
                let name = cookie.name.lowercased()
                guard Self.authCookieHints.contains(where: { name.contains($0) }) else { return false }
                return cookie.isSecure || cookie.isHTTPOnly
            },
            includeAllDomainCookiesWhenSessionFound: true,
            essentialCookieNames: Self.essentialCookieNames,
            maxAttempts: 4,
            failureMessage: "No session cookies found. Finish signing in, then click Capture Session."
        )
    }

    nonisolated static func isGrokDomain(_ domain: String) -> Bool {
        Domain.matches(domain, hosts: grokHosts)
    }
}
