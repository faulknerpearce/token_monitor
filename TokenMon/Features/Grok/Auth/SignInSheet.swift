import SwiftUI

struct SignInView: View {
    @ObservedObject var auth: AuthSessionService
    var onComplete: () -> Void

    /// Identity providers that host the Grok/xAI sign-in flow.
    static let authHosts = ["accounts.x.ai", "auth.x.ai", "api.x.com", "twitter.com", "x.com"]

    /// Exact-or-suffix host match (via `Domain.matches`) rather than a naive
    /// `contains`, so e.g. `netflix.com` cannot satisfy `"x.com"`.
    static func isAuthHost(_ host: String) -> Bool {
        Domain.matches(host, hosts: authHosts)
    }

    /// The page the flow returns to once signed in. Suffix-matched so
    /// `grok.com.evil.example` is rejected.
    static func isReturnPage(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return Domain.matches(host, hosts: ["grok.com"])
    }

    var body: some View {
        ProviderSignInSheet(
            auth: auth,
            config: ProviderSignInConfig(
                title: "Sign in to Grok",
                subtitle: "Sign in with your Grok / xAI account. This window finishes on its own once you're back on grok.com.",
                startURL: URL(
                    string: "https://accounts.x.ai/sign-in?redirect=https%3A%2F%2Fgrok.com%2F%3F_s%3Dusage"
                )!,
                isAuthHost: { host, _ in Self.isAuthHost(host) },
                isReturnPage: { url in Self.isReturnPage(url) },
                returnDelayNanoseconds: 1_500_000_000
            ),
            onComplete: onComplete
        )
    }
}
