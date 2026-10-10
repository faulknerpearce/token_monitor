import SwiftUI

/// Caption under provider data that a later refresh failed to update: the
/// failure, and how old the data on screen is.
struct StaleDataCaption: View {
    let message: String
    let lastRefreshedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message)
            if let lastRefreshedAt {
                Text("Showing data from \(lastRefreshedAt, style: .relative) ago.")
            }
        }
        .font(PanelTypography.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
