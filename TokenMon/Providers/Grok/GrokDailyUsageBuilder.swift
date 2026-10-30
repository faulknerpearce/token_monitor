import Foundation

/// Builds a Settings → Usage style “Daily use” series on the **billing period** axis:
/// 7 calendar days starting at the period start (e.g. Thu→Wed). Prefers local
/// day-over-day snapshot deltas within the period, falls back to a server daily
/// series, and leaves bars empty until two valid sample days exist.
enum GrokDailyUsageBuilder {
    /// Equal daily share of the weekly SuperGrok pool.
    static let dailyCapPercent: Double = 100.0 / 7.0

    /// Caches the week/day formatter pair per calendar to avoid per-call construction.
    private static let formatterCacheLock = NSLock()
    // SwiftLint versions disagree on where `nonisolated(unsafe)` goes; SwiftFormat sets this order.
    // swiftlint:disable:next modifier_order superfluous_disable_command
    private nonisolated(unsafe) static var formatterCache: [String: (weekday: DateFormatter, dayOfMonth: DateFormatter)] = [:]

    static func makeDateFormatters(
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
    /// provider-supplied `resetsAt` exists.
    static func week(
        history: [WeeklyUsageSnapshot],
        current: WeeklyUsageSnapshot?,
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
        let endOfDay = endOfDaySamples(mergedSamples(history: history, current: current, calendar: cal), calendar: cal)
        let sortedDays = endOfDay.keys.sorted()

        // Samples through this period’s last day. The anchor filter excludes prior-period days.
        let samplesThroughWeekEnd = sortedDays.filter { $0 <= weekEnd }
        let samplesInWeek = samplesThroughWeekEnd.filter { $0 >= weekStart }

        // Anchor to the billing period of the *displayed* week. After a weekly rollover,
        // current.resetsAt is the new period; past weeks (weekOffset < 0) keep the earlier
        // period’s samples so the left-chevron history paints.
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
            cumulativeByDay: endOfDay.mapValues(\.usedPercent),
            endOfDay: endOfDay
        )
        let validSampleDays = trackingStartDay.map { start in samePeriodThroughWeekEnd.filter { $0 >= start } }
            ?? samePeriodThroughWeekEnd

        let samples = WeekSamples(
            endOfDay: endOfDay,
            sortedDays: sortedDays,
            validSampleDays: validSampleDays,
            trackingStartDay: trackingStartDay,
            weekStart: weekStart,
            currentProducts: current?.products
        )
        let (weekdayFormatter, dayOfMonthFormatter) = Self.makeDateFormatters(calendar: cal)
        let days: [DailyUsageDay] = (0..<dayCount).compactMap { offset in
            guard let dayStart = cal.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            let bar = dayBar(on: dayStart, samples: samples, calendar: cal)
            return DailyUsageDay(
                dayStart: dayStart,
                weekdaySymbol: String(weekdayFormatter.string(from: dayStart).prefix(3)),
                dayOfMonth: dayOfMonthFormatter.string(from: dayStart),
                segments: bar.segments,
                isToday: cal.isDate(dayStart, inSameDayAs: now),
                isAfterReset: bar.isAfterReset
            )
        }

        // Estimated when this period window has fewer than two sample days for deltas.
        let inPeriodSampleDays = validSampleDays.filter { $0 >= weekStart && $0 <= weekEnd }
        let isEstimated = inPeriodSampleDays.count < 2 && weekOffset == 0
        return finalize(
            weekStart: weekStart,
            weekEnd: weekEnd,
            days: days,
            isEstimated: isEstimated,
            resetsAt: effectiveResetsAt,
            calendar: cal
        )
    }

    /// End-of-day samples of the displayed week, ready to turn into bars.
    private struct WeekSamples {
        /// The last sample of each calendar day (see `endOfDaySamples`).
        let endOfDay: [Date: WeeklyUsageSnapshot]
        let sortedDays: [Date]
        /// Sample days in the displayed period, from the last mid-period rebase on.
        let validSampleDays: [Date]
        let trackingStartDay: Date?
        let weekStart: Date
        let currentProducts: [ProductUsage]?
    }

    /// `history` plus `current` when it is newer and not a same-day
    /// near-duplicate of the last sample, oldest first.
    private static func mergedSamples(
        history: [WeeklyUsageSnapshot],
        current: WeeklyUsageSnapshot?,
        calendar cal: Calendar
    ) -> [WeeklyUsageSnapshot] {
        var samples = history
        if let current, samples.isEmpty || (samples.last.map { $0.fetchedAt < current.fetchedAt } ?? true) {
            let isNearDuplicate = samples.last.map { last in
                abs(last.usedPercent - current.usedPercent) < 0.05
                    && abs(last.fetchedAt.timeIntervalSince(current.fetchedAt)) < 60
                    && cal.isDate(last.fetchedAt, inSameDayAs: current.fetchedAt)
            } ?? false
            if !isNearDuplicate {
                samples.append(current)
            }
        }
        return samples.sorted { $0.fetchedAt < $1.fetchedAt }
    }

    /// End-of-day cumulative used% (last sample that day), preferring
    /// post-rollover samples when `resetsAt` advances mid-day.
    private static func endOfDaySamples(
        _ samples: [WeeklyUsageSnapshot],
        calendar cal: Calendar
    ) -> [Date: WeeklyUsageSnapshot] {
        var endOfDay: [Date: WeeklyUsageSnapshot] = [:]
        for sample in samples {
            let day = cal.startOfDay(for: sample.fetchedAt)
            guard let existing = endOfDay[day] else {
                endOfDay[day] = sample
                continue
            }
            // Prefer the sample after a real period advance on the same calendar day.
            if isBillingPeriodAdvanced(from: existing.resetsAt, to: sample.resetsAt),
               sample.fetchedAt >= existing.fetchedAt {
                endOfDay[day] = sample
                continue
            }
            // Ignore older-period samples after a newer period already won the day.
            if isBillingPeriodAdvanced(from: sample.resetsAt, to: existing.resetsAt) {
                continue
            }
            if sample.fetchedAt >= existing.fetchedAt {
                endOfDay[day] = sample
            }
        }
        return endOfDay
    }

    /// The bar for the day starting at `dayStart`: its product segments and
    /// whether it opens after a reset.
    private static func dayBar(
        on dayStart: Date,
        samples: WeekSamples,
        calendar cal: Calendar
    ) -> (segments: [DailyUsageSegment], isAfterReset: Bool) {
        let endOfDay = samples.endOfDay
        let isPeriodStart = cal.isDate(dayStart, inSameDayAs: samples.weekStart)

        // Prefer the latest prior *valid* sample day in the same billing period so a
        // missing poll day still yields a correct multi-day delta on the next sample.
        let dayResets = endOfDay[dayStart]?.resetsAt
        let prevDayKey = samples.validSampleDays.last { prev in
            prev < dayStart && isSameBillingPeriod(endOfDay[prev]?.resetsAt, dayResets)
        }
        let prevCumulative = prevDayKey.flatMap { endOfDay[$0]?.usedPercent }
        let isTrackingStart = samples.trackingStartDay.map { cal.isDate(dayStart, inSameDayAs: $0) } ?? false

        var segments: [DailyUsageSegment] = []
        var isAfterReset = isTrackingStart

        guard let dayCumulative = endOfDay[dayStart]?.usedPercent,
              samples.validSampleDays.contains(dayStart)
        else { return (segments, isAfterReset) }

        let products = endOfDay[dayStart]?.products ?? samples.currentProducts ?? []
        let previousProducts = prevDayKey.flatMap { endOfDay[$0]?.products } ?? []
        if let previous = prevCumulative {
            if dayCumulative + 5 < previous {
                // Mid-period rebase drop: restart tracking with absolute week-to-date.
                isAfterReset = true
                if dayCumulative > 0.05 {
                    segments.append(contentsOf: segmentsFromProducts(products, fallbackTotal: dayCumulative))
                }
            } else {
                // Day-over-day growth. If cumulative is flat or lower without a rebase,
                // still show period-to-date on the period-start day when it is the only
                // available baseline (first bar after a new week opens).
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
            // show period-to-date so day 1 has a bar after rollover.
            if isTrackingStart { isAfterReset = true }
            if let priorAny = samples.sortedDays.last(where: { $0 < dayStart }),
               isBillingPeriodAdvanced(from: endOfDay[priorAny]?.resetsAt, to: dayResets) {
                isAfterReset = true
            }
            segments.append(contentsOf: segmentsFromProducts(products, fallbackTotal: dayCumulative))
        } else if dayCumulative > 0.05,
                  let priorAny = samples.sortedDays.last(where: { $0 < dayStart && $0 >= samples.weekStart }),
                  let priorSnap = endOfDay[priorAny],
                  isBillingPeriodAdvanced(from: priorSnap.resetsAt, to: dayResets) {
            // Rollover observed between two days already in this period window:
            // paint post-reset week-to-date only, excluding prior-period usage.
            isAfterReset = true
            segments.append(contentsOf: segmentsFromProducts(products, fallbackTotal: dayCumulative))
        }
        // First sample mid-period: the bar stays empty until a second day.
        return (segments, isAfterReset)
    }

    // MARK: - Billing period week

    /// Calendar days for the active SuperGrok billing period (7, or 8 on the
    /// reset day as described below): before
    /// `resetsAt`, the previous reset day through the day before reset; once it fires,
    /// the window rolls to the new period starting that day. On the reset day itself,
    /// before the reset instant, the running period still owns today, so the current
    /// window (`weekOffset == 0`) runs through the reset day as an eighth bar. Returns
    /// nil when `resetsAt` is unknown.
    static func billingPeriodWeekBounds(
        resetsAt: Date?,
        weekOffset: Int,
        calendar: Calendar,
        now: Date
    ) -> (start: Date, end: Date)? {
        let cal = calendar

        guard let resetsAt else { return nil }
        let resetDay = cal.startOfDay(for: resetsAt)
        // Active period start: 7 days before the reset day while still in period, or
        // the reset day itself once `resetsAt` has passed and the API still reports it.
        var baseStart: Date
        if now >= resetsAt {
            baseStart = resetDay
            // The API can lag `resetsAt` by more than one period, leaving the
            // window entirely in the past. Roll forward by whole periods until the
            // window contains today. Before the reset fires the prior period is
            // kept, so this roll applies only on the post-reset branch.
            let today = cal.startOfDay(for: now)
            var guardIter = 0
            while guardIter < 520 {
                let windowEnd = cal.date(byAdding: .day, value: 6, to: baseStart) ?? baseStart
                if today <= windowEnd { break }
                guard let advanced = cal.date(byAdding: .day, value: 7, to: baseStart) else { break }
                baseStart = advanced
                guardIter += 1
            }
        } else {
            baseStart = cal.date(byAdding: .day, value: -7, to: resetDay) ?? resetDay
        }
        let shiftedStart = cal.date(byAdding: .day, value: weekOffset * 7, to: baseStart) ?? baseStart
        let shiftedEnd = cal.date(byAdding: .day, value: 6, to: shiftedStart) ?? shiftedStart
        if weekOffset == 0, now < resetsAt, cal.isDate(now, inSameDayAs: resetDay) {
            return (shiftedStart, resetDay)
        }
        return (shiftedStart, shiftedEnd)
    }

    // MARK: - Helpers

    /// `resetsAt` for the SuperGrok period that owns the displayed week window: the
    /// live value for the current week, or in-window sample metadata for past weeks
    /// (falling back to the day after `weekEnd`).
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

    static func finalize(
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

    /// Same SuperGrok pool period (both `resetsAt` values within the rollover threshold).
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

    /// Day-over-day growth per product, for the products that increased.
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
    /// Uses the current product mix as weights for the *delta* only. When no
    /// products exist, labels the delta "other".
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
