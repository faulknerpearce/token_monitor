import Foundation

extension OpenCodeAuthSession: ProviderSignInProviding {
    /// Captures the console session, then records the workspace and account.
    var signInConfig: ProviderSignInConfig {
        ProviderSignInConfig(
            title: "Sign in to OpenCode",
            subtitle: "Sign in to the OpenCode console. This window finishes on its own once the console loads.",
            startURL: URL(staticString: "https://opencode.ai/console/login"),
            isAuthHost: { host, path in
                host.contains("auth.opencode.ai")
                    || path.contains("/auth/authorize")
                    || path.contains("/console/login")
            },
            isReturnPage: { url in
                guard let host = url.host?.lowercased(), host == "opencode.ai" || host.hasSuffix(".opencode.ai"),
                      !host.contains("auth.") else { return false }
                let path = url.path
                if path.hasPrefix("/console") {
                    // Console landing page after sign-in (past the login form).
                    return !path.hasPrefix("/console/login")
                }
                return path.contains("/workspace")
                    || (path.hasPrefix("/auth") && !path.contains("authorize"))
            },
            onReturned: { [weak self] url in
                if let id = OpenCodeConsoleClient.workspaceID(from: url) {
                    self?.saveWorkspaceID(id)
                }
            },
            afterCapture: { [weak self] in
                guard let self, let cookie = cookieHeader() else { return }
                let client = OpenCodeConsoleClient(cookieHeader: cookie)
                // Keep the workspace from the sign-in redirect; list the
                // account's workspaces only when the redirect carried none.
                if let id = try? await client.resolveOrgID(preferred: workspaceID) {
                    saveWorkspaceID(id)
                }
                if let email = await client.fetchAccountEmail() {
                    saveAccountEmail(email)
                }
            }
        )
    }
}
