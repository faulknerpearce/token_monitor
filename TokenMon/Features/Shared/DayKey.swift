import Foundation

/// A calendar day as a `yyyy-MM-dd` string, independent of time zone.
///
/// Stores persist days in this form so a recorded day keeps meaning the same
/// calendar date after the system time zone changes, which an absolute
/// `startOfDay` instant does not. Keys sort chronologically as strings.
enum DayKey {
    /// The key for the calendar day containing `date` in `calendar`.
    static func key(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return format(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    /// Start of the day `key` names, in `calendar`; nil for a malformed key.
    static func startOfDay(for key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) }
    }

    /// The key `days` days after `key` (negative for earlier days).
    static func adding(days: Int, to key: String, calendar: Calendar) -> String? {
        guard let start = startOfDay(for: key, calendar: calendar),
              let shifted = calendar.date(byAdding: .day, value: days, to: start) else { return nil }
        return self.key(for: shifted, calendar: calendar)
    }

    /// The day a stored `startOfDay` instant was recorded for.
    ///
    /// Payloads in the older store format key days by the absolute
    /// local-midnight instant, without the zone it was taken in. A local
    /// midnight in a zone at UTC offset `o` falls at `-o` past UTC midnight, so the instant's UTC time of day pins
    /// the offset to one of two values a day apart; the one inside the real
    /// range of offsets (−12 h … +14 h) is used, and `preferredOffset` (the
    /// current zone's) breaks the tie for ±12 h. The date at that offset is the
    /// recorded day, whatever zone the Mac is in now.
    static func key(forStoredStartOfDay instant: Date, preferredOffset: Int) -> String {
        let seconds = Int(instant.timeIntervalSince1970.rounded())
        let secondOfDay = ((seconds % 86_400) + 86_400) % 86_400
        let candidates = [-secondOfDay, 86_400 - secondOfDay].filter { (-43_200...50_400).contains($0) }
        let offset = candidates.min { abs($0 - preferredOffset) < abs($1 - preferredOffset) } ?? 0
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? utc.timeZone
        return key(for: instant.addingTimeInterval(TimeInterval(offset)), calendar: utc)
    }

    private static func format(year: Int, month: Int, day: Int) -> String {
        let yearText = String(year)
        let paddedYear = String(repeating: "0", count: max(0, 4 - yearText.count)) + yearText
        return "\(paddedYear)-\(month < 10 ? "0" : "")\(month)-\(day < 10 ? "0" : "")\(day)"
    }
}
