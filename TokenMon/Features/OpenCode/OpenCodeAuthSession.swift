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

    private static func openCodePolicy() -> WebKitCookieCapture.Policy {
        WebKitCookieCapture.Policy(
            isDomain: { domain in Domain.matches(domain, hosts: openCodeHosts) },
            isPreferredSessionCookie: { $0.name.lowercased() == "auth" },
            looksLikeAuthCookie: { cookie in
                let name = cookie.name.lowercased()
                if name == "auth" || name == "session" || name == "sid" { return true }
                let hints = ["auth", "session", "token", "jwt", "sid", "account", "openid", "oauth"]
                return hints.contains { name.contains($0) }
            },
            includeAllDomainCookiesWhenSessionFound: true,
            // OpenAuth issues a single `auth` cookie for the console.
            essentialCookieNames: ["auth"],
            maxAttempts: 4,
            failureMessage: "No OpenCode console session cookie found. Finish signing in until you see your workspace, then click Capture Session."
        )
    }

    init() {
        super.init(
            config: ProviderAuthConfig(
                storeFilenamePrefix: "opencode_auth_",
                logCategory: "OpenCodeAuth",
                startsSignedOut: true,
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

    nonisolated static func isOpenCodeDomain(_ domain: String) -> Bool {
        Domain.matches(domain, hosts: openCodeHosts)
    }
}
