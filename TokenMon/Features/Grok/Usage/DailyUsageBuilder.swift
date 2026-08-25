import Foundation

/// Builds a Settings → Usage style “Daily use” series on the **billing period** axis.
///
/// The SuperGrok pool is a rolling week that ends at `resetsAt` (often mid-day Thursday).
/// The chart shows **7 full calendar days starting at the period start** (e.g. Thu→Wed).
/// When the period rolls over, the whole window advances — bars are never split across
/// two billing periods.
///
/// Priority:
/// 1. Server daily series (when discovered / passed in)
/// 2. Local snapshot deltas between successive sample days **within the same billing period**
/// 3. Mid-period reset/rebase (used% drops, `resetsAt` unchanged): drop prior days and
///    start tracking from that day with the current week-to-date total
/// 4. Real period rollover (used% drops and `resetsAt` advances): start the new period’s week
/// 5. Until two valid sample days exist (normal week), leave bars empty
enum DailyUsageBuilder {
    /// Equal daily share of the weekly SuperGrok pool.
    static let dailyCapPercent: Double = 100.0 / 7.0

    /// Caches the week/day formatter pair per calendar to avoid per-call construction.
    private static let formatterCacheLock = NSLock()
    private static var formatterCache: [String: (weekday: DateFormatter, dayOfMonth: DateFormatter)] = [:]

    private static func makeDateFormatters(
        calendar: Calendar
    ) -> (weekday: DateFormatter, dayOfMonth: DateFormatter) {
        let key = "\(String(describing: calendar.identifier))|\(calendar.timeZone.identifier)|\(calendar.locale?.identifier ?? "")"
        formatterCacheLock.lock()
        defer { formatterCacheLock.unlock() }
        if let cached = formatterCache[key] {
            return cached
        }

        let weekday = DateFormatter()
        weekday.locale = .current
        weekday.calendar = calendar
        weekday.dateFormat = "EEE"

        let dayOfMonth = DateFormatter()
        dayOfMonth.locale = .current
        dayOfMonth.calendar = calendar
        dayOfMonth.dateFormat = "d"

        let pair = (weekday, dayOfMonth)
        formatterCache[key] = pair
        return pair
    }

    /// Maps weekly-pool percent into 0…1 of the daily track (`100/7` cap).
    static func fillFraction(forDayUsage percent: Double) -> Double {
        guard percent > 0.05 else { return 0 }
        return min(percent / dailyCapPercent, 1.0)
    }

    /// Billing-period week for the SuperGrok pool. Returns nil when no
    /// provider-supplied `resetsAt` exists — a calendar Mon–Sun week is never
    /// invented as a substitute.
    static func week(
        history: [WeeklyUsageSnapshot],
        current: WeeklyUsageSnapshot?,
        serverDaily: [DailyUsageSnapshot] = [],
        weekOffset: Int = 0,
        resetsAt: Date? = nil,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> DailyUsageWeek? {
        let cal = calendar

        let effectiveResetsAt = resetsAt ?? current?.resetsAt
        guard
            let effectiveResetsAt,
            let (weekStart, weekEnd) = billingPeriodWeekBounds(
                resetsAt: effectiveResetsAt,
                weekOffset: weekOffset,
                calendar: cal,
                now: now
            )
        else { return nil }
        let dayCount = max(
            1,
            (cal.dateComponents([.day], from: weekStart, to: weekEnd).day ?? 6) + 1
        )

        // Local day-over-day history is the source of truth for tracked usage.
        // Only fall back to a server daily series when local samples cannot paint bars
        // (heuristic protobuf day stamps have produced false positives that wiped weeks).
        var samples = history
        if let current {
            if samples.isEmpty || (samples.last.map { $0.fetchedAt < current.fetchedAt } ?? true) {
                if let last = samples.last,
                   abs(last.usedPercent - current.usedPercent) < 0.05,
                   abs(last.fetchedAt.timeIntervalSince(current.fetchedAt)) < 60,
                   cal.isDate(last.fetchedAt, inSameDayAs: current.fetchedAt) {
                    // same-day near-duplicate — keep history only
                } else {
                    samples.append(current)
                }
            }
        }
        samples.sort { $0.fetchedAt < $1.fetchedAt }

        // End-of-day cumulative used% (last sample that day), preferring post-rollover
        // samples when `resetsAt` advances mid-day.
        var endOfDay: [Date: WeeklyUsageSnapshot] = [:]
        for sample in samples {
            let day = cal.startOfDay(for: sample.fetchedAt)
            if let existing = endOfDay[day] {
                let existingResets = existing.resetsAt
                let sampleResets = sample.resetsAt
                // Prefer the sample after a real period advance on the same calendar day.
                if isBillingPeriodAdvanced(from: existingResets, to: sampleResets),
                   sample.fetchedAt >= existing.fetchedAt {
                    endOfDay[day] = sample
                    continue
                }
                // Ignore older-period samples after a newer period already won the day.
                if isBillingPeriodAdvanced(from: sampleResets, to: existingResets) {
                    continue
                }
                if sample.fetchedAt >= existing.fetchedAt {
                    endOfDay[day] = sample
                }
            } else {
                endOfDay[day] = sample
            }
        }

        let sortedDays = endOfDay.keys.sorted()
        var cumulativeByDay: [Date: Double] = [:]
        var productsByDay: [Date: [ProductUsage]] = [:]
        var resetsByDay: [Date: Date?] = [:]
        for day in sortedDays {
            guard let snap = endOfDay[day] else { continue }
            cumulativeByDay[day] = snap.usedPercent
            productsByDay[day] = snap.products
            resetsByDay[day] = snap.resetsAt
        }

        let (weekdayFormatter, dayOfMonthFormatter) = Self.makeDateFormatters(calendar: cal)

        // Samples through this period’s last day. Prior-period days stay out via anchor filter.
        let samplesThroughWeekEnd = sortedDays.filter { $0 <= weekEnd }
        let samplesInWeek = samplesThroughWeekEnd.filter { $0 >= weekStart }

        // Anchor to the billing period of the *displayed* week — not always the live snapshot.
        // After a weekly rollover, current.resetsAt is the new period; past weeks (weekOffset < 0)
        // must keep last period’s samples so the left-chevron history still paints.
        let anchorResets = periodAnchorResets(
            weekOffset: weekOffset,
            weekStart: weekStart,
            weekEnd: weekEnd,
            currentResetsAt: current?.resetsAt ?? effectiveResetsAt,
            samplesInWeek: samplesInWeek,
            endOfDay: endOfDay,
            calendar: cal
        )
        let samePeriodThroughWeekEnd = samplesThroughWeekEnd.filter { day in
            isSameBillingPeriod(endOfDay[day]?.resetsAt, anchorResets)
        }

        // Mid-period server reset/rebase (used% drops, `resetsAt` unchanged): drop every
        // prior sample day and start the daily series from that day forward.
        let trackingStartDay = latestMidPeriodRecalibrationDay(
            sampleDays: samePeriodThroughWeekEnd,
            cumulativeByDay: cumulativeByDay,
            endOfDay: endOfDay
        )

        let validSampleDays: [Date]
        if let trackingStartDay {
            validSampleDays = samePeriodThroughWeekEnd.filter { $0 >= trackingStartDay }
        } else {
            validSampleDays = samePeriodThroughWeekEnd
        }

        var days: [DailyUsageDay] = []

        for offset in 0..<dayCount {
            guard let dayStart = cal.date(byAdding: .day, value: offset, to: weekStart) else { continue }
            let isToday = cal.isDate(dayStart, inSameDayAs: now)
            let isPeriodStart = cal.isDate(dayStart, inSameDayAs: weekStart)
            let symbol = String(weekdayFormatter.string(from: dayStart).prefix(3))
            let dayNum = dayOfMonthFormatter.string(from: dayStart)

            // Prefer the latest prior *valid* sample day in the same billing period so a
            // missing poll day still yields a correct multi-day delta on the next sample.
            let dayResets = resetsByDay[dayStart] ?? nil
            let prevDayKey = validSampleDays.last { prev in
                guard prev < dayStart else { return false }
                let prevResets = resetsByDay[prev] ?? nil
                return isSameBillingPeriod(prevResets, dayResets)
            }
            let prevCumulative = prevDayKey.flatMap { cumulativeByDay[$0] }
            let dayCumulative = cumulativeByDay[dayStart]
            let dayIsValid = validSampleDays.contains(dayStart)
            let isTrackingStart = trackingStartDay.map { cal.isDate(dayStart, inSameDayAs: $0) } ?? false

            var segments: [DailyUsageSegment] = []
            var isAfterReset = isTrackingStart

            if let dayCumulative, dayIsValid {
                let products = productsByDay[dayStart] ?? current?.products ?? []
                let previousProducts = prevDayKey.flatMap { productsByDay[$0] } ?? []
                if let previous = prevCumulative {
                    if dayCumulative + 5 < previous {
                        // Mid-period rebase drop: restart tracking with absolute week-to-date.
                        isAfterReset = true
                        if dayCumulative > 0.05 {
                            segments.append(
                                contentsOf: segmentsFromProducts(
                                    products,
                                    fallbackTotal: dayCumulative
                                )
                            )
                        }
                    } else {
                        // Day-over-day growth. If cumulative is flat or lower without a rebase,
                        // still show period-to-date on the period-start day when it's the only
                        // baseline we have (first bar after a new week opens).
                        segments.append(
                            contentsOf: growthSegments(
                                previousUsed: previous,
                                dayUsed: dayCumulative,
                                previousProducts: previousProducts,
                                products: products
                            )
                        )
                    }
                } else if dayCumulative > 0.05, isTrackingStart || isPeriodStart {
                    // Period-start day (e.g. new-week Thursday) or mid-period rebase:
                    // show period-to-date so day 1 is not blank after rollover.
                    if isTrackingStart { isAfterReset = true }
                    if let priorAny = sortedDays.last(where: { $0 < dayStart }),
                       isBillingPeriodAdvanced(from: endOfDay[priorAny]?.resetsAt, to: dayResets) {
                        isAfterReset = true
                    }
                    segments.append(
                        contentsOf: segmentsFromProducts(products, fallbackTotal: dayCumulative)
                    )
                } else if dayCumulative > 0.05,
                          let priorAny = sortedDays.last(where: { $0 < dayStart && $0 >= weekStart }),
                          let priorSnap = endOfDay[priorAny],
                          isBillingPeriodAdvanced(from: priorSnap.resetsAt, to: dayResets) {
                    // Rollover observed between two days already in this period window:
                    // paint post-reset week-to-date only (never merge prior-period usage).
                    isAfterReset = true
                    segments.append(
                        contentsOf: segmentsFromProducts(products, fallbackTotal: dayCumulative)
                    )
                }
                // First sample mid-period (not period start): leave empty until a second day.
            }

            days.append(
                DailyUsageDay(
                    dayStart: dayStart,
                    weekdaySymbol: symbol,
                    dayOfMonth: dayNum,
                    segments: segments,
                    isToday: isToday,
                    isAfterReset: isAfterReset,
                    resetAt: nil
                )
            )
        }

        // Estimated when this period window has fewer than two sample days for deltas.
        let inPeriodSampleDays = validSampleDays.filter { $0 >= weekStart && $0 <= weekEnd }
        let isEstimated = inPeriodSampleDays.count < 2 && weekOffset == 0
        let localWeek = finalize(
            weekStart: weekStart,
            weekEnd: weekEnd,
            days: days,
            isEstimated: isEstimated,
            resetsAt: effectiveResetsAt,
            calendar: cal
        )
        if localWeek.hasDailyData || serverDaily.isEmpty {
            return localWeek
        }

        let weekDays = buildDaysFromServer(
            serverDaily: serverDaily,
            weekStart: weekStart,
            dayCount: dayCount,
            calendar: cal,
            now: now
        )
        if weekDays.contains(where: { !$0.segments.isEmpty }) {
            return finalize(
                weekStart: weekStart,
                weekEnd: weekEnd,
                days: weekDays,
                isEstimated: false,
                resetsAt: effectiveResetsAt,
                calendar: cal
            )
        }
        return localWeek
    }

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
                    isAfterReset: false,
                    resetAt: nil
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

    // MARK: - Billing period week

    /// Exactly **7** calendar days for the active SuperGrok billing period.
    ///
    /// - **Before** `resetsAt`: previous reset day → day before reset
    ///   (e.g. next reset Thu Jul 16 → **Thu Jul 9 … Wed Jul 15**). One Thursday only.
    /// - **After** `resetsAt` fires: whole window rolls to the new period starting that day
    ///   (**Thu Jul 16 … Wed Jul 22**). Never appends a second Thursday onto the old week.
    /// - Once the API advances `resetsAt` by a week, the same formula
    ///   (`startOfDay(resetsAt) - 7` … `+ 6`) yields the new period.
    ///
    /// Returns nil when `resetsAt` is unknown — never falls back to a calendar week.
    static func billingPeriodWeekBounds(
        resetsAt: Date?,
        weekOffset: Int,
        calendar: Calendar,
        now: Date
    ) -> (start: Date, end: Date)? {
        let cal = calendar

        guard let resetsAt else { return nil }
        let resetDay = cal.startOfDay(for: resetsAt)
        // Active period start for the current snapshot of `resetsAt`:
        // • Still in the period (now < resetsAt): started 7 days before that reset day.
        // • Past the reset instant (now >= resetsAt) and API has not moved `resetsAt` yet:
        //   roll the chart to the new week starting on `resetDay` (no second Thursday).
        // • API already advanced `resetsAt`: now < new resetsAt again → first branch with
        //   resetDay = next week, so start = that day − 7 = current period’s Thursday.
        let baseStart: Date
        if now >= resetsAt {
            baseStart = resetDay
        } else {
            baseStart = cal.date(byAdding: .day, value: -7, to: resetDay) ?? resetDay
        }
        let shiftedStart = cal.date(byAdding: .day, value: weekOffset * 7, to: baseStart) ?? baseStart
        let shiftedEnd = cal.date(byAdding: .day, value: 6, to: shiftedStart) ?? shiftedStart
        return (shiftedStart, shiftedEnd)
    }

    // MARK: - Helpers

    /// `resetsAt` for the SuperGrok period that owns the displayed week window.
    ///
    /// - **Current week** (`weekOffset == 0`): live snapshot / API value.
    /// - **Past weeks**: prefer in-window sample metadata; else the calendar day after
    ///   `weekEnd` (period end is the day before the next reset).
    private static func periodAnchorResets(
        weekOffset: Int,
        weekStart: Date,
        weekEnd: Date,
        currentResetsAt: Date?,
        samplesInWeek: [Date],
        endOfDay: [Date: WeeklyUsageSnapshot],
        calendar: Calendar
    ) -> Date? {
        if weekOffset == 0 {
            return currentResetsAt
                ?? samplesInWeek.last.flatMap { endOfDay[$0]?.resetsAt }
        }

        // Most recent in-window sample carries the period that closed (or was active) then.
        if let fromHistory = samplesInWeek.last.flatMap({ endOfDay[$0]?.resetsAt }) {
            return fromHistory
        }

        // No samples yet for that week: expected reset is the calendar day after weekEnd.
        if let expected = calendar.date(byAdding: .day, value: 1, to: weekEnd) {
            // If the live resetsAt still lands on that day (timezone / API lag), keep it.
            if let currentResetsAt,
               calendar.isDate(calendar.startOfDay(for: currentResetsAt), inSameDayAs: expected) {
                return currentResetsAt
            }
            return calendar.date(
                bySettingHour: 12,
                minute: 0,
                second: 0,
                of: expected
            ) ?? expected
        }

        return currentResetsAt
    }

    private static func buildDaysFromServer(
        serverDaily: [DailyUsageSnapshot],
        weekStart: Date,
        dayCount: Int,
        calendar: Calendar,
        now: Date
    ) -> [DailyUsageDay] {
        let (weekdayFormatter, dayOfMonthFormatter) = Self.makeDateFormatters(calendar: calendar)

        let byDay = Dictionary(
            serverDaily.map { (calendar.startOfDay(for: $0.dayStart), $0) },
            uniquingKeysWith: { _, last in last }
        )

        var days: [DailyUsageDay] = []
        for offset in 0..<dayCount {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: weekStart) else { continue }
            let symbol = String(weekdayFormatter.string(from: dayStart).prefix(3))
            let dayNum = dayOfMonthFormatter.string(from: dayStart)
            let snap = byDay[dayStart]
            let segments: [DailyUsageSegment]
            if let snap, snap.percentOfWeekly > 0.05 {
                segments = segmentsFromProducts(snap.products, fallbackTotal: snap.percentOfWeekly)
            } else {
                segments = []
            }
            days.append(
                DailyUsageDay(
                    dayStart: dayStart,
                    weekdaySymbol: symbol,
                    dayOfMonth: dayNum,
                    segments: segments,
                    isToday: calendar.isDate(dayStart, inSameDayAs: now),
                    isAfterReset: false,
                    resetAt: nil
                )
            )
        }
        return days
    }

    private static func finalize(
        weekStart: Date,
        weekEnd: Date,
        days: [DailyUsageDay],
        isEstimated: Bool,
        resetsAt: Date?,
        calendar: Calendar
    ) -> DailyUsageWeek {
        var legend: [DailyUsageLegendItem] = []
        var seen = Set<String>()
        for day in days {
            for seg in day.segments {
                guard seen.insert(seg.productID).inserted else { continue }
                legend.append(
                    DailyUsageLegendItem(
                        id: seg.productID,
                        displayName: seg.displayName,
                        colorToken: seg.colorToken
                    )
                )
            }
        }
        legend.sort { lhs, rhs in
            let lhsIndex = ProductCatalog.displayOrder.firstIndex(of: lhs.id) ?? 99
            let rhsIndex = ProductCatalog.displayOrder.firstIndex(of: rhs.id) ?? 99
            return lhsIndex < rhsIndex
        }

        let hasDailyData = days.contains { !$0.segments.isEmpty }

        return DailyUsageWeek(
            weekStart: weekStart,
            weekEnd: weekEnd,
            days: days,
            legendProducts: legend,
            hasDailyData: hasDailyData,
            isEstimated: isEstimated
        )
    }

    /// Absolute product slices — only products with usage above zero.
    private static func segmentsFromProducts(
        _ products: [ProductUsage],
        fallbackTotal: Double? = nil
    ) -> [DailyUsageSegment] {
        let visible = products.filter { $0.percentOfPool > 0.05 }
        if !visible.isEmpty {
            return ProductCatalog.sortForDisplay(visible).map { product in
                DailyUsageSegment(
                    productID: product.id,
                    displayName: product.displayName,
                    percentOfWeekly: product.percentOfPool,
                    colorToken: product.colorToken
                )
            }
        }
        guard let total = fallbackTotal, total > 0.05 else { return [] }
        return [
            DailyUsageSegment(
                productID: "other",
                displayName: "Other",
                percentOfWeekly: total,
                colorToken: .other
            )
        ]
    }

    /// True when `resetsAt` moved forward enough to indicate a SuperGrok period rollover.
    private static func isBillingPeriodAdvanced(from previous: Date?, to current: Date?) -> Bool {
        guard let previous, let current else { return false }
        return current.timeIntervalSince(previous) > 12 * 3600
    }

    /// Same SuperGrok pool period (neither side’s `resetsAt` advanced past the other).
    private static func isSameBillingPeriod(_ from: Date?, _ to: Date?) -> Bool {
        !isBillingPeriodAdvanced(from: from, to: to) && !isBillingPeriodAdvanced(from: to, to: from)
    }

    /// Latest day whose cumulative used% fell sharply without `resetsAt` advancing (server rebase).
    private static func latestMidPeriodRecalibrationDay(
        sampleDays: [Date],
        cumulativeByDay: [Date: Double],
        endOfDay: [Date: WeeklyUsageSnapshot]
    ) -> Date? {
        guard sampleDays.count >= 2 else { return nil }
        var latest: Date?
        for index in 1..<sampleDays.count {
            let previousDay = sampleDays[index - 1]
            let day = sampleDays[index]
            guard
                let previousUsed = cumulativeByDay[previousDay],
                let dayUsed = cumulativeByDay[day],
                dayUsed + 5 < previousUsed
            else { continue }
            let previousResets = endOfDay[previousDay]?.resetsAt
            let dayResets = endOfDay[day]?.resetsAt
            if isBillingPeriodAdvanced(from: previousResets, to: dayResets) {
                continue
            }
            latest = day
        }
        return latest
    }

    /// Day-over-day growth: prefer per-product increases; fall back to total delta weighted by mix.
    private static func growthSegments(
        previousUsed: Double,
        dayUsed: Double,
        previousProducts: [ProductUsage],
        products: [ProductUsage]
    ) -> [DailyUsageSegment] {
        let productSegments = productDeltaSegments(from: previousProducts, to: products)
        let productSum = productSegments.reduce(0.0) { $0 + $1.percentOfWeekly }
        let totalDelta = max(0, dayUsed - previousUsed)
        if !productSegments.isEmpty, productSum > 0.05 {
            return productSegments
        }
        if totalDelta > 0.05 {
            return distribute(total: totalDelta, products: products)
        }
        return []
    }

    /// Day-over-day growth per product — omits products that did not increase.
    private static func productDeltaSegments(
        from previous: [ProductUsage],
        to current: [ProductUsage]
    ) -> [DailyUsageSegment] {
        var previousByID: [String: Double] = [:]
        for product in previous {
            previousByID[product.id.lowercased()] = product.percentOfPool
        }

        var deltas: [ProductUsage] = []
        for product in current {
            let key = product.id.lowercased()
            let delta = max(0, product.percentOfPool - (previousByID[key] ?? 0))
            guard delta > 0.05 else { continue }
            deltas.append(
                ProductUsage(
                    id: product.id,
                    displayName: product.displayName,
                    percentOfPool: delta,
                    colorToken: product.colorToken
                )
            )
        }
        return ProductCatalog.sortForDisplay(deltas).map { product in
            DailyUsageSegment(
                productID: product.id,
                displayName: product.displayName,
                percentOfWeekly: product.percentOfPool,
                colorToken: product.colorToken
            )
        }
    }

    /// Proportional split of a total when product-level deltas are unavailable.
    ///
    /// Uses the current product mix only as weights for the *delta*, not as absolute
    /// week-to-date amounts. When no products exist, label as "other" (never Build).
    private static func distribute(total: Double, products: [ProductUsage]) -> [DailyUsageSegment] {
        let visible = products.filter { $0.percentOfPool > 0.05 }
        let sum = visible.reduce(0.0) { $0 + $1.percentOfPool }
        guard total > 0.05 else { return [] }

        if visible.isEmpty || sum < 0.05 {
            return [
                DailyUsageSegment(
                    productID: "other",
                    displayName: "Other",
                    percentOfWeekly: total,
                    colorToken: .other
                )
            ]
        }

        return ProductCatalog.sortForDisplay(visible).compactMap { product in
            let share = product.percentOfPool / sum
            let percent = total * share
            guard percent > 0.05 else { return nil }
            return DailyUsageSegment(
                productID: product.id,
                displayName: product.displayName,
                percentOfWeekly: percent,
                colorToken: product.colorToken
            )
        }
    }
}
