import Foundation
import WebKit

/// Shared WebKit cookie capture with provider-specific domain/session policy.
enum WebKitCookieCapture {
    /// Domain, session-cookie, and retry rules selecting which WebKit cookies to keep.
    struct Policy: Sendable {
        var isDomain: @Sendable (String) -> Bool
        /// Preferred session cookie (e.g. `auth`, `WorkosCursorSessionToken`).
        var isPreferredSessionCookie: @Sendable (HTTPCookie) -> Bool
        var looksLikeAuthCookie: @Sendable (HTTPCookie) -> Bool
        /// When preferred session is found, include all domain cookies if non-empty.
        var includeAllDomainCookiesWhenSessionFound: Bool
        /// Lowercased names of the only cookies this provider actually sends.
        ///
        /// When non-empty (or `essentialCookiePrefixes` is), only these are
        /// persisted, and capture succeeds only once the preferred session
        /// cookie is among them. Empty falls back to the domain-wide rules.
        var essentialCookieNames: Set<String>
        /// Lowercased name prefixes whose whole family is sent. NextAuth chunks a
        /// large session JWT into `__Secure-next-auth.session-token.0`, `.1`, …,
        /// so the family matches by prefix and keeps every chunk of the session.
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

        /// The chunked family `cookieName` belongs to (its lowercased prefix),
        /// or `nil` for a cookie outside every prefixed family.
        func essentialFamily(of cookieName: String) -> String? {
            let name = cookieName.lowercased()
            return essentialCookiePrefixes.first { name == $0 || name.hasPrefix($0 + ".") }
        }
    }

    /// Cookies chosen from the sign-in store plus the derived header and email.
    struct CaptureResult: Sendable {
        var cookies: [HTTPCookie]
        var cookieHeader: String
        var email: String?
    }

    /// Captures session cookies from `dataStore`, retrying until `policy` succeeds.
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
    /// A provider with an allowlist stores only its essential cookies, and only
    /// once the session cookie is among them; until then capture keeps waiting
    /// and leaves the rest of the jar (analytics, another account's SSO)
    /// unstored. Without an allowlist the domain-wide rules apply.
    static func select(from cookies: [HTTPCookie], policy: Policy) -> [HTTPCookie]? {
        let relevant = cookies.filter { policy.isDomain($0.domain) }
        guard !relevant.isEmpty else { return nil }

        if policy.hasEssentialCookieAllowlist {
            let essential = relevant.filter { policy.isEssential($0.name) }
            return essential.contains(where: policy.isPreferredSessionCookie) ? essential : nil
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

    /// Best-effort account email from an `email` / `user_email` cookie, else
    /// from any cookie whose whole value is a plausible address.
    static func extractEmail(from cookies: [HTTPCookie]) -> String? {
        for cookie in cookies where ["email", "user_email"].contains(cookie.name.lowercased()) {
            let decoded = cookie.value.removingPercentEncoding ?? cookie.value
            if isPlausibleEmail(decoded) {
                return decoded
            }
        }
        for cookie in cookies {
            let decoded = cookie.value.removingPercentEncoding ?? cookie.value
            if isPlausibleEmail(decoded) {
                return decoded
            }
        }
        return nil
    }

    /// True for a single `local@domain.tld` address: one `@`, a non-empty local
    /// part, a dotted domain with a letters-only TLD, and no whitespace,
    /// quotes, separators, or URL syntax.
    static func isPlausibleEmail(_ value: String) -> Bool {
        guard value.count <= 254 else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0]
        let domain = parts[1]
        let localAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".!#$%&'*+-/=?^_`{|}~"))
        let domainAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard !local.isEmpty, local.count <= 64,
              local.unicodeScalars.allSatisfy(localAllowed.contains),
              domain.unicodeScalars.allSatisfy(domainAllowed.contains) else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return true
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
