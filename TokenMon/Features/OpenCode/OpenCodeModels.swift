import Foundation

/// Go limit windows (`rolling5h`, `weekly`, `monthly`).
enum OpenCodeWindowKind: String, Codable, CaseIterable, Sendable {
    case rolling5h
    case weekly
    case monthly

    var label: String {
        switch self {
        case .rolling5h: return "5-Hour"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    var defaultLimitUSD: Double {
        switch self {
        case .rolling5h: return 12
        case .weekly: return 30
        case .monthly: return 60
        }
    }
}

/// Spend against one Go limit window with its reset.
struct OpenCodeWindowUsage: Identifiable, Hashable, Sendable {
    var kind: OpenCodeWindowKind
    var usedUSD: Double
    var limitUSD: Double
    var resetsAt: Date?
    var sessionCount: Int

    var id: OpenCodeWindowKind { kind }

    var usedPercent: Double {
        Self.clampedPercent(usedUSD: usedUSD, limitUSD: limitUSD)
    }

    /// Spend as percent of limit; returns `0` when `limitUSD` is not positive.
    static func clampedPercent(usedUSD: Double, limitUSD: Double) -> Double {
        guard limitUSD > 0 else { return 0 }
        return Percent.clamp(usedUSD / limitUSD * 100)
    }
}

/// Plan spend and tokens for one `provider/model` in the week window.
struct OpenCodeModelUsage: Identifiable, Hashable, Sendable {
    var providerID: String
    var modelID: String
    var sessionCount: Int
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheReadTokens: Int64
    var cacheWriteTokens: Int64
    var costUSD: Double
    var percentOfWindow: Double
    /// True when `costUSD` was derived from tokens (Zen $0 rows).
    var isCostEstimated: Bool = false

    var id: String { "\(providerID)/\(modelID)" }

    var displayName: String {
        OpenCodeCatalog.modelDisplayName(providerID: providerID, modelID: modelID)
    }
}

/// One stacked segment inside an hour column.
struct OpenCodeHourSegment: Identifiable, Hashable, Sendable {
    var providerID: String
    var modelID: String
    var costUSD: Double
    /// Billable or paid-equivalent plan value used for quota deltas.
    var quotaCostUSD: Double
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var cacheWriteTokens: Int64 = 0
    var messageCount: Int = 0

    var id: String { "\(providerID)/\(modelID)" }

    var displayName: String {
        OpenCodeCatalog.modelDisplayName(providerID: providerID, modelID: modelID)
    }

    var totalTokens: Int64 {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    /// Activity weight for Overview: prefer $; fall back to message count so free turns count.
    var activityWeight: Double {
        if costUSD > 0 { return costUSD }
        return Double(messageCount) * 0.01
    }
}

/// One hour of the local day (0…23), with model cost stacks.
struct OpenCodeHourUsage: Identifiable, Hashable, Sendable {
    var hour: Int
    var segments: [OpenCodeHourSegment]
    var messageCount: Int = 0

    var id: Int { hour }

    var totalUSD: Double {
        segments.reduce(0) { $0 + $1.costUSD }
    }

    var totalTokens: Int64 {
        segments.reduce(0) { $0 + $1.totalTokens }
    }

    var hourLabel: String {
        Format.hourLabel(for: hour)
    }
}

/// Legend entry for one `provider/model` in the day chart.
struct OpenCodeHourLegendItem: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var providerID: String
    var modelID: String
}

/// Local day usage as 24 hourly stacks with a legend.
struct OpenCodeDayHourlyUsage: Hashable, Sendable {
    var dayStart: Date
    var hours: [OpenCodeHourUsage] // always 24 entries, hour 0…23
    var legend: [OpenCodeHourLegendItem]

    var maxHourUSD: Double {
        hours.map(\.totalUSD).max() ?? 0
    }

    var isEmpty: Bool {
        maxHourUSD <= 0 && hours.allSatisfy { $0.messageCount == 0 }
    }

    var dayTotalUSD: Double {
        hours.reduce(0) { $0 + $1.totalUSD }
    }

    /// Overview weights: keep Go and Zen separate; xAI/Grok-via-harness → Grok;
    /// other BYOK providers are excluded.
    func overviewProviderHourWeights() -> (
        openCodeGo: [Double],
        openCodeZen: [Double],
        grokViaOpenCode: [Double]
    ) {
        var openCodeGo = Array(repeating: 0.0, count: 24)
        var openCodeZen = Array(repeating: 0.0, count: 24)
        var grok = Array(repeating: 0.0, count: 24)
        for hour in hours where (0..<24).contains(hour.hour) {
            for segment in hour.segments {
                let weight = segment.activityWeight
                guard weight > 0 else { continue }
                switch segment.providerID.lowercased() {
                case "opencode-go":
                    openCodeGo[hour.hour] += weight
                case "opencode":
                    openCodeZen[hour.hour] += weight
                default:
                    if OpenCodeLocalStats.grokViaOpenCode(
                        providerID: segment.providerID,
                        modelID: segment.modelID
                    ) {
                        grok[hour.hour] += weight
                    }
                }
            }
        }
        return (openCodeGo, openCodeZen, grok)
    }

    /// Hourly percentage-point consumption of the estimated OpenCode weekly quota.
    /// Direct BYOK providers have no OpenCode quota and therefore contribute zero.
    func overviewProviderQuotaHourWeights(monthlyLimitUSD: Double) -> (
        openCodeGo: [Double],
        openCodeZen: [Double]
    ) {
        var openCodeGo = Array(repeating: 0.0, count: 24)
        var openCodeZen = Array(repeating: 0.0, count: 24)
        let weeklyLimitUSD = monthlyLimitUSD / QuotaNormalization.averageWeeksPerMonth
        guard weeklyLimitUSD > 0 else { return (openCodeGo, openCodeZen) }

        for hour in hours where (0..<24).contains(hour.hour) {
            for segment in hour.segments {
                let quotaDelta = max(0, segment.quotaCostUSD) / weeklyLimitUSD * 100
                guard quotaDelta > 0 else { continue }
                switch segment.providerID.lowercased() {
                case "opencode-go":
                    openCodeGo[hour.hour] += quotaDelta
                case "opencode":
                    openCodeZen[hour.hour] += quotaDelta
                default:
                    break
                }
            }
        }
        return (openCodeGo, openCodeZen)
    }

    /// Hourly token counts split into Go and Zen series.
    func overviewProviderHourTokenCounts() -> (
        openCodeGo: [Int64],
        openCodeZen: [Int64]
    ) {
        var openCodeGo = Array(repeating: Int64(0), count: 24)
        var openCodeZen = Array(repeating: Int64(0), count: 24)
        for hour in hours where (0..<24).contains(hour.hour) {
            for segment in hour.segments {
                switch segment.providerID.lowercased() {
                case "opencode-go":
                    openCodeGo[hour.hour] += segment.totalTokens
                case "opencode":
                    openCodeZen[hour.hour] += segment.totalTokens
                default:
                    break
                }
            }
        }
        return (openCodeGo, openCodeZen)
    }
}

/// Provider and model display names with stealth-alias handling.
enum OpenCodeCatalog {
    static func providerShortName(_ providerID: String) -> String {
        switch providerID.lowercased() {
        case "opencode-go": return "Go"
        case "opencode": return "Zen"
        case "deepseek": return "DeepSeek"
        case "xai": return "xAI"
        case "openrouter": return "OpenRouter"
        case "nvidia": return "NVIDIA"
        case "alibaba": return "Alibaba"
        case "google": return "Google"
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        default: return providerID
        }
    }

    /// Display name for `providerID`/`modelID`, resolving the `Muse Spark` alias.
    static func modelDisplayName(providerID: String, modelID: String) -> String {
        let lower = modelID.lowercased()
        if lower.contains("muse-spark") || lower.contains("muse_spark") || lower.contains("musepark") {
            return "\(providerShortName(providerID)) · Muse Spark"
        }
        return "\(providerShortName(providerID)) · \(modelID)"
    }
}

/// Local or console OpenCode usage with windows, models, and monthly totals.
struct OpenCodeSnapshot: Identifiable, Hashable, Sendable {
    var id: UUID
    var fetchedAt: Date
    var windows: [OpenCodeWindowUsage]
    var models: [OpenCodeModelUsage]
    var isEstimated: Bool
    /// Plan (Go/Zen) tokens in the current billing month.
    var monthlyTokens: Int64
    /// Plan Go recorded $ + Zen token estimates for the billing month.
    var monthlyEstimatedUSD: Double
    var monthlyInputTokens: Int64 = 0
    var monthlyOutputTokens: Int64 = 0

    init(
        id: UUID = UUID(),
        fetchedAt: Date = Date(),
        windows: [OpenCodeWindowUsage],
        models: [OpenCodeModelUsage],
        isEstimated: Bool = true,
        monthlyTokens: Int64 = 0,
        monthlyEstimatedUSD: Double = 0,
        monthlyInputTokens: Int64 = 0,
        monthlyOutputTokens: Int64 = 0
    ) {
        self.id = id
        self.fetchedAt = fetchedAt
        self.windows = windows
        self.models = models
        self.isEstimated = isEstimated
        self.monthlyTokens = monthlyTokens
        self.monthlyEstimatedUSD = monthlyEstimatedUSD
        self.monthlyInputTokens = monthlyInputTokens
        self.monthlyOutputTokens = monthlyOutputTokens
    }

    /// Menu-bar metric: monthly Go usage (same window as the overview ring).
    var primaryUsedPercent: Double { monthlyUsedPercent }

    /// True when the local session DB contributed model/token/spend stats. The
    /// console snapshot alone carries none, so the Stats card is omitted rather
    /// than rendered as `$0.00 / 0 tokens`.
    var hasLocalStats: Bool {
        !models.isEmpty || monthlyTokens > 0 || monthlyEstimatedUSD > 0
    }

    /// Overview ring metric: monthly Go usage window.
    var monthlyUsedPercent: Double {
        windows.first { $0.kind == .monthly }?.usedPercent
            ?? windows.first { $0.kind == .weekly }?.usedPercent
            ?? 0
    }

    static let preview = OpenCodeSnapshot(
        windows: [
            OpenCodeWindowUsage(kind: .rolling5h, usedUSD: 8.6, limitUSD: 12, resetsAt: Date().addingTimeInterval(7200), sessionCount: 14),
            OpenCodeWindowUsage(kind: .weekly, usedUSD: 12.4, limitUSD: 30, resetsAt: Date().addingTimeInterval(86_400 * 3), sessionCount: 41),
            OpenCodeWindowUsage(kind: .monthly, usedUSD: 16.9, limitUSD: 60, resetsAt: Date().addingTimeInterval(86_400 * 17), sessionCount: 120)
        ],
        models: [
            OpenCodeModelUsage(
                providerID: "opencode-go",
                modelID: "minimax-m3",
                sessionCount: 9,
                inputTokens: 14_200_000,
                outputTokens: 1_300_000,
                cacheReadTokens: 512_000_000,
                cacheWriteTokens: 0,
                costUSD: 4.1,
                percentOfWindow: 48
            ),
            OpenCodeModelUsage(
                providerID: "opencode-go",
                modelID: "kimi-k3",
                sessionCount: 3,
                inputTokens: 8_900_000,
                outputTokens: 420_000,
                cacheReadTokens: 301_000_000,
                cacheWriteTokens: 0,
                costUSD: 2.6,
                percentOfWindow: 30
            )
        ],
        monthlyTokens: 48_000_000,
        monthlyEstimatedUSD: 22.4,
        monthlyInputTokens: 35_000_000,
        monthlyOutputTokens: 8_500_000
    )
}

/// Shared Go/Zen accents and deterministic model colors.
enum ModelPalette {
    /// Shared orange accent — OpenCode Go (5-hour limit, models); overview uses orange too.
    static let orange = ProviderAccent.openCode
    /// Shared purple accent — OpenCode Zen, Overview Zen bars, weekly/monthly limits.
    static let purple = SRGB(red: 0.58, green: 0.44, blue: 0.86)

    static let sRGB: [SRGB] = [
        SRGB(red: 0.55, green: 0.78, blue: 1.0),
        SRGB(red: 0.11, green: 0.38, blue: 0.82),
        SRGB(red: 0.22, green: 0.32, blue: 0.48),
        SRGB(red: 0.40, green: 0.55, blue: 0.82),
        SRGB(red: 0.75, green: 0.90, blue: 1.0),
        SRGB(red: 0.90, green: 0.45, blue: 0.20),
        SRGB(red: 0.20, green: 0.60, blue: 0.40),
        SRGB(red: 0.60, green: 0.30, blue: 0.70)
    ]

    static func sRGB(for seed: String) -> SRGB {
        let hash = seed.utf8.reduce(5381) { ($0 &* 33) ^ Int($1) }
        let index = Int(hash.magnitude % UInt(sRGB.count))
        return sRGB[index]
    }

    static func sRGB(forProvider providerID: String, seed: String) -> SRGB {
        switch providerID.lowercased() {
        case "opencode-go": return orange
        case "opencode": return purple
        default: return sRGB(for: seed)
        }
    }
}
