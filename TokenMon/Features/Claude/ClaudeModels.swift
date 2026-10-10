import Foundation

/// One Claude rate-limit window (`five_hour` / `seven_day`).
struct ClaudeUsageWindow: Hashable, Sendable {
    /// 0…100 utilization of the window.
    var usedPercent: Double
    var resetsAt: Date?
    /// Model the limit applies to (`"Fable"`) when it is model-scoped rather
    /// than account-wide; `nil` for an account-wide limit.
    var scopeName: String?

    var remainingPercent: Double {
        Percent.clamp(100 - usedPercent)
    }
}

/// Parsed `claude.ai/api/organizations/{org}/usage` payload.
struct ClaudeUsageResponse: Hashable, Sendable {
    var fiveHour: ClaudeUsageWindow?
    var sevenDay: ClaudeUsageWindow?

    /// Parses the raw usage JSON.
    ///
    /// The legacy `five_hour` / `seven_day` objects win when present. Accounts
    /// whose `seven_day` is `null` report their weekly pool only in the `limits`
    /// array (`group: "weekly"`), and that entry is used instead.
    static func parse(_ data: Data) throws -> ClaudeUsageResponse {
        let root = try ProviderHTTP.jsonObject(data, context: .claude)
        let limits = (root["limits"] as? [[String: Any]]) ?? []
        return ClaudeUsageResponse(
            fiveHour: window(from: root["five_hour"]) ?? limitWindow(in: limits, group: "session"),
            sevenDay: window(from: root["seven_day"]) ?? limitWindow(in: limits, group: "weekly")
        )
    }

    private static func window(from raw: Any?) -> ClaudeUsageWindow? {
        guard let dict = raw as? [String: Any],
              let utilization = JSON.number(dict["utilization"])
        else { return nil }
        return ClaudeUsageWindow(usedPercent: Percent.clamp(utilization), resetsAt: resetDate(dict["resets_at"]))
    }

    /// Picks the `limits` entry for `group`: an account-wide (unscoped) limit
    /// first, then an active one, then the most used.
    private static func limitWindow(in limits: [[String: Any]], group: String) -> ClaudeUsageWindow? {
        let candidates = limits.filter { JSON.string($0["group"]) == group && JSON.number($0["percent"]) != nil }
        func rank(_ entry: [String: Any]) -> (Int, Int, Double) {
            let unscoped = scopeName(entry["scope"]) == nil ? 1 : 0
            let active = (entry["is_active"] as? Bool) == true ? 1 : 0
            return (unscoped, active, JSON.number(entry["percent"]) ?? 0)
        }
        guard let best = candidates.max(by: { rank($0) < rank($1) }),
              let percent = JSON.number(best["percent"])
        else { return nil }
        return ClaudeUsageWindow(
            usedPercent: Percent.clamp(percent),
            resetsAt: resetDate(best["resets_at"]),
            scopeName: scopeName(best["scope"])
        )
    }

    /// Display name of a limit's model scope, `nil` when the limit is unscoped.
    private static func scopeName(_ raw: Any?) -> String? {
        guard let scope = raw as? [String: Any],
              let model = scope["model"] as? [String: Any]
        else { return nil }
        return JSON.string(model["display_name"]) ?? JSON.string(model["id"])
    }

    private static func resetDate(_ raw: Any?) -> Date? {
        (raw as? String).flatMap(ISO8601DateFormatter.parseFlexible)
    }
}

/// Headline Claude rate-limit snapshot (5-hour and weekly windows).
struct ClaudeSnapshot: Identifiable, Hashable, Sendable {
    var id: Date { fetchedAt }
    var fetchedAt: Date
    var fiveHour: ClaudeUsageWindow?
    var sevenDay: ClaudeUsageWindow?
    var accountEmail: String?

    var resetsAt: Date? { fiveHour?.resetsAt ?? sevenDay?.resetsAt }

    /// Weekly track label, naming the model when the weekly limit is model-scoped.
    var weeklyLabel: String {
        sevenDay?.scopeName.map { "Weekly · \($0)" } ?? "Weekly"
    }

    var headlineUsedPercent: Double {
        (fiveHour ?? sevenDay)?.usedPercent ?? 0
    }
}
