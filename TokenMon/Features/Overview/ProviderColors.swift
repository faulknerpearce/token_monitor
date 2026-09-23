import SwiftUI

/// Shared provider accent colors, used by panels, the menu bar, and the overview.
///
/// This was formerly `ConcentricUsageRingView`, whose ring `body` and stat rows
/// were never instantiated; only these color statics were referenced.
enum ProviderColors {
    static let grokColor = ProviderAccent.grok.color.opacity(0.85)
    static let openCodeColor = ProviderAccent.openCode.color.opacity(0.78)
    /// Canonical Cursor sRGB, shared with other renderers (e.g. the menu bar icon).
    static let cursorSRGB = ProviderAccent.cursor
    static let cursorColor = cursorSRGB.color.opacity(0.85)
    static let claudeSRGB = ProviderAccent.claude
    static let claudeColor = claudeSRGB.color.opacity(0.85)
    static let chatgptColor = ProviderAccent.chatGPT.color.opacity(0.85)
    static let openRouterColor = ProviderAccent.openRouter.color.opacity(0.85)
    /// Grok Bot brand graphite; stays legible as a bar fill without colliding with
    /// Grok navy or Cursor green.
    static let grokbotSRGB = ProviderAccent.grokbot
    static let grokbotColor = grokbotSRGB.color.opacity(0.85)
}
