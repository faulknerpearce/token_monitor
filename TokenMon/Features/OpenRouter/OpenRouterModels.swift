import Foundation

/// `/key` payload describing the authenticated API key.
struct OpenRouterKeyData: Codable, Sendable {
    var label: String?
    var usage: Double
    var usageDaily: Double?
    var usageWeekly: Double?
    var usageMonthly: Double?
    /// Spending cap configured on the key (USD), `nil` when unlimited.
    var limit: Double?
    var limitRemaining: Double?
    var limitReset: String?
    var isFreeTier: Bool?
    var isManagementKey: Bool?

    enum CodingKeys: String, CodingKey {
        case label, usage, limit
        case usageDaily = "usage_daily"
        case usageWeekly = "usage_weekly"
        case usageMonthly = "usage_monthly"
        case limitRemaining = "limit_remaining"
        case limitReset = "limit_reset"
        case isFreeTier = "is_free_tier"
        case isManagementKey = "is_management_key"
    }
}

struct OpenRouterKeyResponse: Codable, Sendable {
    var data: OpenRouterKeyData
}

/// `GET /credits` payload — only served to management keys.
struct OpenRouterCreditsData: Codable, Sendable {
    /// Total credits purchased (USD).
    var totalCredits: Double
    /// Total credits used (USD).
    var totalUsage: Double

    enum CodingKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }
}

struct OpenRouterCreditsResponse: Codable, Sendable {
    var data: OpenRouterCreditsData
}

enum OpenRouterBudgetSource: String, Sendable {
    /// Credits purchased on the account (`/credits`, management keys).
    case accountCredits
    /// Per-key spending cap from `/key`.
    case keyLimit

    var label: String {
        switch self {
        case .accountCredits: return "Account credits"
        case .keyLimit: return "Key limit"
        }
    }
}

enum OpenRouterUsageError: LocalizedError, ProviderUsageError {
    case notSignedIn
    case unauthorized
    case badResponse(String)
    case network(String)

    var usageError: UsageError {
        switch self {
        case .notSignedIn: return .notSignedIn
        case .unauthorized: return .unauthorized
        case let .badResponse(message): return .badResponse(message)
        case let .network(message): return .network(message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Add an OpenRouter API key to load usage."
        case .unauthorized:
            return "OpenRouter rejected the API key. Check or replace it."
        case let .badResponse(message):
            return "OpenRouter response error: \(message)"
        case let .network(message):
            return "OpenRouter network error: \(message)"
        }
    }
}

/// One OpenRouter poll result.
///
/// Budget model: the credits the user put in. A management key resolves the
/// true account balance via `/credits`; otherwise the snapshot falls back to
/// the key's own credit limit. Keys with no limit anywhere show spend only.
struct OpenRouterSnapshot: Identifiable, Hashable, Sendable {
    var id: Date { fetchedAt }
    var fetchedAt: Date
    var keyLabel: String?
    var isManagementKey: Bool
    var isFreeTier: Bool
    /// Purchased credits (USD) when `/credits` succeeded.
    var accountCreditsUSD: Double?
    /// Total account spend (USD) when `/credits` succeeded.
    var accountUsedUSD: Double?
    /// This key's all-time spend (USD), always available from `/key`.
    var keyUsageUSD: Double
    var keyUsageDailyUSD: Double
    var keyUsageWeeklyUSD: Double
    var keyUsageMonthlyUSD: Double
    var keyLimitUSD: Double?
    var keyLimitRemainingUSD: Double?

    /// Which denominator backs `usedPercent`.
    var budgetSource: OpenRouterBudgetSource?
    /// Budget denominator in USD — purchased credits or key limit.
    var budgetUSD: Double?
    /// Spend measured against `budgetSource`.
    var usedUSD: Double
    var remainingUSD: Double?

    /// Percent of credits consumed; `nil` when there is no budget to divide by.
    var usedPercent: Double? {
        guard let budgetUSD, budgetUSD > 0 else { return nil }
        return Percent.clamp(usedUSD / budgetUSD * 100)
    }

    static func build(
        key: OpenRouterKeyData,
        credits: OpenRouterCreditsData?,
        fetchedAt: Date = Date()
    ) -> OpenRouterSnapshot {
        var snapshot = OpenRouterSnapshot(
            fetchedAt: fetchedAt,
            keyLabel: key.label,
            isManagementKey: key.isManagementKey ?? false,
            isFreeTier: key.isFreeTier ?? false,
            accountCreditsUSD: credits?.totalCredits,
            accountUsedUSD: credits?.totalUsage,
            keyUsageUSD: key.usage,
            keyUsageDailyUSD: key.usageDaily ?? 0,
            keyUsageWeeklyUSD: key.usageWeekly ?? 0,
            keyUsageMonthlyUSD: key.usageMonthly ?? 0,
            keyLimitUSD: key.limit,
            keyLimitRemainingUSD: key.limitRemaining,
            budgetSource: nil,
            budgetUSD: nil,
            usedUSD: key.usage,
            remainingUSD: nil
        )

        if let credits, credits.totalCredits > 0 {
            snapshot.budgetSource = .accountCredits
            snapshot.budgetUSD = credits.totalCredits
            snapshot.usedUSD = credits.totalUsage
            snapshot.remainingUSD = max(0, credits.totalCredits - credits.totalUsage)
        } else if let limit = key.limit, limit > 0 {
            snapshot.budgetSource = .keyLimit
            snapshot.budgetUSD = limit
            // Window selection comes from the provider's own `limit_reset` — never
            // the local calendar. Inside a reset window the bar shows spend against
            // the *current window* so it reconciles with `limit_remaining`; without
            // a reset window, `/key` usage is all-time.
            let windowUsage = key.limitReset.flatMap { reset in
                key.limitRemaining.map { max(0, limit - $0) }
                    ?? Self.windowUsage(key: key, reset: reset.lowercased())
            }
            snapshot.usedUSD = windowUsage ?? key.usage
            snapshot.remainingUSD = key.limitRemaining
                ?? windowUsage.map { max(0, limit - $0) }
                ?? max(0, limit - key.usage)
        }

        // Negative balances (overdraft) clamp so the bar never underfills.
        snapshot.usedUSD = max(0, snapshot.usedUSD)
        return snapshot
    }

    /// `/key` usage field matching the provider-declared `limit_reset` window.
    private static func windowUsage(key: OpenRouterKeyData, reset: String) -> Double? {
        switch reset {
        case "daily": return key.usageDaily
        case "weekly": return key.usageWeekly
        case "monthly": return key.usageMonthly
        default: return nil
        }
    }
}
