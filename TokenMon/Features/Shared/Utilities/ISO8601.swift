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

    /// Fractional-seconds and plain forms as format styles: value types, safe
    /// across threads, and about 100× faster to parse than the formatters.
    private static let flexibleStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()

    /// Parses a date, trying fractional-seconds form first, then plain.
    ///
    /// The format styles parse first; a string they reject is retried with the
    /// formatters, so every string the formatters accept still parses.
    /// Fractional seconds keep their full precision.
    static func parseFlexible(_ string: String) -> Date? {
        if let date = try? flexibleStyle.parse(string) { return date }
        if let date = try? plainStyle.parse(string) { return date }
        return flexible.date(from: string) ?? plain.date(from: string)
    }
}
