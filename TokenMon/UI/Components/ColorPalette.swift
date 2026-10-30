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

    /// SwiftUI color (sRGB).
    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    /// AppKit color (calibrated sRGB).
    var nsColor: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}
