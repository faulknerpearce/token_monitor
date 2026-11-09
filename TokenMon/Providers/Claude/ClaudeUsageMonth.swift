import Foundation

/// A calendar month of the Claude Code ledger, reckoned in the ledger's
/// calendar (UTC days in the app, so the month turns over at midnight UTC).
struct ClaudeUsageMonth: Hashable, Sendable {
    /// First instant of the month in `calendar`.
    let start: Date
    /// The calendar the month and its day keys are reckoned in.
    let calendar: Calendar

    /// The month containing `date` in `calendar`.
    init(containing date: Date, calendar: Calendar) {
        self.start = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        self.calendar = calendar
    }

    /// The month before this one.
    var previous: Self {
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        return Self(containing: dayBefore, calendar: calendar)
    }

    /// The `yyyy-MM` prefix every ``DayKey`` of this month starts with.
    var keyPrefix: String {
        String(DayKey.key(for: start, calendar: calendar).prefix(7))
    }

    /// The ``DayKey`` of the month's first day.
    var firstDayKey: String {
        DayKey.key(for: start, calendar: calendar)
    }

    /// Whether the day `key` names falls in this month.
    func contains(dayKey key: String) -> Bool {
        key.hasPrefix(keyPrefix)
    }

    /// The month's English name, e.g. "November".
    var name: String {
        Format.date(start, dateFormat: "MMMM", timeZone: calendar.timeZone)
    }

    /// A day of this calendar as a short date, e.g. "Oct 9".
    func shortDate(_ date: Date) -> String {
        Format.date(date, dateFormat: "MMM d", timeZone: calendar.timeZone)
    }

    /// The days of this month from `since` to its end, e.g. "Oct 9–31", or
    /// just "Oct 31" when `since` is the last day.
    func span(from since: Date) -> String {
        let first = shortDate(since)
        guard let lastDay = calendar.range(of: .day, in: .month, for: start)?.count,
              calendar.component(.day, from: since) < lastDay
        else { return first }
        return "\(first)–\(lastDay)"
    }
}

/// How much of a month the ledger's saved days cover.
///
/// The ledger only knows the days it has saved. Claude Code deletes old
/// transcripts (after 30 days by default), so usage from before the first scan
/// that is older than that is gone; the first saved day is therefore the
/// earliest day the record can vouch for. A month that starts on or after that
/// day is covered whole; a month the first saved day falls inside is covered
/// only from that day.
enum ClaudeMonthCoverage: Hashable, Sendable {
    /// The ledger has days from the month's first day or earlier.
    case complete
    /// The ledger's first saved day, `since`, falls inside the month, so days
    /// before it may be missing.
    case partial(since: Date)
    /// The ledger has no day in or before the month. `recordedSince` is its
    /// first saved day, nil when nothing is saved.
    case none(recordedSince: Date?)

    /// The coverage of `month` by a ledger whose earliest saved day is
    /// `earliestDayKey` (nil when the ledger is empty).
    static func of(_ month: ClaudeUsageMonth, earliestDayKey: String?) -> Self {
        guard let earliestDayKey else { return .none(recordedSince: nil) }
        // `DayKey`s sort chronologically as strings.
        if earliestDayKey <= month.firstDayKey { return .complete }
        let since = DayKey.startOfDay(for: earliestDayKey, calendar: month.calendar)
        if month.contains(dayKey: earliestDayKey), let since {
            return .partial(since: since)
        }
        return .none(recordedSince: since)
    }
}
