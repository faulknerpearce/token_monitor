import SwiftUI

struct CursorSignInView: View {
    @ObservedObject var auth: CursorAuthSession
    var onComplete: () -> Void

    var body: some View {
        ProviderSignInSheet(
            auth: auth,
            config: ProviderSignInConfig(
                title: "Sign in to Cursor",
                subtitle: "Sign in to your Cursor account. This window finishes on its own once you reach the dashboard.",
                startURL: URL(string: "https://cursor.com/dashboard/usage")!,
                isAuthHost: { host, path in
                    host.contains("authenticator.cursor")
                        || host.contains("accounts.google")
                        || host.contains("github.com")
                        || path.contains("/login")
                        || path.contains("/signin")
                },
                isReturnPage: { url in
                    guard let host = url.host?.lowercased() else { return false }
                    let onCursor = host == "cursor.com" || host.hasSuffix(".cursor.com")
                    return onCursor
                        && (url.path.contains("/dashboard") || url.path.contains("/settings"))
                }
            ),
            onComplete: onComplete
        )
    }
}
