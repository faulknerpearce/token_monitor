import Foundation

/// Parses REST usage JSON from a known set of usage keys and wrappers.
///
/// Reads only usage-specific keys (bare `percent` / `value` are ignored) and
/// requires every percentage to lie in 0...100, so an unrelated 200 response
/// fails to parse as usage.
enum GrokUsageResponseParser {
    /// Parses `data` as usage JSON, returning nil when no usable pool is present.
    static func parseJSON(_ data: Data, accountEmail: String?) -> WeeklyUsageSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parseAny(obj, accountEmail: accountEmail)
    }

    private static let wrapperKeys = ["usage", "data", "subscription", "billing", "credits", "result"]

    private static func parseAny(_ obj: Any, accountEmail: String?) -> WeeklyUsageSnapshot? {
        guard let dict = obj as? [String: Any] else { return nil }

        // Nested common wrappers
        for key in wrapperKeys {
            if let nested = dict[key], let snap = parseAny(nested, accountEmail: accountEmail) {
                return snap
            }
        }

        let used = firstDouble(dict, keys: [
            "usedPercent", "usagePercent", "credit_usage_percent", "percentUsed",
            "used_percent", "usage_percent"
        ])
        let remaining = firstDouble(dict, keys: [
            "remainingPercent", "remaining_percent", "percentRemaining"
        ])
        guard isPercent(used), isPercent(remaining) else { return nil }

        var products: [ProductUsage] = []
        if let breakdown = dict["products"] as? [[String: Any]]
            ?? dict["breakdown"] as? [[String: Any]]
            ?? dict["productBreakdown"] as? [[String: Any]] {
            products = breakdown.compactMap { item in
                let id = stringValue(item["id"])
                    ?? stringValue(item["key"])
                    ?? stringValue(item["name"])
                    ?? "other"
                let name = stringValue(item["displayName"])
                    ?? stringValue(item["name"])
                    ?? stringValue(item["label"])
                    ?? ProductCatalog.displayName(for: id)
                guard let pct = firstDouble(item, keys: ["percentOfPool", "usagePercent"]) else { return nil }
                return ProductUsage(id: id.lowercased(), displayName: name, percentOfPool: pct)
            }
        } else if let map = dict["byProduct"] as? [String: Any] ?? dict["productUsage"] as? [String: Any] {
            products = map.compactMap { key, value in
                let pct: Double
                if let n = value as? Double { pct = n } else if let n = value as? Int { pct = Double(n) } else if let nested = value as? [String: Any] {
                    guard let nestedPct = firstDouble(nested, keys: ["percentOfPool", "usagePercent"]) else { return nil }
                    pct = nestedPct
                } else { return nil }
                return ProductUsage(
                    id: key.lowercased(),
                    displayName: ProductCatalog.displayName(for: key),
                    percentOfPool: pct
                )
            }
        }

        let resetsString = firstString(dict, keys: [
            "resetsAt", "resetAt", "reset_at", "billingPeriodEnd", "periodEnd", "nextReset"
        ])
        let resetsAt = resetsString.flatMap { ISO8601DateFormatter.parseFlexible($0) }

        let credits = firstDecimal(dict, keys: [
            "extraCredits", "extraCreditsBalance", "onDemandBalance", "creditsBalance"
        ])

        guard products.allSatisfy({ isPercent($0.percentOfPool) }) else { return nil }

        // Accept if a used% or products that sum to used are present.
        let inferredUsed: Double? = {
            if let used { return used }
            let sum = products.reduce(0) { $0 + $1.percentOfPool }
            return sum > 0 ? sum : nil
        }()

        guard let inferredUsed, isPercent(inferredUsed) else { return nil }
        let rem = remaining ?? max(0, 100 - inferredUsed)
        let finalProducts = products.isEmpty
            ? GrokUsageClient.synthesizeProducts(usedPercent: inferredUsed)
            : products

        return WeeklyUsageSnapshot(
            usedPercent: inferredUsed,
            remainingPercent: rem,
            resetsAt: resetsAt,
            products: finalProducts,
            extraCreditsBalance: credits,
            accountEmail: accountEmail ?? stringValue(dict["email"])
        )
    }

    /// True for a missing value or a finite value in 0...100 (with a little
    /// rounding slack).
    private static func isPercent(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0 && value <= 100.5
    }

    private static func firstDouble(_ dict: [String: Any], keys: [String]) -> Double? {
        JSON.firstDouble(dict, keys: keys)
    }

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        JSON.firstString(dict, keys: keys)
    }

    private static func firstDecimal(_ dict: [String: Any], keys: [String]) -> Decimal? {
        JSON.firstDecimal(dict, keys: keys)
    }

    private static func stringValue(_ any: Any?) -> String? {
        JSON.string(any)
    }
}
