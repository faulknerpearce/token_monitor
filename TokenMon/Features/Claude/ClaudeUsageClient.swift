import Foundation

enum ClaudeUsageError: LocalizedError, ProviderUsageError {
    case notSignedIn
    case unauthorized
    case missingOrganization
    case badResponse(String)
    case network(String)

    var usageError: UsageError {
        switch self {
        case .notSignedIn: return .notSignedIn
        case .unauthorized: return .unauthorized
        case .missingOrganization: return .notSignedIn
        case let .badResponse(message): return .badResponse(message)
        case let .network(message): return .network(message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to Claude to load usage."
        case .unauthorized:
            return "Claude session expired. Sign in again."
        case .missingOrganization:
            return "Claude organization id not found in session. Sign in again."
        case let .badResponse(message):
            return "Claude response error: \(message)"
        case let .network(message):
            return "Claude network error: \(message)"
        }
    }
}

/// Fetches Claude rate-limit usage via either the OAuth API
/// (`api.anthropic.com/api/oauth/usage`, per-model) or the cookie-authenticated
/// `claude.ai` internal endpoint as a fallback.
struct ClaudeUsageClient: Sendable {
    static let baseURL = URL(string: "https://claude.ai")!
    static let oauthBaseURL = URL(string: "https://api.anthropic.com")!

    private let cookieHeader: String
    private let oauthToken: String?

    init(cookieHeader: String, oauthToken: String? = nil) {
        self.cookieHeader = cookieHeader
        self.oauthToken = oauthToken
    }

    /// Reads a Claude Code OAuth token from env / credentials file / Keychain
    /// when the caller doesn't already have one.
    init(cookieHeader: String, readsOAuthToken: Bool) {
        self.cookieHeader = cookieHeader
        self.oauthToken = readsOAuthToken ? ClaudeOAuthTokenProvider.accessToken() : nil
    }

    func fetchUsage(now: Date = Date()) async throws -> (ClaudeUsageResponse, Date) {
        let hasCookies = !cookieHeader.isEmpty
            && Self.organizationID(fromCookieHeader: cookieHeader) != nil
        if let token = oauthToken, !token.isEmpty {
            do {
                return try await fetchOAuthUsage(token: token, now: now)
            } catch let oauthError as ClaudeUsageError {
                // Prefer cookie fallback whenever a web session exists — auth
                // failures, transport blips, and 5xx on the OAuth endpoint
                // should not wipe the existing cookie-backed panel.
                if hasCookies {
                    // fall through
                } else {
                    throw oauthError
                }
            } catch {
                if !hasCookies { throw error }
            }
        }
        guard let organizationID = Self.organizationID(fromCookieHeader: cookieHeader) else {
            throw ClaudeUsageError.missingOrganization
        }
        let data = try await get(path: "/api/organizations/\(organizationID)/usage")
        let response = try ClaudeUsageResponse.parse(data)
        return (response, now)
    }

    /// Direct OAuth fetch (also used by tests).
    func fetchOAuthUsage(token: String, now: Date = Date()) async throws -> (ClaudeUsageResponse, Date) {
        let data = try await getOAuth(path: "/api/oauth/usage", token: token)
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

    private func get(path: String) async throws -> Data {
        guard let resolved = URL(string: path, relativeTo: Self.baseURL)?.absoluteURL else {
            throw ClaudeUsageError.badResponse("Invalid path \(path)")
        }
        var request = URLRequest(url: resolved)
        request.httpMethod = "GET"
        AuthenticatedRequest.applyHeaders(
            to: &request,
            cookieHeader: cookieHeader,
            bearerToken: nil,
            referer: "https://claude.ai/"
        )
        return try await AuthenticatedRequest.perform(request) { usageError in
            switch usageError {
            case .notSignedIn: return ClaudeUsageError.notSignedIn
            case .unauthorized: return ClaudeUsageError.unauthorized
            case let .network(message): return ClaudeUsageError.network(message)
            case let .badResponse(message): return ClaudeUsageError.badResponse(message)
            }
        }
    }

    private func getOAuth(path: String, token: String) async throws -> Data {
        guard let resolved = URL(string: path, relativeTo: Self.oauthBaseURL)?.absoluteURL else {
            throw ClaudeUsageError.badResponse("Invalid OAuth path \(path)")
        }
        var request = URLRequest(url: resolved)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")
        return try await AuthenticatedRequest.perform(request) { usageError in
            switch usageError {
            case .notSignedIn: return ClaudeUsageError.notSignedIn
            case .unauthorized: return ClaudeUsageError.unauthorized
            case let .network(message): return ClaudeUsageError.network(message)
            case let .badResponse(message): return ClaudeUsageError.badResponse(message)
            }
        }
    }
}
