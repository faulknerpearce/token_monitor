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
    var periodUsedPercent: Double? = nil

    private let trackHeight: CGFloat = PanelChartStem.height
    private static let stemWidth: CGFloat = PanelChartStem.width
    private static let barCornerRadius: CGFloat = PanelChartStem.cornerRadius
    private static let bankEpsilon = 0.05

    private var pace: DailyBudget.PaceHeadroom? {
        guard let periodUsedPercent else { return nil }
        let days = week.displayDays.map {
            DailyBudgetDay(
                date: $0.dayStart,
                spentUSD: $0.totalPercent,
                budgetUSD: DailyUsageBuilder.dailyCapPercent
            )
        }
        return DailyBudget.paceHeadroom(days: days, periodConsumed: periodUsedPercent)
    }

    private var footerCaption: String? {
        if let pace, let caption = paceCaption(pace) {
            return caption
        }
        if week.isEstimated || !week.hasDailyData {
            return "Daily bars only show changes between samples. Week totals are above."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                PanelSectionHeader(title: "Daily Budget \(Int(DailyUsageBuilder.dailyCapPercent.rounded()))%")
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .help("Share of weekly allowance per day (budget 14.3%/day).")
                Spacer(minLength: 8)
                PanelPill(text: week.rangeLabel)
            }

            HStack(spacing: 8) {
                weekNavButton(systemName: "chevron.left", action: onPreviousWeek)
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

    private func paceCaption(_ pace: DailyBudget.PaceHeadroom) -> String? {
        if pace.periodConsumed <= 0.001 {
            if pace.earnedThroughToday > pace.dailyBudget + Self.bankEpsilon {
                return String(
                    format: "No usage yet. Up to %.1f%% available today from unused earlier days.",
                    pace.headroomToday
                )
            }
            return String(format: "No usage yet. Budget is %.1f%% per day.", pace.dailyBudget)
        }
        if pace.headroomToday < 0 {
            return String(
                format: "Above even pace. Used %.0f%% with only %.1f%% available through today.",
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
        return nil
    }

    private func dayColumn(_ day: DailyUsageDay) -> some View {
        let fraction = Self.fillFraction(forDayUsage: day.totalPercent)
        let fillHeight = max(6, trackHeight * CGFloat(fraction))

        return VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                Color.primary.opacity(0.12)

                if fraction > 0 {
                    ConcentricUsageRingView.grokColor
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
                Text(day.totalPercent > 0.5 ? "\(Int(day.totalPercent.rounded()))%" : " ")
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
