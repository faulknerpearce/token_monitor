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
