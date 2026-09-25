import Foundation

/// Fetches OpenRouter usage via its public REST API (bearer key auth).
///
/// Two parallel calls:
/// - `GET /key` — works with every key; all-time/daily/weekly/monthly spend
///   plus any per-key credit limit.
/// - `GET /credits` — purchased vs. used account credits; only management
///   keys are served this endpoint, so failure here degrades quietly.
struct OpenRouterUsageClient: Sendable {
    static let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    private let apiKey: String
    private let decoder = JSONDecoder()

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func fetchSnapshot(now: Date = Date()) async throws -> OpenRouterSnapshot {
        async let keyData = get("key")
        // Inference keys are refused on /credits (HTTP 403) — that is an
        // expected shape, not an error, so degrade to key-limit budgeting.
        async let creditsData = try? get("credits")
        // /activity (per-model spend) also requires a management key; ordinary
        // keys get 403, so degrade to no model breakdown.
        async let activityData = try? get("activity")

        let key = try await decode(OpenRouterKeyResponse.self, from: keyData)
        var credits: OpenRouterCreditsResponse?
        if let data = await creditsData {
            credits = try? decode(OpenRouterCreditsResponse.self, from: data)
        }
        var activity: [OpenRouterActivityRow]?
        if let data = await activityData {
            activity = try? decode(OpenRouterActivityResponse.self, from: data).data
        }
        return OpenRouterSnapshot.build(
            key: key.data,
            credits: credits?.data,
            activity: activity,
            fetchedAt: now
        )
    }

    /// Parses a `/key` payload without network access (tests + diagnostics).
    static func parseKey(_ data: Data) throws -> OpenRouterKeyResponse {
        try JSONDecoder().decode(OpenRouterKeyResponse.self, from: data)
    }

    /// Parses a `/credits` payload without network access (tests + diagnostics).
    static func parseCredits(_ data: Data) throws -> OpenRouterCreditsResponse {
        try JSONDecoder().decode(OpenRouterCreditsResponse.self, from: data)
    }

    /// Parses an `/activity` payload without network access (tests + diagnostics).
    static func parseActivity(_ data: Data) throws -> OpenRouterActivityResponse {
        try JSONDecoder().decode(OpenRouterActivityResponse.self, from: data)
    }

    private func get(_ path: String) async throws -> Data {
        try await ProviderHTTP.get(
            path,
            baseURL: Self.baseURL,
            context: .openRouter,
            bearerToken: apiKey
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ProviderError.badResponse(.openRouter, "Unexpected JSON: \(error.localizedDescription)")
        }
    }
}
