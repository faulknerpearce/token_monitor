import Foundation

/// Fetches OpenRouter usage via its public REST API (bearer key auth).
///
/// - `GET /key` — works with every key; all-time/daily/weekly/monthly spend
///   plus any per-key credit limit and whether the key is a management key.
/// - `GET /credits` and `GET /activity` — purchased vs. used account credits
///   and per-model spend. OpenRouter serves these only to management keys, so
///   they are requested only after `/key` reports one (or does not say), and a
///   failure on either degrades quietly.
struct OpenRouterUsageClient: Sendable {
    static let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    /// Endpoint paths, resolved under `baseURL`.
    enum Endpoint: String, CaseIterable, Sendable {
        case key
        case credits
        case activity
    }

    /// Fetches one endpoint's body; the live client issues an authenticated GET.
    typealias Fetch = @Sendable (Endpoint) async throws -> Data

    private let fetch: Fetch
    private let decoder = JSONDecoder()

    init(apiKey: String) {
        self.init { endpoint in
            try await ProviderHTTP.get(
                endpoint.rawValue,
                baseURL: Self.baseURL,
                context: .openRouter,
                bearerToken: apiKey
            )
        }
    }

    /// Injects the transport (tests supply canned bodies per endpoint).
    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// Absolute URL requested for `endpoint`.
    static func url(for endpoint: Endpoint) -> URL? {
        ProviderHTTP.resolve(endpoint.rawValue, baseURL: baseURL)
    }

    /// Fetches `/key`, then `/credits` and `/activity` in parallel when the key
    /// may be a management key.
    func fetchSnapshot(now: Date = Date()) async throws -> OpenRouterSnapshot {
        let key = try await decode(OpenRouterKeyResponse.self, from: fetch(.key)).data
        guard key.isManagementKey != false else {
            return OpenRouterSnapshot.build(key: key, credits: nil, activity: nil, fetchedAt: now)
        }
        async let creditsData = try? fetch(.credits)
        async let activityData = try? fetch(.activity)
        let credits = await creditsData.flatMap { try? decode(OpenRouterCreditsResponse.self, from: $0).data }
        let activity = await activityData.flatMap { try? decode(OpenRouterActivityResponse.self, from: $0).data }
        return OpenRouterSnapshot.build(key: key, credits: credits, activity: activity, fetchedAt: now)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ProviderError.badResponse(.openRouter, "Unexpected JSON: \(error.localizedDescription)")
        }
    }
}
