import SwiftUI

/// Daily-budget bar chart styled exactly like the Grok daily-use chart.
///
/// 7 vertical stems (one per calendar day). Each stem's full height is that day's
/// budget — an even share of the allowance (`100% / daysInPeriod`, weekly ≈14.3% or
/// monthly ≈3.2%). The fill shows how much of that day's allowance was actually used.
/// Hover the ⓘ icon for what the bars count toward, and hover a bar for its exact %.
struct DailyBudgetBarsView: View {
    let days: [DailyBudgetDay]
    var accent: Color
    var title: String = "Daily Budget"
    /// What the equal daily share is drawn from, e.g. "monthly" or "weekly".
    var allowanceNoun: String = "monthly"
    /// Optional longer explanation shown as an info tooltip next to the header.
    var infoText: String?

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

            if days.allSatisfy({ $0.spentUSD <= 0.001 }) {
                Text(String(format: "No usage this period yet — daily budget is %.1f%% of your %@ allowance.", dailyBudget, allowanceNoun))
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            } else if days.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: Date()) && $0.spentUSD > $0.budgetUSD }) {
                Text("Over daily allowance — pace is above even spend.")
                    .font(PanelTypography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
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
#Preview {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let days: [DailyBudgetDay] = (0..<7).map { offset in
        let date = calendar.date(byAdding: .day, value: offset - 6, to: today)!
        let spent: Double = [1.2, 0, 4.1, 2.8, 0.5, 3.6, 1.0][offset]
        return DailyBudgetDay(date: date, spentUSD: spent, budgetUSD: 3.3)
    }
    return DailyBudgetBarsView(days: days, accent: ModelPalette.purple.color)
        .padding()
        .frame(width: 360)
}
#endif
