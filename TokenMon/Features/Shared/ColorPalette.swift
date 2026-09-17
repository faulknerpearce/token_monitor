import AppKit
import SwiftUI

/// Canonical sRGB color components shared by the SwiftUI and AppKit renderers.
///
/// Providers and semantic color tokens expose their colors as an `SRGB` value,
/// then let callers convert to the framework color they need, so a single set
/// of component values stays consistent between `Color` and `NSColor` surfaces.
struct SRGB {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    /// SwiftUI color.
    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    /// AppKit color (calibrated sRGB).
    var nsColor: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Canonical brand accent per provider.
///
/// Single source of truth for every surface (SwiftUI panels/rings and the AppKit
/// menu-bar renderer), so a recolor is one edit and the renderers cannot drift.
enum ProviderAccent {
    static let grok = SRGB(red: 0.11, green: 0.38, blue: 0.82)
    static let openCode = SRGB(red: 1.0, green: 0.55, blue: 0.0)
    static let cursor = SRGB(red: 0.18, green: 0.53, blue: 0.38)
    static let claude = SRGB(red: 0.85, green: 0.47, blue: 0.34)
    static let chatGPT = SRGB(red: 0.16, green: 0.52, blue: 0.46)
    static let openRouter = SRGB(red: 0.45, green: 0.36, blue: 0.90)
    static let grokbot = SRGB(red: 0.38, green: 0.42, blue: 0.50)
}
