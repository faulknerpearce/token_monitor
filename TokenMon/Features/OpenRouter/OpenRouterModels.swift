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
    /// Per-model spend over the last 30 days (`/activity`; management keys only).
    var models: [OpenRouterModelUsage] = []

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
        activity: [OpenRouterActivityRow]? = nil,
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
            // Window selection follows the provider's `limit_reset`, not the local
            // calendar: inside a reset window the bar shows spend against the current
            // window; without one, `/key` usage is all-time.
            let windowUsage = key.limitReset.flatMap { reset in
                key.limitRemaining.map { max(0, limit - $0) }
                    ?? Self.windowUsage(key: key, reset: reset.lowercased())
            }
            snapshot.usedUSD = windowUsage ?? key.usage
            snapshot.remainingUSD = key.limitRemaining
                ?? windowUsage.map { max(0, limit - $0) }
                ?? max(0, limit - key.usage)
        }

        snapshot.models = OpenRouterModelUsage.models(from: activity ?? [])

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

/// One row of `GET /activity` — spend/tokens for a model on a UTC day, grouped
/// by endpoint (so a model can appear several times in one day).
struct OpenRouterActivityRow: Codable, Sendable {
    var date: String
    var model: String
    var providerName: String?
    var usage: Double
    var requests: Int
    var promptTokens: Int
    var completionTokens: Int
    var reasoningTokens: Int

    enum CodingKeys: String, CodingKey {
        case date, model, usage, requests
        case providerName = "provider_name"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case reasoningTokens = "reasoning_tokens"
    }
}

struct OpenRouterActivityResponse: Codable, Sendable {
    var data: [OpenRouterActivityRow]
}

/// One model in the OpenRouter spend breakdown, aggregated over the activity window.
struct OpenRouterModelUsage: Identifiable, Hashable, Sendable {
    /// Canonical display slug — stealth aliases resolved (e.g. `z-ai/glm-5.3-flash`).
    var modelID: String
    /// The slug OpenRouter actually reported (e.g. `stealth/ox-alpha`).
    var activitySlug: String
    var requests: Int
    var promptTokens: Int
    var completionTokens: Int
    var costUSD: Double
    /// True when `costUSD` was derived from tokens (a free/stealth row reported $0).
    var isCostEstimated: Bool
    /// Share of the window's model spend, 0…100.
    var percentOfWindow: Double = 0

    var id: String { activitySlug }

    /// The slug was a stealth alias later revealed as a known model.
    var isRevealed: Bool { modelID != activitySlug }

    var totalTokens: Int { promptTokens + completionTokens }

    /// Aggregates activity rows by canonical model, estimating value for rows
    /// OpenRouter reports at $0 (free/stealth models).
    static func models(from rows: [OpenRouterActivityRow]) -> [OpenRouterModelUsage] {
        var byCanonical: [String: OpenRouterModelUsage] = [:]
        for row in rows {
            let canonical = OpenRouterModelPricing.canonicalSlug(row.model)
            var usage = byCanonical[canonical] ?? OpenRouterModelUsage(
                modelID: canonical,
                activitySlug: row.model,
                requests: 0,
                promptTokens: 0,
                completionTokens: 0,
                costUSD: 0,
                isCostEstimated: false
            )
            usage.requests += max(0, row.requests)
            usage.promptTokens += max(0, row.promptTokens)
            usage.completionTokens += max(0, row.completionTokens)
            usage.costUSD += max(0, row.usage)
            byCanonical[canonical] = usage
        }

        for (key, var usage) in byCanonical where usage.costUSD <= 0 {
            let value = OpenRouterModelPricing.estimatedValueUSD(
                slug: usage.modelID,
                promptTokens: usage.promptTokens,
                completionTokens: usage.completionTokens
            )
            if value > 0 {
                usage.costUSD = value
                usage.isCostEstimated = true
            }
            byCanonical[key] = usage
        }

        let total = byCanonical.values.reduce(0) { $0 + $1.costUSD }
        return byCanonical.values
            .sorted { lhs, rhs in
                if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
                return lhs.totalTokens > rhs.totalTokens
            }
            .map { usage in
                var copy = usage
                copy.percentOfWindow = total > 0 ? copy.costUSD / total * 100 : 0
                return copy
            }
    }
}

/// OpenRouter model identity and value helpers.
enum OpenRouterModelPricing {
    /// Stealth slugs that were later revealed as a public model: display and
    /// price them as the real slug.
    private static let revealedSlugs: [String: String] = [
        "stealth/ox-alpha": "z-ai/glm-5.3-flash"
    ]

    /// Resolves a stealth alias to the model it was revealed to be.
    static func canonicalSlug(_ slug: String) -> String {
        revealedSlugs[slug.lowercased()] ?? slug
    }

    /// Value of a model's tokens when OpenRouter reports no cost. Reuses the
    /// shared OpenRouter-sourced rate table via the bare model id.
    static func estimatedValueUSD(slug: String, promptTokens: Int, completionTokens: Int) -> Double {
        let bare = canonicalSlug(slug).split(separator: "/").last.map(String.init) ?? slug
        return OpenCodeZenCostEstimate.estimate(
            modelID: bare,
            inputTokens: Int64(max(0, promptTokens)),
            outputTokens: Int64(max(0, completionTokens)),
            cacheReadTokens: 0,
            cacheWriteTokens: 0
        )
    }
}
