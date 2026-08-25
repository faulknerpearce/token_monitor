import SwiftUI

/// Daily-budget bar chart for providers whose quota window is a **week**
/// (Claude). Bars usually cover the full period; pace uses the first bar as
/// period start.
struct WeeklyDailyBudgetBarsView: View {
    let days: [DailyBudgetDay]
    var accent: Color
    var title: String = "Daily Budget"
    var infoText: String?
    var periodUsedPercent: Double?

    var body: some View {
        DailyBudgetBarsView(
            days: days,
            accent: accent,
            title: title,
            allowancePeriod: .weekly,
            allowanceNoun: "weekly",
            infoText: infoText,
            periodUsedPercent: periodUsedPercent,
            periodStart: DailyBudget.weeklyPacePeriodStart(days: days)
        )
    }
}

/// Daily-budget bar chart for providers whose quota is a **subscription /
/// billing month** (Cursor, OpenCode Go). Shows the last 7 days; pace earns
/// across the full subscription month — never the calendar month of today.
struct MonthlyDailyBudgetBarsView: View {
    let days: [DailyBudgetDay]
    var accent: Color
    var title: String = "Daily Budget"
    var infoText: String?
    var periodUsedPercent: Double?
    /// Billing-cycle / Go-subscription start when known.
    var periodStart: Date?
    /// Next reset / cycle end — used to derive start when `periodStart` is nil.
    var resetsAt: Date?

    var body: some View {
        let start = DailyBudget.monthlyPacePeriodStart(
            days: days,
            knownStart: periodStart,
            resetsAt: resetsAt
        )
        return DailyBudgetBarsView(
            days: days,
            accent: accent,
            title: title,
            allowancePeriod: .monthly,
            allowanceNoun: "monthly",
            infoText: infoText,
            periodUsedPercent: periodUsedPercent,
            periodStart: start
        )
    }
}

/// Shared stem chart + pace footer. Prefer `WeeklyDailyBudgetBarsView` or
/// `MonthlyDailyBudgetBarsView` at call sites so weekly vs subscription-month
/// math cannot be mixed up.
struct DailyBudgetBarsView: View {
    let days: [DailyBudgetDay]
    var accent: Color
    var title: String = "Daily Budget"
    var allowancePeriod: DailyBudget.AllowancePeriod = .monthly
    /// What the equal daily share is drawn from, e.g. "monthly" or "weekly".
    var allowanceNoun: String = "monthly"
    /// Optional longer explanation shown as an info tooltip next to the header.
    var infoText: String?
    /// Live used % for the same pool the bars pace against (API source of truth).
    var periodUsedPercent: Double?
    /// Start of the full quota period (subscription month or weekly window).
    var periodStart: Date?

    private let trackHeight: CGFloat = PanelChartStem.height
    private static let stemWidth: CGFloat = PanelChartStem.width
    private static let barCornerRadius: CGFloat = PanelChartStem.cornerRadius
    /// Headroom meaningfully above one daily share → show banked caption.
    private static let bankEpsilon = 0.05

    /// Render a day reliably (weekday + day-of-month), cached per calendar.
    private static let formatterCacheLock = NSLock()
    private static var formatterCache: [String: (weekday: DateFormatter, dayOfMonth: DateFormatter)] = [:]

    private var rangeLabel: String {
        guard let first = days.first?.date, let last = days.last?.date else { return "" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "MMMM d"
        let cal = Calendar.current
        let sameMonth = cal.component(.month, from: first) == cal.component(.month, from: last)
            && cal.component(.year, from: first) == cal.component(.year, from: last)
        if sameMonth {
            return "\(fmt.string(from: first)) – \(cal.component(.day, from: last))"
        }
        return "\(fmt.string(from: first)) – \(last.formatted(Date.FormatStyle().month(.abbreviated).day()))"
    }

    private var dailyBudget: Double { days.first?.budgetUSD ?? 0 }

    private var pace: DailyBudget.PaceHeadroom? {
        guard let periodUsedPercent else { return nil }
        let start = periodStart ?? DailyBudget.pacePeriodStart(
            period: allowancePeriod,
            days: days
        )
        // Weekly windows earn from visible bars when start is unknown.
        // Monthly requires a subscription start — never invent a calendar month.
        let elapsed: Int?
        if let start {
            elapsed = DailyBudget.elapsedDaysThroughToday(from: start)
        } else if allowancePeriod == .weekly {
            elapsed = nil
        } else {
            return nil
        }
        return DailyBudget.paceHeadroom(
            days: days,
            periodConsumed: periodUsedPercent,
            elapsedDaysInPeriod: elapsed
        )
    }

    private var footerCaption: String? {
        if let pace {
            return paceCaption(pace)
        }
        // Fallback when no live used % was passed.
        if days.allSatisfy({ $0.spentUSD <= 0.001 }) {
            return String(format: "No usage yet. Budget is %.1f%% per day.", dailyBudget)
        }
        if days.contains(where: {
            Calendar.current.isDate($0.date, inSameDayAs: Date()) && $0.spentUSD > $0.budgetUSD
        }) {
            return "Over today's daily allowance."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                PanelSectionHeader(title: dailyBudget > 0 ? "\(title) \(Int(dailyBudget.rounded()))%" : title)
                if let infoText {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .help(infoText)
                        .accessibilityLabel(infoText)
                }
                Spacer(minLength: 8)
                PanelPill(text: rangeLabel)
            }

            HStack(alignment: .bottom, spacing: 0) {
                ForEach(days) { day in
                    dayColumn(day)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: trackHeight + 36)

            if let footerCaption {
                Text(footerCaption)
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func paceCaption(_ pace: DailyBudget.PaceHeadroom) -> String? {
        if pace.periodConsumed <= 0.001 {
            if pace.earnedThroughToday > pace.dailyBudget + Self.bankEpsilon {
                return String(
                    format: "Up to %.1f%% available today from unused earlier days.",
                    pace.headroomToday
                )
            }
            return nil
        }
        if pace.headroomToday < 0 {
            return String(
                format: "Used %.0f%% with only %.1f%% available through today.",
                pace.periodConsumed,
                pace.earnedThroughToday
            )
        }
        if pace.headroomToday > pace.dailyBudget + Self.bankEpsilon {
            return String(
                format: "%.1f%% still available today from unused earlier days.",
                pace.headroomToday
            )
        }
        return String(format: "%.1f%% usage left through today.", pace.headroomToday)
    }

    private func dayColumn(_ day: DailyBudgetDay) -> some View {
        // Full stem height = the day's allowance. Fill = usage vs that allowance — mirrors Grok DailyUsageChartView.
        let fraction = day.budgetUSD > 0 ? min(1, max(0, day.spentUSD / day.budgetUSD)) : 0
        let fillHeight = max(6, trackHeight * CGFloat(fraction))
        let isFuture = day.date > Calendar.current.startOfDay(for: Date())
        let (weekday, _) = Self.formatters(for: day.date)

        return VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                Color.primary.opacity(0.12)

                if fraction > 0.005 && !isFuture {
                    accent
                        .frame(height: min(trackHeight, fillHeight))
                }
            }
            .frame(width: Self.stemWidth, height: trackHeight)
            .clipShape(RoundedRectangle(cornerRadius: Self.barCornerRadius, style: .continuous))
            .frame(maxWidth: .infinity)
            .opacity(isFuture ? 0.4 : 1)
            .help(dayHelp(day))

            VStack(spacing: 1) {
                Text(day.spentUSD > 0.5 ? "\(Int(day.spentUSD.rounded()))%" : " ")
                    .font(PanelTypography.micro)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(String(weekday.string(from: day.date).prefix(2)))
                    .font(PanelTypography.micro)
                    .foregroundStyle(.tertiary)
            }
            .frame(height: 26)
        }
        .frame(maxWidth: .infinity)
    }

    private static func formatters(for date: Date) -> (weekday: DateFormatter, dayOfMonth: DateFormatter) {
        let calendar = Calendar.current
        let key = "\(calendar.identifier)|\(calendar.timeZone.identifier)|\(calendar.locale?.identifier ?? "")"
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

    private func dayHelp(_ day: DailyBudgetDay) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MMM d"
        let dateStr = formatter.string(from: day.date)
        if day.budgetUSD <= 0 { return "\(dateStr): no budget" }
        if day.spentUSD <= 0.001 { return String(format: "%@: used 0%% of %.1f%% allowance", dateStr, day.budgetUSD) }
        let ofAllowance = Int((day.spentUSD / day.budgetUSD * 100).rounded())
        return String(format: "%@: %.1f%% of %@, %d%% of daily allowance", dateStr, day.spentUSD, allowanceNoun, ofAllowance)
    }
}

#if DEBUG
#Preview("Monthly") {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let days: [DailyBudgetDay] = (0..<7).map { offset in
        let date = calendar.date(byAdding: .day, value: offset - 6, to: today)!
        let spent: Double = [1.2, 0, 4.1, 2.8, 0.5, 3.6, 1.0][offset]
        return DailyBudgetDay(date: date, spentUSD: spent, budgetUSD: 3.3)
    }
    return MonthlyDailyBudgetBarsView(
        days: days,
        accent: ModelPalette.purple.color,
        periodUsedPercent: 12,
        periodStart: calendar.date(byAdding: .day, value: -20, to: today)
    )
    .padding()
    .frame(width: 360)
}

#Preview("Weekly") {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let days: [DailyBudgetDay] = (0..<7).map { offset in
        let date = calendar.date(byAdding: .day, value: offset - 6, to: today)!
        return DailyBudgetDay(date: date, spentUSD: Double(offset), budgetUSD: 100.0 / 7)
    }
    return WeeklyDailyBudgetBarsView(
        days: days,
        accent: ConcentricUsageRingView.claudeColor,
        periodUsedPercent: 40
    )
    .padding()
    .frame(width: 360)
}
#endif
