import AppKit
import SwiftUI

/// Card container: rounded 12pt, filled + stroke, 12pt interior padding.
/// Used for provider sections.
struct PanelCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 10) {
        PanelCard {
            HStack {
                PanelSectionHeader(title: "Weekly Usage")
                Spacer()
                Text("42% Used")
                    .font(PanelTypography.bodyDigit)
                    .foregroundStyle(.primary)
            }
            RoundedRectangle(cornerRadius: 2).fill(.blue).frame(height: 8)
            Text("Resets Sun 24 August 12:00am")
                .font(PanelTypography.caption)
                .foregroundStyle(.tertiary)
        }
        PanelCard {
            PanelSectionHeader(title: "Categories")
            HStack(spacing: 12) {
                Text("Chat 22%").font(PanelTypography.body)
                Text("Code 12%").font(PanelTypography.body)
                Text("Voice 8%").font(PanelTypography.body)
            }
        }
    }
    .padding()
    .frame(width: 380)
}
#endif
