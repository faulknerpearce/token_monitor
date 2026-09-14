import Foundation

enum CursorPoolKind: String, Codable, CaseIterable, Sendable {
    case total
    case auto
    case api

    var label: String {
        switch self {
        case .total: return "Total"
        case .auto: return "Auto"
        case .api: return "API"
        }
    }
}

/// Pace vs even-consumption budget across the billing cycle.
struct CursorPace: Hashable, Sendable {
    /// Even-rate expected used % at `now`.
    var expectedUsedPercent: Double
    /// `expected - actual`. Positive = reserve (ahead), negative = deficit.
    var deltaPercent: Double
    var willLastUntilReset: Bool

    var isReserve: Bool { deltaPercent > 2 }
    var isDeficit: Bool { deltaPercent < -2 }

    var paceLabel: String {
        if isReserve {
            return "\(Int(deltaPercent.rounded()))% in reserve"
        }
        if isDeficit {
            return "\(Int((-deltaPercent).rounded()))% in deficit"
        }
        return "On pace"
    }

    var forecastLabel: String {
        willLastUntilReset ? "Lasts until reset" : "May run out before reset"
    }

    static func compute(
        usedPercent: Double,
        cycleStart: Date?,
        cycleEnd: Date?,
        now: Date = Date()
    ) -> CursorPace? {
        guard let start = cycleStart, let end = cycleEnd, end > start else { return nil }
        let duration = end.timeIntervalSince(start)
        let elapsed = now.timeIntervalSince(start)
        guard duration > 0 else { return nil }
        // Hide pace until a few percent of the cycle has elapsed.
        let fraction = min(1, max(0, elapsed / duration))
        guard fraction >= 0.03 else { return nil }

        let expected = fraction * 100
        let delta = expected - usedPercent
        let projectedEnd = usedPercent / fraction
        return CursorPace(
            expectedUsedPercent: expected,
            deltaPercent: delta,
            willLastUntilReset: projectedEnd <= 100.5
        )
    }
}

struct CursorPoolUsage: Identifiable, Hashable, Sendable {
    var kind: CursorPoolKind
    /// 0…100 used (matches Cursor dashboard percent fields).
    var usedPercent: Double
    var resetsAt: Date?
    var pace: CursorPace?

    var id: CursorPoolKind { kind }

    var remainingPercent: Double {
        Percent.clamp(100 - usedPercent)
    }
}

struct CursorCostStats: Hashable, Sendable {
    /// Sum of Cursor `chargedCents` over the billing cycle (USD).
    var meteredCycleUSD: Double
    /// Token total over the billing cycle.
    var cycleTokens: Int64
    var cycleInputTokens: Int64 = 0
    var cycleOutputTokens: Int64 = 0
    /// Sum of `chargedCents` for today (USD).
    var todayUSD: Double
    /// Sum of `chargedCents` over the last 20 days (USD).
    var last20dUSD: Double
    /// Token total for today.
    var todayTokens: Int64
    /// Token total over the last 20 days.
    var last20dTokens: Int64
}

struct CursorDayHourlyUsage: Hashable, Sendable {
    var dayStart: Date
    /// Raw event activity weights per hour (0…23), retained for diagnostics.
    var hourWeights: [Double]
    /// Percentage-point plan quota consumption per hour (0…23).
    var quotaHourWeights: [Double]
    /// Total input/output/cache tokens per hour (0…23).
    var hourTokenWeights: [Int64] = Array(repeating: 0, count: 24)

    var isEmpty: Bool {
        quotaHourWeights.allSatisfy { $0 <= 0 } && hourWeights.allSatisfy { $0 <= 0 }
    }
}

struct CursorSnapshot: Identifiable, Hashable, Sendable {
    var id: Date { fetchedAt }
    var fetchedAt: Date
    /// Headline Total used % — Overview ring + primary metric.
    var usedPercent: Double
    var pools: [CursorPoolUsage]
    var billingCycleStart: Date?
    var billingCycleEnd: Date?
    var membershipType: String?
    /// Included plan spend in USD (cents ÷ 100).
    var planUsedUSD: Double?
    var planLimitUSD: Double?
    var onDemandEnabled: Bool
    var onDemandUsedUSD: Double?
    var onDemandLimitUSD: Double?
    var costStats: CursorCostStats?
    var accountEmail: String?

    var resetsAt: Date? { billingCycleEnd }

    var displayPlanName: String {
        guard let membershipType, !membershipType.isEmpty else { return "Cursor" }
        let trimmed = membershipType.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("cursor") {
            return trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased()
        }
        return "Cursor \(trimmed.prefix(1).uppercased())\(trimmed.dropFirst().lowercased())"
    }
}
