import Foundation

/// Cadence of the quota pool a provider's main usage card measures.
///
/// Rendered as the card's section header, e.g. `Usage Pool Weekly`. A provider
/// that exposes a single cadence keeps its name; one that exposes two or more
/// (a 5-hour session *and* a weekly pool) collapses to `mixed`.
enum UsagePool: String, Hashable, Sendable {
    case hourly
    case weekly
    case monthly
    case mixed

    var displayName: String {
        switch self {
        case .hourly: return "Hourly"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .mixed: return "Mixed"
        }
    }

    /// Section-header text for the provider's main usage card.
    var sectionTitle: String { "Usage Pool \(displayName)" }

    /// Collapses the cadences a provider exposes into one label: a single
    /// cadence keeps its name, two or more (or none) become `mixed`.
    static func combining(_ pools: [UsagePool]) -> UsagePool {
        let unique = Set(pools)
        return unique.count == 1 ? unique.first! : .mixed
    }
}

extension WeeklyUsageSnapshot {
    /// SuperGrok reports one rolling weekly pool.
    var usagePool: UsagePool { .weekly }
}

extension GrokbotSnapshot {
    /// The period length comes from the payload's own start → reset span, so a
    /// non-weekly plan still labels correctly.
    var usagePool: UsagePool {
        let days = daysInPeriod()
        if days >= 25 { return .monthly }
        if days <= 10 { return .weekly }
        return .mixed
    }
}

extension ClaudeSnapshot {
    /// Five-hour session + weekly pool.
    var usagePool: UsagePool {
        .combining([
            fiveHour != nil ? .hourly : nil,
            sevenDay != nil ? .weekly : nil
        ].compactMap { $0 })
    }
}

extension ChatGPTSnapshot {
    /// Five-hour primary + weekly secondary pool.
    var usagePool: UsagePool {
        .combining([
            primary != nil ? .hourly : nil,
            secondary != nil ? .weekly : nil
        ].compactMap { $0 })
    }
}

extension CursorSnapshot {
    /// Monthly billing cycle.
    var usagePool: UsagePool { .monthly }
}
