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
                isAuthHost: { host, path in
                    host.contains("clerk.claude")
                        || host.contains("accounts.google")
                        || host.contains("github.com")
                        || host.contains("appleid.apple")
                        || path.contains("/login")
                        || path.contains("/signin")
                },
                isReturnPage: { url in
                    guard let host = url.host?.lowercased() else { return false }
                    let onClaude = host == "claude.ai" || host.hasSuffix(".claude.ai")
                    return onClaude && !url.path.isEmpty && url.path != "/login"
                }
            ),
            onComplete: onComplete
        )
    }
}
