import SwiftUI

/// ChatGPT sign-in sheet (captures the NextAuth session cookie).
struct ChatGPTSignInView: View {
    @ObservedObject var auth: ChatGPTAuthSession
    var onComplete: () -> Void

    var body: some View {
        ProviderSignInSheet(
            auth: auth,
            config: ProviderSignInConfig(
                title: "Sign in to ChatGPT",
                subtitle: "Sign in to your ChatGPT account. This window finishes on its own once you return to chatgpt.com.",
                startURL: URL(string: "https://chatgpt.com/")!,
                isAuthHost: ChatGPTSignInView.isAuthHost,
                isReturnPage: ChatGPTSignInView.isReturnPage
            ),
            onComplete: onComplete
        )
    }

    /// True for OpenAI auth hosts and in-page login/signin paths.
    static func isAuthHost(host: String, path: String) -> Bool {
        host.contains("auth.openai")
            || host.contains("auth0.openai")
            || host.contains("accounts.google")
            || host.contains("appleid.apple")
            || host.contains("login.microsoft")
            || path.contains("/login")
            || path.contains("/signin")
    }

    /// True on chatgpt.com after login — excludes login/signin/auth paths.
    static func isReturnPage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let onChatGPT = host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
        guard onChatGPT else { return false }
        let path = url.path.lowercased()
        if path.contains("login") || path.contains("signin") || path.contains("/auth") {
            return false
        }
        return true
    }
}
