import Foundation

/// Shared ISO-8601 parsing helpers, tolerating optional fractional seconds.
/// Formatters are cached statically.
extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses a date, trying fractional-seconds form first, then plain.
    static func parseFlexible(_ string: String) -> Date? {
        flexible.date(from: string) ?? plain.date(from: string)
    }
}
