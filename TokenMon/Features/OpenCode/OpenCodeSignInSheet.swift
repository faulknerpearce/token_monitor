import SwiftUI

/// OpenCode console sign-in sheet capturing the console session.
struct OpenCodeSignInView: View {
    @ObservedObject var auth: OpenCodeAuthSession
    var onComplete: () -> Void

    var body: some View {
        ProviderSignInSheet(
            auth: auth,
            config: ProviderSignInConfig(
                title: "Sign in to OpenCode",
                subtitle: "Sign in to the OpenCode console. This window finishes on its own once the console loads.",
                startURL: URL(string: "https://opencode.ai/console/login")!,
                isAuthHost: { host, path in
                    host.contains("auth.opencode.ai")
                        || path.contains("/auth/authorize")
                        || path.contains("/console/login")
                },
                isReturnPage: { url in
                    guard let host = url.host?.lowercased() else { return false }
                    guard host == "opencode.ai" || host.hasSuffix(".opencode.ai"),
                          !host.contains("auth.") else { return false }
                    let path = url.path
                    if path.hasPrefix("/console") {
                        // Console landing page after sign-in, not the login form itself.
                        return !path.hasPrefix("/console/login")
                    }
                    return path.contains("/workspace")
                        || (path.hasPrefix("/auth") && !path.contains("authorize"))
                },
                onReturned: { url in
                    if let id = OpenCodeConsoleClient.workspaceID(from: url) {
                        auth.saveWorkspaceID(id)
                    }
                }
            ),
            onComplete: onComplete,
            afterCapture: {
                guard let cookie = auth.cookieHeader() else { return }
                let client = OpenCodeConsoleClient(cookieHeader: cookie)
                if let id = try? await client.resolveOrgID() {
                    auth.saveWorkspaceID(id)
                }
                if let email = await client.fetchAccountEmail() {
                    auth.saveAccountEmail(email)
                }
            }
        )
    }
}
