import Foundation

/// How one value (API-rate spend or tokens) moved from last month to this
/// month, and its one-line description ("↑ 18% · +$212.40 vs October").
enum MonthlyUsageChange: Hashable, Sendable {
    /// No usage last month, so there is nothing to compare against.
    case new
    /// The two months differ by less than the unit's ``Unit/resolution``.
    case unchanged
    /// Up by `amount`; `percent` is nil when last month's value was too small
    /// to divide by (it rounds to zero in the unit).
    case increase(amount: Double, percent: Double?)
    /// Down by `amount` (a positive number); `percent` as for ``increase(amount:percent:)``.
    case decrease(amount: Double, percent: Double?)

    /// What the compared value measures.
    enum Unit: String, Codable, CaseIterable, Hashable, Sendable {
        /// API-rate value in US dollars.
        case usd
        /// Token counts.
        case tokens

        /// The smallest difference shown in this unit: half a cent, or half
        /// a token; anything smaller rounds away and counts as no change.
        var resolution: Double {
            switch self {
            case .usd: return 0.005
            case .tokens: return 0.5
            }
        }

        /// `amount` (non-negative) as shown in a change, e.g. "$212.40" or
        /// "1.2M tokens".
        func format(_ amount: Double) -> String {
            switch self {
            case .usd: return Format.usd(amount)
            case .tokens: return Format.tokens(Int64(amount.rounded())) + " tokens"
            }
        }
    }

    /// The change from `previous` to `current`.
    ///
    /// - Parameters:
    ///   - previous: Last month's value; nil when there was no usage at all
    ///     last month (a model first used this month).
    ///   - current: This month's value.
    ///   - unit: What the values measure.
    static func between(previous: Double?, current: Double, unit: Unit) -> Self {
        guard let previous else { return .new }
        let difference = current - previous
        guard abs(difference) >= unit.resolution else { return .unchanged }
        let percent = previous >= unit.resolution ? difference / previous * 100 : nil
        return difference > 0
            ? .increase(amount: difference, percent: percent)
            : .decrease(amount: -difference, percent: percent.map(abs))
    }

    /// One line describing the change against `previousMonth` (its name,
    /// e.g. "October").
    ///
    /// "↑ 18% · +$212.40 vs October", "↓ 12% · −$80.00 vs October",
    /// "↑ $3.91 vs October" when last month rounds to zero, "Same as October",
    /// or "New this month".
    func summary(versus previousMonth: String, unit: Unit) -> String {
        switch self {
        case .new:
            return "New this month"
        case .unchanged:
            return "Same as \(previousMonth)"
        case let .increase(amount, percent):
            return Self.line(arrow: "↑", sign: "+", amount: amount, percent: percent, unit: unit, versus: previousMonth)
        case let .decrease(amount, percent):
            return Self.line(arrow: "↓", sign: "\u{2212}", amount: amount, percent: percent, unit: unit, versus: previousMonth)
        }
    }

    private static func line(
        arrow: String,
        sign: String,
        amount: Double,
        percent: Double?,
        unit: Unit,
        versus previousMonth: String
    ) -> String {
        guard let percent else {
            return "\(arrow) \(unit.format(amount)) vs \(previousMonth)"
        }
        return "\(arrow) \(percentText(percent)) · \(sign)\(unit.format(amount)) vs \(previousMonth)"
    }

    /// ``summary(versus:unit:)`` in words for VoiceOver, without arrows or
    /// signs: "Up 18%, $212.40 more than October", "$3.91 more than October",
    /// "Down 12%, $80.00 less than October", "Same as October", or
    /// "New this month".
    func spokenSummary(versus previousMonth: String, unit: Unit) -> String {
        switch self {
        case .new, .unchanged:
            return summary(versus: previousMonth, unit: unit)
        case let .increase(amount, percent):
            let difference = "\(unit.format(amount)) more than \(previousMonth)"
            return percent.map { "Up \(Self.percentText($0)), \(difference)" } ?? difference
        case let .decrease(amount, percent):
            let difference = "\(unit.format(amount)) less than \(previousMonth)"
            return percent.map { "Down \(Self.percentText($0)), \(difference)" } ?? difference
        }
    }

    /// A non-negative percentage rounded to a whole number, without
    /// overstating the extremes: "<1%" for a change that rounds to 0, and
    /// ">99%" for one just short of 100 (a drop to nearly, but not exactly,
    /// nothing).
    static func percentText(_ percent: Double) -> String {
        let magnitude = abs(percent)
        let rounded = magnitude.rounded(.toNearestOrAwayFromZero)
        if rounded == 0 { return "<1%" }
        if rounded == 100, magnitude < 100 { return ">99%" }
        return "\(Int(rounded))%"
    }
}
