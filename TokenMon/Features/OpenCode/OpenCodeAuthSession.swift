import Combine
import Foundation
import os
import WebKit

/// Console session for opencode.ai (OpenAuth cookie `auth`).
/// Separate from Grok WebKit cookies so the two providers do not clobber each other.
@MainActor
final class OpenCodeAuthSession: ProviderAuthSession {
    private static let openCodeHosts = ["opencode.ai", "auth.opencode.ai"]

    /// Last known workspace id (`wrk_…`) from redirect or prior fetch.
    @Published private(set) var workspaceID: String?

    /// Console session cookie. The console authenticates separately from the
    /// site's `auth` cookie, so this must be captured and sent to `/console/api/*`.
    static let consoleSessionCookieName = "__host-console_session"

    static func openCodePolicy() -> WebKitCookieCapture.Policy {
        WebKitCookieCapture.Policy(
            isDomain: { domain in Domain.matches(domain, hosts: openCodeHosts) },
            isPreferredSessionCookie: {
                let name = $0.name.lowercased()
                return name == "auth" || name == Self.consoleSessionCookieName
            },
            looksLikeAuthCookie: { cookie in
                let name = cookie.name.lowercased()
                if name == "auth" || name == "session" || name == "sid" { return true }
                if name == Self.consoleSessionCookieName { return true }
                let hints = ["auth", "session", "token", "jwt", "sid", "account", "openid", "oauth"]
                return hints.contains { name.contains($0) }
            },
            includeAllDomainCookiesWhenSessionFound: true,
            // The console API request needs both the console session
            // (`__Host-console_session`) and the site cookies (`auth=…; provider=…`);
            // narrowing to `auth`/`provider` alone dropped the console session and
            // broke workspace binding. Unrelated analytics cookies are still excluded.
            essentialCookieNames: ["auth", "provider", Self.consoleSessionCookieName],
            maxAttempts: 4,
            failureMessage: "No OpenCode console session cookie found. Finish signing in until you see the console, then click Finish Sign-In."
        )
    }

    init() {
        super.init(
            config: ProviderAuthConfig(
                storeFilenamePrefix: "opencode_auth_",
                logCategory: "OpenCodeAuth",
                usesBearerToken: false,
                extraStoreKeys: ["workspace"],
                signOutHosts: Self.openCodeHosts,
                capturePolicy: Self.openCodePolicy(),
                isDomain: { domain in Domain.matches(domain, hosts: Self.openCodeHosts) }
            )
        )
    }

    override func refreshFromDisk() {
        super.refreshFromDisk()
        workspaceID = readStore(key: "workspace")
    }

    func saveWorkspaceID(_ id: String) {
        writeStore(key: "workspace", value: id)
        workspaceID = id
    }
}
