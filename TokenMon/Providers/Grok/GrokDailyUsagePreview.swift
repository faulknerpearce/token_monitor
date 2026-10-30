import Foundation

extension GrokDailyUsageBuilder {
    /// Preview billing-period week (Thu→Wed) with sample product bars.
    static func preview(now: Date = Date(), calendar: Calendar = .current) -> DailyUsageWeek {
        let cal = calendar
        // Anchor a synthetic reset so the preview is always a Thu→Wed period.
        let resetAt = ISO8601DateFormatter.parseFlexible("2026-07-16T20:25:00Z")
            ?? now.addingTimeInterval(3 * 24 * 3600)
        guard let (weekStart, weekEnd) = billingPeriodWeekBounds(
            resetsAt: resetAt,
            weekOffset: 0,
            calendar: cal,
            now: resetAt.addingTimeInterval(-2 * 24 * 3600)
        ) else {
            return finalize(
                weekStart: now,
                weekEnd: now,
                days: [],
                isEstimated: true,
                resetsAt: resetAt,
                calendar: cal
            )
        }

        let pattern: [(Double, Double, Double)] = [
            (5, 1, 0),   // period start (e.g. Thu)
            (7, 2, 1),   // Fri
            (2, 1, 0),   // Sat
            (0, 0, 0),   // Sun
            (18, 5, 1),  // Mon
            (4, 1, 0),   // Tue
            (3, 0, 0)    // Wed
        ]

        let (weekdayFormatter, dayOfMonthFormatter) = Self.makeDateFormatters(calendar: cal)

        var days: [DailyUsageDay] = []
        for offset in 0..<7 {
            guard let dayStart = cal.date(byAdding: .day, value: offset, to: weekStart) else { continue }
            var segments: [DailyUsageSegment] = []
            let (build, api, chat) = pattern[offset]
            if build > 0 {
                segments.append(
                    DailyUsageSegment(
                        productID: "build",
                        displayName: "Grok Build",
                        percentOfWeekly: build,
                        colorToken: .build
                    )
                )
            }
            if api > 0 {
                segments.append(
                    DailyUsageSegment(
                        productID: "api",
                        displayName: "API",
                        percentOfWeekly: api,
                        colorToken: .api
                    )
                )
            }
            if chat > 0 {
                segments.append(
                    DailyUsageSegment(
                        productID: "chat",
                        displayName: "Chat",
                        percentOfWeekly: chat,
                        colorToken: .chat
                    )
                )
            }
            days.append(
                DailyUsageDay(
                    dayStart: dayStart,
                    weekdaySymbol: String(weekdayFormatter.string(from: dayStart).prefix(3)),
                    dayOfMonth: dayOfMonthFormatter.string(from: dayStart),
                    segments: segments,
                    isToday: false,
                    isAfterReset: false
                )
            )
        }

        return finalize(
            weekStart: weekStart,
            weekEnd: weekEnd,
            days: days,
            isEstimated: false,
            resetsAt: resetAt,
            calendar: cal
        )
    }
}
