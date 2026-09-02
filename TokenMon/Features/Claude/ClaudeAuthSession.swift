import Foundation

/// Session for claude.ai (`sessionKey` auth cookie + `lastActiveOrg` org id).
@MainActor
final class ClaudeAuthSession: ProviderAuthSession {
    private static let claudeHosts = [
        "claude.ai",
        "www.claude.ai",
        "api.claude.ai"
    ]

    private static func claudePolicy() -> WebKitCookieCapture.Policy {
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

    init() {
        super.init(
            config: ProviderAuthConfig(
                storeFilenamePrefix: "claude_auth_",
                logCategory: "ClaudeAuth",
                startsSignedOut: true,
                usesBearerToken: false,
                extraStoreKeys: [],
                signOutHosts: Self.claudeHosts,
                capturePolicy: Self.claudePolicy(),
                isDomain: { domain in Domain.matches(domain, hosts: Self.claudeHosts) }
            )
        )
    }

    nonisolated static func isClaudeDomain(_ domain: String) -> Bool {
        Domain.matches(domain, hosts: claudeHosts)
    }
}
