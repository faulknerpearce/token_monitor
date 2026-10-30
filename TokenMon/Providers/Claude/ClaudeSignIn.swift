import Foundation

extension ClaudeAuthSession: ProviderSignInProviding {
    /// True for Claude SSO hosts (Clerk) and in-page login/signin paths.
    nonisolated static func isAuthHost(host: String, path: String) -> Bool {
        host.contains("clerk.claude")
            || host.contains("accounts.google")
            || host.contains("github.com")
            || host.contains("appleid.apple")
            || path.contains("/login")
            || path.contains("/signin")
    }

    /// True on claude.ai after login. Excludes the Clerk SSO subdomain
    /// (`clerk.claude.ai`) and login/signin/auth paths, so capture fires only
    /// on a signed-in page.
    nonisolated static func isReturnPage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host == "claude.ai" || host == "www.claude.ai" else { return false }
        let path = url.path.lowercased()
        if path.contains("login") || path.contains("signin") || path.contains("/auth") {
            return false
        }
        return true
    }

    /// Captures the `sessionKey` session cookie.
    var signInConfig: ProviderSignInConfig {
        ProviderSignInConfig(
            title: "Sign in to Claude",
            subtitle: "Sign in to your Claude account. This window finishes on its own once you return to claude.ai.",
            startURL: URL(staticString: "https://claude.ai/new"),
            isAuthHost: Self.isAuthHost,
            isReturnPage: Self.isReturnPage
        )
    }
}
