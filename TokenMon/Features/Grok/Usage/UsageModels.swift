import Foundation

/// Semantic color tokens for product segments in the usage bar.
enum ProductColor: String, Codable, CaseIterable, Sendable {
    case build
    case api
    case chat
    case imagine
    case voice
    case other

    static func from(productID: String) -> ProductColor {
        switch productID.lowercased() {
        case "build", "grok_build", "grok-build", "grok build":
            return .build
        case "api":
            return .api
        case "chat", "grok", "text":
            return .chat
        case "imagine", "image", "video", "media":
            return .imagine
        case "voice":
            return .voice
        default:
            return .other
        }
    }

    /// Canonical sRGB components shared by SwiftUI and AppKit renderers.
    var sRGB: SRGB {
        switch self {
        case .chat: return ProviderAccent.grok // navy — Chat
        case .build: return SRGB(red: 0.55, green: 0.78, blue: 1.0) // sky blue — Grok Build
        case .voice: return SRGB(red: 0.40, green: 0.55, blue: 0.82) // mid blue — Voice
        case .api: return SRGB(red: 0.22, green: 0.32, blue: 0.48) // dark navy — API
        case .imagine: return SRGB(red: 0.75, green: 0.90, blue: 1.0) // pale blue — Imagine
        case .other: return SRGB(red: 0.45, green: 0.45, blue: 0.45)
        }
    }
}

/// Canonical product IDs, labels, and stable sort order for UI surfaces.
enum ProductCatalog {
    /// Preference toggle order.
    static let knownIDs = ["build", "api", "chat", "imagine", "voice", "other"]
    /// Visual priority for bars / chips (matches grok.com: Chat, Build, Imagine, …).
    static let displayOrder = ["chat", "build", "imagine", "voice", "api", "other"]

    static func displayName(for id: String) -> String {
        switch id.lowercased() {
        case "build": return "Grok Build"
        case "api": return "API"
        case "chat": return "Chat"
        case "imagine": return "Imagine"
        case "voice": return "Voice"
        case "other": return "Other"
        default: return id.capitalized
        }
    }

    static func shortName(for id: String) -> String {
        switch id.lowercased() {
        case "build": return "Build"
        case "api": return "API"
        case "chat": return "Chat"
        case "imagine": return "Imagine"
        case "voice": return "Voice"
        case "other": return "Other"
        default: return displayName(for: id)
        }
    }

    static func sortForDisplay(_ products: [ProductUsage]) -> [ProductUsage] {
        products.sorted { lhs, rhs in
            let lhsIndex = displayOrder.firstIndex(of: lhs.id.lowercased()) ?? 99
            let rhsIndex = displayOrder.firstIndex(of: rhs.id.lowercased()) ?? 99
            return lhsIndex < rhsIndex
        }
    }

    /// Products for a panel's bar and category rows: the snapshot's own products
    /// in canonical display order, limited to the user's visible set, keeping any
    /// non-zero contribution (the menu bar applies a 0.05 floor instead). A
    /// breakdown-less snapshot carries a synthesized `"other"` slice, which this
    /// returns so the bar reflects the headline used% instead of painting an
    /// empty track.
    static func panelProducts(_ products: [ProductUsage], visible: Set<String>) -> [ProductUsage] {
        filtered(products, visible: visible, threshold: 0)
    }

    /// Products that are both user-visible and contribute at least `threshold` to
    /// the pool, in canonical display order. Used by the menu bar renderer and panels.
    static func filtered(
        _ products: [ProductUsage],
        visible: Set<String>,
        threshold: Double
    ) -> [ProductUsage] {
        let byID = Dictionary(
            products.map { ($0.id.lowercased(), $0) },
            uniquingKeysWith: { _, last in last }
        )
        return displayOrder.compactMap { id in
            guard visible.contains(id),
                  let product = byID[id],
                  product.percentOfPool > threshold
            else { return nil }
            return product
        }
    }
}

/// A single product's contribution to the weekly SuperGrok usage pool.
struct ProductUsage: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    var percentOfPool: Double
    var colorToken: ProductColor

    init(id: String, displayName: String, percentOfPool: Double, colorToken: ProductColor? = nil) {
        self.id = id
        self.displayName = displayName
        self.percentOfPool = max(0, min(100, percentOfPool))
        self.colorToken = colorToken ?? ProductColor.from(productID: id)
    }
}

// MARK: - Daily use (Settings → Usage style)

/// One product slice of a single day's contribution to the weekly pool.
struct DailyUsageSegment: Identifiable, Hashable, Sendable {
    var id: String { productID }
    var productID: String
    var displayName: String
    var percentOfWeekly: Double
    var colorToken: ProductColor
}

/// One calendar day in the daily-use chart.
struct DailyUsageDay: Identifiable, Hashable, Sendable {
    var id: Date { dayStart }
    var dayStart: Date
    var weekdaySymbol: String
    /// Day-of-month for axis labels (e.g. "16").
    var dayOfMonth: String
    var segments: [DailyUsageSegment]
    var isToday: Bool
    /// True when a billing-period rollover or mid-period rebase started on this day.
    var isAfterReset: Bool
    /// Exact reset time when this is the reset day.
    var resetAt: Date?

    var totalPercent: Double {
        segments.reduce(0) { $0 + $1.percentOfWeekly }
    }
}

/// Legend entry for the daily use chart.
struct DailyUsageLegendItem: Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    var colorToken: ProductColor
}

/// Server-provided daily usage row (when a daily API is discovered).
struct DailyUsageSnapshot: Identifiable, Hashable, Codable, Sendable {
    var dayStart: Date
    var percentOfWeekly: Double
    var products: [ProductUsage]

    var id: Date { dayStart }
}

/// Billing-period window for the daily use chart (e.g. Thu→Wed when the pool resets Thursday).
struct DailyUsageWeek: Hashable, Sendable {
    var weekStart: Date
    var weekEnd: Date
    var days: [DailyUsageDay]
    /// Products that appear in any day (for legend).
    var legendProducts: [DailyUsageLegendItem]
    /// True when at least one day has a real usage delta (not empty fallback).
    var hasDailyData: Bool
    /// True when fewer than two in-week samples exist (daily bars not yet day-over-day).
    var isEstimated: Bool

    /// Chronological days for the chart (billing period start → +6 days).
    var displayDays: [DailyUsageDay] {
        days
    }

    var rangeLabel: String {
        let format = Date.FormatStyle().month(.abbreviated).day()
        return "\(weekStart.formatted(format)) – \(weekEnd.formatted(format))"
    }
}

/// Snapshot of the weekly SuperGrok usage pool at a point in time.
struct WeeklyUsageSnapshot: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var fetchedAt: Date
    var usedPercent: Double
    var remainingPercent: Double
    var resetsAt: Date?
    var products: [ProductUsage]
    var extraCreditsBalance: Decimal?
    var accountEmail: String?
    /// Per-day series from server when available (not required for Codable round-trip).
    var dailySeries: [DailyUsageSnapshot]

    init(
        id: UUID = UUID(),
        fetchedAt: Date = Date(),
        usedPercent: Double,
        remainingPercent: Double? = nil,
        resetsAt: Date? = nil,
        products: [ProductUsage] = [],
        extraCreditsBalance: Decimal? = nil,
        accountEmail: String? = nil,
        dailySeries: [DailyUsageSnapshot] = []
    ) {
        self.id = id
        self.fetchedAt = fetchedAt
        let clampedUsed = max(0, min(100, usedPercent))
        self.usedPercent = clampedUsed
        self.remainingPercent = max(
            0,
            min(100, remainingPercent ?? (100 - clampedUsed))
        )
        self.resetsAt = resetsAt
        self.products = products
        self.extraCreditsBalance = extraCreditsBalance
        self.accountEmail = accountEmail
        self.dailySeries = dailySeries
    }

    /// Products with non-zero contribution, preserving API order.
    var visibleProducts: [ProductUsage] {
        products.filter { $0.percentOfPool > 0.05 }
    }

    static let preview = WeeklyUsageSnapshot(
        usedPercent: 35,
        remainingPercent: 65,
        resetsAt: Calendar.current.date(byAdding: .day, value: 5, to: Date()),
        products: [
            ProductUsage(id: "build", displayName: "Grok Build", percentOfPool: 25),
            ProductUsage(id: "api", displayName: "API", percentOfPool: 9),
            ProductUsage(id: "chat", displayName: "Chat", percentOfPool: 1)
        ],
        extraCreditsBalance: nil,
        accountEmail: "user@example.com"
    )
}
