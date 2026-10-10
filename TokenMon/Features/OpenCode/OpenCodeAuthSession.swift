import Combine
import Foundation
import os
import WebKit

/// Console session for opencode.ai (OpenAuth cookie `auth`).
/// Kept separate from Grok WebKit cookies so each provider keeps its own session.
@MainActor
final class OpenCodeAuthSession: ProviderAuthSession {
    private static let openCodeHosts = ["opencode.ai", "auth.opencode.ai"]

    /// Last known workspace id (`wrk_…`) from redirect or prior fetch.
    @Published private(set) var workspaceID: String?

    /// Console session cookie. The console authenticates separately from the
    /// site's `auth` cookie, so this is captured and sent to `/console/api/*`.
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
            // (`__Host-console_session`) and the site cookies (`auth=…; provider=…`)
            // for workspace binding. Unrelated analytics cookies are excluded.
            essentialCookieNames: ["auth", "provider", Self.consoleSessionCookieName],
            maxAttempts: 4,
            failureMessage: "No OpenCode console session cookie found. Finish signing in until you see the console, then click Finish Sign-In."
        )
    }

    static func openCodeConfig() -> ProviderAuthConfig {
        ProviderAuthConfig(
            storeFilenamePrefix: "opencode_auth_",
            logCategory: "OpenCodeAuth",
            extraStoreKeys: ["workspace"],
            signOutHosts: openCodeHosts,
            capturePolicy: openCodePolicy(),
            isDomain: { domain in Domain.matches(domain, hosts: openCodeHosts) }
        )
    }

    /// Live store by default; tests isolate it to `directory` or pass `store`.
    init(directory: URL? = nil, store: (any CredentialStore)? = nil) {
        super.init(config: Self.openCodeConfig(), directory: directory, store: store)
    }

    override func refreshFromDisk() {
        super.refreshFromDisk()
        workspaceID = readStore(key: "workspace")
    }

    func saveWorkspaceID(_ id: String) {
        writeStore(key: "workspace", value: id)
        workspaceID = id
    }

    /// Clears the in-memory workspace id alongside the persisted key, so the next
    /// poll after sign-out resolves its org afresh.
    override func clearBrowserState() {
        super.clearBrowserState()
        workspaceID = nil
    }
}
