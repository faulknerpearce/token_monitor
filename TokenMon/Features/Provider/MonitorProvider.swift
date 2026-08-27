import Foundation

enum MonitorProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case overview
    case grok
    case cursor
    case opencode
    case claude
    case chatgpt
    case openrouter

    var id: String { rawValue }

    /// Concrete usage providers in default dropdown / menu-bar order (Overview excluded).
    static var usageProviders: [MonitorProvider] {
        [.grok, .cursor, .opencode, .claude, .chatgpt, .openrouter]
    }

    /// Drops Overview and unknowns, de-duplicates, then appends any usage
    /// providers the saved list does not yet know about so new providers appear
    /// without wiping a user's order.
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

    /// Reorders the visible subsequence in `order` while leaving hidden
    /// providers in their existing slots.
    static func movingVisible(
        order: [MonitorProvider],
        visible: [MonitorProvider],
        from source: IndexSet,
        to destination: Int
    ) -> [MonitorProvider] {
        let normalized = normalizedOrder(order)
        var moved = visible
        moved.move(fromOffsets: source, toOffset: destination)
        var iterator = moved.makeIterator()
        let visibleSet = Set(visible)
        return normalized.map { provider in
            guard visibleSet.contains(provider), let next = iterator.next() else {
                return provider
            }
            return next
        }
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
        }
    }

    /// Short label in the dropdown provider switcher.
    var switcherLabel: String {
        switch self {
        case .overview: return "All"
        case .grok, .cursor, .opencode, .claude, .chatgpt, .openrouter: return displayName
        }
    }

    /// Whether this mode should refresh Grok usage.
    var pollsGrok: Bool {
        self == .grok || self == .overview
    }

    /// Whether this mode should refresh OpenCode usage.
    var pollsOpenCode: Bool {
        self == .opencode || self == .overview
    }

    /// Whether this mode should refresh Cursor usage.
    var pollsCursor: Bool {
        self == .cursor || self == .overview
    }

    /// Whether this mode should refresh Claude usage.
    var pollsClaude: Bool {
        self == .claude || self == .overview
    }

    /// Whether this mode should refresh ChatGPT/Codex usage.
    var pollsChatGPT: Bool {
        self == .chatgpt || self == .overview
    }

    /// Whether this mode should refresh OpenRouter usage.
    var pollsOpenRouter: Bool {
        self == .openrouter || self == .overview
    }

    /// Public dashboard / console URL for “Visit website”.
    var websiteURL: URL? {
        switch self {
        case .overview:
            return nil
        case .grok:
            return URL(string: "https://grok.com/?_s=usage")
        case .opencode:
            return URL(string: "https://opencode.ai")
        case .cursor:
            return URL(string: "https://cursor.com/dashboard/usage")
        case .claude:
            return URL(string: "https://claude.ai/settings/usage")
        case .chatgpt:
            return URL(string: "https://chatgpt.com/codex")
        case .openrouter:
            return URL(string: "https://openrouter.ai/credits")
        }
    }
}
