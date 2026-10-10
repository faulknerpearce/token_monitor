import Foundation

/// Session for cursor.com (`WorkosCursorSessionToken`).
/// Uses its own cookie store, isolated from the Grok / OpenCode sessions.
@MainActor
final class CursorAuthSession: ProviderAuthSession {
    private static let cursorHosts = [
        "cursor.com",
        "cursor.sh",
        "authenticator.cursor.sh",
        "api2.cursor.sh"
    ]

    static func cursorPolicy() -> WebKitCookieCapture.Policy {
        WebKitCookieCapture.Policy(
            isDomain: { domain in Self.isCursorDomain(domain) },
            isPreferredSessionCookie: {
                $0.name == "WorkosCursorSessionToken"
                    || $0.name.lowercased() == "workoscursorsessiontoken"
            },
            looksLikeAuthCookie: { cookie in
                let name = cookie.name.lowercased()
                if name == "workoscursorsessiontoken" { return true }
                let hints = ["session", "token", "auth", "workos", "cursor"]
                return hints.contains { name.contains($0) }
            },
            includeAllDomainCookiesWhenSessionFound: true,
            // The dashboard requests authenticate on this one cookie.
            essentialCookieNames: ["workoscursorsessiontoken"],
            maxAttempts: 4,
            failureMessage: "No Cursor session cookie found. Finish signing in until you see the usage dashboard, then click Capture Session."
        )
    }

    static func cursorConfig() -> ProviderAuthConfig {
        ProviderAuthConfig(
            storeFilenamePrefix: "cursor_auth_",
            logCategory: "CursorAuth",
            extraStoreKeys: [],
            signOutHosts: cursorHosts,
            capturePolicy: cursorPolicy(),
            isDomain: { domain in Self.isCursorDomain(domain) }
        )
    }

    /// Live store by default; tests isolate it to `directory` or pass `store`.
    init(directory: URL? = nil, store: (any CredentialStore)? = nil) {
        super.init(config: Self.cursorConfig(), directory: directory, store: store)
    }

    nonisolated static func isCursorDomain(_ domain: String) -> Bool {
        Domain.matches(domain, hosts: cursorHosts)
    }
}
