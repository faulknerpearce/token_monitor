import SwiftUI

/// Daily-budget bar chart for providers whose quota window is a **week**
/// (Claude). Bars usually cover the full period; pace uses the first bar as
/// period start. After an early provider reset, preserved prior-window days
/// lead the bars (dimmed) and pace starts at the first bar that is not one.
struct WeeklyDailyBudgetBarsView: View {
    let days: [DailyBudgetDay]
    var accent: Color
    var title: String = "Daily Budget"
    var periodUsedPercent: Double?
    /// Pool reset instant — paces the remainder against time left until reset.
    var resetsAt: Date?
    var onPreviousWeek: (() -> Void)?
    var onNextWeek: (() -> Void)?
    var canGoNext: Bool = false
    /// Past weeks omit the live "left today" footer.
    var showsLiveFooter: Bool = true

    var body: some View {
        DailyBudgetBarsView(
            days: days,
            accent: accent,
            title: title,
            allowancePeriod: .weekly,
            allowanceNoun: "weekly",
            periodUsedPercent: periodUsedPercent,
            resetsAt: resetsAt,
            periodStart: DailyBudget.weeklyPacePeriodStart(days: days),
            onPreviousWeek: onPreviousWeek,
            onNextWeek: onNextWeek,
            canGoNext: canGoNext,
            showsLiveFooter: showsLiveFooter
        )
    }
}

/// Daily-budget bar chart for providers whose quota is a **subscription /
/// billing month** (Cursor, OpenCode Go). Bars are the Monday–Sunday week
/// containing today; pace still earns across the full subscription month.
struct MonthlyDailyBudgetBarsView: View {
    let days: [DailyBudgetDay]
    var accent: Color
    var title: String = "Daily Budget"
    var periodUsedPercent: Double?
    /// Billing-cycle / Go-subscription start when known.
    var periodStart: Date?
    /// Next reset / cycle end — used to derive start when `periodStart` is nil.
    var resetsAt: Date?
    var onPreviousWeek: (() -> Void)?
    var onNextWeek: (() -> Void)?
    var canGoNext: Bool = false
    /// Past weeks omit the live "left today" footer.
    var showsLiveFooter: Bool = true

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
            periodUsedPercent: periodUsedPercent,
            periodStart: start,
            onPreviousWeek: onPreviousWeek,
            onNextWeek: onNextWeek,
            canGoNext: canGoNext,
            showsLiveFooter: showsLiveFooter
        )
    }
}

/// Shared stem chart + pace footer. Prefer `WeeklyDailyBudgetBarsView` or
/// `MonthlyDailyBudgetBarsView` at call sites.
struct DailyBudgetBarsView: View {
    let days: [DailyBudgetDay]
    var accent: Color
    var title: String = "Daily Budget"
    var allowancePeriod: DailyBudget.AllowancePeriod = .monthly
    /// What the equal daily share is drawn from, e.g. "monthly" or "weekly".
    var allowanceNoun: String = "monthly"
    /// Live used % for the same pool the bars pace against (API source of truth).
    var periodUsedPercent: Double?
    /// Next reset — paces the remainder against time left until reset.
    var resetsAt: Date?
    /// Start of the full quota period (subscription month or weekly window).
    var periodStart: Date?
    var onPreviousWeek: (() -> Void)?
    var onNextWeek: (() -> Void)?
    var canGoNext: Bool = false
    /// Past weeks omit pace and the "no usage yet" fallback.
    var showsLiveFooter: Bool = true

    private let trackHeight: CGFloat = PanelChartStem.height
    private static let stemWidth: CGFloat = PanelChartStem.width
    private static let barCornerRadius: CGFloat = PanelChartStem.cornerRadius

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
        // Weekly windows earn from visible bars when start is unknown;
        // monthly requires a subscription start. Today is an elapsed day so the
        // on-track allowance includes the current day's share.
        let elapsedDays: Int?
        if let start {
            elapsedDays = DailyBudget.elapsedDaysThroughToday(from: start)
        } else if allowancePeriod == .weekly {
            elapsedDays = nil
        } else {
            return nil
        }
        return DailyBudget.paceHeadroom(
            days: days,
            periodConsumed: periodUsedPercent,
            elapsedDaysInPeriod: elapsedDays,
            resetsAt: resetsAt
        )
    }

    private var footerCaption: String? {
        guard showsLiveFooter else { return nil }
        if let pace {
            return DailyBudget.paceCaption(pace)
        }
        // Fallback when no live used % was passed.
        if days.allSatisfy({ $0.spentUSD <= 0.001 }) {
            return String(format: "No usage yet · %.1f%%/day", dailyBudget)
        }
        if days.contains(where: {
            Calendar.current.isDate($0.date, inSameDayAs: Date()) && $0.isOverBudget
        }) {
            return "Over today's allowance"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                PanelSectionHeader(title: title)
                if dailyBudget > 0 {
                    Text(String(format: "%.1f%%", dailyBudget))
                        .font(PanelTypography.bodyDigit)
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 8)
                Text(rangeLabel)
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.primary)
            }

            if onPreviousWeek != nil || onNextWeek != nil {
                WeekChartNavigation(
                    onPreviousWeek: onPreviousWeek,
                    onNextWeek: onNextWeek,
                    canGoNext: canGoNext
                )
            }

            HStack(alignment: .bottom, spacing: 0) {
                ForEach(days) { day in
                    dayColumn(day)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: trackHeight + 42)

            if let footerCaption {
                Text(footerCaption)
                    .font(PanelTypography.metricLabel)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dayColumn(_ day: DailyBudgetDay) -> some View {
        // Full stem height = the day's allowance; fill = usage vs that allowance.
        let fraction = day.percentOfBudget / 100
        let fillHeight = max(6, trackHeight * CGFloat(fraction))
        let isFuture = day.date > Calendar.current.startOfDay(for: Date())
        let (weekday, _) = Self.formatters(for: day.date)

        return VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                // Track stays at full strength on every day; only the fill
                // fades on future days.
                Color.primary.opacity(0.12)

                if fraction > 0.005 && !isFuture {
                    // Prior-window history is dimmed: it belongs to the pool an
                    // early provider reset ended, not the one being paced.
                    accent
                        .opacity(day.isPriorWindow ? 0.45 : 1)
                        .frame(height: min(trackHeight, fillHeight))
                }
            }
            .frame(width: Self.stemWidth, height: trackHeight)
            .clipShape(RoundedRectangle(cornerRadius: Self.barCornerRadius, style: .continuous))
            .frame(maxWidth: .infinity)
            .help(dayHelp(day))

            VStack(spacing: 1) {
                Text("\(max(0, Int(day.spentUSD.rounded())))%")
                    .font(PanelTypography.microDigit)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(String(weekday.string(from: day.date).prefix(2)))
                    .font(PanelTypography.microDigit)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 32)
            .opacity(isFuture ? 0.5 : 1)
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
        if day.isPriorWindow {
            return String(format: "%@: %.1f%% of the %@ pool before the provider reset it early", dateStr, day.spentUSD, allowanceNoun)
        }
        if day.budgetUSD <= 0 { return "\(dateStr): no budget" }
        if day.spentUSD <= 0.001 { return String(format: "%@: used 0%% of %.1f%% allowance", dateStr, day.budgetUSD) }
        let ofAllowance = Int((day.spentUSD / day.budgetUSD * 100).rounded())
        return String(format: "%@: %.1f%% of %@, %d%% of daily allowance", dateStr, day.spentUSD, allowanceNoun, ofAllowance)
    }
}

/// Back and forward arrows shared by the SuperGrok daily chart and the other
/// providers' daily-budget bars.
struct WeekChartNavigation: View {
    var onPreviousWeek: (() -> Void)?
    var onNextWeek: (() -> Void)?
    var canGoNext: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            button(
                systemName: "chevron.left",
                action: onPreviousWeek,
                disabled: onPreviousWeek == nil
            )
            Spacer(minLength: 0)
            button(
                systemName: "chevron.right",
                action: onNextWeek,
                disabled: !canGoNext
            )
        }
    }

    private func button(
        systemName: String,
        action: (() -> Void)?,
        disabled: Bool
    ) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: systemName)
                .font(PanelTypography.captionSemibold)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.35) : Color.secondary)
        .disabled(disabled)
    }
}

/// Weekly or monthly daily-budget card with the same week arrows as SuperGrok.
///
/// `0` shows the current window and its live pace caption. Negative offsets
/// show earlier weeks of bars and drop the "left today" footer.
struct NavigableDailyBudgetCard: View {
    enum Style {
        case weekly
        case monthly
    }

    var style: Style
    var accent: Color
    var periodUsedPercent: Double?
    var periodStart: Date?
    var resetsAt: Date?
    var daysForWeek: (Int) -> [DailyBudgetDay]

    @State private var weekOffset = 0

    var body: some View {
        let days = daysForWeek(weekOffset)
        if !days.isEmpty {
            PanelCard {
                switch style {
                case .weekly:
                    WeeklyDailyBudgetBarsView(
                        days: days,
                        accent: accent,
                        periodUsedPercent: weekOffset == 0 ? periodUsedPercent : nil,
                        resetsAt: weekOffset == 0 ? resetsAt : nil,
                        onPreviousWeek: { weekOffset = WeekOffset.previous(weekOffset) },
                        onNextWeek: { weekOffset = WeekOffset.next(weekOffset) },
                        canGoNext: WeekOffset.canGoNext(weekOffset),
                        showsLiveFooter: weekOffset == 0
                    )
                case .monthly:
                    MonthlyDailyBudgetBarsView(
                        days: days,
                        accent: accent,
                        periodUsedPercent: weekOffset == 0 ? periodUsedPercent : nil,
                        periodStart: weekOffset == 0 ? periodStart : nil,
                        resetsAt: weekOffset == 0 ? resetsAt : nil,
                        onPreviousWeek: { weekOffset = WeekOffset.previous(weekOffset) },
                        onNextWeek: { weekOffset = WeekOffset.next(weekOffset) },
                        canGoNext: WeekOffset.canGoNext(weekOffset),
                        showsLiveFooter: weekOffset == 0
                    )
                }
            }
        }
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
        accent: ProviderColors.claudeColor,
        periodUsedPercent: 40
    )
    .padding()
    .frame(width: 360)
}
#endif
