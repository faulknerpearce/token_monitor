import SwiftUI

private struct UpdateCheckerKey: EnvironmentKey {
    static let defaultValue: UpdateChecker? = nil
}

extension EnvironmentValues {
    /// The app's update checker, read by `UpdateAvailableIndicator`.
    var updateChecker: UpdateChecker? {
        get { self[UpdateCheckerKey.self] }
        set { self[UpdateCheckerKey.self] = newValue }
    }
}

/// One-line "update available" row for the menu-bar panel. Shows nothing
/// until the environment's update checker has found a newer release.
struct UpdateAvailableIndicator: View {
    @Environment(\.updateChecker) private var checker

    var body: some View {
        if let checker {
            UpdateAvailableRow(checker: checker)
        }
    }
}

private struct UpdateAvailableRow: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        if let release = checker.availableRelease {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    Task { await checker.performPrimaryAction() }
                } label: {
                    Label(
                        checker.isInstalling
                            ? "Installing TokenMon \(release.version.description)…"
                            : "TokenMon \(release.version.description) is available",
                        systemImage: "arrow.down.circle"
                    )
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(!checker.canAct)
                .help("Download, verify, and install the update")

                if let statusMessage = checker.statusMessage {
                    Text(statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 10)
        }
    }
}
