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

    private static func cursorPolicy() -> WebKitCookieCapture.Policy {
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

    init() {
        super.init(
            config: ProviderAuthConfig(
                storeFilenamePrefix: "cursor_auth_",
                logCategory: "CursorAuth",
                startsSignedOut: true,
                usesBearerToken: false,
                extraStoreKeys: [],
                signOutHosts: Self.cursorHosts,
                capturePolicy: Self.cursorPolicy(),
                isDomain: { domain in Domain.matches(domain, hosts: Self.cursorHosts) }
            )
        )
    }

    nonisolated static func isCursorDomain(_ domain: String) -> Bool {
        Domain.matches(domain, hosts: cursorHosts)
    }
}
