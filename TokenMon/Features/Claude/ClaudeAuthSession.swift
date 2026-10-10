import Foundation

/// Session for claude.ai (`sessionKey` auth cookie + `lastActiveOrg` org id).
@MainActor
final class ClaudeAuthSession: ProviderAuthSession {
    private static let claudeHosts = [
        "claude.ai",
        "www.claude.ai",
        "api.claude.ai"
    ]

    static func claudePolicy() -> WebKitCookieCapture.Policy {
        WebKitCookieCapture.Policy(
            isDomain: { domain in Domain.matches(domain, hosts: claudeHosts) },
            isPreferredSessionCookie: { $0.name == "sessionKey" },
            looksLikeAuthCookie: { cookie in
                let name = cookie.name.lowercased()
                if name == "sessionkey" || name == "lastactiveorg" { return true }
                let hints = ["session", "token", "auth", "claude"]
                return hints.contains { name.contains($0) }
            },
            includeAllDomainCookiesWhenSessionFound: true,
            // `sessionKey` authenticates; `lastActiveOrg` carries the org UUID
            // that ClaudeUsageClient parses back out of the header.
            essentialCookieNames: ["sessionkey", "lastactiveorg"],
            maxAttempts: 4,
            failureMessage: "No Claude session cookie found. Finish signing in to claude.ai, then click Capture Session."
        )
    }

    static func claudeConfig() -> ProviderAuthConfig {
        ProviderAuthConfig(
            storeFilenamePrefix: "claude_auth_",
            logCategory: "ClaudeAuth",
            extraStoreKeys: [],
            signOutHosts: claudeHosts,
            capturePolicy: claudePolicy(),
            isDomain: { domain in Domain.matches(domain, hosts: claudeHosts) },
            // The org UUID identifies whose usage the stored history holds.
            accountIdentityCookie: "lastactiveorg"
        )
    }

    /// Live store by default; tests isolate it to `directory` or pass `store`.
    init(directory: URL? = nil, store: (any CredentialStore)? = nil) {
        super.init(config: Self.claudeConfig(), directory: directory, store: store)
    }
}
