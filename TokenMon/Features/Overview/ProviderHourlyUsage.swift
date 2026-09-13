import Foundation

enum QuotaNormalization {
    /// Average calendar weeks in a month, used to compare monthly plans with Grok's weekly pool.
    static let averageWeeksPerMonth = 365.2425 / 12 / 7
}

/// One hour's Grok / OpenCode Go / OpenCode Zen / Cursor / Claude / Grokbot quota consumption.
struct ProviderHourUsage: Identifiable, Hashable, Sendable {
    var hour: Int
    /// 0…100 share of this hour’s combined activity.
    var grokSharePercent: Double
    /// 0…100 share of this hour's combined activity.
    var openCodeGoSharePercent: Double
    /// 0…100 share of this hour's combined activity.
    var openCodeZenSharePercent: Double
    /// 0…100 share of this hour’s combined activity.
    var cursorSharePercent: Double
    /// 0…100 share of this hour’s combined activity.
    var claudeSharePercent: Double
    /// 0…100 share of this hour’s combined activity.
    var grokbotSharePercent: Double
    /// Percentage points of provider quota consumed during this hour.
    var activity: Double
    /// Dollar-ish amount for peak labels (OpenCode / harness $ for this hour).
    var costUSD: Double
    /// Token totals when the provider exposes them. Grok/Claude currently report quota only.
    var grokTokens: Int64?
    var openCodeGoTokens: Int64
    var openCodeZenTokens: Int64
    var cursorTokens: Int64
    var claudeTokens: Int64?

    var id: Int { hour }

    var openCodeSharePercent: Double {
        openCodeGoSharePercent + openCodeZenSharePercent
    }

    var grokActivity: Double { activity * grokSharePercent / 100 }
    var openCodeGoActivity: Double { activity * openCodeGoSharePercent / 100 }
    var openCodeZenActivity: Double { activity * openCodeZenSharePercent / 100 }
    var cursorActivity: Double { activity * cursorSharePercent / 100 }
    var claudeActivity: Double { activity * claudeSharePercent / 100 }
    var grokbotActivity: Double { activity * grokbotSharePercent / 100 }

    var hourLabel: String {
        Format.hourLabel(for: hour)
    }

    var hasActivity: Bool { activity > 0 }
}

struct ProviderDayHourlyUsage: Hashable, Sendable {
    var dayStart: Date
    var hours: [ProviderHourUsage] // 24 entries

    var maxActivity: Double {
        hours.map(\.activity).max() ?? 0
    }

    var isEmpty: Bool {
        maxActivity <= 0
    }

    /// Merge hourly quota-consumption deltas into provider shares.
    ///
    /// All hourly inputs are percentage-point deltas against the provider's own quota,
    /// which makes the combined height comparable without daily re-normalization.
    /// `hourCostUSD` is used only for peak `$` labels.
    static func build(
        dayStart: Date,
        grokHourWeights: [Double],
        openCodeGoHourWeights: [Double],
        openCodeZenHourWeights: [Double],
        cursorHourWeights: [Double] = Array(repeating: 0, count: 24),
        claudeHourWeights: [Double] = Array(repeating: 0, count: 24),
        grokbotHourWeights: [Double] = Array(repeating: 0, count: 24),
        hourCostUSD: [Double]? = nil,
        grokHourTokens: [Int64]? = nil,
        openCodeGoHourTokens: [Int64] = Array(repeating: 0, count: 24),
        openCodeZenHourTokens: [Int64] = Array(repeating: 0, count: 24),
        cursorHourTokens: [Int64] = Array(repeating: 0, count: 24),
        claudeHourTokens: [Int64]? = nil
    ) -> ProviderDayHourlyUsage {
        // Pad/truncate to 24 instead of trapping: a malformed caller should
        // degrade to a zeroed hour, never crash the menu bar.
        let grokHourWeights = Self.normalized(grokHourWeights)
        let openCodeGoHourWeights = Self.normalized(openCodeGoHourWeights)
        let openCodeZenHourWeights = Self.normalized(openCodeZenHourWeights)
        let cursorHourWeights = Self.normalized(cursorHourWeights)
        let claudeHourWeights = Self.normalized(claudeHourWeights)
        let grokbotHourWeights = Self.normalized(grokbotHourWeights)
        let costs = Self.normalized(hourCostUSD ?? [])
        let grokHourTokens = Self.normalized(grokHourTokens)
        let claudeHourTokens = Self.normalized(claudeHourTokens)
        let openCodeGoHourTokens = Self.normalized(openCodeGoHourTokens)
        let openCodeZenHourTokens = Self.normalized(openCodeZenHourTokens)
        let cursorHourTokens = Self.normalized(cursorHourTokens)

        let hours: [ProviderHourUsage] = (0..<24).map { hour in
            let grokDelta = max(0, grokHourWeights[hour])
            let openGoDelta = max(0, openCodeGoHourWeights[hour])
            let openZenDelta = max(0, openCodeZenHourWeights[hour])
            let cursorDelta = max(0, cursorHourWeights[hour])
            let claudeDelta = max(0, claudeHourWeights[hour])
            let grokbotDelta = max(0, grokbotHourWeights[hour])
            let activity = grokDelta + openGoDelta + openZenDelta + cursorDelta + claudeDelta + grokbotDelta
            let grokShare = activity > 0 ? grokDelta / activity * 100 : 0
            let openGoShare = activity > 0 ? openGoDelta / activity * 100 : 0
            let openZenShare = activity > 0 ? openZenDelta / activity * 100 : 0
            let cursorShare = activity > 0 ? cursorDelta / activity * 100 : 0
            let claudeShare = activity > 0 ? claudeDelta / activity * 100 : 0
            let grokbotShare = activity > 0 ? grokbotDelta / activity * 100 : 0
            return ProviderHourUsage(
                hour: hour,
                grokSharePercent: grokShare,
                openCodeGoSharePercent: openGoShare,
                openCodeZenSharePercent: openZenShare,
                cursorSharePercent: cursorShare,
                claudeSharePercent: claudeShare,
                grokbotSharePercent: grokbotShare,
                activity: activity,
                costUSD: max(0, costs[hour]),
                grokTokens: grokHourTokens?[hour],
                openCodeGoTokens: max(0, openCodeGoHourTokens[hour]),
                openCodeZenTokens: max(0, openCodeZenHourTokens[hour]),
                cursorTokens: max(0, cursorHourTokens[hour]),
                claudeTokens: claudeHourTokens?[hour]
            )
        }

        return ProviderDayHourlyUsage(dayStart: dayStart, hours: hours)
    }

    private static func normalized(_ values: [Double]) -> [Double] {
        if values.count == 24 { return values }
        if values.count > 24 { return Array(values.prefix(24)) }
        return values + Array(repeating: 0.0, count: 24 - values.count)
    }

    private static func normalized(_ values: [Int64]) -> [Int64] {
        if values.count == 24 { return values }
        if values.count > 24 { return Array(values.prefix(24)) }
        return values + Array(repeating: 0, count: 24 - values.count)
    }

    private static func normalized(_ values: [Double]?) -> [Double]? {
        values.map { normalized($0) }
    }

    private static func normalized(_ values: [Int64]?) -> [Int64]? {
        values.map { normalized($0) }
    }
}
