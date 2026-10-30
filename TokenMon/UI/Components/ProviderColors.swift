import SwiftUI

extension MonitorProvider {
    /// Canonical brand accent, shared by the SwiftUI panels and the AppKit
    /// menu-bar renderer; a neutral grey for the Overview pseudo-provider.
    var accent: SRGB {
        switch self {
        case .overview: return SRGB(red: 0.5, green: 0.5, blue: 0.5)
        case .grok: return SRGB(red: 0.11, green: 0.38, blue: 0.82)
        case .opencode: return SRGB(red: 1.0, green: 0.55, blue: 0.0)
        case .cursor: return SRGB(red: 0.18, green: 0.53, blue: 0.38)
        case .claude: return SRGB(red: 0.85, green: 0.47, blue: 0.34)
        case .chatgpt: return SRGB(red: 0.16, green: 0.52, blue: 0.46)
        case .openrouter: return SRGB(red: 0.45, green: 0.36, blue: 0.90)
        case .grokbot: return SRGB(red: 0.38, green: 0.42, blue: 0.50)
        }
    }

    /// Accent for bars and charts in the panels (slightly translucent).
    var accentColor: Color {
        accent.color.opacity(0.85)
    }
}
