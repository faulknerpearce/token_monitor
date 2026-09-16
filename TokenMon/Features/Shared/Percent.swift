import Foundation

/// Percentage clamping used by renderers and model math.
enum Percent {
    /// Growth smaller than this is rounding noise and is not recorded.
    static let noiseFloor: Double = 0.05

    /// A drop at least this large is a quota-window reset; anything smaller is
    /// downward noise. Aligns with the mid-period rebase floor in
    /// `DailyUsageBuilder` (`dayCumulative + 5 < previous`).
    static let resetDropFloor: Double = 5

    static func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}
