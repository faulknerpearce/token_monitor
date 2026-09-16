import SwiftUI

struct ClaudeSignInView: View {
    @ObservedObject var auth: ClaudeAuthSession
    var onComplete: () -> Void

    var body: some View {
        ProviderSignInSheet(
            auth: auth,
            config: ProviderSignInConfig(
                title: "Sign in to Claude",
                subtitle: "Sign in to your Claude account. This window finishes on its own once you return to claude.ai.",
                startURL: URL(string: "https://claude.ai/new")!,
                isAuthHost: ClaudeSignInView.isAuthHost,
                isReturnPage: ClaudeSignInView.isReturnPage
            ),
            onComplete: onComplete
        )
    }

    /// True for Claude SSO hosts (Clerk) and in-page login/signin paths.
    static func isAuthHost(host: String, path: String) -> Bool {
        host.contains("clerk.claude")
            || host.contains("accounts.google")
            || host.contains("github.com")
            || host.contains("appleid.apple")
            || path.contains("/login")
            || path.contains("/signin")
    }

    /// True on claude.ai after login. Excludes the Clerk SSO subdomain
    /// (`clerk.claude.ai`) and login/signin/auth paths, so capture cannot fire
    /// on a sign-in page.
    static func isReturnPage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        guard host == "claude.ai" || host == "www.claude.ai" else { return false }
        let path = url.path.lowercased()
        if path.contains("login") || path.contains("signin") || path.contains("/auth") {
            return false
        }
        return true
    }
}
