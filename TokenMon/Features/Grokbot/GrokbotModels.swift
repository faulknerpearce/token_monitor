import Foundation

/// Which subscription is paying for the Bot allowance.
///
/// The usage payload reports the SuperGrok plan name when the allowance comes
/// from that side; otherwise it is Cursor-funded. One endpoint serves both
/// channels.
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
/// `resetsAt` is `nil` when the payload arrived without `next_reset_timestamp_utc`;
/// the panel then hides the weekly section.
struct GrokbotSnapshot: Codable, Hashable, Sendable {
    var fetchedAt: Date
    var usedPercent: Double
    var periodStart: Date?
    var resetsAt: Date?
    var entitlement: GrokbotEntitlement
    var accountEmail: String?
    /// True when the plan carries an included Bot allowance. False for
    /// `included_limit_zero` or `has_non_zero_included_limit == false`, where usage
    /// is pure on-demand spend with no pool to measure a percentage against.
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

    /// Length of the current allowance period in calendar days. The Bot pool is
    /// weekly, so the provider's `current_period_start` → `next_reset_timestamp_utc`
    /// span is only trusted when it is itself roughly a week (6...8 calendar days,
    /// which absorbs a window that is a few hours short or long). Any other span —
    /// a same-day collapse on reset day, a truncated 5-day span, a fortnight —
    /// is unreliable and falls back to 7, as does a payload missing either end.
    func daysInPeriod(calendar: Calendar = .current) -> Int {
        guard let days = reportedSpanDays(calendar: calendar), (6 ... 8).contains(days) else { return 7 }
        return days
    }

    /// Calendar-day span exactly as the payload reports it
    /// (`current_period_start` → `next_reset_timestamp_utc`), or nil when either
    /// end is missing or the pair is out of order. This is the raw span: the pool
    /// label (`usagePool`) follows what the provider says, while bars and pace use
    /// the sanitized `daysInPeriod`.
    func reportedSpanDays(calendar: Calendar = .current) -> Int? {
        guard let periodStart, let resetsAt, resetsAt > periodStart else { return nil }
        return DailyBudget.daysInBillingCycle(start: periodStart, end: resetsAt, calendar: calendar)
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
