import Foundation

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

    /// Whether this mode should refresh `provider` (its own tab, or Overview).
    func polls(_ provider: MonitorProvider) -> Bool {
        self == provider || self == .overview
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
        case .grokbot:
            return URL(string: "https://cursor.com/bot")
        }
    }
}
