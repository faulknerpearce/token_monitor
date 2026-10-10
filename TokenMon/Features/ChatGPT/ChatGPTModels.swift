import Foundation

/// One Codex rate-limit window from `wham/usage`.
struct ChatGPTUsageWindow: Hashable, Sendable {
    /// 0…100 used (clamped — the endpoint can report >100 at the edge).
    var usedPercent: Double
    var resetsAt: Date?
    /// Window length reported by the endpoint (`limit_window_seconds`).
    var windowSeconds: Int?

    var remainingPercent: Double {
        Percent.clamp(100 - usedPercent)
    }

    /// Track label derived from `windowSeconds` ("5-Hour Window", "Weekly"),
    /// or `fallback` when the length is not reported.
    func label(fallback: String) -> String {
        guard let windowSeconds, windowSeconds > 0 else { return fallback }
        let hours = Double(windowSeconds) / 3600
        switch hours {
        case 168: return "Weekly"
        case 24: return "Daily"
        case let value where value < 24 && value == value.rounded():
            return "\(Int(value))-Hour Window"
        case let value where value.truncatingRemainder(dividingBy: 24) == 0:
            return "\(Int(value / 24))-Day Window"
        default:
            return fallback
        }
    }
}

/// Parsed `chatgpt.com/backend-api/wham/usage` payload.
struct ChatGPTUsageResponse: Hashable, Sendable {
    var planName: String?
    var allowed: Bool
    var limitReached: Bool
    var primary: ChatGPTUsageWindow?
    var secondary: ChatGPTUsageWindow?

    /// Parses the raw usage JSON (`primary_window` = 5h, `secondary_window` = weekly).
    static func parse(_ data: Data) throws -> ChatGPTUsageResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse(.chatGPT, "Unexpected usage payload")
        }
        let rateLimit = root["rate_limit"] as? [String: Any] ?? root
        return ChatGPTUsageResponse(
            planName: JSON.string(root["plan_type"]),
            allowed: (rateLimit["allowed"] as? Bool) ?? true,
            limitReached: (rateLimit["limit_reached"] as? Bool) ?? false,
            primary: window(from: rateLimit["primary_window"] ?? rateLimit["five_hour"]),
            secondary: window(from: rateLimit["secondary_window"] ?? rateLimit["weekly"])
        )
    }

    private static func window(from raw: Any?) -> ChatGPTUsageWindow? {
        guard let dict = raw as? [String: Any],
              let used = JSON.firstDouble(dict, keys: ["used_percent", "utilization"])
        else { return nil }
        let resetAt = JSON.nested(dict, ["reset_at"]).flatMap { value -> Date? in
            if let seconds = JSON.number(value) {
                return Date(timeIntervalSince1970: seconds)
            }
            if let string = JSON.string(value) {
                return ISO8601DateFormatter.parseFlexible(string)
            }
            return nil
        }
        return ChatGPTUsageWindow(
            usedPercent: Percent.clamp(used),
            resetsAt: resetAt,
            windowSeconds: JSON.firstDouble(dict, keys: ["limit_window_seconds"]).map(Int.init)
        )
    }
}

/// Headline Codex rate-limit snapshot (5-hour and weekly windows).
struct ChatGPTSnapshot: Identifiable, Hashable, Sendable {
    var id: Date { fetchedAt }
    var fetchedAt: Date
    var planName: String?
    var allowed: Bool
    var limitReached: Bool
    var primary: ChatGPTUsageWindow?
    var secondary: ChatGPTUsageWindow?

    var resetsAt: Date? { primary?.resetsAt ?? secondary?.resetsAt }

    var headlineUsedPercent: Double {
        (primary ?? secondary)?.usedPercent ?? 0
    }

    var displayPlanName: String {
        guard let planName, !planName.isEmpty else { return "ChatGPT" }
        return planName.prefix(1).uppercased() + planName.dropFirst().lowercased()
    }
}

/// Reads claims (account id, expiry) from a ChatGPT web access-token JWT.
enum ChatGPTAccountID {
    /// Decodes the ChatGPT web access-token JWT payload and extracts the
    /// account id from the `https://api.openai.com/auth` claim.
    static func fromAccessToken(_ token: String) -> String? {
        guard let root = payload(of: token),
              let auth = root["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        if let id = JSON.string(auth["chatgpt_account_id"]) {
            return id
        }
        for (key, value) in auth where key.lowercased().contains("account_id") {
            if let id = JSON.string(value) { return id }
        }
        return nil
    }

    /// The token's `exp` claim, or nil when the token is not a readable JWT.
    static func expiry(fromAccessToken token: String) -> Date? {
        payload(of: token).flatMap { JSON.number($0["exp"]) }.map { Date(timeIntervalSince1970: $0) }
    }

    /// Decoded JWT payload object.
    private static func payload(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let data = base64URLDecoded(String(parts[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        var string = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = string.count % 4
        if remainder > 0 {
            string.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: string)
    }
}
