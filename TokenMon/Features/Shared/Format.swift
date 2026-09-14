import Foundation

/// Shared value formatters.
enum Format {
    static let usdCurrency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    /// Compact human-readable token count (K / M / B).
    static func tokens(_ count: Int64) -> String {
        let value = Double(count)
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", value / 1_000_000_000)
        }
        if value >= 1_000_000 {
            let millions = value / 1_000_000
            return millions >= 10
                ? String(format: "%.0fM", millions)
                : String(format: "%.1fM", millions)
        }
        if value >= 1_000 {
            return String(format: "%.0fK", value / 1_000)
        }
        return "\(count)"
    }

    /// USD currency string without an approximation prefix.
    static func usd(_ usd: Double) -> String {
        usdCurrency.string(from: NSNumber(value: usd)) ?? "$0"
    }

    /// Twelve-hour clock label for a 0–23 hour, e.g. 0 → "12a", 15 → "3p".
    static func hourLabel(for hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        case 1..<12: return "\(hour)a"
        default: return "\(hour - 12)p"
        }
    }

    /// Cached DateFormatter keyed by date format.
    private static let formatterCacheLock = NSLock()
    private static var formatterCache: [String: DateFormatter] = [:]

    private static func cachedFormatter(dateFormat: String, timeZone: TimeZone?) -> DateFormatter {
        let key = "\(dateFormat)|\(timeZone?.identifier ?? "default")"
        formatterCacheLock.lock()
        defer { formatterCacheLock.unlock() }
        if let formatter = formatterCache[key] {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat
        formatterCache[key] = formatter
        return formatter
    }

    /// Formats a reset date in a fixed locale, with lowercase meridian (am/pm).
    static func resetDate(_ date: Date, dateFormat: String, timeZone: TimeZone? = nil) -> String {
        cachedFormatter(dateFormat: dateFormat, timeZone: timeZone)
            .string(from: date)
            .replacingOccurrences(of: "AM", with: "am")
            .replacingOccurrences(of: "PM", with: "pm")
    }
}
