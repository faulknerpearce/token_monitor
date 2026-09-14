import SwiftUI

struct OpenCodeLimitBar: View {
    let window: OpenCodeWindowUsage

    private var fill: Color {
        switch window.kind {
        case .rolling5h: return ModelPalette.orange.color
        case .weekly, .monthly: return ModelPalette.purple.color
        }
    }

    var body: some View {
        SlimUsageTrack(
            label: window.kind.label,
            percent: window.usedPercent,
            color: fill,
            caption: window.resetsAt.map { resetLabel(for: $0) }
        )
    }

    private func resetLabel(for date: Date) -> String {
        switch window.kind {
        case .rolling5h:
            return "Resets \(date.formatted(.relative(presentation: .named)))"
        case .weekly:
            return Format.resetCaption(date, dateFormat: "EEE h:mma")
        case .monthly:
            return Format.resetCaption(date)
        }
    }
}
