import SwiftUI

/// Settings → Usage style “Daily use” bar chart for the **billing period** week.
///
/// Each day’s track is an equal share of the weekly pool (`100/7`).
/// Grey stem is the daily cap; Grok blue is how much of that cap was used.
/// Footer pacing uses the pulled weekly used % when provided.
struct DailyUsageChartView: View {
    let week: DailyUsageWeek
    var onPreviousWeek: (() -> Void)?
    var onNextWeek: (() -> Void)?
    var canGoNext: Bool = true
    /// Live weekly used % for the current period (omit for past weeks).
    var periodUsedPercent: Double?
    /// Pool reset instant — paces the remainder against time left until reset.
    var resetsAt: Date?

    private let trackHeight: CGFloat = PanelChartStem.height
    private static let stemWidth: CGFloat = PanelChartStem.width
    private static let barCornerRadius: CGFloat = PanelChartStem.cornerRadius

    private var pace: DailyBudget.PaceHeadroom? {
        guard let periodUsedPercent else { return nil }
        let days = week.displayDays.map {
            DailyBudgetDay(
                date: $0.dayStart,
                spentUSD: $0.totalPercent,
                budgetUSD: DailyUsageBuilder.dailyCapPercent
            )
        }
        // Billing-period week already spans the full SuperGrok pool window.
        // Credit days elapsed through today so the on-track allowance includes today.
        let elapsed = DailyBudget.elapsedDaysThroughToday(from: week.weekStart)
        return DailyBudget.paceHeadroom(
            days: days,
            periodConsumed: periodUsedPercent,
            elapsedDaysInPeriod: elapsed,
            resetsAt: resetsAt
        )
    }

    private var footerCaption: String? {
        if let pace, let caption = DailyBudget.paceCaption(pace) {
            return caption
        }
        if week.isEstimated || !week.hasDailyData {
            return "Bars update between polls · week totals above"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                PanelSectionHeader(title: "Daily Budget \(String(format: "%.1f%%", DailyUsageBuilder.dailyCapPercent))")
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .help(String(
                        format: "Share of weekly allowance per day (budget %.1f%%/day).",
                        DailyUsageBuilder.dailyCapPercent
                    ))
                Spacer(minLength: 8)
                PanelPill(text: week.rangeLabel)
            }

            HStack(spacing: 8) {
                weekNavButton(
                    systemName: "chevron.left",
                    action: onPreviousWeek,
                    disabled: onPreviousWeek == nil
                )
                Spacer(minLength: 0)
                weekNavButton(
                    systemName: "chevron.right",
                    action: onNextWeek,
                    disabled: !canGoNext
                )
            }

            HStack(alignment: .bottom, spacing: 0) {
                ForEach(week.displayDays) { day in
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

    private func dayColumn(_ day: DailyUsageDay) -> some View {
        let fraction = Self.fillFraction(forDayUsage: day.totalPercent)
        let fillHeight = max(6, trackHeight * CGFloat(fraction))

        return VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                Color.primary.opacity(0.12)

                if fraction > 0 {
                    ProviderColors.grokColor
                        .frame(height: min(trackHeight, fillHeight))
                }
            }
            .frame(width: Self.stemWidth, height: trackHeight)
            .clipShape(RoundedRectangle(cornerRadius: Self.barCornerRadius, style: .continuous))
            .frame(maxWidth: .infinity)
            .help(
                day.totalPercent > 0.05
                    ? String(format: "%.0f%% of weekly pool", day.totalPercent)
                    : ""
            )

            VStack(spacing: 1) {
                Text("\(max(0, Int(day.totalPercent.rounded())))%")
                    .font(PanelTypography.micro)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(String(day.weekdaySymbol.prefix(2)))
                    .font(PanelTypography.micro)
                    .foregroundStyle(.tertiary)
            }
            .frame(height: 26)
        }
        .frame(maxWidth: .infinity)
    }

    private func weekNavButton(
        systemName: String,
        action: (() -> Void)?,
        disabled: Bool = false
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

    /// Maps weekly-pool percent into track height using the equal daily cap (`100/7`).
    static func fillFraction(forDayUsage percent: Double) -> Double {
        DailyUsageBuilder.fillFraction(forDayUsage: percent)
    }
}

#if DEBUG
#Preview {
    DailyUsageChartView(week: DailyUsageBuilder.preview(), periodUsedPercent: 12)
        .padding()
        .frame(width: 340)
}
#endif
