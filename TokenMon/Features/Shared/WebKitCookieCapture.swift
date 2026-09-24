import Foundation
import WebKit

/// Shared WebKit cookie capture with provider-specific domain/session policy.
enum WebKitCookieCapture {
    struct Policy: Sendable {
        var isDomain: @Sendable (String) -> Bool
        /// Preferred session cookie (e.g. `auth`, `WorkosCursorSessionToken`).
        var isPreferredSessionCookie: @Sendable (HTTPCookie) -> Bool
        var looksLikeAuthCookie: @Sendable (HTTPCookie) -> Bool
        /// When preferred session is found, include all domain cookies if non-empty.
        var includeAllDomainCookiesWhenSessionFound: Bool
        /// Lowercased names of the only cookies this provider actually sends.
        ///
        /// When non-empty and the preferred session cookie is among them, only
        /// these are persisted. Empty, or a set without the preferred cookie,
        /// falls back to the full domain jar.
        var essentialCookieNames: Set<String>
        /// Lowercased name prefixes whose whole family is sent. NextAuth chunks a
        /// large session JWT into `__Secure-next-auth.session-token.0`, `.1`, …,
        /// so matching on the exact name would drop the session and keep only an
        /// unrelated cookie that happens to share the allowlist.
        var essentialCookiePrefixes: Set<String>
        var maxAttempts: Int
        var retryDelayNanoseconds: UInt64
        var failureMessage: String

        init(
            isDomain: @escaping @Sendable (String) -> Bool,
            isPreferredSessionCookie: @escaping @Sendable (HTTPCookie) -> Bool = { _ in false },
            looksLikeAuthCookie: @escaping @Sendable (HTTPCookie) -> Bool,
            includeAllDomainCookiesWhenSessionFound: Bool = true,
            essentialCookieNames: Set<String> = [],
            essentialCookiePrefixes: Set<String> = [],
            maxAttempts: Int = 1,
            retryDelayNanoseconds: UInt64 = 400_000_000,
            failureMessage: String
        ) {
            self.isDomain = isDomain
            self.isPreferredSessionCookie = isPreferredSessionCookie
            self.looksLikeAuthCookie = looksLikeAuthCookie
            self.includeAllDomainCookiesWhenSessionFound = includeAllDomainCookiesWhenSessionFound
            self.essentialCookieNames = Set(essentialCookieNames.map { $0.lowercased() })
            self.essentialCookiePrefixes = Set(essentialCookiePrefixes.map { $0.lowercased() })
            self.maxAttempts = maxAttempts
            self.retryDelayNanoseconds = retryDelayNanoseconds
            self.failureMessage = failureMessage
        }

        /// True when this provider narrows its persisted jar to an allowlist.
        var hasEssentialCookieAllowlist: Bool {
            !essentialCookieNames.isEmpty || !essentialCookiePrefixes.isEmpty
        }

        /// True when `cookieName` is one of the only cookies this provider sends,
        /// including every chunk of a prefixed family.
        func isEssential(_ cookieName: String) -> Bool {
            let name = cookieName.lowercased()
            if essentialCookieNames.contains(name) { return true }
            return essentialCookiePrefixes.contains { name == $0 || name.hasPrefix($0 + ".") }
        }
    }

    struct CaptureResult: Sendable {
        var cookies: [HTTPCookie]
        var cookieHeader: String
        var email: String?
    }

    @MainActor
    static func capture(policy: Policy, dataStore: WKWebsiteDataStore) async -> CaptureResult? {
        let attempts = max(1, policy.maxAttempts)
        for attempt in 1...attempts {
            let cookies = await WKWebsiteDataStoreBridge.shared.allCookies(in: dataStore)
            let chosen = select(from: cookies, policy: policy)

            if let chosen, !chosen.isEmpty {
                let header = chosen.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                return CaptureResult(
                    cookies: chosen,
                    cookieHeader: header,
                    email: extractEmail(from: chosen)
                )
            }

            if attempt < attempts {
                try? await Task.sleep(nanoseconds: policy.retryDelayNanoseconds)
            }
        }
        return nil
    }

    /// Picks the cookies to persist out of everything the sign-in web view holds.
    ///
    /// Prefers the provider's `essentialCookieNames` allowlist and only widens to
    /// the whole domain jar when that yields nothing usable.
    static func select(from cookies: [HTTPCookie], policy: Policy) -> [HTTPCookie]? {
        let relevant = cookies.filter { policy.isDomain($0.domain) }
        guard !relevant.isEmpty else { return nil }

        // Store only what the requests actually send, when the provider says so
        // and the session cookie is really in there.
        if policy.hasEssentialCookieAllowlist {
            let essential = relevant.filter { policy.isEssential($0.name) }
            if essential.contains(where: policy.isPreferredSessionCookie) {
                return essential
            }
        }

        let preferred = relevant.first(where: policy.isPreferredSessionCookie)
        let authish = relevant.filter { policy.looksLikeAuthCookie($0) }

        if let preferred {
            return policy.includeAllDomainCookiesWhenSessionFound ? relevant : [preferred]
        }
        if !authish.isEmpty {
            return policy.includeAllDomainCookiesWhenSessionFound ? relevant : authish
        }
        return nil
    }

    static func extractEmail(from cookies: [HTTPCookie]) -> String? {
        for cookie in cookies {
            let name = cookie.name.lowercased()
            if ["email", "user_email"].contains(name) {
                let decoded = cookie.value.removingPercentEncoding ?? cookie.value
                if decoded.contains("@"), decoded.contains(".") {
                    return decoded
                }
            }
        }
        for cookie in cookies {
            let value = cookie.value
            if value.contains("@"), value.count < 200, !value.contains(" ") {
                return value
            }
        }
        return nil
    }

    @MainActor
    static func clearHTTPCookieStorage(hosts: [String]) {
        let storage = HTTPCookieStorage.shared
        for domain in hosts {
            if let url = URL(string: "https://\(domain)") {
                storage.cookies(for: url)?.forEach { storage.deleteCookie($0) }
            }
        }
    }
}
