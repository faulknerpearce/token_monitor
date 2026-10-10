import SwiftUI

/// Usage bar for one `OpenCodeWindowUsage` with its reset caption.
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
            caption: caption
        )
    }

    private var caption: String? {
        if let resetsAt = window.resetsAt {
            return resetLabel(for: resetsAt)
        }
        // The local rolling window has a reset clock only once a Go session lands
        // in the last 5h; until then the caption says there is no recent usage.
        if window.kind == .rolling5h, window.usedPercent <= 0 {
            return "No usage in last 5h"
        }
        return nil
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
