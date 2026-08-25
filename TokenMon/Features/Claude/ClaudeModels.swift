import Foundation

/// One Claude rate-limit window (`five_hour` / `seven_day`).
struct ClaudeUsageWindow: Hashable, Sendable {
    /// 0…100 utilization of the window.
    var usedPercent: Double
    var resetsAt: Date?

    var remainingPercent: Double {
        Percent.clamp(100 - usedPercent)
    }
}

/// Parsed `claude.ai/api/organizations/{org}/usage` payload, plus the
/// OAuth `api.anthropic.com/api/oauth/usage` variant which adds per-model
/// weekly windows (`seven_day_opus` / `seven_day_sonnet` / `seven_day_haiku`).
struct ClaudeUsageResponse: Hashable, Sendable {
    var fiveHour: ClaudeUsageWindow?
    var sevenDay: ClaudeUsageWindow?
    /// Per-model weekly windows from the OAuth endpoint (`null` when unused).
    var sevenDayOpus: ClaudeUsageWindow?
    var sevenDaySonnet: ClaudeUsageWindow?
    var sevenDayHaiku: ClaudeUsageWindow?

    /// Known per-model weekly rate-limit buckets, in display order
    /// (Opus → Sonnet → Haiku). These are independent caps from the OAuth
    /// endpoint — not a composition of `seven_day`. Null / unused omitted.
    var perModelWindows: [(label: String, window: ClaudeUsageWindow)] {
        var out: [(String, ClaudeUsageWindow)] = []
        if let opusWindow = sevenDayOpus { out.append(("Opus", opusWindow)) }
        if let sonnetWindow = sevenDaySonnet { out.append(("Sonnet", sonnetWindow)) }
        if let haikuWindow = sevenDayHaiku { out.append(("Haiku", haikuWindow)) }
        return out
    }

    /// Parses the raw usage JSON (`five_hour` / `seven_day` windows, plus the
    /// optional `seven_day_*` per-model windows from the OAuth endpoint).
    static func parse(_ data: Data) throws -> ClaudeUsageResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageError.badResponse("Unexpected usage payload")
        }
        return ClaudeUsageResponse(
            fiveHour: window(from: root["five_hour"]),
            sevenDay: window(from: root["seven_day"]),
            sevenDayOpus: window(from: root["seven_day_opus"]),
            sevenDaySonnet: window(from: root["seven_day_sonnet"]),
            sevenDayHaiku: window(from: root["seven_day_haiku"])
        )
    }

    private static func window(from raw: Any?) -> ClaudeUsageWindow? {
        guard let dict = raw as? [String: Any],
              let utilization = JSON.number(dict["utilization"])
        else { return nil }
        let resetsAt = (dict["resets_at"] as? String).flatMap(ISO8601DateFormatter.parseFlexible)
        return ClaudeUsageWindow(usedPercent: Percent.clamp(utilization), resetsAt: resetsAt)
    }
}

struct ClaudeSnapshot: Identifiable, Hashable, Sendable {
    var id: Date { fetchedAt }
    var fetchedAt: Date
    var fiveHour: ClaudeUsageWindow?
    var sevenDay: ClaudeUsageWindow?
    var sevenDayOpus: ClaudeUsageWindow?
    var sevenDaySonnet: ClaudeUsageWindow?
    var sevenDayHaiku: ClaudeUsageWindow?
    var accountEmail: String?

    var resetsAt: Date? { fiveHour?.resetsAt ?? sevenDay?.resetsAt }

    var headlineUsedPercent: Double {
        (fiveHour ?? sevenDay)?.usedPercent ?? 0
    }

    /// Per-model rows for the panel, matching `ClaudeUsageResponse.perModelWindows`.
    var perModelWindows: [(label: String, window: ClaudeUsageWindow)] {
        var out: [(String, ClaudeUsageWindow)] = []
        if let opusWindow = sevenDayOpus { out.append(("Opus", opusWindow)) }
        if let sonnetWindow = sevenDaySonnet { out.append(("Sonnet", sonnetWindow)) }
        if let haikuWindow = sevenDayHaiku { out.append(("Haiku", haikuWindow)) }
        return out
    }
}
