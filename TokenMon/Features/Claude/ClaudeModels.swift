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

/// Parsed `claude.ai/api/organizations/{org}/usage` payload.
struct ClaudeUsageResponse: Hashable, Sendable {
    var fiveHour: ClaudeUsageWindow?
    var sevenDay: ClaudeUsageWindow?

    /// Parses the raw usage JSON (`five_hour` / `seven_day` windows).
    static func parse(_ data: Data) throws -> ClaudeUsageResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageError.badResponse("Unexpected usage payload")
        }
        return ClaudeUsageResponse(
            fiveHour: window(from: root["five_hour"]),
            sevenDay: window(from: root["seven_day"])
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
    var accountEmail: String?

    var resetsAt: Date? { fiveHour?.resetsAt ?? sevenDay?.resetsAt }

    var headlineUsedPercent: Double {
        (fiveHour ?? sevenDay)?.usedPercent ?? 0
    }
}
