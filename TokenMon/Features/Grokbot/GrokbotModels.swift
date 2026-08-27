import Foundation

/// Which subscription is paying for the Bot allowance.
///
/// Grok Bot ships as a Cursor-backed app (`com.anysphere.sand`) but is sold
/// through both channels, so the same account can be entitled via Cursor or via
/// a SuperGrok plan. The usage payload reports the SuperGrok plan name when the
/// allowance comes from that side, which is the only signal that distinguishes
/// the two — there is no separate endpoint per channel.
enum GrokbotEntitlement: Codable, Hashable, Sendable {
    case cursor
    case superGrok(planLabel: String)

    var captionText: String {
        switch self {
        case .cursor: return "via Cursor"
        case let .superGrok(planLabel):
            return planLabel.isEmpty ? "via SuperGrok" : "via \(planLabel)"
        }
    }
}

/// Snapshot of the weekly Grok Bot allowance at a point in time.
///
/// `resetsAt` is `nil` when the payload arrived without `next_reset_timestamp_utc`.
/// The panel withholds the weekly section in that case rather than substituting a
/// calendar-derived window — see the project rule in `Docs/ARCHITECTURE.md`.
struct GrokbotSnapshot: Codable, Hashable, Sendable {
    var fetchedAt: Date
    var usedPercent: Double
    var periodStart: Date?
    var resetsAt: Date?
    var entitlement: GrokbotEntitlement
    var accountEmail: String?
    /// False when the plan carries no included Bot allowance (`included_limit_zero`,
    /// or `has_non_zero_included_limit == false`) — usage is then pure on-demand
    /// spend and a percent-of-pool bar would be meaningless.
    var hasIncludedAllowance: Bool

    init(
        fetchedAt: Date,
        usedPercent: Double,
        periodStart: Date? = nil,
        resetsAt: Date? = nil,
        entitlement: GrokbotEntitlement = .cursor,
        accountEmail: String? = nil,
        hasIncludedAllowance: Bool = true
    ) {
        self.fetchedAt = fetchedAt
        self.usedPercent = Percent.clamp(usedPercent)
        self.periodStart = periodStart
        self.resetsAt = resetsAt
        self.entitlement = entitlement
        self.accountEmail = accountEmail
        self.hasIncludedAllowance = hasIncludedAllowance
    }

    var remainingPercent: Double {
        Percent.clamp(100 - usedPercent)
    }

    /// Length of the current allowance period, derived from the provider's own
    /// `current_period_start` → `next_reset_timestamp_utc` pair. Uses calendar
    /// days (start-of-day) so a 7×24h window that is a few hours short still
    /// counts as 7 bars. Falls back to 7 only when the payload gave a reset
    /// but no period start.
    func daysInPeriod(calendar: Calendar = .current) -> Int {
        guard let periodStart, let resetsAt, resetsAt > periodStart else { return 7 }
        let days = DailyBudget.daysInBillingCycle(start: periodStart, end: resetsAt, calendar: calendar)
        return min(31, max(1, days))
    }

    static let preview = GrokbotSnapshot(
        fetchedAt: Date(),
        usedPercent: 42,
        periodStart: Calendar.current.date(byAdding: .day, value: -3, to: Date()),
        resetsAt: Calendar.current.date(byAdding: .day, value: 4, to: Date()),
        entitlement: .cursor,
        accountEmail: "user@example.com"
    )
}

enum GrokbotUsageError: LocalizedError, ProviderUsageError, Equatable {
    case notSignedIn
    case unauthorized
    case noBotAccess(String)
    case badResponse(String)
    case network(String)

    var usageError: UsageError {
        switch self {
        case .notSignedIn: return .notSignedIn
        case .unauthorized: return .unauthorized
        case let .network(message): return .network(message)
        case let .noBotAccess(message): return .badResponse(message)
        case let .badResponse(message): return .badResponse(message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to Cursor to load your Grokbot allowance."
        case .unauthorized:
            return "Cursor session expired. Sign in again."
        case let .noBotAccess(message):
            return message
        case let .badResponse(message):
            return "Grokbot response error: \(message)"
        case let .network(message):
            return "Grokbot network error: \(message)"
        }
    }
}
