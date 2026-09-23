import Foundation

/// Session for cursor.com (`WorkosCursorSessionToken`).
/// Separate cookie store from Grok / OpenCode so providers do not clobber each other.
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
            isDomain: { domain in Domain.matches(domain, hosts: cursorHosts) },
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
            usesBearerToken: false,
            extraStoreKeys: [],
            signOutHosts: cursorHosts,
            capturePolicy: cursorPolicy(),
            isDomain: { domain in Domain.matches(domain, hosts: cursorHosts) }
        )
    }

    init() {
        super.init(config: Self.cursorConfig())
    }

    /// Test seam: isolates the session's file store to `directory`.
    init(directory: URL?) {
        super.init(config: Self.cursorConfig(), directory: directory)
    }

    nonisolated static func isCursorDomain(_ domain: String) -> Bool {
        Domain.matches(domain, hosts: cursorHosts)
    }
}
