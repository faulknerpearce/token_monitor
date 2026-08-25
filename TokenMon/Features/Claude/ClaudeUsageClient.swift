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

/// Fetches claude.ai rate-limit usage via the cookie-authenticated internal endpoint.
struct ClaudeUsageClient: Sendable {
    static let baseURL = URL(string: "https://claude.ai")!

    private let cookieHeader: String

    init(cookieHeader: String) {
        self.cookieHeader = cookieHeader
    }

    func fetchUsage(now: Date = Date()) async throws -> (ClaudeUsageResponse, Date) {
        guard let organizationID = Self.organizationID(fromCookieHeader: cookieHeader) else {
            throw ClaudeUsageError.missingOrganization
        }
        let data = try await get(path: "/api/organizations/\(organizationID)/usage")
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
}
