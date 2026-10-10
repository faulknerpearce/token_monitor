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
    ///
    /// Each unit rounds half away from zero, and a value that rounds up to 1000
    /// of one unit is shown in the next (999,500 → "1.0M", not "1000K").
    static func tokens(_ count: Int64) -> String {
        let value = Double(count)
        guard value >= 1_000 else { return "\(count)" }
        let thousands = rounded(value / 1_000, decimals: 0)
        if thousands < 1_000 {
            return compact(thousands, decimals: 0, suffix: "K")
        }
        let millions = value / 1_000_000
        let millionDecimals = rounded(millions, decimals: 1) < 10 ? 1 : 0
        let shownMillions = rounded(millions, decimals: millionDecimals)
        if shownMillions < 1_000 {
            return compact(shownMillions, decimals: millionDecimals, suffix: "M")
        }
        return compact(rounded(value / 1_000_000_000, decimals: 1), decimals: 1, suffix: "B")
    }

    private static func rounded(_ value: Double, decimals: Int) -> Double {
        let scale = decimals == 0 ? 1.0 : 10.0
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    private static func compact(_ value: Double, decimals: Int, suffix: String) -> String {
        String(format: "%.\(decimals)f\(suffix)", value)
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

    /// Cached DateFormatter keyed by date format and time-zone identifier. A
    /// `nil` time zone resolves to the current system zone at each call, and the
    /// cache is emptied when the system time zone changes.
    private static let formatterCacheLock = NSLock()
    // swiftlint:disable:next modifier_order
    private nonisolated(unsafe) static var formatterCache: [String: DateFormatter] = [:]
    private static let timeZoneObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: .NSSystemTimeZoneDidChange,
        object: nil,
        queue: nil
    ) { _ in
        NSTimeZone.resetSystemTimeZone()
        Format.clearFormatterCache()
    }

    private static func cachedFormatter(dateFormat: String, timeZone: TimeZone?) -> DateFormatter {
        _ = timeZoneObserver
        let zone = timeZone ?? TimeZone.current
        let key = "\(dateFormat)|\(zone.identifier)"
        formatterCacheLock.lock()
        defer { formatterCacheLock.unlock() }
        if let formatter = formatterCache[key] {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = dateFormat
        formatterCache[key] = formatter
        return formatter
    }

    /// Number of cached date formatters.
    static var cachedFormatterCount: Int {
        formatterCacheLock.lock()
        defer { formatterCacheLock.unlock() }
        return formatterCache.count
    }

    private static func clearFormatterCache() {
        formatterCacheLock.lock()
        formatterCache.removeAll()
        formatterCacheLock.unlock()
    }

    /// Formats a reset date in a fixed locale, with lowercase meridian (am/pm).
    static func resetDate(_ date: Date, dateFormat: String, timeZone: TimeZone? = nil) -> String {
        cachedFormatter(dateFormat: dateFormat, timeZone: timeZone)
            .string(from: date)
            .replacingOccurrences(of: "AM", with: "am")
            .replacingOccurrences(of: "PM", with: "pm")
    }

    /// `Resets …` caption for a reset date.
    static func resetCaption(
        _ date: Date,
        dateFormat: String = "EEE dd MMMM h:mma",
        timeZone: TimeZone? = nil
    ) -> String {
        "Resets \(resetDate(date, dateFormat: dateFormat, timeZone: timeZone))"
    }
}
