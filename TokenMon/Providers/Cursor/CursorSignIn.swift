import Foundation

extension CursorAuthSession: ProviderSignInProviding {
    /// Identity providers that host the Cursor (WorkOS) sign-in flow.
    nonisolated static let authHosts = ["authenticator.cursor.sh", "authenticator.cursor.com", "accounts.google.com", "github.com"]

    /// True for a sign-in step: an identity-provider host (exact-or-suffix
    /// match via `Domain.matches`, so `github.com.evil.example` is rejected) or
    /// a login path.
    nonisolated static func isAuthPage(host: String, path: String) -> Bool {
        Domain.matches(host, hosts: authHosts) || path.contains("/login") || path.contains("/signin")
    }

    /// Captures the dashboard session cookie.
    var signInConfig: ProviderSignInConfig {
        ProviderSignInConfig(
            title: "Sign in to Cursor",
            subtitle: "Sign in to your Cursor account. This window finishes on its own once you reach the dashboard.",
            startURL: URL(staticString: "https://cursor.com/dashboard/usage"),
            isAuthHost: { host, path in Self.isAuthPage(host: host, path: path) },
            isReturnPage: { url in
                guard let host = url.host?.lowercased() else { return false }
                let onCursor = host == "cursor.com" || host.hasSuffix(".cursor.com")
                return onCursor
                    && (url.path.contains("/dashboard") || url.path.contains("/settings"))
            }
        )
    }
}
