import Foundation

/// Fetches claude.ai rate-limit usage via the cookie-authenticated internal endpoint.
struct ClaudeUsageClient: Sendable {
    static let baseURL = URL(string: "https://claude.ai")!

    private let cookieHeader: String

    init(cookieHeader: String) {
        self.cookieHeader = cookieHeader
    }

    func fetchUsage(now: Date = Date()) async throws -> (ClaudeUsageResponse, Date) {
        guard let organizationID = Self.organizationID(fromCookieHeader: cookieHeader) else {
            throw ProviderError.custom(
                message: "Claude organization id not found in session. Sign in again.",
                usage: .notSignedIn
            )
        }
        let data = try await ProviderHTTP.get(
            "/api/organizations/\(organizationID)/usage",
            baseURL: Self.baseURL,
            context: .claude,
            cookieHeader: cookieHeader,
            referer: "https://claude.ai/"
        )
        let response = try ClaudeUsageResponse.parse(data)
        return (response, now)
    }

    /// Extracts the org UUID from the `lastActiveOrg` cookie pair.
    static func organizationID(fromCookieHeader header: String) -> String? {
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "lastActiveOrg"
            else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
