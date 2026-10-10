import Foundation

/// Usage providers plus the `overview` aggregate pseudo-provider.
enum MonitorProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case overview
    case grok
    case cursor
    case opencode
    case claude
    case chatgpt
    case openrouter
    case grokbot

    var id: String { rawValue }

    /// Concrete usage providers in default dropdown / menu-bar order (Overview excluded).
    static var usageProviders: [MonitorProvider] {
        [.grok, .cursor, .opencode, .claude, .chatgpt, .openrouter, .grokbot]
    }

    /// Drops Overview and unknowns, de-duplicates, then appends any usage
    /// providers missing from the saved list, so new providers appear while
    /// the user's order is kept.
    static func normalizedOrder(_ raw: [MonitorProvider]) -> [MonitorProvider] {
        var seen = Set<MonitorProvider>()
        var result: [MonitorProvider] = []
        result.reserveCapacity(usageProviders.count)
        for provider in raw {
            guard provider != .overview, !seen.contains(provider),
                  usageProviders.contains(provider)
            else { continue }
            seen.insert(provider)
            result.append(provider)
        }
        for provider in usageProviders where !seen.contains(provider) {
            result.append(provider)
        }
        return result
    }

    var displayName: String {
        switch self {
        case .overview: return "Overview"
        case .grok: return "Grok"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .openrouter: return "OpenRouter"
        case .grokbot: return "Grokbot"
        }
    }

    /// Short label in the dropdown provider switcher.
    var switcherLabel: String {
        self == .overview ? "All" : displayName
    }

    /// Whether this mode refreshes `provider` (its own tab, or Overview).
    func polls(_ provider: MonitorProvider) -> Bool {
        self == provider || self == .overview
    }
}
