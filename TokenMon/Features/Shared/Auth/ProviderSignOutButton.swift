import SwiftUI

/// "Sign out" affordance for signed-in provider surfaces.
///
/// Renders as a full-width, right-aligned row: a tertiary icon that swaps to an
/// inline confirm/cancel pair when pressed. `action` runs only after the user
/// confirms.
///
/// - Parameters:
///   - provider: Provider whose session this button ends; names the confirm prompt.
///   - action: Invoked after the user confirms; typically `auth.signOut()` plus
///     `poller.clearSnapshot()`.
struct ProviderSignOutButton: View {
    let provider: MonitorProvider
    let action: () -> Void

    @State private var isConfirming = false

    var body: some View {
        HStack(spacing: 6) {
            Spacer()
            if isConfirming {
                confirmControls
            } else {
                signOutIcon
            }
        }
    }

    private var signOutIcon: some View {
        Button {
            isConfirming = true
        } label: {
            Image(systemName: "person.crop.circle.badge.minus")
                .font(PanelTypography.caption)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sign out")
        .accessibilityLabel("Sign out")
    }

    @ViewBuilder
    private var confirmControls: some View {
        Text("Sign out of \(provider.displayName)?")
            .font(PanelTypography.caption)
            .foregroundStyle(.secondary)

        Button {
            isConfirming = false
            action()
        } label: {
            Image(systemName: "checkmark.circle.fill")
                .font(PanelTypography.caption)
                .foregroundStyle(.red)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Confirm sign out")
        .accessibilityLabel("Confirm sign out")

        Button {
            isConfirming = false
        } label: {
            Image(systemName: "xmark.circle")
                .font(PanelTypography.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Cancel")
        .accessibilityLabel("Cancel")
    }
}
